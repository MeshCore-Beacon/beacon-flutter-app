import 'package:beacon/core/page_pacer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'lets a region-sized load through at once, then spaces pages 300 ms apart',
    () {
      final now = DateTime(2026);
      final pacer = PagePacer(now: () => now);
      for (var i = 0; i < 40; i++) {
        expect(pacer.reserve(), Duration.zero);
      }
      expect(pacer.reserve(), const Duration(milliseconds: 300));
      expect(pacer.reserve(), const Duration(milliseconds: 600));
    },
  );

  test('never sends more than 240 pages in any minute', () {
    var now = DateTime(2026);
    final pacer = PagePacer(now: () => now);
    final sends = <DateTime>[];
    for (var i = 0; i < 1000; i++) {
      now = now.add(pacer.reserve());
      sends.add(now);
      now = now.add(const Duration(milliseconds: 20));
    }
    var most = 0;
    for (var i = 0, j = 0; i < sends.length; i++) {
      while (sends[i].difference(sends[j]) >= const Duration(minutes: 1)) {
        j++;
      }
      if (i - j + 1 > most) most = i - j + 1;
    }
    expect(most, lessThanOrEqualTo(240));
    expect(most, greaterThan(200));
  });

  test('refills while idle', () {
    var now = DateTime(2026);
    final pacer = PagePacer(now: () => now);
    for (var i = 0; i < 40; i++) {
      pacer.reserve();
    }
    now = now.add(const Duration(seconds: 12));
    for (var i = 0; i < 10; i++) {
      expect(pacer.reserve(), Duration.zero);
    }
  });
}
