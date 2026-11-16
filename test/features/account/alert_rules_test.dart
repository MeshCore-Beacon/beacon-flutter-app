import 'package:beacon/features/account/alert_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('temperature limits are typed in the instance unit', () {
    expect(parseTenths('95', 'f'), 350);
    expect(parseTenths('14', 'f'), -100);
    expect(tenthsText(350, 'f'), '95');
    expect(tenthsText(-100, 'c'), '-10.0');
    expect(parseTenths('-10.0'), -100);
  });

  test('whole Fahrenheit survives the round trip', () {
    for (var f = -58; f <= 302; f++) {
      expect(tenthsText(parseTenths('$f', 'f'), 'f'), '$f');
    }
  });

  test('the Fahrenheit limits are the Celsius range', () {
    expect(tenthsInRange(parseTenths('-58', 'f')!), isTrue);
    expect(tenthsInRange(parseTenths('302', 'f')!), isTrue);
    expect(tenthsInRange(parseTenths('-59', 'f')!), isFalse);
    expect(tenthsInRange(parseTenths('303', 'f')!), isFalse);
  });
}
