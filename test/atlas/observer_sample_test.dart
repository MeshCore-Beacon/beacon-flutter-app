import 'package:beacon/features/atlas/atlas.dart';
import 'package:beacon/features/atlas/observer_sample.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime.utc(2026, 10, 13, 12, 30).millisecondsSinceEpoch;
Map<String, dynamic> point(
  num hoursAgo,
  num? observations,
  num? snrAvg, {
  num? rssiAvg,
  num? airtimeMs,
}) => {
  't': now - (hoursAgo * hourMs).round(),
  'observations': observations,
  'snrAvg': snrAvg,
  'snrMin': null,
  'rssiAvg': rssiAvg,
  'airtimeMs': airtimeMs,
};
Map<String, dynamic> activity(
  List<Map<String, dynamic>> points, [
  Map<String, dynamic> extra = const {},
]) => {
  'range': '24h',
  'interval': '1h',
  'radio': null,
  'payloadTypes': <dynamic>[],
  'points': points,
  ...extra,
};
Map<String, dynamic> tele(List<Map<String, dynamic>> points) => {
  'range': '24h',
  'interval': '1h',
  'points': [
    for (final p in points)
      {
        't': now,
        'batteryMv': null,
        'airtimeTxSecs': null,
        'airtimeRxSecs': null,
        'noiseFloorDb': null,
        'uptimeSeconds': null,
        'queueLength': null,
        'receiveErrors': null,
        ...p,
      },
  ],
};
ObserverSample sum(
  Map<String, dynamic>? a,
  Map<String, dynamic>? t, [
  Map<String, dynamic>? observer,
  AtlasRange range = AtlasRange.day,
]) => summarizeObserver(a, t, observer, range, now);
List<T> last<T>(List<T> list, int n) => list.sublist(list.length - n);

void main() {
  test('missing endpoints and unread rollup hours are not measured zeros', () {
    expect(sum(null, null).counts.every((v) => v == null), isTrue);
    final sample = sum(activity([], {'rawFrom': now - hourMs}), null);
    expect(sample.counts.first, isNull);
    expect(sample.counts.last, 0);
    expect(sample.partial, isTrue);
  });

  test('shows a status battery without inventing history', () {
    final sample = sum(null, null, {'batteryLevel': 4.17});
    expect(sample.battery, 4.17);
    expect(sample.batteryHourly.every((v) => v == null), isTrue);
  });

  test('excludes future readings while preserving an uptime reset', () {
    final sample = sum(
      activity([point(-5, 999, 99), point(0, 2, 0)]),
      tele([
        {'t': now + hourMs, 'batteryMv': 99999, 'noiseFloorDb': -1},
        {'t': now - hourMs, 'noiseFloorDb': -110, 'uptimeSeconds': 100},
        {'t': now, 'noiseFloorDb': -110, 'uptimeSeconds': 0},
      ]),
    );
    expect(sample.heard, 2);
    expect(sample.battery, isNull);
    expect(last(sample.uptimeHourly, 2), [100, 0]);
  });

  test('a bucket just after a lagging tick lands in the newest slot', () {
    final sample = sum(activity([point(-0.5, 6, 2)]), null);
    expect(sample.counts[23], 6);
    expect(sample.heard, 6);
  });

  test('prefers the status record noise floor over telemetry', () {
    final telemetry = tele([
      {'t': now, 'noiseFloorDb': -110},
    ]);
    expect(
      sum(null, telemetry, {
        'statusMetadata': {
          'stats': {'noise_floor': -98},
        },
      }).noise,
      -98,
    );
    expect(sum(null, telemetry, {}).noise, -110);
  });

  test('bins packets heard per hour, newest last, and sums them', () {
    final sample = sum(
      activity([point(0, 3, 1), point(1, 5, 2), point(30, 99, 0)]),
      null,
    );
    expect(sample.counts, hasLength(24));
    expect(sample.counts[23], 3);
    expect(sample.counts[22], 5);
    expect(sample.counts[0], 0);
    expect(sample.heard, 8);
  });

  test('ranks the payload types heard, dropping empty ones', () {
    final sample = sum(
      activity(
        [point(0, 8, null)],
        {
          'payloadTypes': [
            {'payloadType': 5, 'payloadTypeName': 'GRP_TXT', 'count': 2},
            {'payloadType': 4, 'payloadTypeName': 'ADVERT', 'count': 6},
            {'payloadType': 1, 'payloadTypeName': 'RESPONSE', 'count': 0},
          ],
        },
      ),
      null,
    );
    expect(
      [for (final type in sample.types) (type.name, type.count)],
      [('ADVERT', 6.0), ('GRP_TXT', 2.0)],
    );
  });

  test('airtime from cumulative counters, a reboot step as zero', () {
    final sample = sum(
      null,
      tele([
        {
          't': now - 3 * hourMs,
          'airtimeTxSecs': 100,
          'airtimeRxSecs': 1000,
          'noiseFloorDb': -110,
        },
        {
          't': now - 2 * hourMs,
          'airtimeTxSecs': 136,
          'airtimeRxSecs': 1180,
          'noiseFloorDb': -110,
        },
        {
          't': now - hourMs,
          'airtimeTxSecs': 10,
          'airtimeRxSecs': 20,
          'noiseFloorDb': -110,
        },
      ]),
    );
    expect(sample.airtimeSource, 'radio');
    expect(sample.airtimeTx, closeTo(0.5, 1e-9));
    expect(sample.airtimeRx, closeTo(2.5, 1e-9));
    expect(sample.airtime, closeTo(3, 1e-9));
    expect(sample.airtimeHourly[21], closeTo(6, 1e-9));
    expect(sample.airtimeHourly[22], 0);
    expect(sample.airtimeHourly[20], isNull);
  });

  test('estimates receive airtime from heard packets without counters', () {
    final sample = sum(
      activity([
        point(0, 1, null, airtimeMs: 72000),
        point(1, 1, null),
        point(2, null, null),
      ]),
      null,
    );
    expect(sample.airtimeSource, 'heard');
    expect(sample.airtimeTx, isNull);
    // 72 s on air over the 23 hours that were read
    expect(sample.airtime, closeTo(72 / (23 * 3600) * 100, 1e-9));
    expect(sample.airtimeRx, sample.airtime);
    expect(sample.airtimeHourly[23], closeTo(2, 1e-9));
    expect(sample.airtimeHourly[22], 0);
    expect(sample.airtimeHourly[21], isNull);
  });

  test('latest noise floor and battery, ignoring all-zero rows', () {
    final sample = sum(
      null,
      tele([
        {'t': now - 2 * hourMs, 'noiseFloorDb': -118, 'batteryMv': 4050},
        {'t': now - hourMs, 'noiseFloorDb': 0, 'batteryMv': 0},
        {'t': now - 3 * hourMs, 'noiseFloorDb': -121, 'batteryMv': null},
      ]),
    );
    expect(sample.noise, -118);
    expect(sample.battery, closeTo(4.05, 1e-9));
    expect(sample.noiseHourly[20], -121);
    expect(sample.noiseHourly[21], -118);
    expect(sample.noiseHourly[22], isNull);
  });

  test('a zero battery on an otherwise live row is no battery', () {
    final sample = sum(
      null,
      tele([
        {
          't': now - hourMs,
          'batteryMv': 0,
          'noiseFloorDb': -96,
          'uptimeSeconds': 5,
        },
      ]),
    );
    expect(sample.noise, -96);
    expect(sample.battery, isNull);
    expect(sample.batteryHourly[22], isNull);
    expect(sample.uptime, 5);
  });

  test('weights the SNR and RSSI window mean by packet count', () {
    final sample = sum(
      activity([
        point(0, 30, 2, rssiAvg: -100),
        point(1, 10, 10, rssiAvg: -80),
        point(2, 5, null),
        point(40, 99, 50, rssiAvg: -10),
      ]),
      null,
    );
    expect(last(sample.snrHourly, 3), [null, 10, 2]);
    expect(last(sample.rssiHourly, 3), [null, -80, -100]);
    expect(sample.snr, closeTo(4, 1e-9));
    expect(sample.rssi, closeTo(-95, 1e-9));
    expect(sample.snrHourly[0], isNull);
  });

  test('keeps a real zero SNR; no mean without signal readings', () {
    expect(sum(activity([point(0, 4, 0)]), null).snr, 0);
    final none = sum(activity([point(0, 4, null)]), null);
    expect([none.snr, none.rssi], [null, null]);
  });

  test('queue is its latest reading, with the last reading per hour', () {
    final sample = sum(
      null,
      tele([
        {'t': now - 2 * hourMs, 'queueLength': 4, 'noiseFloorDb': -110},
        {'t': now - hourMs - 60000, 'queueLength': 9, 'noiseFloorDb': -110},
        {'t': now - hourMs, 'queueLength': 1, 'noiseFloorDb': -110},
      ]),
    );
    expect(sample.queue, 1);
    expect(last(sample.queueHourly, 3), [4, 1, null]);
  });

  test('receive errors per hour from the counter, a reboot step as zero', () {
    final sample = sum(
      null,
      tele([
        {'t': now - 4 * hourMs, 'receiveErrors': 100},
        {'t': now - 3 * hourMs, 'receiveErrors': 103},
        {'t': now - 2 * hourMs - 60000, 'receiveErrors': 104},
        {'t': now - 2 * hourMs, 'receiveErrors': 110},
        {'t': now - hourMs, 'receiveErrors': 2},
        {'t': now, 'receiveErrors': 7},
      ]),
    );
    expect(last(sample.errorsHourly, 5), [null, 3, 7, 0, 5]);
    expect(sample.errors, 15);
    final single = sum(
      null,
      tele([
        {'t': now, 'receiveErrors': 50},
      ]),
    );
    expect(single.errors, isNull);
    expect(single.errorsHourly.every((v) => v == null), isTrue);
  });

  test('prefers the record uptime and gives nulls on empty input', () {
    final empty = sum(null, null, null, AtlasRange.threeDays);
    expect([
      empty.heard,
      empty.airtime,
      empty.airtimeSource,
      empty.noise,
      empty.battery,
      empty.uptime,
      empty.snr,
      empty.rssi,
      empty.queue,
      empty.errors,
    ], List.filled(10, null));
    expect(empty.types, isEmpty);
    expect(empty.counts, hasLength(72));
    final sample = sum(
      null,
      tele([
        {'uptimeSeconds': 10},
      ]),
      {'uptimeSeconds': 99},
    );
    expect(sample.uptime, 99);
  });
}
