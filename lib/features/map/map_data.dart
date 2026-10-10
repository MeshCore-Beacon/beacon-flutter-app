import '../../core/json.dart';

Map<String, dynamic> collection(Iterable<Map<String, dynamic>> features) => {
  'type': 'FeatureCollection',
  'features': features.toList(),
};
Map<String, dynamic> feature(
  String type,
  dynamic coordinates,
  Map<String, dynamic> properties,
) => {
  'type': 'Feature',
  if (properties['id'] != null) 'id': properties['id'],
  'geometry': {'type': type, 'coordinates': coordinates},
  'properties': properties,
};
bool hasLocation(Map<String, dynamic>? node) {
  final lat = number(node?['lat']), lng = number(node?['lng']);
  return lat != null &&
      lng != null &&
      lat.isFinite &&
      lng.isFinite &&
      lat.abs() <= 90 &&
      lng.abs() <= 180 &&
      (lat != 0 || lng != 0);
}

List<double> coordinates(Map<String, dynamic> n) => [
  number(n['lng'])!,
  number(n['lat'])!,
];
Map<String, dynamic> nodeFeatures(
  List<Map<String, dynamic>> nodes, {
  String type = '',
}) => collection(
  nodes
      .where(
        (n) => hasLocation(n) && (type.isEmpty || n['nodeTypeName'] == type),
      )
      .map(
        (n) => feature('Point', coordinates(n), {
          'id': n['id'],
          'name': n['name'] ?? n['id'],
          'nodeTypeName': n['nodeTypeName'] ?? 'unknown',
          'isObserver': n['isObserver'] == true,
        }),
      ),
);
Map<String, dynamic> neighborFeatures(
  List<Map<String, dynamic>> nodes,
  String mode,
  String? selected,
) {
  final located = {
    for (final n in nodes.where(hasLocation)) textOf(n['id']): n,
  };
  final seen = <String>{};
  final result = <Map<String, dynamic>>[];
  if (mode == 'off') return collection(result);
  for (final n in located.values) {
    for (final id
        in (n['neighborIds'] is List ? n['neighborIds'] as List : const [])) {
      final other = located[id];
      if (other == null || id == n['id']) continue;
      final pair = [textOf(n['id']), textOf(id)]..sort();
      final incident = n['id'] == selected || id == selected;
      if (mode == 'selected' && !incident || !seen.add(pair.join('|'))) {
        continue;
      }
      result.add(
        feature(
          'LineString',
          [coordinates(n), coordinates(other)],
          {'selected': incident},
        ),
      );
    }
  }
  return collection(result);
}

Map<String, dynamic> focusedFeatures(
  Map<String, dynamic>? selected,
  List<Map<String, dynamic>> neighbors, {
  int? now,
}) {
  if (!hasLocation(selected)) return collection([]);
  final folded = <String, Map<String, dynamic>>{};
  for (final n in neighbors.where(hasLocation)) {
    final id = textOf(n['id']);
    if (id == selected!['id']) continue;
    final prev = folded[id];
    folded[id] = {
      ...n,
      'observationCount':
          (number(prev?['observationCount']) ?? 0) +
          (number(n['observationCount']) ?? 0),
      'lastSeen': [
        (number(prev?['lastSeen']) ?? 0),
        (number(n['lastSeen']) ?? 0),
      ].reduce((a, b) => a > b ? a : b),
    };
  }
  return collection(
    folded.values.map(
      (n) => feature(
        'LineString',
        [coordinates(selected!), coordinates(n)],
        {
          'selected': true,
          'obs': n['observationCount'],
          'ageDays':
              (((now ?? DateTime.now().millisecondsSinceEpoch) -
                          (number(n['lastSeen']) ?? 0)) /
                      86400000)
                  .clamp(0, double.infinity),
        },
      ),
    ),
  );
}

const pathColors = [
  '#ff6b35',
  '#00b4d8',
  '#22c55e',
  '#e879f9',
  '#eab308',
  '#3b82f6',
  '#ef4444',
  '#a78bfa',
];
List<Map<String, dynamic>> packetPaths(Map<String, dynamic> detail) {
  final output = <Map<String, dynamic>>[];
  void add(
    String key,
    String label,
    dynamic propagation,
    List<Map<String, dynamic>> hops,
  ) {
    final points = <Map<String, dynamic>>[];
    final seen = <String>{};
    var gap = false;
    for (final hop in hops) {
      final candidates = rows(hop['nodes']);
      final n = candidates.length == 1
          ? candidates.single
          : <String, dynamic>{};
      final loc = {'lat': n['latitude'], 'lng': n['longitude']};
      if (hop['confidence'] != 'high' || !hasLocation(loc)) {
        gap = true;
        continue;
      }
      final id = textOf(n['id']);
      if (!seen.add(id)) {
        gap = points.isNotEmpty && points.last['id'] != id;
        continue;
      }
      points.add({
        ...loc,
        'id': id,
        'name': n['name'] ?? id,
        'breakBefore': gap && points.isNotEmpty,
      });
      gap = false;
    }
    if (points.length >= 2) {
      output.add({
        'key': key,
        'label': label,
        'propagationMs': propagation,
        'points': points,
      });
    }
  }

  final isTrace = object(detail['header'])['payloadType'] == 9;
  if (isTrace) {
    add('trace', 'Trace route', null, rows(detail['resolvedRoute']));
  } else {
    for (final obs in rows(detail['observations'])) {
      final source = object(obs['resolvedSource']),
          destination = object(obs['resolvedDestination']);
      add(
        textOf(obs['observerId']),
        textOf(obs['observerName'], textOf(obs['observerId'])),
        obs['propagationTimeMs'],
        [
          if (source['confidence'] == 'high') source,
          ...rows(obs['resolvedPath']),
          if (destination['confidence'] == 'high') destination,
        ],
      );
    }
  }
  output.sort(
    (a, b) => (number(a['propagationMs']) ?? double.infinity).compareTo(
      number(b['propagationMs']) ?? double.infinity,
    ),
  );
  for (var i = 0; i < output.length; i++) {
    output[i]['color'] = pathColors[i % pathColors.length];
  }
  return output;
}

Map<String, dynamic> pathFeatures(
  List<Map<String, dynamic>> paths,
  String? key,
) {
  final lines = <Map<String, dynamic>>[], points = <Map<String, dynamic>>[];
  for (final path in paths.where((p) => key == null || p['key'] == key)) {
    var segment = <List<double>>[];
    void finish() {
      if (segment.length > 1) {
        lines.add(
          feature('LineString', segment, {
            'key': path['key'],
            'color': path['color'],
          }),
        );
      }
      segment = [];
    }

    for (final p in rows(path['points'])) {
      if (p['breakBefore'] == true) finish();
      segment.add(coordinates(p));
      points.add(
        feature('Point', coordinates(p), {
          'id': p['id'],
          'name': p['name'],
          'color': path['color'],
        }),
      );
    }
    finish();
  }
  return {'lines': collection(lines), 'points': collection(points)};
}

List<Map<String, dynamic>> flowNodes(Map<String, dynamic> observation) {
  if (observation['resolvedPath'] is! List) return [];
  final source = object(observation['resolvedSource']),
      destination = object(observation['resolvedDestination']);
  final hops = [
    if (source['confidence'] == 'high') source,
    ...rows(observation['resolvedPath']),
    if (destination['confidence'] == 'high') destination,
  ];
  final result = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final h in hops) {
    final ns = rows(h['nodes']);
    if (h['confidence'] != 'high' || ns.length != 1) return [];
    final n = ns.single;
    final p = {...n, 'lat': n['latitude'], 'lng': n['longitude']};
    if (!hasLocation(p)) return [];
    if (seen.add(textOf(p['id']))) result.add(p);
  }
  return result;
}

Map<String, dynamic> flowFrame(List<Map<String, dynamic>> flows, int now) {
  final dots = <Map<String, dynamic>>[], trails = <Map<String, dynamic>>[];
  final glow = <String, double>{};
  for (final flow in flows) {
    final ns = rows(flow['nodes']);
    if (ns.length < 2) continue;
    final elapsed = now - (number(flow['start']) ?? 0);
    if (elapsed < 0) continue;
    final duration = (ns.length - 1) * 480;
    final fade = (1 - (elapsed - duration) / 1000).clamp(0.0, 1.0);
    if (fade <= 0) continue;
    final t = (elapsed / 480).clamp(0.0, (ns.length - 1).toDouble());
    final idx = t.floor();
    for (final node in ns.take(idx + 1)) {
      final id = textOf(node['id']);
      if (id.isNotEmpty && fade > (glow[id] ?? 0)) glow[id] = fade;
    }
    final coords = ns.take(idx + 1).map(coordinates).toList();
    if (idx < ns.length - 1) {
      final a = coordinates(ns[idx]), b = coordinates(ns[idx + 1]);
      final p = [
        a[0] + (b[0] - a[0]) * (t - idx),
        a[1] + (b[1] - a[1]) * (t - idx),
      ];
      coords.add(p);
      dots.add(feature('Point', p, {'a': 1.0}));
    }
    if (coords.length >= 2) {
      trails.add(feature('LineString', coords, {'a': 0.6 * fade}));
    }
  }
  return {'dots': collection(dots), 'trails': collection(trails), 'glow': glow};
}

// Match expressions work on both native SDKs; iOS lacks feature-state updates.
dynamic liveMarkerOpacity(bool live, Map<String, dynamic> glow) {
  if (!live) return 1.0;
  if (glow.isEmpty) return 0.08;
  return [
    'match',
    ['get', 'id'],
    for (final entry in glow.entries) ...[
      entry.key,
      (number(entry.value) ?? 0).clamp(0.08, 1.0),
    ],
    0.08,
  ];
}

Uri mapShareUri(
  Uri base,
  Map<String, dynamic> region, {
  required double lat,
  required double lng,
  required double zoom,
  required String style,
  required String nodeType,
  required bool cluster,
  required String neighbors,
  required bool borders,
  required bool flow,
}) => base.replace(
  queryParameters: {
    'tab': 'Map',
    if (region['iatas'] != null)
      'iata': region['iatas'] is List
          ? (region['iatas'] as List).join(',')
          : textOf(region['iatas']),
    if (region['region'] != null) 'region': textOf(region['region']),
    'lat': lat.toStringAsFixed(5),
    'lng': lng.toStringAsFixed(5),
    'zoom': zoom.toStringAsFixed(2),
    'style': style,
    if (nodeType.isNotEmpty) 'node_type': nodeType,
    'clustering': cluster ? 'on' : 'off',
    'neighbor_lines': neighbors,
    'borders': borders ? 'on' : 'off',
    'flow': flow ? 'on' : 'off',
  },
);
