import 'package:beacon/features/account/password_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the minimum counts characters, not UTF-16 units or bytes', () {
    expect(newPasswordOk('a' * 11), false);
    expect(newPasswordOk('a' * 12), true);
    expect(newPasswordOk('éàùèâêîôûëïü'), true); // 12 characters, 24 bytes
    expect('😀' * 11, hasLength(22)); // 11 characters, 22 UTF-16 units
    expect(newPasswordOk('😀' * 11), false);
    expect(newPasswordOk('😀' * 12), true);
  });

  test('the maximum is 128 bytes', () {
    expect(newPasswordOk('a' * 128), true);
    expect(newPasswordOk('a' * 129), false);
    expect(newPasswordOk('é' * 64), true); // 128 bytes
    expect(newPasswordOk('é' * 65), false);
  });
}
