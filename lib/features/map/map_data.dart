import 'dart:math' as math;

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

const nodeTypes = ['companion', 'repeater', 'room_server', 'sensor'];

// Under All, Live keeps repeaters and companions on the map as idle dots.
List<String> liveDotTypes(String filter) =>
    filter.isEmpty ? ['repeater', 'companion'] : [filter];

Map<String, dynamic> flowFrame(List<Map<String, dynamic>> flows, int now) {
  final dots = <Map<String, dynamic>>[], trails = <Map<String, dynamic>>[];
  final lit = <String, Map<String, num>>{};
  for (final flow in flows) {
    final ns = rows(flow['nodes']);
    if (ns.length < 2) continue;
    final start = number(flow['start']) ?? 0;
    final elapsed = now - start;
    if (elapsed < 0) continue;
    final duration = (ns.length - 1) * 480;
    final fade = (1 - (elapsed - duration) / 1000).clamp(0.0, 1.0);
    if (fade <= 0) continue;
    final t = (elapsed / 480).clamp(0.0, (ns.length - 1).toDouble());
    final idx = t.floor();
    for (var i = 0; i <= idx; i++) {
      final id = textOf(ns[i]['id']), at = start + i * 480;
      // The light follows the packet: full on arrival, out 0.9 s later.
      final light = 1 - (now - at) / 900;
      if (id.isEmpty || light <= 0 || at <= (lit[id]?['at'] ?? -1)) continue;
      lit[id] = {'a': light, 'at': at};
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
  return {'dots': collection(dots), 'trails': collection(trails), 'lit': lit};
}

// The map's glyph font has no emoji; they would render as blank boxes.
final _pictographs = RegExp(
  // The lint parses without unicode: true; this is valid in unicode mode.
  // ignore: valid_regexps
  r'[\p{Extended_Pictographic}\u{1F1E6}-\u{1F1FF}\u{1F3FB}-\u{1F3FF}'
  r'\u{E0020}-\u{E007F}\u{FE0E}\u{FE0F}\u{200D}\u{20E3}]',
  unicode: true,
);
String mapLabel(Object? name) =>
    textOf(name)
        .replaceAll(_pictographs, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

Map<String, Map<String, dynamic>> featureIndex(Map<String, dynamic> points) => {
  for (final f in rows(points['features']))
    textOf(object(f['properties'])['id']): f,
};

// Lit nodes come from the node list: packet hops carry no node type.
Map<String, dynamic> litFeatures(
  Map<String, dynamic> lit,
  Map<String, Map<String, dynamic>> index,
) {
  final entries = [
    for (final MapEntry(:key, :value) in lit.entries)
      if (nodeTypes.contains(object(index[key]?['properties'])['nodeTypeName']))
        (id: key, light: object(value)),
  ];
  entries.sort((a, b) {
    final order = (number(a.light['at']) ?? 0).compareTo(
      number(b.light['at']) ?? 0,
    );
    return order != 0 ? order : a.id.compareTo(b.id);
  });
  final features = <Map<String, dynamic>>[];
  for (final (seq, e) in entries.indexed) {
    final f = index[e.id]!, props = object(f['properties']);
    final type = props['nodeTypeName'];
    features.add(
      feature('Point', object(f['geometry'])['coordinates'], {
        'id': e.id,
        'nodeTypeName': type,
        'label': type == 'repeater' || type == 'companion'
            ? mapLabel(props['name'])
            : '',
        'a': e.light['a'],
        'seq': seq,
      }),
    );
  }
  return collection(features);
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

Map<String, dynamic>? nearestFeature(List hits, double lat, double lng) {
  final scale = math.cos(lat * math.pi / 180);
  Map<String, dynamic>? best;
  var bestDistance = double.infinity;
  for (final hit in hits) {
    final coords = object(object(hit)['geometry'])['coordinates'];
    if (coords is! List || coords.length < 2) continue;
    final x = number(coords[0]), y = number(coords[1]);
    if (x == null || y == null) continue;
    final dx = (x - lng) * scale, dy = y - lat;
    final distance = dx * dx + dy * dy;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = object(object(hit)['properties']);
    }
  }
  return best;
}

int countInBounds(
  Map<String, dynamic> points, {
  required double south,
  required double west,
  required double north,
  required double east,
}) {
  var count = 0;
  for (final f in rows(points['features'])) {
    final coords = object(f['geometry'])['coordinates'];
    if (coords is! List || coords.length < 2) continue;
    final lng = number(coords[0]), lat = number(coords[1]);
    if (lng == null || lat == null || lat < south || lat > north) continue;
    // A viewport across the antimeridian has west > east.
    final inside = west <= east
        ? lng >= west && lng <= east
        : lng >= west || lng <= east;
    if (inside) count++;
  }
  return count;
}
