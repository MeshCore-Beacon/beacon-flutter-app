import 'package:beacon/features/map/map_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'map links preserve deployment prefix and web-compatible view parameters',
    () {
      final link = mapShareUri(
        Uri.parse('https://example.org/beacon'),
        {'iatas': 'YOW,YUL'},
        lat: 45.123456,
        lng: -75.12,
        zoom: 9.876,
        style: 'dark',
        nodeType: 'repeater',
        cluster: true,
        neighbors: 'selected',
        borders: true,
        flow: false,
      );
      expect(link.path, '/beacon');
      expect(link.queryParameters['tab'], 'Map');
      expect(link.queryParameters['iata'], 'YOW,YUL');
      expect(link.queryParameters['lat'], '45.12346');
      expect(link.queryParameters['zoom'], '9.88');
      expect(link.queryParameters['node_type'], 'repeater');
    },
  );
  test(
    'rejects reset and invalid coordinates but preserves single zero axes',
    () {
      expect(hasLocation({'lat': 0, 'lng': 0}), false);
      expect(hasLocation({'lat': 91, 'lng': 1}), false);
      expect(hasLocation({'lat': 0, 'lng': 10}), true);
      expect(hasLocation({'lat': double.nan, 'lng': 10}), false);
    },
  );
  test('GeoJSON uses longitude first and undirected edges occur once', () {
    final nodes = <Map<String, dynamic>>[
      {
        'id': 'a',
        'lat': 43,
        'lng': -79,
        'neighborIds': ['b', 'a'],
      },
      {
        'id': 'b',
        'lat': 44,
        'lng': -80,
        'neighborIds': ['a'],
      },
      {
        'id': 'c',
        'lat': 0,
        'lng': 0,
        'neighborIds': ['a'],
      },
    ];
    expect(nodeFeatures(nodes)['features'][0]['geometry']['coordinates'], [
      -79,
      43,
    ]);
    expect(neighborFeatures(nodes, 'on', null)['features'].length, 1);
    expect(neighborFeatures(nodes, 'selected', 'c')['features'], isEmpty);
  });
  test(
    'focused links fold duplicate region observations and use freshest age',
    () {
      final fc = focusedFeatures(
        {'id': 'a', 'lat': 43, 'lng': -79},
        [
          {
            'id': 'b',
            'lat': 44,
            'lng': -80,
            'observationCount': 2,
            'lastSeen': 86400000,
          },
          {
            'id': 'b',
            'lat': 44,
            'lng': -80,
            'observationCount': 3,
            'lastSeen': 172800000,
          },
        ],
        now: 259200000,
      );
      expect(fc['features'].single['properties'], {
        'selected': true,
        'obs': 5.0,
        'ageDays': 1.0,
      });
    },
  );
  test('live flow refuses any ambiguous hop and interpolates valid hops', () {
    Map<String, dynamic> hop(String id, int lat) => {
      'confidence': 'high',
      'nodes': [
        {'id': id, 'latitude': lat, 'longitude': -79},
      ],
    };
    expect(
      flowNodes({
        'resolvedPath': [
          hop('a', 43),
          {'confidence': 'low', 'nodes': []},
          hop('b', 44),
        ],
      }),
      isEmpty,
    );
    final ns = flowNodes({
      'resolvedPath': [hop('a', 43), hop('b', 44)],
    });
    final f = flowFrame([
      {'nodes': ns, 'start': 0},
    ], 240);
    expect(f['dots']['features'].single['geometry']['coordinates'], [
      -79.0,
      43.5,
    ]);
    expect(
      flowFrame([
        {'nodes': ns, 'start': 0},
      ], 1500)['dots']['features'],
      isEmpty,
    );
  });
  test('live light peaks when the dot arrives and fades over 0.9 s', () {
    final nodes = [
      {'id': 'a', 'lat': 43, 'lng': -79},
      {'id': 'b', 'lat': 44, 'lng': -79},
    ];
    final flows = [
      {'nodes': nodes, 'start': 0},
    ];
    expect(flowFrame(flows, 0)['lit'], {
      'a': {'a': 1.0, 'at': 0},
    });
    expect(flowFrame(flows, 480)['lit'], {
      'a': {'a': closeTo(1 - 480 / 900, 1e-9), 'at': 0},
      'b': {'a': 1.0, 'at': 480},
    });
    expect(flowFrame(flows, 900)['lit'], {
      'b': {'a': closeTo(1 - 420 / 900, 1e-9), 'at': 480},
    });
    expect(flowFrame(flows, 1380)['lit'], isEmpty);
    // A later packet re-lights a node to full.
    expect(
      flowFrame([
        ...flows,
        {'nodes': nodes, 'start': 600},
      ], 600)['lit']['a'],
      {'a': 1.0, 'at': 600},
    );
    expect(flowFrame([], 0)['lit'], isEmpty);
  });
  test('lit features rank newest last, name only repeaters, skip unknowns', () {
    final index = featureIndex(
      nodeFeatures([
        {
          'id': 'r',
          'name': 'Valentine 💬',
          'nodeTypeName': 'repeater',
          'lat': 47.6,
          'lng': -122.3,
        },
        {
          'id': 'c',
          'name': 'Phone',
          'nodeTypeName': 'companion',
          'lat': 47.5,
          'lng': -122.2,
        },
        {
          'id': 'u',
          'name': 'Odd',
          'nodeTypeName': 'unknown',
          'lat': 47.4,
          'lng': -122.1,
        },
      ]),
    );
    final fc = litFeatures({
      'c': {'a': 1.0, 'at': 960},
      'r': {'a': .5, 'at': 480},
      'u': {'a': 1.0, 'at': 960},
      'gone': {'a': 1.0, 'at': 960},
    }, index);
    final fs = fc['features'] as List;
    expect(fs.map((f) => f['properties']['id']), ['r', 'c']);
    expect(fs.map((f) => f['properties']['seq']), [0, 1]);
    expect(fs.map((f) => f['properties']['label']), ['Valentine', '']);
    expect(fs.map((f) => f['properties']['a']), [.5, 1.0]);
    // Position comes from the node list, not the packet hop.
    expect(fs.first['geometry']['coordinates'], [-122.3, 47.6]);
  });
  test('map labels drop emoji the map font cannot draw', () {
    expect(mapLabel('Portage Bay 🐳'), 'Portage Bay');
    expect(mapLabel('🇨🇦 Ottawa'), 'Ottawa');
    expect(mapLabel('👍🏽 ok'), 'ok');
    expect(mapLabel('a 1️⃣ b'), 'a 1 b');
    expect(mapLabel('🐳🐳'), '');
    expect(mapLabel('Ålesund_Rpt'), 'Ålesund_Rpt');
    expect(mapLabel(null), '');
  });
  test('unknown hops break paths instead of fabricating a connection', () {
    Map<String, dynamic> hop(String id, int lat) => {
      'confidence': 'high',
      'nodes': [
        {'id': id, 'latitude': lat, 'longitude': -79},
      ],
    };
    final paths = packetPaths({
      'header': {'payloadType': 1},
      'observations': [
        {
          'observerId': 'o',
          'resolvedPath': [
            hop('a', 43),
            {'nodes': []},
            hop('b', 44),
            hop('c', 45),
          ],
        },
      ],
    });
    expect(paths.single['points'][1]['breakBefore'], true);
    expect(pathFeatures(paths, null)['lines']['features'].length, 1);
  });
  test('wrong-typed neighborIds are ignored', () {
    final nodes = <Map<String, dynamic>>[
      {'id': 'a', 'lat': 45.0, 'lng': -75.0, 'neighborIds': 'b'},
      {
        'id': 'b',
        'lat': 46.0,
        'lng': -75.0,
        'neighborIds': {'x': 1},
      },
    ];
    expect(neighborFeatures(nodes, 'on', null)['features'], isEmpty);
  });
  test('live taps pick the nearest hit and counts span the antimeridian', () {
    Map<String, dynamic> hit(String id, double lng, double lat) =>
        feature('Point', [lng, lat], {'id': id});
    expect(
      nearestFeature(
        [hit('far', -75.02, 45), hit('near', -75.001, 45)],
        45,
        -75,
      )!['id'],
      'near',
    );
    expect(nearestFeature([], 45, -75), isNull);
    final points = nodeFeatures([
      {'id': 'w', 'lat': 0.5, 'lng': 179.5},
      {'id': 'e', 'lat': 0.5, 'lng': -179.5},
      {'id': 'x', 'lat': 0.5, 'lng': 10},
    ]);
    expect(countInBounds(points, south: 0, west: 179, north: 1, east: -179), 2);
    expect(countInBounds(points, south: 0, west: 9, north: 1, east: 11), 1);
  });
}
