import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/atlas/atlas.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const nodeId = '11111111-1111-4111-8111-111111111111';
const observerId = '44444444-4444-4444-8444-444444444444';
final key = 'ab' * 32;
final nodePin = <String, dynamic>{
  'kind': 'node',
  'id': nodeId,
  'publicKey': key,
  'name': 'My repeater',
};
const observerPin = <String, dynamic>{
  'kind': 'observer',
  'observerId': observerId,
  'name': 'Listener',
};

List<Map<String, dynamic>> parse(List<dynamic> pins) => [
  for (final pin in parseAtlas(
    jsonEncode({'version': 2, 'range': '24h', 'pins': pins}),
  ).pins)
    pin.toJson(),
];

final now = DateTime.utc(2026, 9, 29, 12).millisecondsSinceEpoch;
// The tick sits ten minutes into the hour; hour(n) is the bucket n hours back.
final tick = now + 600000;
int hour(int n) => now - n * hourMs;
Map<String, dynamic> point(
  int n,
  num observations, {
  num? snrAvg,
  num? rssiAvg,
}) => {
  't': hour(n),
  'observations': observations,
  'snrAvg': snrAvg,
  'rssiAvg': rssiAvg,
  'hopAvg': null,
};
Map<String, dynamic> activityOf([Map<String, dynamic> extra = const {}]) => {
  'windowStart': tick - 24 * hourMs,
  'windowEnd': tick,
  'generatedAt': tick,
  'range': '24h',
  'summary': {
    'observations': 0,
    'snrAvg': null,
    'rssiAvg': null,
    'hopAvg': null,
  },
  'points': <dynamic>[],
  'latest': null,
  ...extra,
};

void main() {
  group('saved Atlas', () {
    test(
      'restores ordered identities, normalizes keys, removes duplicates',
      () {
        final saved = parseAtlas(
          jsonEncode({
            'version': 2,
            'range': '3d',
            'pins': [
              {...nodePin, 'publicKey': key.toUpperCase()},
              nodePin,
              {...nodePin, 'publicKey': 'cd' * 32},
            ],
          }),
        );
        expect(saved.range, AtlasRange.threeDays);
        expect(saved.toJson(), {
          'version': 2,
          'range': '3d',
          'pins': [
            nodePin,
            {...nodePin, 'publicKey': 'cd' * 32},
          ],
        });
      },
    );

    test('tolerates corrupt, old and future storage and caps the list', () {
      final old = jsonEncode({
        'version': 1,
        'range': '3d',
        'nodes': [nodePin],
      });
      for (final value in [
        null,
        '{',
        '[]',
        '{"version":3}',
        old,
        '{"version":2,"pins":{}}',
      ]) {
        expect(parseAtlas(value).pins, isEmpty);
      }
      final result = parseAtlas(
        jsonEncode({
          'version': 2,
          'range': '30d',
          'pins': [
            {...nodePin, 'publicKey': 'abcd'},
            {...nodePin, 'id': '../unsafe'},
            for (var i = 0; i < 20; i++)
              {...nodePin, 'publicKey': i.toRadixString(16).padLeft(64, '0')},
          ],
        }),
      );
      expect(result.pins, hasLength(atlasLimit));
      expect(result.range, AtlasRange.day);
    });

    test('keeps both kinds and the observer hint, drops unknown kinds', () {
      final first = {
        ...nodePin,
        'name': 'One',
        'observerId': '33333333-3333-4333-8333-333333333333',
      };
      final pins = parseAtlas(
        jsonEncode({
          'version': 2,
          'range': '24h',
          'pins': [
            first,
            observerPin,
            {'kind': 'channel', 'id': 'x', 'name': 'Nope'},
            {'kind': 'observer', 'observerId': 'not-a-uuid', 'name': 'Bad'},
            {...nodePin, 'name': 'Twin', 'observerId': 'bad'},
          ],
        }),
      ).pins;
      expect([for (final pin in pins) pin.toJson()], [first, observerPin]);
      expect(pins[0].key, key);
      expect(pins[1].key, observerId);
    });

    test('dedupes observer pins and caps both kinds together', () {
      Map<String, dynamic> observer(int n) => {
        'kind': 'observer',
        'observerId': '${'$n'.padLeft(8, '0')}-0000-4000-8000-000000000000',
        'name': 'L$n',
      };
      expect(
        parse([
          observer(1),
          observer(1),
          for (var i = 0; i < 14; i++) observer(i + 2),
        ]),
        hasLength(atlasLimit),
      );
    });

    test('an append goes through the same dedupe and cap', () {
      final saved = parseAtlas(
        jsonEncode({
          'version': 2,
          'range': '24h',
          'pins': [nodePin],
        }),
      );
      expect(saved.appended(saved.pins.first).pins, hasLength(1));
    });
  });

  group('observer view tiles', () {
    const tiles = ['snr', 'battery', 'queue', 'errors'];
    test('keeps four distinct known tiles on both kinds, in slot order', () {
      const other = ['packets', 'rssi', 'uptime', 'types'];
      expect(
        parse([
          {...nodePin, 'tiles': tiles},
          {...observerPin, 'tiles': other},
        ]),
        [
          {...nodePin, 'tiles': tiles},
          {...observerPin, 'tiles': other},
        ],
      );
    });

    test('drops tiles that are not four distinct known ids', () {
      for (final bad in [
        ['snr', 'battery', 'queue'],
        ['snr', 'snr', 'queue', 'errors'],
        ['snr', 'battery', 'queue', 'voltage'],
        ['snr', 'battery', 'queue', 'errors', 'noise'],
        'snr',
        null,
        [1, 2, 3, 4],
      ]) {
        expect(
          parse([
            {...nodePin, 'tiles': bad},
          ]),
          [nodePin],
        );
      }
    });

    test('does not store the default layout', () {
      expect(
        parse([
          {...observerPin, 'tiles': defaultTiles},
        ]),
        [observerPin],
      );
      final pin = parseAtlas(
        jsonEncode({
          'version': 2,
          'pins': [
            {...nodePin, 'tiles': tiles},
          ],
        }),
      ).pins.single;
      expect(pin.withTiles(defaultTiles).toJson(), nodePin);
      const moved = ['noise', 'battery', 'types', 'airtime'];
      expect(pin.withTiles(moved).toJson(), {...nodePin, 'tiles': moved});
    });
  });

  group('pinned card view', () {
    test('keeps a non-default view on a node pin only', () {
      expect(
        parse([
          {...nodePin, 'view': 'heard'},
        ]),
        [
          {...nodePin, 'view': 'heard'},
        ],
      );
      for (final bad in [
        'analytics',
        'map',
        '',
        2,
        null,
        ['heard'],
      ]) {
        expect(
          parse([
            {...nodePin, 'view': bad},
          ]),
          [nodePin],
        );
      }
      expect(
        parse([
          {...observerPin, 'view': 'observer'},
        ]),
        [observerPin],
      );
    });

    test('sets and clears the view without touching the rest of the pin', () {
      final linked = {
        ...nodePin,
        'observerId': observerId,
        'tiles': ['snr', 'battery', 'types', 'noise'],
      };
      final pin = parseAtlas(
        jsonEncode({
          'version': 2,
          'pins': [linked],
        }),
      ).pins.single;
      expect(pin.withView(AtlasView.observer).toJson(), {
        ...linked,
        'view': 'observer',
      });
      expect(
        pin.withView(AtlasView.heard).withView(AtlasView.analytics).toJson(),
        linked,
      );
    });

    test('a pinned Observer view waits for the observer link', () {
      final pins = parseAtlas(
        jsonEncode({
          'version': 2,
          'pins': [
            {...nodePin, 'view': 'observer'},
            {
              ...nodePin,
              'publicKey': 'cd' * 32,
              'view': 'observer',
              'observerId': observerId,
            },
            observerPin,
          ],
        }),
      ).pins;
      expect(pins[0].homeView, AtlasView.analytics);
      expect(pins[0].view, AtlasView.observer);
      expect(pins[1].homeView, AtlasView.observer);
      expect(pins[2].homeView, AtlasView.observer);
    });
  });

  group('node activity sample', () {
    test('bins hourly points newest last, totals from the server summary', () {
      final sample = summarizeActivity(
        activityOf({
          'summary': {
            'observations': 50,
            'snrAvg': 5,
            'rssiAvg': -100,
            'hopAvg': 2,
          },
          'points': [
            point(24, 9, snrAvg: 20),
            point(2, 7),
            point(0, 3, snrAvg: 4, rssiAvg: -90),
          ],
          'latest': {'packetHash': 'ef' * 32, 'heardAt': tick - 1000},
        }),
        AtlasRange.day,
        tick,
      );
      expect(sample.counts, hasLength(24));
      expect(sample.counts[23], 3);
      expect(sample.counts[22], 0);
      expect(sample.counts[21], 7);
      expect(sample.counts.fold<double>(0, (a, b) => a + (b ?? 0)), 10);
      expect(sample.present.where((on) => on), hasLength(2));
      expect(sample.snrHourly[23], 4);
      expect(sample.rssiHourly[23], -90);
      expect(sample.snrHourly[21], isNull);
      expect(sample.snrHourly[0], isNull);
      expect(
        [sample.total, sample.snr, sample.rssi, sample.hops],
        [50, 5, -100, 2],
      );
      expect(sample.partial, isFalse);
      expect(sample.latestHash, 'ef' * 32);
      expect(sample.latestHeardAt, tick - 1000);
    });

    test('keeps a real zero mean and nulls a missing one', () {
      final sample = summarizeActivity(
        activityOf({
          'summary': {
            'observations': 4,
            'snrAvg': 0,
            'rssiAvg': null,
            'hopAvg': 'x',
          },
          'points': [point(1, 4, snrAvg: 0)],
        }),
        AtlasRange.day,
        tick,
      );
      expect(sample.snr, 0);
      expect(sample.snrHourly[22], 0);
      expect(sample.rssi, isNull);
      expect(sample.hops, isNull);
    });

    test('hours neither rolled up nor in the raw tail are unknown', () {
      final sample = summarizeActivity(
        activityOf({
          'rolledUntil': hour(10),
          'rawFrom': hour(4),
          'points': [point(12, 2), point(1, 1)],
        }),
        AtlasRange.day,
        tick,
      );
      expect(sample.counts[23 - 12], 2);
      expect(sample.counts[23 - 11], 0);
      expect(sample.counts.sublist(23 - 10, 23 - 4), List.filled(6, null));
      expect(sample.counts[23 - 4], 0);
      expect(sample.present[23 - 7], isFalse);
      expect(sample.partial, isTrue);
      final rawOnly = summarizeActivity(
        activityOf({'rawFrom': hour(4)}),
        AtlasRange.day,
        tick,
      );
      expect(rawOnly.counts.where((v) => v == null), hasLength(19));
    });

    test('is all unknown until the activity has loaded', () {
      final sample = summarizeActivity(null, AtlasRange.threeDays, tick);
      expect(sample.counts, List.filled(72, null));
      expect(sample.present, hasLength(72));
      expect([
        sample.total,
        sample.snr,
        sample.rssi,
        sample.hops,
        sample.latestHash,
      ], List.filled(5, null));
      expect(sample.partial, isFalse);
      expect(
        summarizeActivity(activityOf(), AtlasRange.threeDays, tick).counts,
        List.filled(72, 0),
      );
    });
  });

  group('Atlas export file', () {
    final saved = parseAtlas(
      jsonEncode({
        'version': 2,
        'range': '3d',
        'pins': [
          {
            ...nodePin,
            'view': 'heard',
            'tiles': ['snr', 'battery', 'queue', 'errors'],
          },
          observerPin,
        ],
      }),
    );

    test(
      'round-trips pins, order, range, tiles and view with a format tag',
      () {
        final text = atlasFile(
          saved,
          now: DateTime.fromMillisecondsSinceEpoch(1800000000000),
        );
        final file = jsonDecode(text) as Map<String, dynamic>;
        expect(file['format'], 'beacon-atlas');
        expect(file['version'], 2);
        expect(file['exportedAt'], 1800000000000);
        expect(file['pins'][0]['view'], 'heard');
        expect((file['pins'][1] as Map).containsKey('tiles'), isFalse);
        final read = readAtlasFile(text)!;
        expect(read.skipped, 0);
        expect(read.atlas.toJson(), saved.toJson());
      },
    );

    test('reads a file the web wrote', () {
      const web =
          '{\n  "format": "beacon-atlas",\n  "version": 2,\n  "exportedAt": 1,\n  "range": "24h",\n  "pins": [\n    {\n      "kind": "observer",\n      "observerId": "44444444-4444-4444-8444-444444444444",\n      "name": "Listener"\n    }\n  ]\n}';
      expect(readAtlasFile(web)!.atlas.pins.single.toJson(), observerPin);
    });

    test('names the file by UTC date', () {
      expect(
        atlasFileName(DateTime.utc(2026, 11, 5, 23)),
        'beacon-atlas-2026-11-05.json',
      );
    });

    test('rejects text that is not an Atlas export', () {
      expect(readAtlasFile('not json'), isNull);
      expect(
        readAtlasFile(
          jsonEncode({
            'version': 2,
            'pins': [nodePin],
          }),
        ),
        isNull,
      );
      expect(
        readAtlasFile(jsonEncode({'format': 'beacon-atlas', 'pins': 'x'})),
        isNull,
      );
      expect(readAtlasFile(' ' * (atlasFileMaxBytes + 1)), isNull);
    });

    test('drops invalid and duplicate pins, caps, and counts the skipped', () {
      final many = [
        for (var i = 0; i < 14; i++)
          {
            ...nodePin,
            'id': '11111111-1111-4111-8111-${'$i'.padLeft(12, '0')}',
            'publicKey': i.toRadixString(16).padLeft(2, '0') * 32,
          },
      ];
      final result = readAtlasFile(
        jsonEncode({
          'format': 'beacon-atlas',
          'version': 2,
          'range': '24h',
          'pins': [
            {'kind': 'node', 'id': 'bad'},
            many[0],
            many[0],
            ...many.skip(1),
          ],
        }),
      )!;
      expect(result.atlas.pins, hasLength(12));
      expect(result.skipped, 4);
    });
  });

  group('node lookups', () {
    ApiClient apiWith(Map<String, Object?>? Function(Uri) reply) => ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((request) async {
        final body = reply(request.url);
        return body == null
            ? http.Response('{"error":{"message":"gone"}}', 404)
            : http.Response(jsonEncode(body), 200);
      }),
    );

    test('an observer resolves to the node with the same key only', () async {
      final seen = <Uri>[];
      final api = apiWith((url) {
        seen.add(url);
        return {
          'items': [
            {'id': 'other', 'publicKey': '${'ab' * 31}ff'},
            {'id': nodeId, 'publicKey': key.toUpperCase(), 'name': 'R1'},
          ],
          'hasMore': false,
        };
      });
      final match = await resolveObserverNode(api, {'publicKey': key});
      expect(match?['id'], nodeId);
      expect(seen.single.queryParameters, {'pubkey': key, 'limit': '2'});
      expect(await resolveObserverNode(api, {'publicKey': ''}), isNull);
      expect(seen, hasLength(1));
    });

    test('a pin recovers under a new id by key, never another node', () async {
      final pin = parseAtlas(
        jsonEncode({
          'version': 2,
          'pins': [nodePin],
        }),
      ).pins.single;
      final api = apiWith(
        (url) => switch (url.path) {
          '/api/v1/nodes/$nodeId' => {'id': nodeId, 'publicKey': 'cd' * 32},
          '/api/v1/nodes' => {
            'items': [
              {'id': 'fresh', 'publicKey': key},
            ],
          },
          '/api/v1/nodes/fresh' => {'id': 'fresh', 'publicKey': key},
          _ => null,
        },
      );
      expect((await loadAtlasNode(api, pin))['id'], 'fresh');
      final gone = apiWith(
        (url) => url.path == '/api/v1/nodes' ? {'items': <dynamic>[]} : null,
      );
      await expectLater(
        loadAtlasNode(gone, pin),
        throwsA(predicate(isNotFound)),
      );
    });
  });
}
