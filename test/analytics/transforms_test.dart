import 'package:beacon/features/analytics/transforms.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'path sparks sum hash widths and keep missing or undefined shares as gaps',
    () {
      final sparks = pathSparklines({
        'since': 0,
        'until': 14400000,
        'hourly': [
          {'hour': 0, 'oneByte': 5, 'twoByte': 3, 'threeByte': 2},
          {'hour': 3600000, 'oneByte': 0, 'twoByte': 0, 'threeByte': 0},
          {'hour': 7200000, 'oneByte': 5, 'twoByte': 3},
        ],
      });
      expect(sparks['With hash paths']!.map((p) => p.y), [10, 0, null, null]);
      expect(sparks['Multi-byte share']!.map((p) => p.y), [
        .5,
        null,
        null,
        null,
      ]);
    },
  );

  test(
    'traffic area sparks count unique reporting areas and preserve gaps',
    () {
      final points = trafficAreaHours(
        [
          {'hour': 0, 'iata': ' yow ', 'observationCount': 0},
          {'hour': 0, 'iata': 'YOW', 'observationCount': 2},
          {'hour': 0, 'iata': 'YYZ', 'observationCount': 5},
          {'hour': 7200000, 'iata': 'YOW', 'observationCount': -1},
        ],
        0,
        7200000,
      );
      expect(points.map((p) => p.y), [2, null, null]);
    },
  );

  test(
    'live clock drift formats signed durations without count abbreviations',
    () {
      expect(clockDriftLabel(-1791043164), '-497511h 59m behind');
      expect(clockDriftLabel(61), '+1m 1s ahead');
      expect(clockDriftLabel(0), 'in sync');
      expect(clockDriftLabel(null), 'Unavailable');
    },
  );
  test('scope hourly zeros only complete covered hours and hides old membership series', () {
    final r = scopeLines(
      [
        {
          'hourly': [
            {'hour': 0, 'packets': 3},
          ],
        },
      ],
      [
        {'hour': 0, 'status': 'complete'},
        {'hour': 3600000, 'status': 'missing'},
        {'hour': 7200000, 'status': 'complete'},
      ],
      0,
      10800000,
    );
    expect(r['Packets']!.map((p) => p.y), [3, null, 0]);
    expect(r.containsKey('Observers'), false);
  });
  test(
    'ego folds duplicate IATA observations and uses freshest edge timestamp',
    () {
      final folded = foldNeighbours('center', [
        {'id': 'a', 'observationCount': 2, 'lastSeen': 10},
        {'id': 'a', 'observationCount': 3, 'lastSeen': 20},
        {'id': 'center', 'observationCount': 9},
      ]);
      expect(folded.single['observationCount'], 5);
      expect(folded.single['lastSeen'], 20);
    },
  );
  test('windowed series keeps absent hours and zero-sample signal as gaps', () {
    final p = windowedPoints(
      {
        'since': 0,
        'until': 10800000,
        'hourly': [
          {'hour': 0, 'snrSamples': 0, 'snrAverage': 0},
          {'hour': 7200000, 'snrSamples': 1, 'snrAverage': 2},
        ],
      },
      'snrAverage',
      sampleKey: 'snrSamples',
    );
    expect(p.map((e) => e.y), [null, null, 2]);
  });
  test('activity fills observed silence but preserves unread rollup gaps', () {
    final p = fillActivity([], 1000, 0, 4000, rolledUntil: 1000, rawFrom: 3000);
    expect(p.map((e) => e['observations']), [0, null, null, 0, 0]);
  });
  test(
    'airtime uses elapsed time, resets clamp and missing remains missing',
    () {
      final p = airtimePercent([
        {'t': 0, 'airtimeRxSecs': 10},
        {'t': 10000, 'airtimeRxSecs': 15},
        {'t': 20000, 'airtimeRxSecs': 2},
        {'t': 30000, 'airtimeRxSecs': null},
      ], 'airtimeRxSecs');
      expect(p.map((e) => e.y), [50, 0, null]);
    },
  );
  test(
    'traffic absent hours are gaps, reported zero is zero and IATA normalizes',
    () {
      final m = trafficHours(
        [
          {'hour': 3600000, 'iata': ' yvr ', 'observationCount': 0},
        ],
        0,
        7200000,
      );
      expect(m.map((e) => e.y), [null, 0, null]);
    },
  );
  test('partial rollup values never displayed', () {
    expect(
      rollupPoints([
        {
          'hour': 0,
          'status': 'partial',
          'values': {'observations': 22},
        },
      ], 'observations').single.y,
      null,
    );
  });
  test('comparison rejects same observer and inverted time', () {
    const a = '00000000-0000-0000-0000-000000000001';
    const b = '00000000-0000-0000-0000-000000000002';
    expect(validateComparison(a, a.toUpperCase(), 0, 10), isNotNull);
    expect(validateComparison(a, b, 10, 0), isNotNull);
    expect(validateComparison(a, b, 0, 10), isNull);
  });
  test('graph deduplicates reciprocal edges and skips self links', () {
    expect(
      graphEdges([
        {
          'id': 'a',
          'neighborIds': ['a', 'b'],
        },
        {
          'id': 'b',
          'neighborIds': ['a'],
        },
      ]),
      [(0, 1)],
    );
  });
  test('graphEdges ignores wrong-typed neighborIds', () {
    expect(
      graphEdges([
        {'id': 'a', 'neighborIds': 'b'},
        {'id': 'b', 'neighborIds': 7},
      ]),
      isEmpty,
    );
  });
}
