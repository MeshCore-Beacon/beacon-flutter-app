import 'package:beacon/core/units.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toDisplayTemp converts for f and leaves c alone', () {
    expect(toDisplayTemp(35, 'f'), closeTo(95, 1e-9));
    expect(toDisplayTemp(35, 'c'), 35);
  });

  test('fromDisplayTemp converts back', () {
    expect(fromDisplayTemp(95, 'f'), closeTo(35, 1e-9));
    expect(fromDisplayTemp(-40, 'f'), closeTo(-40, 1e-9));
    expect(fromDisplayTemp(35, 'c'), 35);
  });

  test('tempSymbol follows the unit', () {
    expect(tempSymbol('c'), '°C');
    expect(tempSymbol('f'), '°F');
  });

  test('formatTemp', () {
    expect(formatTemp(16.5, 'c'), '16.5 °C');
    expect(formatTemp(16.5, 'f'), '61.7 °F');
    expect(formatTemp(16.5, 'f', digits: 0), '62 °F');
  });
}
