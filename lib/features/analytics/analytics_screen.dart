import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'advertiser_list.dart';
import 'charts.dart';
import 'comparison.dart';
import 'neighbour_graph.dart';
import 'transforms.dart';

export 'observer_charts.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({
    super.key,
    required this.api,
    required this.region,
    required this.onOpen,
    this.initialTab = 'Mesh',
    this.observerId,
  });
  final ApiClient api;
  final String initialTab;
  final String? observerId;
  final Map<String, dynamic> region;
  final void Function(String kind, String id) onOpen;
  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  String tab = 'Mesh', range = '7d', advertiserSort = 'flood';
  int refreshed = DateTime.now().millisecondsSinceEpoch;
  Map<String, dynamic>? comparison;
  Timer? refreshTimer;
  @override
  void initState() {
    super.initState();
    tab = tabs.contains(widget.initialTab) ? widget.initialTab : 'Mesh';
    seedComparison();
    refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          ![
            'Clock Drift',
            'Compare Observers',
            'Neighbour Graph',
          ].contains(tab)) {
        setState(() => refreshed = DateTime.now().millisecondsSinceEpoch);
      }
    });
  }

  void seedComparison() {
    if (widget.observerId?.isNotEmpty ?? false) {
      tab = 'Compare Observers';
      comparison = {
        'observerA': widget.observerId,
        'observerB': '',
        'since': refreshed - 86400000,
        'until': refreshed,
      };
    }
  }

  @override
  void didUpdateWidget(covariant AnalyticsScreen old) {
    super.didUpdateWidget(old);
    if (old.observerId != widget.observerId) seedComparison();
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  static const tabs = [
    'Mesh',
    'Traffic',
    'Signal',
    'Paths',
    'Scopes',
    'Talkers',
    'Clock Drift',
    'Compare Observers',
    'Neighbour Graph',
  ];
  Map<String, dynamic> get window => {
    ...widget.region,
    'since': refreshed ~/ 60000 * 60000 - rangeHours[range]! * 3600000,
    'until': refreshed ~/ 60000 * 60000,
  };
  Map<String, dynamic> get rolled => {
    ...widget.region,
    ...rolledWindow(range, refreshed),
  };
  Widget query(
    String endpoint,
    Widget Function(dynamic) builder, {
    Map<String, dynamic>? params,
    Duration? pollInterval,
  }) => StatsQuery(
    api: widget.api,
    path: endpoint,
    params: params ?? window,
    pollInterval: pollInterval,
    builder: builder,
  );
  Widget bars(
    String title,
    String endpoint,
    String label,
    String value, {
    String? kind,
    String? id,
    Map<String, dynamic>? params,
  }) => AnalyticsCard(
    title: title,
    child: query(endpoint, (d) {
      final r = rows(d);
      return RankedBars(
        labels: r
            .map((e) => textOf(e[label], textOf(e['publicKey'], textOf(e[id]))))
            .toList(),
        values: r.map((e) => number(e[value])).toList(),
        onTap: kind == null
            ? null
            : (i) {
                final v = textOf(r[i][id]);
                if (v.isNotEmpty) widget.onOpen(kind, v);
              },
      );
    }, params: params),
  );
  List<ChartPoint> points(dynamic values, String x, String y) =>
      rows(values)
          .map((r) => ChartPoint(number(r[x]) ?? 0, number(r[y])))
          .toList();
  Widget rollup() => AnalyticsCard(
    title: '${tr('Observations')} · $range · UTC',
    child: query(
      '/stats/series',
      (d) => TimeChart(
        series: {
          'Observations': rollupPoints(
            rows(object(d)['hours']),
            'observations',
          ),
          'Unique packets': rollupPoints(
            rows(object(d)['hours']),
            'uniquePackets',
          ),
        },
      ),
      params: rolled,
    ),
  );
  Widget metrics(Map<String, dynamic> values) => Wrap(
    spacing: 24,
    runSpacing: 12,
    children: values.entries
        .map(
          (e) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                e.key,
                style: TextStyle(
                  fontSize: 10,
                  color: BeaconColors.of(context).muted,
                ),
              ),
              Text(
                countLabel(number(e.value)),
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 22,
                ),
              ),
            ],
          ),
        )
        .toList(),
  );
  List<Widget> mesh() => [
    AnalyticsCard(
      title: 'Mesh · last 24 complete hours',
      child: query('/stats/series', (d) {
        final o = object(d), s = object(o['summary']);
        final available = (number(o['completeHours']) ?? 0) > 0;
        return MetricGrid(
          values: {
            'Total packets': available ? s['uniquePackets'] : null,
            'Observations': available ? s['observations'] : null,
            'Active observers': available ? s['activeObservers'] : null,
            'Active areas': available ? s['activeIatas'] : null,
          },
          sparks: {
            for (final e in {
              'Total packets': 'uniquePackets',
              'Observations': 'observations',
              'Active observers': 'activeObservers',
              'Active areas': 'activeIatas',
            }.entries)
              e.key: rollupPoints(rows(o['hours']), e.value),
          },
        );
      }, params: {...widget.region, ...rolledWindow('24h', refreshed)}),
    ),
    rollup(),
    bars(
      tr('Top observers · {{range}}').replaceAll('{{range}}', range),
      '/stats/top-observers',
      'displayName',
      'observationCount',
      kind: 'observer',
      id: 'observerId',
    ),
    bars(
      tr('Payload types · {{range}}').replaceAll('{{range}}', range),
      '/stats/payload-breakdown',
      'payloadTypeName',
      'count',
    ),
    bars(
      tr('Top nodes · {{range}}').replaceAll('{{range}}', range),
      '/stats/top-nodes',
      'nodeName',
      'observationCount',
      kind: 'node',
      id: 'nodeId',
    ),
    AnalyticsCard(
      title: 'Node types · all time',
      child: query('/stats/node-types', (d) {
        final r = rows(d);
        return DonutChart(
          labels: r.map((e) => textOf(e['nodeTypeName'])).toList(),
          values: r.map((e) => number(e['count'])).toList(),
          center: 'NODES',
          colors: r
              .map(
                (e) => analyticsNodeColor(textOf(e['nodeTypeName']), context),
              )
              .toList(),
        );
      }, params: widget.region),
    ),
    AnalyticsCard(
      title: 'Radio presets · all time',
      child: query('/stats/radio-presets', (d) {
        final grouped = <String, Map<String, double>>{};
        for (final r in rows(d)) {
          final preset = textOf(r['preset']);
          if (preset.split(',').every((n) => double.tryParse(n) == 0)) continue;
          final v = grouped.putIfAbsent(
            preset,
            () => {'Nodes': 0, 'Observers': 0},
          );
          final kind = r['sourceType'] == 'node' ? 'Nodes' : 'Observers';
          v[kind] = v[kind]! + (number(r['count']) ?? 0);
        }
        final labels = grouped.keys.toList()
          ..sort(
            (a, b) =>
                (grouped[b]!.values.reduce((x, y) => x + y))
                    .compareTo(grouped[a]!.values.reduce((x, y) => x + y)),
          );
        return StackedRows(
          labels: labels
              .take(8)
              .map(
                (p) => p.split(',').length == 3
                    ? '${p.split(',')[0]} · ${p.split(',')[1]}k · SF${p.split(',')[2]}'
                    : p,
              )
              .toList(),
          series: {
            for (final k in ['Nodes', 'Observers'])
              k: labels.take(8).map((p) => grouped[p]![k]).toList(),
          },
        );
      }, params: widget.region),
    ),
  ];
  List<Widget> traffic() => [
    query('/stats/observations', (d) {
      final r = rows(d);
      final end = refreshed ~/ 3600000 * 3600000,
          start = end - (rangeHours[range]! - 1) * 3600000;
      final areas = <String, double>{};
      for (final e in r) {
        final h = number(e['hour']), v = number(e['observationCount']);
        if (h == null || v == null || h < start || h > end || v < 0) continue;
        final name = normalizedIata(e['iata']);
        areas[name] = (areas[name] ?? 0) + v;
      }
      final names = areas.keys.toList()
        ..sort((a, b) => areas[b]!.compareTo(areas[a]!));
      final totals = trafficHours(r, start, end);
      final byArea = {
        for (final n in names.take(7)) n: trafficHours(r, start, end, iata: n),
      };
      return Column(
        children: [
          MetricGrid(
            values: {
              'Observations': areas.values.fold<double>(0, (a, b) => a + b),
              'Active areas': areas.values.where((v) => v > 0).length,
              'Busiest hour': totals.where((p) => p.y != null).isEmpty
                  ? null
                  : totals.fold<double>(0, (v, p) => (p.y ?? 0) > v ? p.y! : v),
              'Active hours':
                  '${totals.where((p) => p.y != null).length}/${totals.length}',
            },
            sparks: {
              'Observations': totals,
              'Active areas': trafficAreaHours(r, start, end),
              'Busiest hour': totals,
            },
            presence: {'Active hours': totals.map((p) => p.y != null).toList()},
          ),
          const SizedBox(height: 12),
          AnalyticsCard(
            title: 'Observations by area',
            child: TimeChart(
              stacked: true,
              series: {
                for (final n in names.take(7)) n: byArea[n]!,
                if (names.length > 7)
                  tr('Other areas'): List.generate(
                    totals.length,
                    (i) => ChartPoint(
                      totals[i].x,
                      totals[i].y == null
                          ? null
                          : totals[i].y! -
                                names
                                    .take(7)
                                    .fold<double>(
                                      0,
                                      (sum, n) => sum + (byArea[n]![i].y ?? 0),
                                    ),
                    ),
                  ),
              },
            ),
          ),
          AnalyticsCard(
            title:
                '${tr('Hourly activity · {{range}}').replaceAll('{{range}}', range)} · UTC',
            child: ActivityHeatmap(points: totals),
          ),
          AnalyticsCard(
            title: 'Observation share',
            child: DonutChart(
              labels: [
                ...names.take(20),
                if (names.length > 20) tr('Other areas'),
              ],
              values: [
                ...names.take(20).map((n) => areas[n]),
                if (names.length > 20)
                  names
                      .skip(20)
                      .fold<double>(0, (sum, n) => sum + (areas[n] ?? 0)),
              ],
              center: 'OBSERVATIONS',
            ),
          ),
          AnalyticsCard(
            title: 'By IATA',
            child: RankedBars(
              labels: names,
              values: names.map((n) => areas[n]).toList(),
              pageSize: 10,
            ),
          ),
        ],
      );
    }),
  ];
  List<Widget> signal() => [
    query('/stats/signal', (d) {
      final o = object(d);
      final receptions = windowedPoints(o, 'receptions');
      return Column(
        children: [
          AnalyticsCard(
            title: tr('Signal strength of packets heard by observers.'),
            child: MetricGrid(
              values: {
                'Observations': o['receptions'],
                'Mean SNR': object(o['snr'])['average'],
                'Mean RSSI': object(o['rssi'])['average'],
                'Active hours':
                    '${receptions.where((p) => p.y != null).length}/${receptions.length}',
              },
              sparks: {
                'Observations': receptions,
                'Mean SNR': windowedPoints(
                  o,
                  'snrAverage',
                  sampleKey: 'snrSamples',
                ),
                'Mean RSSI': windowedPoints(
                  o,
                  'rssiAverage',
                  sampleKey: 'rssiSamples',
                ),
              },
              presence: {
                'Active hours': receptions.map((p) => p.y != null).toList(),
              },
            ),
          ),
          AnalyticsCard(
            title: 'Sample availability',
            child: StackedRows(
              labels: ['SNR', 'RSSI'],
              series: {
                'Available': [
                  number(object(o['snr'])['samples']),
                  number(object(o['rssi'])['samples']),
                ],
                'Unavailable': [
                  (number(o['receptions']) ?? 0) -
                      (number(object(o['snr'])['samples']) ?? 0),
                  (number(o['receptions']) ?? 0) -
                      (number(object(o['rssi'])['samples']) ?? 0),
                ],
              },
            ),
          ),
          for (final key in ['snr', 'rssi']) ...[
            AnalyticsCard(
              title: tr('Hourly mean {{metric}} · {{unit}}')
                  .replaceAll('{{metric}}', key.toUpperCase())
                  .replaceAll('{{unit}}', key == 'snr' ? 'dB' : 'dBm'),
              child: TimeChart(
                series: {
                  key.toUpperCase(): windowedPoints(
                    o,
                    '${key}Average',
                    sampleKey: '${key}Samples',
                  ),
                },
                unit: key == 'snr' ? ' dB' : ' dBm',
              ),
            ),
            AnalyticsCard(
              title: tr('{{metric}} distribution · {{unit}}')
                  .replaceAll('{{metric}}', key.toUpperCase())
                  .replaceAll('{{unit}}', key == 'snr' ? 'dB' : 'dBm'),
              child: DistributionChart(
                labels: rows(object(o[key])['histogram'])
                    .map(
                      (b) => b['lower'] == null
                          ? '< ${b['upper']}'
                          : b['upper'] == null
                          ? '≥ ${b['lower']}'
                          : '${b['lower']} to < ${b['upper']}',
                    )
                    .toList(),
                values: rows(object(o[key])['histogram'])
                    .map((b) => number(b['count']))
                    .toList(),
              ),
            ),
          ],
        ],
      );
    }),
  ];
  List<Widget> paths() => [
    query('/stats/paths', (d) {
      final o = object(d);
      final lengths = {
        for (final row in rows(o['pathLengths']))
          (number(row['entries']) ?? 0).toInt(): number(row['receptions']) ?? 0,
      };
      final maxLength = lengths.keys
          .fold<int>(0, (a, b) => a > b ? a : b)
          .clamp(0, 63);
      return Column(
        children: [
          AnalyticsCard(
            title: 'Retained path receptions',
            child: MetricGrid(
              values: {
                'Observations': o['receptions'],
                'With hash paths': o['hashed'],
                'Multi-byte share': (number(o['hashed']) ?? 0) == 0
                    ? null
                    : '${(rows(o['hashWidths']).where((r) => (number(r['bytes']) ?? 0) > 1).fold<double>(0, (sum, r) => sum + (number(r['receptions']) ?? 0)) / (number(o['hashed']) ?? 1) * 100).toStringAsFixed(1)}%',
                'Most path entries': rows(o['pathLengths']).fold<double>(
                  0,
                  (v, r) => (number(r['entries']) ?? 0) > v
                      ? number(r['entries'])!
                      : v,
                ),
              },
              sparks: {
                'Observations': windowedPoints(o, 'receptions'),
                'Most path entries': windowedPoints(o, 'maxEntries'),
                ...pathSparklines(o),
              },
            ),
          ),
          AnalyticsCard(
            title: 'Observed hash widths',
            child: DonutChart(
              labels: rows(o['hashWidths'])
                  .map(
                    (r) => trKey(
                      'paths.hashWidth',
                      count: (number(r['bytes']) ?? 0).toInt(),
                    ),
                  )
                  .toList(),
              values: rows(o['hashWidths'])
                  .map((r) => number(r['receptions']))
                  .toList(),
              center: 'HASH PATHS',
            ),
          ),
          AnalyticsCard(
            title: 'Path format coverage',
            child: DonutChart(
              labels: ['Hash paths', 'Empty', 'Trace', 'Unclassified'],
              values: [
                number(o['hashed']),
                number(o['empty']),
                number(o['trace']),
                number(o['unclassified']),
              ],
              center: 'OBSERVATIONS',
            ),
          ),
          AnalyticsCard(
            title: 'Hash-path observations over time',
            child: TimeChart(
              stacked: true,
              series: {
                for (final e in {
                  '1 byte': 'oneByte',
                  '2 bytes': 'twoByte',
                  '3 bytes': 'threeByte',
                }.entries)
                  e.key: windowedPoints(o, e.value),
              },
            ),
          ),
          AnalyticsCard(
            title: 'Received path entries',
            child: DistributionChart(
              labels: [for (var i = 0; i <= maxLength; i++) '$i'],
              values: [for (var i = 0; i <= maxLength; i++) lengths[i] ?? 0],
            ),
          ),
          AnalyticsCard(
            title: 'Longest path per hour',
            child: TimeChart(
              series: {'Entries': windowedPoints(o, 'maxEntries')},
            ),
          ),
        ],
      );
    }),
  ];
  List<Widget> scopes() => [
    query(
      '/stats/series',
      (series) => query(
        '/stats/scopes',
        (d) => _ScopeContents(
          data: rows(d),
          hours: rows(object(series)['hours']),
          packetKnown: (number(object(series)['completeHours']) ?? 0) > 0,
          since: (number(rolled['since']) ?? 0).toInt(),
          until: (number(rolled['until']) ?? 0).toInt(),
        ),
        params: {...widget.region, 'since': rolled['since']},
      ),
      params: rolled,
    ),
  ];
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Row(
          children: [
            Expanded(
              child: _AnalyticsDropdown<String>(
                value: tab,
                hint: tr('Section'),
                items: tabs
                    .map(
                      (t) => DropdownMenuItem(
                        value: t,
                        child: Text(
                          tr(
                            {
                                  'Signal': 'RF / Signal',
                                  'Paths': 'Paths & hashes',
                                  'Clock Drift': 'Clock drift',
                                  'Compare Observers': 'Compare observers',
                                  'Neighbour Graph': 'Neighbor graph',
                                }[t] ??
                                t,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => tab = v!),
              ),
            ),
            if (![
              'Clock Drift',
              'Compare Observers',
              'Neighbour Graph',
            ].contains(tab)) ...[
              const SizedBox(width: 16),
              SizedBox(
                width: 88,
                child: _AnalyticsDropdown<String>(
                  value: range,
                  hint: tr('Range'),
                  items: rangeHours.keys
                      .map(
                        (r) => DropdownMenuItem(value: r, child: Text(tr(r))),
                      )
                      .toList(),
                  onChanged: (v) => setState(() {
                    range = v!;
                    refreshed = DateTime.now().millisecondsSinceEpoch;
                  }),
                ),
              ),
            ],
          ],
        ),
      ),
      Expanded(
        child: KeyedSubtree(
          key: ValueKey(
            '${widget.api.base}|${widget.region}|$tab|${widget.observerId}',
          ),
          child: tab == 'Neighbour Graph'
              ? NeighbourGraph(
                  api: widget.api,
                  region: widget.region,
                  onOpen: widget.onOpen,
                )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: switch (tab) {
                    'Mesh' => mesh(),
                    'Traffic' => traffic(),
                    'Signal' => signal(),
                    'Paths' => paths(),
                    'Scopes' => scopes(),
                    'Talkers' => [
                      bars(
                        tr('Top talkers · {{range}}')
                            .replaceAll('{{range}}', range),
                        '/stats/top-talkers',
                        'senderName',
                        'messageCount',
                      ),
                      AnalyticsCard(
                        title: tr('Top advertisers · {{range}}')
                            .replaceAll('{{range}}', range),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 4,
                              children: {'flood': 'Flood', 'direct': 'Direct'}
                                  .entries
                                  .map(
                                    (e) => ChoiceChip(
                                      label: Text(
                                        tr(e.value),
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      selected: e.key == advertiserSort,
                                      visualDensity: VisualDensity.compact,
                                      showCheckmark: false,
                                      onSelected: (_) => setState(
                                        () => advertiserSort = e.key,
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                            const SizedBox(height: 4),
                            query(
                              '/stats/top-advertisers',
                              (d) => AdvertiserList(
                                nodes: rows(d),
                                days:
                                    ((number(rolled['until']) ?? refreshed) -
                                        ((refreshed -
                                                rangeHours[range]! * 3600000) ~/
                                            3600000 *
                                            3600000)) /
                                    86400000,
                                onOpen: widget.onOpen,
                              ),
                              params: {
                                ...window,
                                'limit': 20,
                                'sort': advertiserSort,
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                    'Clock Drift' => [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          tr(
                            'Repeaters & room servers out of sync · worst first',
                          ),
                        ),
                      ),
                      query(
                        '/stats/clock-drift',
                        (d) {
                          final data = rows(d);
                          if (data.isEmpty) {
                            return Text(tr('No repeaters out of sync'));
                          }
                          data.sort(
                            (a, b) => (number(b['clockDriftSeconds']) ?? 0)
                                .abs()
                                .compareTo(
                                  (number(a['clockDriftSeconds']) ?? 0).abs(),
                                ),
                          );
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final node in data)
                                _ClockDriftCard(
                                  node: node,
                                  onTap: () => widget.onOpen(
                                    'node',
                                    textOf(node['nodeId']),
                                  ),
                                ),
                            ],
                          );
                        },
                        params: {...widget.region, 'limit': 100},
                        pollInterval: const Duration(minutes: 1),
                      ),
                    ],
                    'Compare Observers' => [
                      ComparisonPanel(
                        api: widget.api,
                        region: widget.region,
                        initialSelection: comparison,
                        onSelection: (value) => comparison = value,
                      ),
                    ],
                    _ => [],
                  },
                ),
        ),
      ),
    ],
  );
}

class _ScopeContents extends StatefulWidget {
  const _ScopeContents({
    required this.data,
    required this.hours,
    required this.packetKnown,
    required this.since,
    required this.until,
  });
  final List<Map<String, dynamic>> data, hours;
  final bool packetKnown;
  final int since, until;
  @override
  State<_ScopeContents> createState() => _ScopeContentsState();
}

class _ScopeContentsState extends State<_ScopeContents> {
  String search = '';
  @override
  Widget build(BuildContext context) {
    final data =
        widget.data
            .where(
              (s) =>
                  textOf(s['name'])
                      .toLowerCase()
                      .contains(search.toLowerCase()),
            )
            .toList()
          ..sort(
            (a, b) => (number(b['packetCount']) ?? 0).compareTo(
              number(a['packetCount']) ?? 0,
            ),
          );
    return Column(
      children: [
        TextField(
          decoration: InputDecoration(
            labelText: tr('Find a scope'),
            hintText: tr('#bc, #east…'),
            prefixIcon: const Icon(Icons.search),
          ),
          onChanged: (s) => setState(() => search = s),
        ),
        const SizedBox(height: 12),
        MetricGrid(
          values: {
            'Scopes with data': data
                .where(
                  (s) => [
                    'packetCount',
                    'observerCount',
                    'nodeCount',
                  ].any((k) => (number(s[k]) ?? 0) != 0),
                )
                .length,
            'Packets': widget.packetKnown
                ? data.fold<double>(
                    0,
                    (sum, s) => sum + (number(s['packetCount']) ?? 0),
                  )
                : null,
            'Observers': data.fold<double>(
              0,
              (sum, s) => sum + (number(s['observerCount']) ?? 0),
            ),
            'Default-scope nodes': data.fold<double>(
              0,
              (sum, s) => sum + (number(s['nodeCount']) ?? 0),
            ),
          },
          sparks: scopeLines(data, widget.hours, widget.since, widget.until),
        ),
        const SizedBox(height: 12),
        for (final e in {
          'Packets by scope': 'packetCount',
          'Observers by scope': 'observerCount',
          'Default-scope nodes': 'nodeCount',
        }.entries)
          AnalyticsCard(
            title: e.key,
            child: Builder(
              builder: (context) {
                if (e.value == 'packetCount' && !widget.packetKnown) {
                  return const AnalyticsEmptyState();
                }
                final ranked = List<Map<String, dynamic>>.of(data)
                  ..sort(
                    (a, b) => (number(b[e.value]) ?? 0).compareTo(
                      number(a[e.value]) ?? 0,
                    ),
                  );
                return RankedBars(
                  labels: [
                    ...ranked.take(12).map((r) => textOf(r['name'])),
                    if (ranked.length > 12) tr('Other scopes'),
                  ],
                  values: [
                    ...ranked.take(12).map((r) => number(r[e.value])),
                    if (ranked.length > 12)
                      ranked
                          .skip(12)
                          .fold<double>(
                            0,
                            (sum, r) => sum + (number(r[e.value]) ?? 0),
                          ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

class _AnalyticsDropdown<T> extends StatelessWidget {
  const _AnalyticsDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    required this.hint,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final colors = BeaconColors.of(context);
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: colors.raised,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          // Nine destinations need room to remain discoverable on short phones.
          menuMaxHeight: 480,
          dropdownColor: colors.surface,
          borderRadius: BorderRadius.circular(6),
          icon: Icon(Icons.expand_more, size: 18, color: colors.muted),
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 11,
            color: colors.normal,
          ),
          hint: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _ClockDriftCard extends StatelessWidget {
  const _ClockDriftCard({required this.node, required this.onTap});
  final Json node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = BeaconColors.of(context);
    final seconds = number(node['clockDriftSeconds']);
    final severity = seconds == null
        ? colors.muted
        : seconds.abs() >= 3600
        ? colors.danger
        : colors.warning;
    Widget badge(String label, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        border: Border.all(color: color.withValues(alpha: .25)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 10,
          color: color,
        ),
      ),
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        textOf(node['nodeName'], shortKey(node['nodeId'])),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.bright,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    badge(
                      textOf(node['nodeTypeName']).toUpperCase(),
                      colors.muted,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      clockDriftLabel(
                        seconds,
                        inSync: tr('in sync'),
                        ahead: tr('ahead'),
                        behind: tr('behind'),
                        unavailable: tr('Unavailable'),
                      ),
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 12,
                        color: severity,
                      ),
                    ),
                    Tooltip(
                      message:
                          '${tr('Checked')}: ${epoch(node['clockCheckedAt'])?.toLocal() ?? tr('Unavailable')}',
                      child: Text(
                        '${tr('Checked')}: ${age(node['clockCheckedAt'])}',
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 10,
                          color: colors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
                if (rows(node['iatas']).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final area in rows(node['iatas']))
                        badge(textOf(area['iata']), colors.primary),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
