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
  test(
    'flow lights reached nodes, combines packets and fades back to idle',
    () {
      final nodes = [
        {'id': 'a', 'lat': 43, 'lng': -79},
        {'id': 'b', 'lat': 44, 'lng': -79},
      ];
      final flows = [
        {'nodes': nodes, 'start': 0},
      ];
      expect(flowFrame(flows, 240)['glow'], {'a': 1.0});
      expect(flowFrame(flows, 480)['glow'], {'a': 1.0, 'b': 1.0});
      expect(flowFrame(flows, 980)['glow'], {'a': .5, 'b': .5});
      expect(
        flowFrame([
          ...flows,
          {'nodes': nodes, 'start': 900},
        ], 980)['glow'],
        {'a': 1.0, 'b': .5},
      );
      expect(flowFrame(flows, 1480)['glow'], isEmpty);
      expect(flowFrame([], 0)['glow'], isEmpty);
      expect(liveMarkerOpacity(false, {'a': 1}), 1.0);
      expect(liveMarkerOpacity(true, {}), 0.08);
      expect(liveMarkerOpacity(true, {'a': 1.0, 'b': .5}), [
        'match',
        ['get', 'id'],
        'a',
        1.0,
        'b',
        .5,
        .08,
      ]);
      final features = nodeFeatures(nodes)['features'] as List;
      expect(features.map((f) => f['id']), ['a', 'b']);
    },
  );
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
}
