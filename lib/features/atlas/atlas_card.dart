import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../analytics/charts.dart';
import 'atlas.dart';
import 'atlas_widgets.dart';
import 'observer_sample.dart';

const atlasRefresh = Duration(minutes: 1);

/// A pin whose radio is gone is checked rarely, so it can come back after a
/// reset without costing a poll a minute.
const atlasMissingRefresh = Duration(minutes: 10);
Duration? pollUnlessGone(Object? error) =>
    isNotFound(error) ? atlasMissingRefresh : atlasRefresh;

/// A 404 means this server has no such endpoint; nothing to poll for.
Duration? pollUnlessMissing(Object? error) =>
    isNotFound(error) ? null : atlasRefresh;

/// One polled read. It keeps the last answer while a later read fails, and
/// stops its timer while disabled.
class AtlasQuery<T> extends ChangeNotifier {
  AtlasQuery(this._fetch, this._interval);
  final Future<T> Function() _fetch;
  final Duration? Function(Object? error) _interval;
  T? data;
  Object? error;
  bool fetching = false;
  bool _enabled = false, _disposed = false;
  Timer? _timer;
  DateTime? _settled;

  bool get pending => data == null && error == null;
  bool get loading => fetching && data == null;

  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    _timer?.cancel();
    if (!value) return;
    final settled = _settled;
    final wait = _interval(error);
    if (settled == null) {
      refetch();
    } else if (wait != null) {
      final left = wait - DateTime.now().difference(settled);
      left > Duration.zero ? _timer = Timer(left, refetch) : refetch();
    }
  }

  Future<void> refetch() async {
    if (_disposed || fetching) return;
    _timer?.cancel();
    fetching = true;
    try {
      final value = await _fetch();
      if (_disposed) return;
      data = value;
      error = null;
    } catch (e) {
      if (_disposed) return;
      error = e;
    }
    fetching = false;
    _settled = DateTime.now();
    final wait = _interval(error);
    if (_enabled && wait != null) _timer = Timer(wait, refetch);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

const _tileLabel = {
  'airtime': 'atlas.airtime',
  'battery': 'atlas.battery',
  'uptime': 'atlas.uptime',
  'types': 'atlas.packetTypes',
  'packets': 'observerPage.records',
  'snr': 'signal.meanSnr',
  'rssi': 'signal.meanRssi',
  'noise': 'atlas.noiseFloor',
  'queue': 'observerPage.queue',
  'errors': 'observerPage.errors',
};

/// Accents belong to the slot, so a card keeps its colours whatever its tiles show.
const _slotAccent = [0, 3, 2, 1];
const _dash = '—';

/// One pinned radio, laid out as the Signal tab's KPI row. A node that also
/// observes gets a third view; an observer-only pin has just that view.
class AtlasCard extends StatefulWidget {
  const AtlasCard({
    super.key,
    required this.api,
    required this.pin,
    required this.range,
    required this.active,
    required this.now,
    required this.view,
    required this.onViewChange,
    required this.onPinView,
    required this.onRemove,
    required this.onResolved,
    required this.onUpgrade,
    required this.onTilesChange,
    required this.onOpen,
    this.handle,
  });
  final ApiClient api;
  final AtlasPin pin;
  final AtlasRange range;
  final bool active;

  /// The page's minute tick, epoch ms.
  final int now;
  final AtlasView view;
  final ValueChanged<AtlasView> onViewChange, onPinView;
  final VoidCallback onRemove;
  final void Function(String id, String? observerId) onResolved;
  final void Function(Json node, String observerId) onUpgrade;
  final ValueChanged<List<String>> onTilesChange;
  final void Function(String kind, String id) onOpen;

  /// Wraps the grip so the page can start a reorder from it.
  final Widget Function(Widget grip)? handle;

  @override
  State<AtlasCard> createState() => _AtlasCardState();
}

class _AtlasCardState extends State<AtlasCard> {
  final _queries = <String, AtlasQuery<dynamic>>{};
  final _keys = <String, String>{};
  final _body = GlobalKey();
  double? _held;

  AtlasPin get pin => widget.pin;
  Json? get node => _queries['node']?.data as Json?;
  Json? get observer => _queries['observer']?.data as Json?;
  String? get observerId => pin.isNode
      ? (_text(node?['observerId']) ?? pin.observerId)
      : pin.observerId;
  String? _text(dynamic value) {
    final text = textOf(value);
    return text.isEmpty ? null : text;
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(AtlasCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    for (final query in _queries.values) {
      query.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    _sync();
    setState(() {});
    final node = this.node;
    // A pin recovered under a new server id, or newly linked to an observer, is
    // saved back. A node record without the link keeps the pin's own.
    if (pin.isNode && node != null) {
      final id = textOf(node['id']);
      final linked = _text(node['observerId']) ?? pin.observerId;
      if (id != pin.id || linked != pin.observerId) {
        widget.onResolved(id, linked);
      }
    }
    // An observer that now advertises becomes a node pin so the card gains the node views.
    final match = _queries['upgrade']?.data as Json?;
    if (!pin.isNode && match != null) widget.onUpgrade(match, pin.observerId!);
  }

  /// Keeps one query per name, replaced when what it asks about changes, and
  /// running only while it is wanted.
  void _use<T>(
    String name,
    String? key,
    bool enabled,
    Future<T> Function() fetch,
    Duration? Function(Object? error) interval,
  ) {
    if (_keys[name] != key) {
      _queries.remove(name)?.dispose();
      _keys.remove(name);
      if (key != null) {
        _keys[name] = key;
        _queries[name] = AtlasQuery<T>(fetch, interval)..addListener(_changed);
      }
    }
    _queries[name]?.enabled = enabled && key != null;
  }

  void _sync() {
    final api = widget.api, active = widget.active;
    final range = widget.range.duration;
    Future<Json> read(String path, [Json params = const {}]) async =>
        object(await api.getCached(path, params));
    _use<Json>(
      'node',
      pin.isNode ? pin.publicKey : null,
      active,
      () => loadAtlasNode(api, widget.pin),
      pollUnlessGone,
    );
    final nodeId = _text(node?['id']);
    _use<Json>(
      'activity',
      nodeId == null ? null : '$nodeId/$range',
      active,
      () => read('/nodes/$nodeId/activity', {'range': range}),
      pollUnlessMissing,
    );
    // The series load only while the Observer view is open. The record does
    // too, unless the card needs it for its title.
    final id = observerId;
    final open = widget.view == AtlasView.observer;
    _use<Json>(
      'observer',
      id,
      active && (open || !pin.isNode),
      () => read('/observers/$id'),
      pollUnlessGone,
    );
    for (final series in const ['activity', 'telemetry']) {
      _use<Json>(
        'observer-$series',
        id == null ? null : '$id/$range',
        active && open,
        () => read('/observers/$id/$series', {
          'range': range,
          'interval': observerInterval,
        }),
        pollUnlessMissing,
      );
    }
    final observerKey = pin.isNode ? null : _text(observer?['publicKey']);
    _use<Json?>(
      'upgrade',
      observerKey,
      active,
      () => resolveObserverNode(api, {'publicKey': observerKey}),
      (_) => atlasRefresh,
    );
    final hash = widget.view == AtlasView.heard
        ? (_queries['activity']?.data == null
              ? null
              : summarizeActivity(
                  _queries['activity']!.data as Json,
                  widget.range,
                  widget.now,
                ).latestHash)
        : null;
    _use<Json>(
      'heard',
      hash,
      true,
      () => read('/packets/${Uri.encodeComponent(hash!)}'),
      (_) => null,
    );
  }

  void _retry(String name) {
    _queries[name]?.refetch();
    setState(() {});
  }

  // The list view is fixed to the tiles' height and scrolls inside it, so
  // flipping never resizes the card.
  void _changeView(AtlasView next) {
    if (widget.view != AtlasView.heard) {
      _held = _body.currentContext?.size?.height ?? _held;
    }
    widget.onViewChange(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    final series = analyticsChartColors(context);
    final node = this.node, observer = this.observer;
    final nodeQuery = _queries['node'], observerQuery = _queries['observer'];
    final activity = _queries['activity'];
    final sample = summarizeActivity(
      activity?.data as Json?,
      widget.range,
      widget.now,
    );
    final id = observerId;
    final view = widget.view;
    final views = !pin.isNode
        ? const [AtlasView.observer]
        : [
            AtlasView.analytics,
            AtlasView.heard,
            if (id != null) AtlasView.observer,
          ];
    final home = pin.homeView;
    final status = observer == null
        ? null
        : observerStatus(observer, widget.now);
    final statusLabel = status == null || status.isEmpty
        ? null
        : at(status == 'online' ? 'online' : 'offline');
    final muted = TextStyle(fontSize: 14, color: c.muted);

    final name =
        _text(pin.isNode ? (node?['name']) : (observer?['displayName'])) ??
        _text(pin.name);
    final canOpen = !pin.isNode || node != null;
    // One line always: a dot carries the status and the name gives way first.
    final (dotColor, dotLabel) = pin.isNode
        ? switch (node?['stale']) {
            false => (c.success, at('recent')),
            true => (c.warning, at('stale')),
            _ => (null, null),
          }
        : statusLabel == null
        ? (null, null)
        : (status == 'online' ? c.success : c.warning, statusLabel);
    final type = pin.isNode
        ? textOf(node?['nodeTypeName'])
        : textOf(observer?['observerType']);
    final title = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 26),
      child: Row(
        children: [
          if (dotColor != null) ...[
            Tooltip(
              message: dotLabel,
              triggerMode: TooltipTriggerMode.tap,
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: InkWell(
              onTap: !canOpen
                  ? null
                  : () => pin.isNode
                        ? widget.onOpen('node', textOf(node!['id']))
                        : widget.onOpen('observer', pin.observerId!),
              child: Text(
                name ??
                    formatHex(
                      pin.isNode
                          ? textOf(node?['id'], pin.id!)
                          : pin.observerId!,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  letterSpacing: .55,
                  fontStyle: name == null ? FontStyle.italic : null,
                  color: name == null
                      ? c.dim
                      : canOpen
                      ? c.primary
                      : c.muted,
                ),
              ),
            ),
          ),
          if (type.isNotEmpty) ...[const SizedBox(width: 8), AtlasBadge(type)],
        ],
      ),
    );

    final grip = AtlasIconButton(
      icon: GripIcon.new,
      label: at('dragToReorder'),
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (views.length > 1) ...[
          AtlasIconButton(
            icon: (color) => PinIcon(color, filled: view == home),
            label: at('pinView'),
            tooltip: at(view == home ? 'viewPinned' : 'pinViewHelp'),
            pressed: view == home,
            onPressed: view == home ? () {} : () => widget.onPinView(view),
          ),
          const SizedBox(width: 4),
        ],
        AtlasIconButton(
          icon: CrossIcon.new,
          label: at('remove'),
          muted: true,
          onPressed: widget.onRemove,
        ),
        const SizedBox(width: 4),
        widget.handle?.call(grip) ?? grip,
      ],
    );

    Widget note(String text, {Color? color}) =>
        Text(text, style: muted.copyWith(color: color));
    Widget retry(String name) => Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        note(tr('Failed to load'), color: c.danger),
        AtlasAction(tr('Retry'), onPressed: () => _retry(name)),
      ],
    );

    final body = <Widget>[
      if (views.length > 1)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: AtlasSegmented<AtlasView>(
            stretch: true,
            label: at('view'),
            value: view,
            onChanged: _changeView,
            options: {
              for (final option in views)
                option: at(switch (option) {
                  AtlasView.analytics => 'viewAnalytics',
                  AtlasView.heard => 'viewHeard',
                  AtlasView.observer => 'viewObserver',
                }),
            },
          ),
        ),
      if (pin.isNode && nodeQuery != null) ...[
        if (nodeQuery.pending) note(tr('Loading…')),
        if (isNotFound(nodeQuery.error))
          note(tr('Node not found'))
        else if (nodeQuery.error != null)
          retry('node'),
      ],
      if (!pin.isNode && observerQuery != null) ...[
        if (observerQuery.pending) note(tr('Loading…')),
        if (isNotFound(observerQuery.error))
          note(at('observerGone'))
        else if (observerQuery.error != null)
          retry('observer'),
      ],
    ];

    if (view == AtlasView.analytics && node != null) {
      final lastSeen = number(node['lastSeen'])?.toInt() ?? 0;
      final meanHops = '${at('meanHops')} ${average(sample.hops)}';
      final neighbors = at(
        'neighbors',
        args: {'count': number(node['knownNeighborCount'])?.toInt() ?? 0},
      );
      final unsupported = isNotFound(activity?.error);
      final window = sample.partial
          ? at('observerPartialCoverage')
          : at('ranges.${widget.range.id}');
      AtlasStatTile tile(
        String label,
        String value,
        int accent, {
        List<double?>? spark,
        List<bool>? presence,
        String? sublabel,
        bool markPeak = false,
      }) => AtlasStatTile(
        label: AtlasStatTile.text(tr(label)),
        value: value,
        accent: series[accent],
        spark: spark,
        markPeak: markPeak,
        presence: presence,
        sublabel: sublabel,
      );
      body.add(
        Column(
          key: _body,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _TileGrid([
              tile(
                'Observations',
                sample.total == null ? _dash : formatCount(sample.total),
                0,
                spark: sample.counts,
                markPeak: true,
                sublabel: window,
              ),
              tile(
                'Mean SNR',
                average(sample.snr, 'dB'),
                2,
                spark: sample.snrHourly,
              ),
              tile(
                'Mean RSSI',
                average(sample.rssi, 'dBm'),
                1,
                spark: sample.rssiHourly,
              ),
              tile(
                'Active hours',
                '${sample.present.where((on) => on).length}/${sample.counts.length}',
                3,
                presence: sample.present,
              ),
            ]),
            const SizedBox(height: 12),
            _Footer(
              left: lastSeen > 0
                  ? '${at('lastSeen')} ${ago(lastSeen, widget.now)}'
                  : null,
              right: '$meanHops · $neighbors',
              loading: activity?.loading ?? false,
              failed: activity?.error != null && !unsupported,
              tip: [
                ?dotLabel,
                if (lastSeen > 0)
                  '${at('lastSeen')} ${formatAbsolute(lastSeen)}',
                meanHops,
                neighbors,
                if (unsupported) at('activityUnsupported'),
                at('sampleHelp'),
              ],
            ),
          ],
        ),
      );
    }

    if (view == AtlasView.heard && node != null) {
      final heard = _queries['heard'];
      final detail = heard?.data as Json?;
      final origin = textOf(detail?['originPubkey']).toLowerCase();
      // Never show another node's observers if the packet resolved to a different origin.
      final sameOrigin = origin.isEmpty || origin == pin.publicKey;
      final latestByObserver = <String, Json>{};
      if (detail != null && sameOrigin) {
        for (final row in rows(detail['observations'])) {
          final previous = latestByObserver[textOf(row['observerId'])];
          if (previous == null ||
              (number(row['heardAt']) ?? 0) >
                  (number(previous['heardAt']) ?? 0)) {
            latestByObserver[textOf(row['observerId'])] = row;
          }
        }
      }
      final observers = latestByObserver.values.toList()
        ..sort(
          (a, b) =>
              (number(b['heardAt']) ?? 0).compareTo(number(a['heardAt']) ?? 0),
        );
      final small = atlasMono(12, c.muted);
      final unsupported = isNotFound(activity?.error);
      Widget line(String text) => Text(text, style: small);
      final Widget content;
      if (activity?.loading ?? activity == null) {
        content = line(tr('Loading…'));
      } else if (sample.latestHash == null) {
        content = line(
          unsupported
              ? at('activityUnsupported')
              : activity?.error != null
              ? tr('Failed to load')
              : at('noReports'),
        );
      } else if (heard == null || heard.pending) {
        content = line(tr('Loading…'));
      } else if (heard.error != null || !sameOrigin) {
        content = line(at('heardUnavailable'));
      } else {
        final list = ListView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: _held == null,
          itemCount: observers.length,
          itemBuilder: (context, i) {
            final row = observers[i];
            final observerId = textOf(row['observerId']);
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.borderSubtle)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: InkWell(
                        onTap: () => widget.onOpen('observer', observerId),
                        child: Text(
                          _text(row['observerName']) ?? formatHex(observerId),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: atlasMono(12, c.primary),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: c.primary.withValues(alpha: .06),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      textOf(row['iata']),
                      style: atlasMono(11, c.primary, weight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            );
          },
        );
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: _held == null ? MainAxisSize.min : MainAxisSize.max,
          children: [
            line(
              '${at('observers', count: observers.length)} ${ago(sample.latestHeardAt ?? widget.now, widget.now)}',
            ),
            const SizedBox(height: 4),
            _held == null
                ? ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: list,
                  )
                : Expanded(child: list),
            const SizedBox(height: 8),
            AtlasAction(
              at('openPacket'),
              onPressed: () => widget.onOpen('packet', sample.latestHash!),
            ),
          ],
        );
      }
      body.add(
        _held == null
            ? content
            : SizedBox(
                height: _held,
                child: Align(alignment: Alignment.topLeft, child: content),
              ),
      );
    }

    if (view == AtlasView.observer &&
        id != null &&
        (pin.isNode ? node : observer) != null) {
      final obs = summarizeObserver(
        _queries['observer-activity']?.data as Json?,
        _queries['observer-telemetry']?.data as Json?,
        observer,
        widget.range,
        widget.now,
      );
      final feeds = [
        _queries['observer-activity'],
        _queries['observer-telemetry'],
      ];
      final unsupported = feeds.any((q) => isNotFound(q?.error));
      final tiles = pin.tiles ?? defaultTiles;
      // The battery tile stands in as uptime for a radio with no battery, so
      // either tile can be showing it.
      final uptimeOnTile =
          tiles.contains('uptime') ||
          (tiles.contains('battery') && obs.battery == null);
      final free = {
        for (final tile in observerTiles)
          if (!tiles.contains(tile)) tile: trKey(_tileLabel[tile]!),
      };
      final window = obs.partial
          ? at('observerPartialCoverage')
          : at('ranges.${widget.range.id}');
      Widget observerTile(String tile, int slot) {
        // Today's stand-in for a radio with no battery, unless the card already has an uptime tile.
        final shown =
            tile == 'battery' &&
                obs.battery == null &&
                !tiles.contains('uptime')
            ? 'uptime'
            : tile;
        AtlasStatTile stat(
          String value, {
          List<double?>? spark,
          bool markPeak = false,
          bool interpolateGaps = false,
          String? sublabel,
          Widget? visual,
        }) => AtlasStatTile(
          key: ValueKey(tile),
          label: TilePicker(
            label: trKey(_tileLabel[shown]!),
            options: free,
            onPick: (next) => widget.onTilesChange([
              for (final (i, old) in tiles.indexed) i == slot ? next : old,
            ]),
            onReset: pin.tiles == null
                ? null
                : () => widget.onTilesChange(defaultTiles),
          ),
          value: value,
          accent: series[_slotAccent[slot]],
          spark: spark,
          markPeak: markPeak,
          interpolateGaps: interpolateGaps,
          sublabel: sublabel,
          visual: visual,
        );
        String count(double? value) =>
            value == null ? _dash : formatCount(value);
        return switch (shown) {
          'airtime' => stat(
            obs.airtime == null ? _dash : percent(obs.airtime!),
            spark: obs.airtimeHourly,
            markPeak: true,
            interpolateGaps: true,
            sublabel: switch (obs.airtimeSource) {
              'radio' =>
                'TX ${percent(obs.airtimeTx!)} · RX ${percent(obs.airtimeRx!)}',
              'heard' => at('airtimeHeard'),
              _ => null,
            },
          ),
          'battery' => stat(
            obs.battery == null ? _dash : formatBattery(obs.battery!),
            spark: obs.batteryHourly,
            interpolateGaps: true,
          ),
          'uptime' => stat(
            obs.uptime == null ? _dash : formatUptime(obs.uptime!),
            spark: obs.uptimeHourly,
          ),
          'types' => stat(
            count(obs.heard),
            sublabel: window,
            visual: TypeMix(types: obs.types, colors: series),
          ),
          'packets' => stat(
            count(obs.heard),
            spark: obs.counts,
            markPeak: true,
            sublabel: window,
          ),
          'snr' => stat(average(obs.snr, 'dB'), spark: obs.snrHourly),
          'rssi' => stat(average(obs.rssi, 'dBm'), spark: obs.rssiHourly),
          'noise' => stat(
            obs.noise == null ? _dash : '${obs.noise!.round()} dBm',
            spark: obs.noiseHourly,
            interpolateGaps: true,
          ),
          'queue' => stat(
            count(obs.queue?.roundToDouble()),
            spark: obs.queueHourly,
            interpolateGaps: true,
          ),
          _ => stat(count(obs.errors), spark: obs.errorsHourly, markPeak: true),
        };
      }

      final radioText = textOf(observer?['radio']);
      double? field(String key) => number(observer?[key]);
      final radio = observer == null
          ? null
          : formatRadio(radioText) ??
                formatRadioParts(
                  freq: field('radioFreqMhz'),
                  sf: field('radioSf'),
                  bw: field('radioBwKhz'),
                  cr: field('radioCr'),
                );
      final compact = [
        for (final part in radioText.split(',')) double.tryParse(part.trim()),
      ];
      final radioShort = observer == null
          ? null
          : compact.length == 3 && !compact.contains(null)
          ? formatRadioParts(freq: compact[0], sf: compact[2])
          : formatRadioParts(freq: field('radioFreqMhz'), sf: field('radioSf'));
      final lastStatus = number(observer?['lastStatusAt'])?.toInt();
      body.add(
        Column(
          key: _body,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _TileGrid([
              for (final (slot, tile) in tiles.indexed)
                observerTile(tile, slot),
            ]),
            const SizedBox(height: 12),
            _Footer(
              dot: status == null || status.isEmpty
                  ? null
                  : status == 'online'
                  ? c.success
                  : c.dim.withValues(alpha: .3),
              left: statusLabel == null && lastStatus == null
                  ? null
                  : [
                      ?statusLabel,
                      if (lastStatus != null) ago(lastStatus, widget.now),
                    ].join(' · '),
              right: radioShort ?? radio ?? '',
              loading: feeds.any((q) => q?.loading ?? false),
              failed: feeds.any(
                (q) => q?.error != null && !isNotFound(q?.error),
              ),
              tip: [
                if (statusLabel != null || lastStatus != null)
                  [
                    ?statusLabel,
                    if (lastStatus != null)
                      '${at('lastStatus')} ${formatAbsolute(lastStatus)}',
                  ].join(' · '),
                ?radio,
                if (!uptimeOnTile && obs.uptime != null)
                  '${at('uptime')} ${formatUptime(obs.uptime!)}',
                if (unsupported) at('observerUnsupported'),
                at('observerHelp'),
              ],
            ),
          ],
        ),
      );
    }

    return AtlasPanel(
      title: title,
      right: actions,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: body,
      ),
    );
  }
}

/// Two tiles a row, each row as tall as its taller tile.
class _TileGrid extends StatelessWidget {
  const _TileGrid(this.tiles);
  final List<Widget> tiles;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < tiles.length; i += 2) ...[
        if (i > 0) const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: tiles[i]),
              const SizedBox(width: 12),
              Expanded(
                child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox(),
              ),
            ],
          ),
        ),
      ],
    ],
  );
}

/// One line that never wraps: the right side gives way first, then the left, a
/// failure never does, and the tip carries every fact in full.
class _Footer extends StatelessWidget {
  const _Footer({
    this.left,
    this.dot,
    required this.right,
    required this.loading,
    required this.failed,
    required this.tip,
  });
  final String? left;
  final Color? dot;
  final String right;
  final bool loading, failed;
  final List<String> tip;
  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    final style = atlasMono(11, c.muted);
    Text text(String value, {Color? color}) => Text(
      value,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: color == null ? style : style.copyWith(color: color),
    );
    final state = failed
        ? tr('Failed to load')
        : loading
        ? tr('Loading…')
        : null;
    return CustomMultiChildLayout(
      delegate: _FooterLayout(
        MediaQuery.textScalerOf(context).scale(16.5).clamp(22, 64),
      ),
      children: [
        if (left != null)
          LayoutId(
            id: 'left',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (dot != null) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(child: text(left!)),
              ],
            ),
          ),
        if (state != null)
          LayoutId(
            id: 'state',
            child: text(state, color: failed ? c.danger : null),
          ),
        LayoutId(id: 'right', child: text(right)),
        LayoutId(id: 'tip', child: AtlasInfoTip(tip)),
      ],
    );
  }
}

// A custom layout, not a LayoutBuilder: cards sit in rows sized to the tallest one.
class _FooterLayout extends MultiChildLayoutDelegate {
  _FooterLayout(this.height);
  final double height;
  static const _gap = 12.0;

  @override
  Size getSize(BoxConstraints constraints) =>
      Size(constraints.maxWidth, height);

  @override
  void performLayout(Size size) {
    double mid(Size child) => (size.height - child.height) / 2;
    BoxConstraints upTo(double width) =>
        BoxConstraints(maxWidth: width < 0 ? 0 : width, maxHeight: size.height);
    final tip = layoutChild('tip', upTo(size.width));
    positionChild('tip', Offset(size.width - tip.width, mid(tip)));
    var room = size.width - tip.width, x = 0.0;
    Size? state;
    if (hasChild('state')) {
      state = layoutChild('state', upTo(room));
      room -= state.width + _gap;
    }
    if (hasChild('left')) {
      final left = layoutChild('left', upTo(room));
      positionChild('left', Offset(0, mid(left)));
      x = left.width + _gap;
      room -= left.width + _gap;
    }
    if (state != null) {
      positionChild('state', Offset(x, mid(state)));
      x += state.width + _gap;
    }
    final right = layoutChild('right', upTo(room));
    positionChild(
      'right',
      Offset(size.width - tip.width - right.width, mid(right)),
    );
  }

  @override
  bool shouldRelayout(_FooterLayout old) => old.height != height;
}
