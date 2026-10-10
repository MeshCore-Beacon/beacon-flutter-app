import 'package:beacon/core/json.dart';
import 'package:beacon/features/directory/directory.dart' show stamp;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('number rejects non-finite values', () {
    expect(number('NaN'), null);
    expect(number('Infinity'), null);
    expect(number('-Infinity'), null);
    expect(number(double.nan), null);
    expect(number(double.infinity), null);
    expect(number('12.5'), 12.5);
    expect(number(3), 3.0);
  });

  test('epoch returns null outside the DateTime range', () {
    expect(epoch(0), DateTime.fromMillisecondsSinceEpoch(0));
    expect(
      epoch('1700000000000'),
      DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    expect(epoch(8.64e15 + 1), null);
    expect(epoch(-8.64e15 - 1), null);
    expect(epoch(1e300), null);
    expect(epoch('NaN'), null);
    expect(epoch(null), null);
  });

  test('age and stamp tolerate hostile timestamps', () {
    for (final value in ['NaN', 'Infinity', 1e300, -1e20]) {
      expect(age(value), 'Unknown');
      expect(stamp(value), 'Unknown');
    }
  });
}
