import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Unpadded base64url of [bytes] random bytes, for verifiers and state.
String randomToken(int bytes, [Random? random]) {
  final source = random ?? Random.secure();
  return _b64url([for (var i = 0; i < bytes; i++) source.nextInt(256)]);
}

/// S256 code challenge: base64url of SHA-256 over the ASCII verifier.
String pkceChallenge(String verifier) =>
    _b64url(sha256.convert(ascii.encode(verifier)).bytes);

/// Compares without stopping at the first difference.
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    diff |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}
