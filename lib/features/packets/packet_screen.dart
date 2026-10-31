import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'filter_dropdown.dart';
import 'packet_expansion.dart';
import 'packet_model.dart';

class PacketScreen extends StatefulWidget {
  const PacketScreen({
    super.key,
    required this.api,
    required this.region,
    required this.onOpen,
    this.events,
  });
  final ApiClient api;
  final Map<String, dynamic> region;
  final void Function(String, String) onOpen;
  final Stream<Json>? events;
  @override
  State<PacketScreen> createState() => _PacketScreenState();
}

class _PacketScreenState extends State<PacketScreen> {
  final buffer = PacketBuffer();
  List<Json> get packets => buffer.packets;
  final ScrollController scroll = ScrollController();
  final TextEditingController search = TextEditingController();
  StreamSubscription<Json>? sub;
  Timer? clock;
  Timer? refreshTimer;
  Timer? searchDebounce;
  String? hashPrefix;
  bool loading = false, hasMore = true;
  Map<String, Object>? nextPage;
  String? error;
  String mode = 'Hash';
  Set<int> types = {};
  Set<int> routes = {};
  Set<String> selectedScopes = {};
  Set<String> selectedObservers = {};
  final Map<String, Set<String>> observersByHash = {};
  final Map<String, String> observerNames = {};
  String? expandedHash;
  bool refreshPending = false;
  List<String> scopes = [];
  List<Json> pending = [];
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load();
    listen();
    clock = Timer.periodic(const Duration(seconds: 5), (_) {
      final retained = {
        ...packets.map((p) => textOf(p['packetHash'])),
        ...pending.map((p) => textOf(p['packetHash'])),
      };
      observersByHash.removeWhere((key, _) => !retained.contains(key));
      if (mounted) setState(() {});
    });
  }

  void listen() {
    sub = widget.events?.listen((event) {
      if (event['type'] == 'refresh') {
        refreshTimer ??= Timer(const Duration(milliseconds: 500), () {
          refreshTimer = null;
          if (loading) {
            refreshPending = true;
          } else {
            load();
          }
        });
        return;
      }
      if (event['event'] != 'packetObservation') return;
      final data = object(event['data']);
      final observation = object(data['observation']);
      final areas = textOf(widget.region['iatas']);
      if (widget.region['iatas'] == '' ||
          (widget.region['region'] != null && widget.region['iatas'] == null) ||
          (areas.isNotEmpty &&
              !areas.split(',').contains(textOf(observation['iata'])))) {
        return;
      }
      final id = textOf(observation['observerId']);
      if (id.isNotEmpty) {
        observersByHash
            .putIfAbsent(textOf(data['packetHash']), () => {})
            .add(id);
        observerNames[id] = textOf(observation['observerName'], shortKey(id));
      }

      if (expandedHash != null || (scroll.hasClients && scroll.offset > 100)) {
        pending = mergePacketEvent(pending, data);
        if (pending.length > 500) pending = pending.take(500).toList();
      } else {
        buffer.addEvent(data);
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant PacketScreen old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api ||
        jsonEncode(old.region) != jsonEncode(widget.region)) {
      ++generation;
      buffer.clear();
      observersByHash.clear();
      observerNames.clear();
      scopes = [];
      expandedHash = null;
      refreshPending = false;
      pending = [];
      nextPage = null;
      loading = false;
      load();
    }
    if (old.events != widget.events) {
      sub?.cancel();
      listen();
    }
  }

  @override
  void dispose() {
    ++generation;
    sub?.cancel();
    clock?.cancel();
    refreshTimer?.cancel();
    searchDebounce?.cancel();
    scroll.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> load({bool older = false}) async {
    if (loading) return;
    if (widget.region['iatas'] == '' ||
        (widget.region['region'] != null && widget.region['iatas'] == null)) {
      setState(() {
        buffer.clear();
        hasMore = false;
      });
      return;
    }
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final params = {
        ...widget.region,
        'limit': 100,
        if (types.isNotEmpty) 'payloadTypes': types.join(','),
        if (routes.isNotEmpty) 'routeTypes': routes.join(','),
        if (selectedScopes.isNotEmpty) 'scopes': selectedScopes.join(','),
        if (hashPrefix != null) 'hashPrefix': hashPrefix,
        if (older) ...?nextPage,
      };
      // Waits out a busy server with the same params; loaded rows stay.
      final response = object(
        await withPageCursorFallback(
          params,
          (p) => (older ? widget.api.getCached : widget.api.get)(
            '/packets',
            p,
            () => mounted && request == generation,
          ),
          isCurrent: () => mounted && request == generation,
        ),
      );
      if (!mounted || request != generation) return;
      setState(() {
        buffer.addHistory(rows(response));
        for (final packet in rows(response)) {
          final observer = object(packet['latestObserver']);
          final id = textOf(observer['id']);
          if (id.isNotEmpty) {
            observerNames[id] = textOf(observer['displayName'], shortKey(id));
            observersByHash
                .putIfAbsent(textOf(packet['packetHash']), () => {})
                .add(id);
          }
        }
        if (older || nextPage?.isNotEmpty != true) {
          nextPage = nextPageParams(response);
          // Like web, no usable cursor means no older page.
          hasMore = nextPage!.isNotEmpty;
        }
      });
    } catch (e) {
      if (mounted && request == generation) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted && request == generation) {
        setState(() => loading = false);
        if (refreshPending) {
          refreshPending = false;
          unawaited(load());
        }
      }
    }
  }

  List<Json> get visible => packets
      .where(
        (p) => matchesPacketFilters(
          p,
          payloadTypes: types,
          routeTypes: routes,
          observers: selectedObservers,
          scopes: selectedScopes,
          search: search.text,
          searchField: mode,
          observersByHash: observersByHash,
        ),
      )
      .toList();
  void filtersChanged() {
    ++generation;
    buffer.clearHistory();
    expandedHash = null;
    refreshPending = false;
    pending = [];
    nextPage = null;
    hasMore = true;
    loading = false;
    load();
  }

  // The server searches stored packets by hash prefix; shorter or non-hex
  // text stays a client-side filter over loaded and live rows.
  String? get serverHashPrefix {
    final text = search.text.trim().toLowerCase();
    return mode == 'Hash' && RegExp(r'^[0-9a-f]{4,16}$').hasMatch(text)
        ? text
        : null;
  }

  void searchChanged({bool immediate = false}) {
    searchDebounce?.cancel();
    void apply() {
      if (!mounted || serverHashPrefix == hashPrefix) return;
      hashPrefix = serverHashPrefix;
      filtersChanged();
    }

    if (immediate) {
      apply();
    } else {
      searchDebounce = Timer(const Duration(milliseconds: 300), apply);
    }
  }

  void resumeLive() {
    // Return synchronously so arrivals cannot queue during a scroll animation.
    if (scroll.hasClients) scroll.jumpTo(0);
    setState(() {
      expandedHash = null;
      buffer.reveal(pending);
      pending = [];
    });
  }

  Future<void> filters() async {
    final optionApi = widget.api;
    final optionRegion = jsonEncode(widget.region);
    if (scopes.isEmpty &&
        widget.region['iatas'] != '' &&
        !(widget.region['region'] != null && widget.region['iatas'] == null)) {
      try {
        final result = await widget.api.get('/scopes', widget.region);
        if (!mounted ||
            optionApi != widget.api ||
            optionRegion != jsonEncode(widget.region)) {
          return;
        }
        if (result is List) scopes = result.map((e) => e.toString()).toList();
      } catch (_) {}
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        tr('Filters'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          update(() {
                            types = {};
                            routes = {};
                            selectedScopes = {};
                            selectedObservers = {};
                            search.clear();
                            mode = 'Hash';
                          });
                          searchDebounce?.cancel();
                          hashPrefix = null;
                          filtersChanged();
                        },
                        child: Text(tr('Clear all')),
                      ),
                    ],
                  ),
                  FilterDropdown<int>(
                    label: 'Payload type',
                    options: payloadNames,
                    selected: types,
                    onChanged: (value) {
                      update(() => types = value);
                      filtersChanged();
                    },
                  ),
                  FilterDropdown<int>(
                    label: 'Route type',
                    options: const {
                      0: 'TRANSPORT_FLOOD',
                      1: 'FLOOD',
                      2: 'DIRECT',
                      3: 'TRANSPORT_DIRECT',
                    },
                    selected: routes,
                    onChanged: (value) {
                      update(() => routes = value);
                      filtersChanged();
                    },
                  ),
                  FilterDropdown<String>(
                    label: 'Observers',
                    options: Map.fromEntries(
                      observerNames.entries.toList()
                        ..sort((a, b) => a.value.compareTo(b.value)),
                    ),
                    selected: selectedObservers,
                    onChanged: (value) {
                      update(() => selectedObservers = value);
                      setState(() {});
                    },
                  ),
                  if (scopes.isNotEmpty)
                    FilterDropdown<String>(
                      label: 'Scope',
                      options: {for (final name in scopes) name: name},
                      selected: selectedScopes,
                      onChanged: (value) {
                        update(() => selectedScopes = value);
                        filtersChanged();
                      },
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(tr('Done')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = visible;
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              DropdownButton<String>(
                value: mode,
                underline: const SizedBox(),
                style: Theme.of(context).textTheme.bodySmall,
                items: [
                  for (final m in ['Hash', 'Path'])
                    DropdownMenuItem(
                      value: m,
                      child: Text(
                        trKey(
                          m == 'Hash' ? 'packetTable.hash' : 'observation.path',
                        ),
                      ),
                    ),
                ],
                onChanged: (v) {
                  setState(() => mode = v!);
                  searchChanged(immediate: true);
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: search,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search, size: 17),
                    hintText: tr('Search'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    suffixIcon: search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 15),
                            onPressed: () {
                              search.clear();
                              setState(() {});
                              searchChanged(immediate: true);
                            },
                          ),
                  ),
                  onChanged: (_) {
                    setState(() {});
                    searchChanged();
                  },
                ),
              ),
              IconButton(
                tooltip: tr('Filters'),
                onPressed: filters,
                icon: Badge(
                  label: Text(
                    '${types.length + routes.length + selectedScopes.length + selectedObservers.length}',
                  ),
                  isLabelVisible:
                      types.isNotEmpty ||
                      routes.isNotEmpty ||
                      selectedScopes.isNotEmpty ||
                      selectedObservers.isNotEmpty,
                  child: const Icon(Icons.tune, size: 21),
                ),
              ),
            ],
          ),
        ),
        if (loading && packets.isEmpty)
          const LinearProgressIndicator(minHeight: 2),
        if (pending.isNotEmpty)
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              key: const ValueKey('resume-live-packets'),
              onPressed: resumeLive,
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                shape: const RoundedRectangleBorder(),
              ),
              icon: const Icon(Icons.arrow_upward, size: 16),
              label: Text(
                trKey('packetList.newPackets', count: pending.length),
              ),
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  tr(error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                TextButton(onPressed: () => load(), child: Text(tr('Retry'))),
              ],
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => load(),
            child: ListView.builder(
              findChildIndexCallback: (key) {
                if (key is! ValueKey) return null;
                final index = data.indexWhere(
                  (p) => p['packetHash'] == key.value,
                );
                return index < 0 ? null : index;
              },
              controller: scroll,
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: data.length + 1,
              itemBuilder: (context, index) {
                if (index == data.length) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        // A failed load is not an empty result; the error above says so.
                        if (data.isEmpty && !loading && error == null)
                          Text(tr('No packets match the current filters.')),
                        if (hasMore)
                          OutlinedButton(
                            onPressed: loading ? null : () => load(older: true),
                            child: Text(tr('Load older packets')),
                          ),
                      ],
                    ),
                  );
                }
                final p = data[index];
                final obs = object(p['latestObserver']);
                final card = Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => setState(
                      () =>
                          expandedHash = expandedHash == textOf(p['packetHash'])
                          ? null
                          : textOf(p['packetHash']),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                shortKey(p['packetHash']).toUpperCase(),
                                style: TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                  letterSpacing: 0.8,
                                  color: primary,
                                ),
                              ),
                              const SizedBox(width: 10),
                              PacketBadge(
                                label: payloadName(p['payloadType']),
                                type: (number(p['payloadType']) ?? 0).toInt(),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '×${p['observationCount'] ?? 1}',
                                style: TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 11,
                                  color: primary,
                                ),
                              ),
                            ],
                          ),
                          if (textOf(p['summary']).isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                textOf(p['summary']),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 7,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                textOf(p['routeTypeName']),
                                style: const TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 10,
                                ),
                              ),
                              if (p['scope'] != null)
                                Text(
                                  textOf(p['scope']),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: primary,
                                  ),
                                ),
                              Text(
                                age(p['lastHeardAt']),
                                style: const TextStyle(fontSize: 11),
                              ),
                              Text(
                                textOf(obs['displayName'], shortKey(obs['id'])),
                                style: const TextStyle(fontSize: 11),
                              ),
                              Text(
                                textOf(obs['iata']),
                                style: TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: primary,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                return Column(
                  key: ValueKey(p['packetHash']),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    card,
                    if (expandedHash == p['packetHash'])
                      PacketExpansion(
                        api: widget.api,
                        packet: p,
                        onOpen: widget.onOpen,
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class PacketBadge extends StatelessWidget {
  const PacketBadge({super.key, required this.label, this.type = 0});
  final String label;
  final int type;
  @override
  Widget build(BuildContext context) {
    final color = switch (type) {
      4 => BeaconColors.of(context).success,
      5 || 6 => BeaconColors.of(context).secondary,
      9 => BeaconColors.of(context).warning,
      _ => Theme.of(context).colorScheme.primary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
