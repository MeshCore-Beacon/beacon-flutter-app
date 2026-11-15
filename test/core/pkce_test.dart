import 'dart:math';

import 'package:beacon/core/pkce.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('challenge matches the RFC 7636 vector', () {
    expect(
      pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
  });

  test('random tokens are unpadded base64url of the asked length', () {
    final verifier = randomToken(32, Random(1));
    expect(verifier.length, 43);
    expect(randomToken(16, Random(1)).length, 22);
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(verifier), true);
    expect(randomToken(32), isNot(randomToken(32)));
  });

  test('constant-time compare', () {
    expect(constantTimeEquals('abc', 'abc'), true);
    expect(constantTimeEquals('abc', 'abd'), false);
    expect(constantTimeEquals('abc', 'abcd'), false);
  });
}
