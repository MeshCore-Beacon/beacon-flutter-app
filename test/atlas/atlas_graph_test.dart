import 'package:beacon/features/atlas/atlas.dart';
import 'package:beacon/features/atlas/atlas_graph.dart';
import 'package:beacon/features/atlas/telemetry_sample.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime.utc(2026, 9, 29, 12).millisecondsSinceEpoch;
// Ten minutes into the hour; hour(n) is the bucket n hours back.
final tick = now + 600000;
int hour(int n) => now - n * hourMs;

void main() {
  group('slot times', () {
    test('each slot starts on its hour, newest last', () {
      for (final range in AtlasRange.values) {
        final slots = HourSlots(range, tick);
        expect(slots.start(range.hours - 1), hour(0));
        expect(slots.start(0), hour(range.hours - 1));
        // A bucket lands in the slot that starts on it.
        for (final back in [0, 1, range.hours - 1]) {
          expect(slots.start(slots.bin(hour(back))), hour(back));
        }
      }
    });

    test('an hourly series keeps its gaps', () {
      final slots = HourSlots(AtlasRange.day, tick);
      final values = List<double?>.filled(24, null)
        ..[21] = 2
        ..[23] = 5;
      final points = slotPoints(values, slots);
      expect(points, hasLength(24));
      expect(points[21].x, hour(2));
      expect(points[21].y, 2);
      expect(points[22].y, isNull);
      expect(points.last.x, hour(0));
      expect(points.last.y, 5);
    });

    test('a series with no value is empty', () {
      String format(double v) => '$v';
      final slots = HourSlots(AtlasRange.day, tick);
      expect(
        AtlasGraph(slotPoints(List.filled(24, null), slots), format).isEmpty,
        isTrue,
      );
      expect(AtlasGraph(slotPoints([null, 0], slots), format).isEmpty, isFalse);
      expect(AtlasGraph(readingPoints([], [], hourMs), format).isEmpty, isTrue);
    });
  });

  group('reading times', () {
    test('a gap goes in where readings are over 1.5 buckets apart', () {
      final times = [hour(10), hour(9), hour(7), hour(6) + hourMs ~/ 2];
      final points = readingPoints(times, [1, 2, 3, 4], hourMs);
      expect(
        [for (final p in points) (p.x, p.y)],
        [
          (hour(10), 1),
          (hour(9), 2),
          (hour(8), null),
          (hour(7), 3),
          (hour(6) + hourMs ~/ 2, 4),
        ],
      );
    });

    test('six hour buckets bridge what hourly ones would not', () {
      final times = [hour(12), hour(6), hour(0)];
      final values = <double>[1, 2, 3];
      expect(readingPoints(times, values, 6 * hourMs), hasLength(3));
      expect(readingPoints(times, values, hourMs), hasLength(5));
    });

    test('the sample keeps when each value was read', () {
      final sample = summarizeTelemetry(
        {
          'points': [
            {'t': hour(1), 'batteryMv': 4000},
            {'t': hour(5), 'batteryMv': 3900, 'noiseFloorDb': -110},
            {'t': hour(3), 'temperatureC': 12},
            {'t': hour(30), 'batteryMv': 3000},
          ],
        },
        AtlasRange.day,
        tick,
      );
      expect(sample.values['battery'], [3.9, 4.0]);
      expect(sample.times['battery'], [hour(5), hour(1)]);
      expect(sample.times['noise'], [hour(5)]);
      expect(sample.times['temperature'], [hour(3)]);
      for (final id in telemetryTileIds) {
        expect(sample.times[id], hasLength(sample.values[id]!.length));
      }
    });
  });
}
