import 'dart:convert';

import 'package:beacon/features/atlas/atlas.dart';
import 'package:beacon/features/atlas/atlas_sync.dart';
import 'package:beacon/features/atlas/telemetry_sample.dart';
import 'package:flutter_test/flutter_test.dart';

const nodeId = '11111111-1111-4111-8111-111111111111';
final key = 'ab' * 32;
final now = DateTime.utc(2026, 9, 29, 12).millisecondsSinceEpoch;
// Ten minutes into the hour; hour(n) is the bucket n hours back.
final tick = now + 600000;
int hour(int n) => now - n * hourMs;

/// Real-shaped readings: counters carry their own span, then a reboot (uptime
/// drops) with no counters and no temperature.
Map<String, dynamic> fixture() => {
  'range': '24h',
  'interval': '1h',
  'polled': true,
  'points': [
    {
      't': hour(10),
      'readings': 3,
      'batteryMv': 4100,
      'temperatureC': 15.2,
      'noiseFloorDb': -112,
      'uptimeSeconds': 500000,
      'airtimeTxSecs': 216.0,
      'airtimeRxSecs': 2160.0,
      'packetsReceived': 3600,
      'packetsSent': 360,
      'receiveErrors': 108,
      'counterSpanSecs': 21600,
    },
    {
      't': hour(4),
      'readings': 1,
      'batteryMv': 4226,
      'noiseFloorDb': -97,
      'lastSnrDb': 12.0,
      'lastRssiDb': -20,
      'uptimeSeconds': 1800,
    },
  ],
};

void main() {
  group('tile values from readings', () {
    final sample = summarizeTelemetry(fixture(), AtlasRange.day, tick);

    test('the latest value of each field, in its unit', () {
      expect(sample.battery, closeTo(4.226, 1e-9));
      expect(sample.noise, -97);
      expect(sample.uptime, 1800);
      expect(sample.temperature, 15.2);
      expect(sample.snr, 12);
      expect(sample.rssi, -20);
      expect(sample.latestAt, hour(4));
    });

    test('counters are rates over counterSpanSecs, not the bucket', () {
      expect(sample.airtimeTx, closeTo(1, 1e-9));
      expect(sample.airtimeRx, closeTo(10, 1e-9));
      expect(sample.airtime, closeTo(11, 1e-9));
      expect(sample.received, closeTo(600, 1e-9));
      expect(sample.sent, closeTo(60, 1e-9));
      expect(sample.errors, closeTo(18, 1e-9));
    });

    test(
      'a point without counters adds no airtime, and a reboot shows as a drop',
      () {
        final airtime = sample.hourly['airtime']!;
        expect(airtime.whereType<double>(), hasLength(1));
        final uptime = sample.hourly['uptime']!;
        expect(uptime[13], 500000);
        expect(uptime[19], 1800);
        expect(uptime.length, 24);
      },
    );

    test('a share over 100 percent has no value', () {
      final bad = summarizeTelemetry(
        {
          'points': [
            {
              't': hour(1),
              'airtimeTxSecs': 900.0,
              'airtimeRxSecs': 900.0,
              'counterSpanSecs': 1000,
            },
          ],
        },
        AtlasRange.day,
        tick,
      );
      expect(bad.airtime, isNull);
    });

    test('no temperature is offered when no reading has one', () {
      expect(sample.hasTemperature, true);
      final points = (fixture()['points'] as List).cast<Map<String, dynamic>>();
      final without = summarizeTelemetry(
        {
          'points': [
            for (final p in points) {...p}..remove('temperatureC'),
          ],
        },
        AtlasRange.day,
        tick,
      );
      expect(without.hasTemperature, false);
      expect(without.temperature, isNull);
    });

    test('readings older than the window are left out', () {
      final old = summarizeTelemetry(
        {
          'points': [
            {'t': hour(30), 'batteryMv': 4000},
          ],
        },
        AtlasRange.day,
        tick,
      );
      expect(old.battery, isNull);
      expect(old.latestAt, isNull);
      final kept = summarizeTelemetry(
        {
          'points': [
            {'t': hour(30), 'batteryMv': 4000},
          ],
        },
        AtlasRange.threeDays,
        tick,
      );
      expect(kept.battery, 4);
    });
  });

  group('dots or a line', () {
    test('under eight readings draws dots', () {
      expect(useDots([null, 1, null, 2, 3]), true);
      expect(useDots(List<double?>.filled(7, 1)), true);
    });
    test('eight or more draws a line', () {
      expect(useDots(List<double?>.filled(8, 1)), false);
      expect(useDots(List<double?>.generate(72, (i) => i.toDouble())), false);
    });
  });

  group('range mapping', () {
    test('24h is 24h', () {
      expect(telemetryRequest(AtlasRange.day, false).range, '24h');
      expect(telemetryRequest(AtlasRange.day, true).range, '24h');
    });
    test('3d is 72h with the flag, a trimmed week without it', () {
      expect(telemetryRequest(AtlasRange.threeDays, true).range, '72h');
      expect(telemetryRequest(AtlasRange.threeDays, false).range, '168h');
      final week = {
        'points': [
          {'t': hour(100), 'batteryMv': 3000},
          {'t': hour(60), 'batteryMv': 3900},
        ],
      };
      final sample = summarizeTelemetry(week, AtlasRange.threeDays, tick);
      expect(sample.battery, 3.9);
      expect(sample.hourly['battery']!.whereType<double>().toList(), [3.9]);
    });
  });

  group('when the tab appears', () {
    final points = {
      'points': [
        {'t': hour(1)},
      ],
    };
    test('readings in the last 30 days', () {
      expect(
        hasTelemetryTab(typeName: 'Repeater', polling: true, readings: points),
        true,
      );
    });
    test('or a node polling route that says polled', () {
      expect(
        hasTelemetryTab(
          typeName: 'Room Server',
          polling: true,
          readings: {'points': <dynamic>[]},
          poller: {'polled': true},
        ),
        true,
      );
    });
    test('not for neither, another type, or polling off', () {
      expect(
        hasTelemetryTab(
          typeName: 'Repeater',
          polling: true,
          readings: {'points': <dynamic>[]},
          poller: {'polled': false},
        ),
        false,
      );
      expect(
        hasTelemetryTab(typeName: 'Companion', polling: true, readings: points),
        false,
      );
      expect(
        hasTelemetryTab(typeName: 'Repeater', polling: false, readings: points),
        false,
      );
    });
  });

  group('pins', () {
    Map<String, dynamic> pin([Map<String, dynamic> extra = const {}]) => {
      'kind': 'node',
      'id': nodeId,
      'publicKey': key,
      'name': 'Hill',
      ...extra,
    };
    AtlasPin parsed(Map<String, dynamic> raw) => parseAtlas(
      jsonEncode({
        'version': 2,
        'range': '24h',
        'pins': [raw],
      }),
    ).pins.single;

    test('keep a valid layout and the telemetry view', () {
      final p = parsed(
        pin({
          'view': 'telemetry',
          'telemetryTiles': ['signal', 'errors', 'packets', 'battery'],
        }),
      );
      expect(p.view, AtlasView.telemetry);
      expect(p.homeView, AtlasView.telemetry);
      expect(p.telemetryTiles, ['signal', 'errors', 'packets', 'battery']);
      expect(p.toJson()['telemetryTiles'], p.telemetryTiles);
      expect(p.toJson()['view'], 'telemetry');
    });

    test('are stored only when they differ from the default', () {
      expect(
        parsed(pin({'telemetryTiles': defaultTelemetryTiles})).telemetryTiles,
        isNull,
      );
      final p = parsed(pin()).withTelemetryTiles(defaultTelemetryTiles);
      expect(p.toJson().containsKey('telemetryTiles'), false);
      expect(
        p.withTelemetryTiles([
          'battery',
          'noise',
          'uptime',
          'errors',
        ]).telemetryTiles,
        ['battery', 'noise', 'uptime', 'errors'],
      );
    });

    test('unknown, repeated or short tile lists fall back to the default', () {
      for (final bad in [
        ['battery', 'noise', 'uptime', 'queue'],
        ['battery', 'battery', 'uptime', 'noise'],
        ['battery', 'noise', 'uptime'],
        'battery',
      ]) {
        expect(parsed(pin({'telemetryTiles': bad})).telemetryTiles, isNull);
      }
    });

    test('survive an export and an import', () {
      final p = parsed(
        pin({
          'view': 'telemetry',
          'telemetryTiles': ['temperature', 'noise', 'uptime', 'airtime'],
        }),
      );
      final back = readAtlasFile(atlasFile(SavedAtlas(pins: [p])))!;
      expect(back.atlas.pins.single.toJson(), p.toJson());
    });

    test('come from the server copy too', () {
      final server = parseServerAtlas({
        'revision': 3,
        'range': '24h',
        'pins': [
          pin({
            'view': 'telemetry',
            'telemetryTiles': ['noise', 'battery', 'uptime', 'airtime'],
          }),
        ],
      })!;
      expect(server.atlas.pins.single.view, AtlasView.telemetry);
      expect(server.atlas.pins.single.telemetryTiles, [
        'noise',
        'battery',
        'uptime',
        'airtime',
      ]);
    });

    test('an observer pin ignores them', () {
      final p = parseAtlas(
        jsonEncode({
          'version': 2,
          'pins': [
            {
              'kind': 'observer',
              'observerId': '44444444-4444-4444-8444-444444444444',
              'name': 'Roof',
              'telemetryTiles': ['noise', 'battery', 'uptime', 'airtime'],
            },
          ],
        }),
      ).pins.single;
      expect(p.toJson().containsKey('telemetryTiles'), false);
    });
  });

  group('PUT body', () {
    final saved = SavedAtlas(
      pins: [
        AtlasPin.node(
          id: nodeId,
          publicKey: key,
          name: 'Hill',
          telemetryTiles: const ['noise', 'battery', 'uptime', 'airtime'],
          view: AtlasView.telemetry,
        ),
        AtlasPin.node(
          id: nodeId,
          publicKey: 'cd' * 32,
          name: 'Ridge',
          view: AtlasView.heard,
        ),
      ],
    );
    List<dynamic> pins(Map<String, dynamic> body) => body['pins'] as List;

    test('a server with the flag gets both fields', () {
      final first = pins(atlasPutBody(saved, const {}, 1)).first as Map;
      expect(first['view'], 'telemetry');
      expect(first['telemetryTiles'], [
        'noise',
        'battery',
        'uptime',
        'airtime',
      ]);
    });

    test('an older server gets neither, other views stay', () {
      final out = pins(atlasPutBody(saved, const {}, 1, telemetry: false));
      expect((out[0] as Map).containsKey('view'), false);
      expect((out[0] as Map).containsKey('telemetryTiles'), false);
      expect((out[1] as Map)['view'], 'heard');
    });

    test('the local copy keeps them over the server copy', () {
      final server = parseServerAtlas({
        'revision': 2,
        'range': '24h',
        'pins': [
          {'kind': 'node', 'id': nodeId, 'publicKey': key, 'name': 'Hill'},
        ],
      })!;
      final merged = carryTelemetry(server.atlas, saved);
      expect(merged.pins.single.view, AtlasView.telemetry);
      expect(merged.pins.single.telemetryTiles, [
        'noise',
        'battery',
        'uptime',
        'airtime',
      ]);
    });
  });
}
