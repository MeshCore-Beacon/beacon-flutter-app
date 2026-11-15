import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../analytics/charts.dart';
import '../analytics/transforms.dart';
import '../atlas/atlas.dart' show hourMs;
import 'directory_widgets.dart';

const _ranges = {'24h': '24h', '7d': '168h', '30d': '720h'};
const _intervalMs = {'24h': hourMs, '168h': 6 * hourMs, '720h': 24 * hourMs};

/// Node types the poller reads, as the server names them.
bool isPolledNodeType(String? typeName) => const {
  'repeater',
  'room server',
  'room_server',
}.contains((typeName ?? '').toLowerCase());

/// The last point that carries [key]; fields come from different points.
double? latestReading(List<Json> points, String key) {
  for (final p in points.reversed) {
    final v = number(p[key]);
    if (v != null) return v;
  }
  return null;
}

/// "4.23 V · 16.5 °C" from the newest battery and temperature, or null for neither.
String? readingsLine(List<Json> points) {
  final mv = latestReading(points, 'batteryMv');
  final c = latestReading(points, 'temperatureC');
  final parts = [
    if (mv != null) '${(mv / 1000).toStringAsFixed(2)} V',
    if (c != null) '${c.toStringAsFixed(1)} °C',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// One chart series. A bucket the server left out, or one without this field, is a
/// null point, so the line breaks instead of bridging the gap.
List<ChartPoint> telemetrySeries(
  List<Json> points,
  String key,
  int bucketMs, {
  double scale = 1,
}) {
  final out = <ChartPoint>[];
  for (var i = 0; i < points.length; i++) {
    final t = number(points[i]['t']) ?? 0;
    final v = number(points[i][key]);
    out.add(ChartPoint(t, v == null ? null : v * scale));
    final next = i + 1 < points.length ? number(points[i + 1]['t']) : null;
    if (next != null && next - t > bucketMs * 1.5) {
      out.add(ChartPoint(t + bucketMs, null));
    }
  }
  return out;
}

/// Counter seconds as a percent of the time they cover. A point with no span, or one
/// that computes above 100, has no value.
List<ChartPoint> airtimeSeries(List<Json> points, String key, int bucketMs) {
  final seconds = telemetrySeries(points, key, bucketMs);
  final out = <ChartPoint>[];
  var i = 0;
  for (final p in seconds) {
    double? y;
    final real = i < points.length && number(points[i]['t']) == p.x;
    if (real) {
      final span = number(points[i]['counterSpanSecs']);
      i++;
      if (p.y != null && span != null && span > 0) {
        final pct = p.y! / span * 100;
        y = pct > 100 ? null : pct;
      }
    }
    out.add(ChartPoint(p.x, y));
  }
  return out;
}

/// Polled readings for a repeater or room server. Draws nothing when the server has
/// polling off, the route is absent, or the node has no readings and no poller.
class NodeTelemetrySection extends StatefulWidget {
  const NodeTelemetrySection({
    super.key,
    required this.api,
    required this.nodeId,
    required this.onOpen,
  });
  final ApiClient api;
  final String nodeId;
  final void Function(String, String) onOpen;
  @override
  State<NodeTelemetrySection> createState() => _NodeTelemetrySectionState();
}

class _NodeTelemetrySectionState extends State<NodeTelemetrySection> {
  String range = '7d';
  bool enabled = false, hidden = false, loaded = false, failed = false;
  Json telemetry = {}, polling = {};
  int generation = 0, rangeToken = 0;

  @override
  void initState() {
    super.initState();
    start();
  }

  @override
  void didUpdateWidget(covariant NodeTelemetrySection old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api || old.nodeId != widget.nodeId) {
      loaded = hidden = enabled = failed = false;
      polling = telemetry = {};
      start();
    }
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  Future<void> start() async {
    final token = ++generation;
    bool current() => mounted && token == generation;
    final features = await widget.api.features();
    if (!current() || !features.polling) return;
    enabled = true;
    // The poller is a nicety: if its route fails the charts still show.
    final pollerFuture = widget.api
        .nodePolling(widget.nodeId)
        .catchError((Object _) => <String, dynamic>{});
    await loadTelemetry();
    final p = await pollerFuture;
    if (!current()) return;
    setState(() => polling = p);
  }

  Future<void> loadTelemetry() async {
    final token = generation, mine = ++rangeToken;
    try {
      final t = await widget.api.nodeTelemetry(
        widget.nodeId,
        range: _ranges[range]!,
      );
      if (!mounted || token != generation || mine != rangeToken) return;
      setState(() {
        telemetry = t;
        hidden = failed = false;
        loaded = true;
      });
    } catch (e) {
      if (!mounted || token != generation || mine != rangeToken) return;
      // Only a 404 means no such route; other failures keep the section and retry.
      final missing = e is ApiException && e.status == 404;
      setState(() {
        hidden = missing;
        failed = !missing;
        loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled || hidden || !loaded) return const SizedBox.shrink();
    final points = rows(telemetry['points']);
    final poller = object(polling['poller']);
    final standbys = rows(polling['standbys']);
    if (!failed &&
        points.isEmpty &&
        poller.isEmpty &&
        telemetry['polled'] != true) {
      return const SizedBox.shrink();
    }
    final colors = BeaconColors.of(context);
    final bucketMs = _intervalMs[_ranges[range]]!;
    bool has(String key) => points.any((p) => number(p[key]) != null);
    Widget chart(
      String title,
      Map<String, List<ChartPoint>> series,
      String unit, {
      bool dots = false,
    }) => AnalyticsCard(
      title: title,
      child: TimeChart(
        unit: unit,
        showSingleSeriesToggle: false,
        showDots: dots,
        series: series,
      ),
    );
    final name = textOf(poller['name'], tr('Unknown'));
    return section(trKey('nodeTelemetry.title'), [
      DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: range,
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        items: [
          DropdownMenuItem(
            value: '24h',
            child: Text(trKey('nodeTelemetry.range24h')),
          ),
          DropdownMenuItem(
            value: '7d',
            child: Text(trKey('nodeTelemetry.range7d')),
          ),
          DropdownMenuItem(
            value: '30d',
            child: Text(trKey('nodeTelemetry.range30d')),
          ),
        ],
        onChanged: (v) {
          if (v == null || v == range) return;
          setState(() => range = v);
          loadTelemetry();
        },
      ),
      const SizedBox(height: 12),
      if (failed) ...[
        Text(
          trKey('nodeTelemetry.failed'),
          style: TextStyle(fontSize: 12, color: colors.danger),
        ),
        TextButton.icon(
          onPressed: loadTelemetry,
          icon: const Icon(Icons.refresh),
          label: Text(tr('Retry')),
        ),
      ] else if (points.isEmpty)
        Text(
          trKey(
            telemetry['polled'] == true
                ? 'nodeTelemetry.empty'
                : 'nodeTelemetry.waiting',
          ),
          style: TextStyle(fontSize: 12, color: colors.muted),
        ),
      if (has('batteryMv'))
        chart(trKey('nodeTelemetry.battery'), {
          trKey('nodeTelemetry.batterySeries'): telemetrySeries(
            points,
            'batteryMv',
            bucketMs,
            scale: .001,
          ),
        }, ' V'),
      if (has('temperatureC'))
        chart(trKey('nodeTelemetry.temperature'), {
          trKey('nodeTelemetry.temperatureSeries'): telemetrySeries(
            points,
            'temperatureC',
            bucketMs,
          ),
        }, ' °C'),
      if (has('noiseFloorDb'))
        chart(trKey('nodeTelemetry.noiseFloor'), {
          trKey('nodeTelemetry.noiseFloorSeries'): telemetrySeries(
            points,
            'noiseFloorDb',
            bucketMs,
          ),
        }, ' dBm'),
      if (has('airtimeTxSecs') || has('airtimeRxSecs'))
        chart(
          trKey('nodeTelemetry.airtime'),
          {
            'RX': airtimeSeries(points, 'airtimeRxSecs', bucketMs),
            'TX': airtimeSeries(points, 'airtimeTxSecs', bucketMs),
          },
          '%',
          dots: true,
        ),
      if (poller.isNotEmpty)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            trKey('nodeTelemetry.polledBy').replaceAll('{{name}}', name),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right, size: 16),
          onTap: textOf(poller['observerId']).isEmpty
              ? null
              : () => widget.onOpen('observer', textOf(poller['observerId'])),
        ),
      if (polling['latestReadingAt'] != null)
        Tooltip(
          message: stamp(polling['latestReadingAt']),
          child: fact(
            trKey('nodeTelemetry.lastReading'),
            age(polling['latestReadingAt']),
          ),
        ),
      if (standbys.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Text(
            trKey('nodeTelemetry.standbys', count: standbys.length),
            style: TextStyle(fontSize: 11, color: colors.muted),
          ),
        ),
    ]);
  }
}
