import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/preferences.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'atlas.dart';
import 'atlas_card.dart';
import 'atlas_grid.dart';
import 'atlas_store.dart';
import 'atlas_widgets.dart';

const _searchLimit = 8;
const _searchMin = 2;
final _hex = RegExp(r'^[0-9a-f]+$');

/// What the search box means for the field picked. Null params: nothing to ask yet.
({String? hint, Json? params}) atlasSearch(String field, String text) {
  final typed = text.trim();
  if (typed.isEmpty) return (hint: null, params: null);
  if (typed.length < _searchMin) return (hint: 'searchTooShort', params: null);
  if (field != 'pubkey') return (hint: null, params: {'name': typed});
  // The server rejects a non-hex prefix, so it is never sent.
  final prefix = typed.toLowerCase();
  return _hex.hasMatch(prefix)
      ? (hint: null, params: {'pubkeyPrefix': prefix})
      : (hint: 'searchNotHex', params: null);
}

/// Pinned node and observer cards. Global by design: pins are radio
/// identities, so the header region picker does not apply here.
class AtlasScreen extends StatefulWidget {
  const AtlasScreen({
    super.key,
    required this.api,
    required this.preferences,
    required this.onOpen,
    this.clock = DateTime.now,
  });
  final ApiClient api;
  final Preferences preferences;
  final void Function(String kind, String id) onOpen;
  final DateTime Function() clock;
  @override
  State<AtlasScreen> createState() => _AtlasScreenState();
}

class _AtlasScreenState extends State<AtlasScreen> with WidgetsBindingObserver {
  late final AtlasStore store;
  late final Timer ticker;
  final search = TextEditingController();
  Timer? debounce;
  String field = 'name', typed = '';
  // One card at a time is away from the view it opens on.
  ({String key, AtlasView view})? open;
  bool resumed = true;
  late int now = widget.clock().millisecondsSinceEpoch;

  int searchRun = 0;
  bool searching = false, searchFailed = false, hasMore = false;
  List<Json>? matches;
  bool adding = false, addFailed = false;

  SavedAtlas get saved => store.saved;

  @override
  void initState() {
    super.initState();
    store = AtlasStore(widget.preferences, widget.preferences.active!.url)
      ..addListener(changed);
    ticker = Timer.periodic(atlasRefresh, (_) {
      if (mounted) {
        setState(() => now = widget.clock().millisecondsSinceEpoch);
      }
    });
    WidgetsBinding.instance.addObserver(this);
  }

  void changed() {
    if (!mounted) return;
    // An import replaced the cards, so no card is away from its home view.
    if (open != null && !saved.pins.any((pin) => pin.key == open!.key)) {
      open = null;
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final next = state == AppLifecycleState.resumed;
    if (next != resumed && mounted) setState(() => resumed = next);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ticker.cancel();
    debounce?.cancel();
    search.dispose();
    store
      ..removeListener(changed)
      ..dispose();
    super.dispose();
  }

  AtlasView viewOf(AtlasPin pin) =>
      open?.key == pin.key ? open!.view : pin.homeView;
  void setView(AtlasPin pin, AtlasView view) => setState(
    () => open = view == pin.homeView ? null : (key: pin.key, view: view),
  );

  void typing(String value) {
    debounce?.cancel();
    // Clearing restores the page right away.
    if (value.isEmpty) {
      runSearch('');
      return;
    }
    setState(() {});
    debounce = Timer(
      const Duration(milliseconds: 300),
      () => runSearch(search.text),
    );
  }

  // Switching the field changes what the box means, so stale text must not carry over.
  void changeField(String value) {
    search.clear();
    debounce?.cancel();
    setState(() => field = value);
    runSearch('');
  }

  Future<void> runSearch(String text) async {
    final run = ++searchRun;
    final query = atlasSearch(field, text);
    final params = field == 'observer' && query.hint == null
        ? (text.trim().isEmpty ? null : {'name': text.trim()})
        : query.params;
    setState(() {
      typed = text.trim();
      // A failed add is about the search it came from; a new search clears it.
      addFailed = false;
      matches = null;
      searchFailed = hasMore = false;
      searching = params != null;
    });
    if (params == null) return;
    try {
      final page = await widget.api.getCached(
        field == 'observer' ? '/observers/directory' : '/nodes',
        {...params, 'limit': _searchLimit},
      );
      if (!mounted || run != searchRun) return;
      setState(() {
        searching = false;
        matches = rows(page);
        hasMore = object(page)['hasMore'] == true;
      });
    } catch (_) {
      if (!mounted || run != searchRun) return;
      setState(() {
        searching = false;
        searchFailed = true;
      });
    }
  }

  void add(Json node) => store.update(
    (value) => value.appended(
      AtlasPin.node(
        id: textOf(node['id']),
        publicKey: textOf(node['publicKey']),
        name: textOf(node['name']),
        observerId: _id(node['observerId']),
      ),
    ),
  );

  String? _id(dynamic value) => textOf(value).isEmpty ? null : textOf(value);

  // An observer whose radio advertises is saved as that node; if the node is
  // pinned already, it just gains the link, so the result reads Saved.
  Future<void> addObserver(Json row) async {
    setState(() {
      adding = true;
      addFailed = false;
    });
    final id = textOf(row['id']), name = textOf(row['displayName']);
    try {
      final observer = object(await widget.api.getCached('/observers/$id'));
      final match = await resolveObserverNode(widget.api, observer);
      if (!mounted) return;
      if (match == null) {
        store.update(
          (value) =>
              value.appended(AtlasPin.observer(observerId: id, name: name)),
        );
      } else {
        final key = textOf(match['publicKey']).toLowerCase();
        store.update(
          (value) => value.pins.any((pin) => pin.isNode && pin.publicKey == key)
              ? value.copyWith(
                  pins: [
                    for (final pin in value.pins)
                      pin.isNode && pin.publicKey == key
                          ? pin.relinked(pin.id!, id)
                          : pin,
                  ],
                )
              : value.appended(
                  AtlasPin.node(
                    id: textOf(match['id']),
                    publicKey: key,
                    name: textOf(match['name'], name),
                    observerId: id,
                  ),
                ),
        );
      }
      setState(() => adding = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          adding = false;
          addFailed = true;
        });
      }
    }
  }

  void replace(AtlasPin pin, AtlasPin Function(AtlasPin) change) =>
      store.update(
        (value) => value.copyWith(
          pins: [
            for (final other in value.pins)
              other.key == pin.key ? change(other) : other,
          ],
        ),
      );

  void remove(AtlasPin pin) => store.update(
    (value) => value.copyWith(
      pins: [
        for (final other in value.pins)
          if (other.key != pin.key) other,
      ],
    ),
  );

  void pinView(AtlasPin pin, AtlasView view) {
    replace(pin, (other) => other.isNode ? other.withView(view) : other);
    if (open?.key == pin.key) setState(() => open = null);
  }

  // An observer pin whose key now resolves to a node takes that node's place
  // in its own slot, and keeps opening on the Observer view it had.
  void upgrade(AtlasPin pin, Json match, String observerId) =>
      store.update((value) {
        final key = textOf(match['publicKey']).toLowerCase();
        final tiles = value.pins
            .where((other) => other.key == pin.key)
            .firstOrNull
            ?.tiles;
        // Already pinned as a node: that pin takes the observer link, as an Add
        // from search does, and the observer pin's tiles unless it has its own.
        if (value.pins.any((other) => other.isNode && other.publicKey == key)) {
          return value.copyWith(
            pins: [
              for (final other in value.pins)
                if (other.key != pin.key)
                  other.isNode && other.publicKey == key
                      ? AtlasPin.node(
                          id: other.id!,
                          publicKey: key,
                          name: other.name,
                          observerId: observerId,
                          tiles: other.tiles ?? tiles,
                          view: other.view,
                        )
                      : other,
            ],
          );
        }
        return value.copyWith(
          pins: [
            for (final other in value.pins)
              other.key == pin.key
                  ? AtlasPin.node(
                      id: textOf(match['id']),
                      publicKey: key,
                      name: textOf(match['name']).isEmpty
                          ? pin.name
                          : textOf(match['name']),
                      observerId: observerId,
                      tiles: tiles,
                      view: AtlasView.observer,
                    )
                  : other,
          ],
        );
      });

  void reorder(int from, int to) => store.update((value) {
    if (from < 0 || from >= value.pins.length) return value;
    if (to < 0 || to >= value.pins.length) return value;
    final pins = [...value.pins];
    pins.insert(to, pins.removeAt(from));
    return value.copyWith(pins: pins);
  });

  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    final full = saved.pins.length >= atlasLimit;
    // A detail screen pushed over the tab pauses the polling, as leaving the tab does.
    final active = resumed && (ModalRoute.of(context)?.isCurrent ?? true);
    final hint = field == 'observer'
        ? (typed.isNotEmpty && typed.length < _searchMin
              ? 'searchTooShort'
              : null)
        : atlasSearch(field, typed).hint;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: c.base,
            border: Border(bottom: BorderSide(color: c.borderSubtle)),
          ),
          child: Row(
            children: [
              Expanded(
                child: _SearchBar(
                  controller: search,
                  field: field,
                  onField: changeField,
                  onChanged: typing,
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: at('localOnly'),
                triggerMode: TooltipTriggerMode.tap,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: full ? c.warning.withValues(alpha: .07) : c.surface,
                    border: Border.all(
                      color: full ? c.warning.withValues(alpha: .15) : c.border,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    at(
                      'savedCountShort',
                      args: {'count': saved.pins.length, 'limit': atlasLimit},
                    ),
                    style: atlasMono(11, full ? c.warning : c.muted),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AtlasSegmented<AtlasRange>(
                label: at('range'),
                value: saved.range,
                onChanged: (range) =>
                    store.update((value) => value.copyWith(range: range)),
                options: {
                  for (final range in AtlasRange.values)
                    range: at('ranges.${range.id}'),
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1568),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (store.storageFailed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Text(
                          at('storageFailed'),
                          style: atlasMono(11, c.warning),
                        ),
                      ),
                    if (typed.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: AtlasPanel(
                          title: Text(at('matches').toUpperCase()),
                          child: _matches(c, hint, full),
                        ),
                      ),
                    if (saved.pins.isEmpty)
                      AtlasEmpty(
                        title: at('emptyTitle'),
                        subtitle: at(
                          'emptyDescription',
                          args: {'limit': atlasLimit},
                        ),
                      )
                    else
                      AtlasGrid(
                        keys: [for (final pin in saved.pins) pin.key],
                        onReorder: reorder,
                        itemBuilder: (context, index, handle) {
                          final pin = saved.pins[index];
                          return AtlasCard(
                            api: widget.api,
                            pin: pin,
                            range: saved.range,
                            active: active,
                            now: now,
                            view: viewOf(pin),
                            onViewChange: (view) => setView(pin, view),
                            onPinView: (view) => pinView(pin, view),
                            onRemove: () => remove(pin),
                            onResolved: (id, observerId) => replace(
                              pin,
                              (other) => other.isNode
                                  ? other.relinked(id, observerId)
                                  : other,
                            ),
                            onUpgrade: (match, observerId) =>
                                upgrade(pin, match, observerId),
                            onTilesChange: (tiles) =>
                                replace(pin, (other) => other.withTiles(tiles)),
                            onOpen: widget.onOpen,
                            handle: handle,
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _matches(BeaconColors c, String? hint, bool full) {
    final small = atlasMono(12, c.muted);
    Widget note(String text, {Color? color}) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(text, style: small.copyWith(color: color)),
    );
    Widget add(bool pinned, String label, VoidCallback onPressed, bool busy) =>
        AtlasAction(
          at(pinned ? 'saved' : 'add'),
          semantics: at(
            pinned ? 'savedName' : 'addName',
            args: {'name': label},
          ),
          onPressed: pinned || full || busy ? null : onPressed,
        );
    Widget row(int index, List<Widget> lead, Widget action) => Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: index == 0
            ? null
            : Border(top: BorderSide(color: c.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: lead,
            ),
          ),
          const SizedBox(width: 8),
          action,
        ],
      ),
    );
    Widget name(String? value, String fallback) => Text(
      value ?? fallback,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: value == null
          ? atlasMono(12, c.dim).copyWith(fontStyle: FontStyle.italic)
          : atlasMono(12, c.bright),
    );
    final items = matches;
    final List<Widget> body;
    if (hint != null) {
      body = [
        Text(at(hint, args: {'min': _searchMin}), style: small),
      ];
    } else if (searchFailed) {
      body = [
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(tr('Failed to load'), style: small.copyWith(color: c.danger)),
            AtlasAction(tr('Retry'), onPressed: () => runSearch(search.text)),
          ],
        ),
      ];
    } else if (searching || items == null) {
      body = [Text(tr('Loading…'), style: small)];
    } else if (items.isEmpty) {
      body = [Text(tr('No matches'), style: small)];
    } else if (field != 'observer') {
      body = [
        for (final (i, node) in items.indexed)
          row(
            i,
            [
              name(_id(node['name']), formatHex(textOf(node['id']))),
              if (textOf(node['nodeTypeName']).isNotEmpty)
                AtlasBadge(textOf(node['nodeTypeName'])),
              if (node['isObserver'] == true) AtlasBadge(at('observerBadge')),
              Tooltip(
                message: textOf(node['publicKey']),
                triggerMode: TooltipTriggerMode.tap,
                child: Text(
                  formatHex(textOf(node['publicKey'])),
                  style: atlasMono(12, c.dim),
                ),
              ),
            ],
            add(
              saved.pins.any(
                (pin) =>
                    pin.isNode &&
                    pin.publicKey == textOf(node['publicKey']).toLowerCase(),
              ),
              _id(node['name']) ?? formatHex(textOf(node['id'])),
              () => this.add(node),
              false,
            ),
          ),
      ];
    } else {
      final clock = DateTime.now().millisecondsSinceEpoch;
      body = [
        for (final (i, observer) in items.indexed)
          row(
            i,
            [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: observerStatus(observer, clock) == 'online'
                      ? c.success
                      : c.dim.withValues(alpha: .3),
                ),
              ),
              name(_id(observer['displayName']), shortKey(observer['id'])),
              if (textOf(observer['observerType']).isNotEmpty)
                AtlasBadge(textOf(observer['observerType'])),
            ],
            add(
              saved.pins.any((pin) => pin.observerId == observer['id']),
              _id(observer['displayName']) ?? shortKey(observer['id']),
              () => addObserver(observer),
              adding,
            ),
          ),
      ];
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ...body,
        if (addFailed) note(tr('Failed to load'), color: c.danger),
        if (hasMore && hint == null)
          note(at('refine', args: {'limit': _searchLimit})),
        if (full && hint == null)
          note(
            at('limitReached', args: {'limit': atlasLimit}),
            color: c.warning,
          ),
      ],
    );
  }
}

/// Field picker joined to a search input, as the web's toolbar search.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.field,
    required this.onField,
    required this.onChanged,
  });
  final TextEditingController controller;
  final String field;
  final ValueChanged<String> onField, onChanged;
  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    final fields = {
      'name': tr('Name'),
      'pubkey': tr('Public Key'),
      'observer': at('fieldObserver'),
    };
    const height = 30.0;
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MenuAnchor(
            menuChildren: [
              for (final MapEntry(:key, :value) in fields.entries)
                MenuItemButton(
                  onPressed: () => onField(key),
                  style: MenuItemButton.styleFrom(
                    minimumSize: const Size(128, 36),
                    textStyle: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                    ),
                    foregroundColor: key == field ? c.bright : c.muted,
                    backgroundColor: key == field
                        ? c.primary.withValues(alpha: .1)
                        : null,
                  ),
                  child: Text(value),
                ),
            ],
            builder: (context, menu, _) => InkWell(
              key: const ValueKey('atlas-search-field'),
              onTap: () => menu.isOpen ? menu.close() : menu.open(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border(
                    top: BorderSide(color: c.border),
                    left: BorderSide(color: c.border),
                    bottom: BorderSide(color: c.border),
                  ),
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(2),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(fields[field]!, style: atlasMono(11, c.muted)),
                    const SizedBox(width: 5),
                    AtlasCaret(color: c.dim),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.border),
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(2),
                ),
              ),
              // Stacked, not a row: a cramped toolbar squeezes the text, never overflows.
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Positioned(
                    left: 8,
                    child: Icon(Icons.search, size: 13, color: c.dim),
                  ),
                  TextField(
                    key: const ValueKey('atlas-search'),
                    controller: controller,
                    onChanged: onChanged,
                    // Otherwise the keyboard reopens on coming back from another screen.
                    onTapOutside: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.search,
                    style: atlasMono(11, c.bright),
                    cursorHeight: 14,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      contentPadding: const EdgeInsets.only(
                        left: 27,
                        right: 26,
                      ),
                      hintText: at('search'),
                      hintStyle: atlasMono(11, c.dim),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) => controller.text.isEmpty
                          ? const SizedBox()
                          : InkWell(
                              onTap: () {
                                controller.clear();
                                FocusManager.instance.primaryFocus?.unfocus();
                                onChanged('');
                              },
                              child: Container(
                                width: 26,
                                alignment: Alignment.center,
                                child: Text('×', style: atlasMono(13, c.dim)),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
