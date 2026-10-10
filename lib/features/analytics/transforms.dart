import 'dart:math' as math;

typedef RecordData = Map<String, dynamic>;
double? metric(dynamic value) =>
    value is num && value.isFinite ? value.toDouble() : null;

class ChartPoint {
  const ChartPoint(this.x, this.y);
  final double x;
  final double? y;
}

const rangeHours = {'24h': 24, '7d': 168, '30d': 720};
Map<String, dynamic> rolledWindow(String range, int now) {
  final until = ((now - 95 * 60000) ~/ 3600000 + 1) * 3600000;
  return {'since': until - rangeHours[range]! * 3600000, 'until': until};
}

List<ChartPoint> rollupPoints(List<RecordData> hours, String key) => hours
    .map(
      (h) => ChartPoint(
        metric(h['hour']) ?? 0,
        h['status'] == 'complete' && h['values'] is Map
            ? metric(h['values'][key])
            : null,
      ),
    )
    .toList();
List<RecordData> fillActivity(
  List<RecordData> points,
  int interval,
  int start,
  int end, {
  int? rolledUntil,
  int? rawFrom,
}) {
  if (interval <= 0 || end < start) return [];
  final indexed = {
    for (final p in points) ((metric(p['t']) ?? 0) ~/ interval) * interval: p,
  };
  final current = end ~/ interval * interval;
  final last = indexed.containsKey(current + interval)
      ? current + interval
      : current;
  return [
    for (var t = (start / interval).ceil() * interval; t <= last; t += interval)
      indexed[t] ??
          {
            't': t,
            'observations':
                rawFrom != null &&
                    t < rawFrom &&
                    (rolledUntil == null || t >= rolledUntil)
                ? null
                : 0,
            'airtimeMs':
                rawFrom != null &&
                    t < rawFrom &&
                    (rolledUntil == null || t >= rolledUntil)
                ? null
                : 0,
            'snrAvg': null,
            'snrMin': null,
            'rssiAvg': null,
          },
  ];
}

List<ChartPoint> airtimePercent(
  List<RecordData> points,
  String key, {
  int? bucketMs,
}) {
  if (bucketMs != null) {
    return points
        .map(
          (p) => ChartPoint(
            metric(p['t']) ?? 0,
            metric(p[key]) == null ? null : metric(p[key])! * 100000 / bucketMs,
          ),
        )
        .toList();
  }
  return [
    for (var i = 1; i < points.length; i++)
      ChartPoint(
        metric(points[i]['t']) ?? 0,
        metric(points[i][key]) != null &&
                metric(points[i - 1][key]) != null &&
                (metric(points[i]['t']) ?? 0) >
                    (metric(points[i - 1]['t']) ?? 0)
            ? math.max(
                    0,
                    metric(points[i][key])! - metric(points[i - 1][key])!,
                  ) *
                  100000 /
                  (metric(points[i]['t'])! - metric(points[i - 1]['t'])!)
            : null,
      ),
  ];
}

List<ChartPoint> trafficHours(
  List<RecordData> rows,
  int start,
  int end, {
  String? iata,
}) {
  final buckets = <int, double>{};
  final present = <int>{};
  for (final r in rows) {
    final t = metric(r['hour']);
    final count = metric(r['observationCount']);
    if (t == null || count == null || count < 0 || t < start || t > end) {
      continue;
    }
    final hour = t ~/ 3600000 * 3600000;
    present.add(hour);
    if (iata == null || normalizedIata(r['iata']) == iata) {
      buckets[hour] = (buckets[hour] ?? 0) + count;
    }
  }
  return [
    for (var t = start; t <= end; t += 3600000)
      ChartPoint(t.toDouble(), present.contains(t) ? buckets[t] ?? 0 : null),
  ];
}

List<ChartPoint> trafficAreaHours(List<RecordData> rows, int start, int end) {
  final areas = <int, Set<String>>{};
  for (final row in rows) {
    final time = metric(row['hour']), count = metric(row['observationCount']);
    if (time == null ||
        count == null ||
        count < 0 ||
        time < start ||
        time > end) {
      continue;
    }
    final hour = time ~/ 3600000 * 3600000;
    areas.putIfAbsent(hour, () => <String>{}).add(normalizedIata(row['iata']));
  }
  return [
    for (var hour = start; hour <= end; hour += 3600000)
      ChartPoint(hour.toDouble(), areas[hour]?.length.toDouble()),
  ];
}

String normalizedIata(dynamic value) => '${value ?? ''}'.trim().isEmpty
    ? 'Unassigned'
    : '$value'.trim().toUpperCase();
String? validateComparison(String a, String b, int since, int until) {
  final uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  if (!uuid.hasMatch(a) ||
      !uuid.hasMatch(b) ||
      a.toLowerCase() == b.toLowerCase()) {
    return 'Choose two different observers.';
  }
  if (since < 0 || until <= since || until > 253402300799999) {
    return 'End must be after start.';
  }
  return null;
}

List<(int, int)> graphEdges(List<RecordData> nodes) {
  final index = {for (var i = 0; i < nodes.length; i++) nodes[i]['id']: i};
  final links = <(int, int)>{};
  for (var i = 0; i < nodes.length; i++) {
    for (final id
        in (nodes[i]['neighborIds'] is List
            ? nodes[i]['neighborIds'] as List
            : const [])) {
      final j = index[id];
      if (j != null && i != j) links.add((math.min(i, j), math.max(i, j)));
    }
  }
  return links.toList();
}

// Retained endpoints omit hours without rows. Those are unknown, not zero.
List<ChartPoint> windowedPoints(
  RecordData data,
  String key, {
  String? sampleKey,
}) {
  final since = metric(data['since']), until = metric(data['until']);
  if (since == null || until == null || until <= since) return [];
  final first = since ~/ 3600000 * 3600000;
  final input = data['hourly'] is List ? data['hourly'] as List : const [];
  final byHour = {
    for (final item in input.whereType<Map>())
      metric(item['hour'])?.toInt(): item,
  };
  return [
    for (var i = 0; i < math.min(721, ((until - first) / 3600000).ceil()); i++)
      ChartPoint(
        (first + i * 3600000).toDouble(),
        byHour[first + i * 3600000] == null ||
                (sampleKey != null &&
                    (metric(byHour[first + i * 3600000]![sampleKey]) ?? 0) <= 0)
            ? null
            : metric(byHour[first + i * 3600000]![key]),
      ),
  ];
}

Map<String, List<ChartPoint>> pathSparklines(RecordData data) {
  final one = windowedPoints(data, 'oneByte');
  final two = windowedPoints(data, 'twoByte');
  final three = windowedPoints(data, 'threeByte');
  final hashed = <ChartPoint>[], share = <ChartPoint>[];
  for (var i = 0; i < one.length; i++) {
    final a = one[i].y, b = two[i].y, c = three[i].y;
    final total = a == null || b == null || c == null ? null : a + b + c;
    hashed.add(ChartPoint(one[i].x, total));
    share.add(
      ChartPoint(
        one[i].x,
        total == null || total == 0 ? null : (b! + c!) / total,
      ),
    );
  }
  return {'With hash paths': hashed, 'Multi-byte share': share};
}

List<RecordData> foldNeighbours(String center, List<RecordData> neighbours) {
  final folded = <String, RecordData>{};
  for (final n in neighbours) {
    final id = '${n['id'] ?? ''}';
    if (id.isEmpty || id == center) continue;
    final previous = folded[id];
    folded[id] = {
      ...n,
      'observationCount':
          (metric(previous?['observationCount']) ?? 0) +
          (metric(n['observationCount']) ?? 0),
      'lastSeen': math.max(
        metric(previous?['lastSeen']) ?? 0,
        metric(n['lastSeen']) ?? 0,
      ),
    };
  }
  return folded.values.toList();
}

Map<String, List<ChartPoint>> scopeLines(
  List<RecordData> scopes,
  List<RecordData> hours,
  int since,
  int until,
) {
  if (scopes.any((s) => s['hourly'] is! List)) return {};
  final byHour = <int, Map<String, double>>{};
  var hasActivity = true;
  for (final scope in scopes) {
    for (final row in (scope['hourly'] as List).whereType<Map>()) {
      final t = metric(row['hour'])?.toInt();
      if (t == null) continue;
      final value = byHour.putIfAbsent(
        t,
        () => {
          'Packets': 0,
          'Scopes with data': 0,
          'Observers': 0,
          'Default-scope nodes': 0,
        },
      );
      final packets = metric(row['packets']) ?? 0,
          observers = metric(row['observers']) ?? 0,
          nodes = metric(row['nodes']) ?? 0;
      value['Packets'] = value['Packets']! + packets;
      value['Observers'] = value['Observers']! + observers;
      value['Default-scope nodes'] = value['Default-scope nodes']! + nodes;
      if (packets != 0 || observers != 0 || nodes != 0) {
        value['Scopes with data'] = value['Scopes with data']! + 1;
      }
      if (row['observers'] == null || row['nodes'] == null) hasActivity = false;
    }
  }
  return {
    for (final key in [
      'Packets',
      'Scopes with data',
      if (hasActivity) ...['Observers', 'Default-scope nodes'],
    ])
      key: [
        for (final hour in hours)
          ChartPoint(
            metric(hour['hour']) ?? 0,
            hour['status'] != 'complete' ||
                    (metric(hour['hour']) ?? 0) < since ||
                    (metric(hour['hour']) ?? 0) >= until
                ? null
                : byHour[metric(hour['hour'])?.toInt()]?[key] ?? 0,
          ),
      ],
  };
}

String clockDriftLabel(
  double? seconds, {
  String inSync = 'in sync',
  String ahead = 'ahead',
  String behind = 'behind',
  String unavailable = 'Unavailable',
}) {
  if (seconds == null || !seconds.isFinite) return unavailable;
  if (seconds == 0) return inSync;
  final magnitude = seconds.abs().round(),
      hours = magnitude ~/ 3600,
      minutes = magnitude % 3600 ~/ 60,
      remainder = magnitude % 60;
  final duration = hours > 0
      ? '${hours}h ${minutes}m'
      : minutes > 0
      ? '${minutes}m ${remainder}s'
      : '${remainder}s';
  return '${seconds > 0 ? '+' : '-'}$duration ${seconds > 0 ? ahead : behind}';
}
