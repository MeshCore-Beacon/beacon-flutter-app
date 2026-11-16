import 'package:beacon/features/map/map_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

const now = 1800000000000, min = 60000, h = 3600000;

Map<String, dynamic> reading(int sampledAt, {int? mv, double? c}) => {
  'nodeId': 'n1',
  'sampledAt': sampledAt,
  'batteryMv': ?mv,
  'temperatureC': ?c,
};

void main() {
  group('telemetryLabel', () {
    test('battery, temperature and age in Celsius', () {
      final l = telemetryLabel(
        reading(now - 38 * min, mv: 4080, c: 1.4),
        'c',
        now,
      );
      expect(l!.text, '4.08V  1°  38m');
      expect(l.old, false);
    });
    test('Fahrenheit instance', () {
      final l = telemetryLabel(
        reading(now - 38 * min, mv: 4080, c: 1.4),
        'f',
        now,
      );
      expect(l!.text, '4.08V  35°  38m');
    });
    test('hours, battery only', () {
      final l = telemetryLabel(reading(now - 27 * h, mv: 3920), 'c', now);
      expect(l!.text, '3.92V  27h');
      expect(l.old, false);
    });
    test('48 hours or older is old and shows days', () {
      final l = telemetryLabel(reading(now - 48 * h, c: 10), 'c', now);
      expect(l!.text, '10°  2d');
      expect(l.old, true);
    });
    test('never draws negative zero', () {
      final l = telemetryLabel(reading(now - 59 * min, c: -0.4), 'c', now);
      expect(l!.text, '0°  59m');
    });
    test('rounds half away from zero and never prints -0', () {
      String text(double c) =>
          telemetryLabel(reading(now - min, c: c), 'c', now)!.text;
      expect(text(-0.5), '-1°  1m');
      expect(text(-1.5), '-2°  1m');
      expect(text(-2.5), '-3°  1m');
      expect(text(0.5), '1°  1m');
      expect(text(-0.4), '0°  1m');
    });
    test('a future sample reads as 0m', () {
      final l = telemetryLabel(reading(now + 5 * min, mv: 4000), 'c', now);
      expect(l!.text, '4.00V  0m');
    });
    test('no battery and no temperature gives no label', () {
      expect(telemetryLabel(reading(now), 'c', now), isNull);
    });
  });

  test('telemetryLabels is keyed by nodeId and drops empty readings', () {
    final labels = telemetryLabels(
      [
        {...reading(now - min, mv: 4000), 'nodeId': 'a'},
        {...reading(now), 'nodeId': 'b'},
      ],
      'c',
      now,
    );
    expect(labels.keys, ['a']);
    expect(labels['a']!.text, '4.00V  1m');
  });

  group('keepLabels', () {
    TelemetryLabel l(String text, {bool old = false}) => (text: text, old: old);
    final prev = {'a': l('4.00V  1m'), 'b': l('3.90V  2d', old: true)};
    Map<String, TelemetryLabel> copy() => {
      'a': l('4.00V  1m'),
      'b': l('3.90V  2d', old: true),
    };

    test('same content keeps the previous instance', () {
      expect(keepLabels(prev, copy()), same(prev));
    });
    test('changed text, old flag, added or removed node give the new map', () {
      final text = {...copy(), 'a': l('4.00V  2m')};
      final old = {...copy(), 'a': l('4.00V  1m', old: true)};
      final added = {...copy(), 'c': l('1m')};
      final removed = {'a': l('4.00V  1m')};
      for (final next in [text, old, added, removed]) {
        expect(keepLabels(prev, next), same(next));
      }
    });
  });
}
