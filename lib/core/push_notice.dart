import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Bound into every sealed notice, so one server's notice never opens as another's.
const pushAadPrefix = 'beacon-push/v1:';

/// The most characters of a radio or server name a notification shows.
const maxNoticeName = 40;

final _aes = AesGcm.with256bits();

/// What a Beacon server sealed for this phone: facts, never wording.
class PushNotice {
  const PushNotice({
    required this.kind,
    required this.name,
    this.value,
    this.detail = '',
    this.targetKind = '',
    this.publicKey = '',
    this.id = '',
    this.tempUnit = 'c',
  });
  final String kind, name, detail, targetKind, publicKey, id, tempUnit;
  final int? value;

  static PushNotice? fromJson(Object? json) {
    if (json is! Map) return null;
    String text(String key) => json[key] is String ? json[key] as String : '';
    final value = json['value'];
    final kind = text('kind');
    if (kind.isEmpty) return null;
    return PushNotice(
      kind: kind,
      name: text('name'),
      value: value is num ? value.toInt() : null,
      detail: text('detail'),
      targetKind: text('targetKind'),
      publicKey: text('publicKey'),
      id: text('id'),
      tempUnit: text('tempUnit') == 'f' ? 'f' : 'c',
    );
  }
}

final _space = RegExp(r'\s', unicode: true);
final _hidden = RegExp(r'[\p{Cc}\p{Cf}�]', unicode: true);
final _spaces = RegExp(r' +');

/// A name as a notification may show it: one line, no hidden characters, capped.
String capName(String name) {
  var s = name.replaceAll(_space, ' ').replaceAll(_hidden, '');
  s = s.replaceAll(_spaces, ' ').trim();
  final runes = s.runes;
  if (runes.length > maxNoticeName) {
    s = String.fromCharCodes(runes.take(maxNoticeName)).trim();
  }
  return s;
}

String _plural(int n, String unit) => n == 1 ? '1 $unit' : '$n ${unit}s';

String _duration(int seconds) {
  if (seconds >= 86400) return _plural(seconds ~/ 86400, 'day');
  if (seconds >= 3600) return _plural(seconds ~/ 3600, 'hour');
  return _plural(seconds ~/ 60, 'minute');
}

/// The sentence alert mail uses (beacon-server `alerts.Sentence`), word for
/// word; null for a kind this app does not know, which is never shown.
String? alertSentence(PushNotice n) {
  final name = capName(n.name);
  final v = n.value ?? 0;
  switch (n.kind) {
    case 'gone_quiet':
      return '$name has not been heard for ${_plural(v, 'hour')}.';
    case 'back_online':
      return '$name is back online.';
    case 'battery_low':
      return '$name battery is low: ${(v / 1000).toStringAsFixed(2)} V.';
    case 'battery_falling':
      return '$name battery is falling by about '
          '${(v / 1000).toStringAsFixed(2)} V a day.';
    case 'rebooted':
      return '$name rebooted.';
    case 'temperature':
      if (n.tempUnit == 'f') {
        final f = v / 10 * 9 / 5 + 32;
        return '$name temperature is ${f.toStringAsFixed(1)} F, '
            'outside your limits.';
      }
      return '$name temperature is ${(v / 10).toStringAsFixed(1)} C, '
          'outside your limits.';
    case 'noise_high':
      return '$name noise floor is high: $v dBm.';
    case 'clock':
      return '$name clock is off by ${_duration(v)}.';
    case 'observer_offline':
      return '$name has not reported for ${_plural(v, 'minute')}.';
    case 'request_attention':
      return switch (n.detail) {
        'login_failed' =>
          'Telemetry request for $name: the repeater did not accept the guest password.',
        'admin_stopped' =>
          'Telemetry request for $name: the password gave admin access and was deleted. Enter a guest password.',
        'disabled' =>
          'Telemetry request for $name was turned off: no observer has heard the repeater for days.',
        _ => 'Telemetry request for $name needs your attention.',
      };
  }
  return null;
}

/// Opens `ct` (base64 of nonce(12) || ciphertext || tag(16)); null for
/// anything that does not decrypt to a notice.
Future<PushNotice?> openNotice(List<int> key, String pushId, Object? ct) async {
  if (key.length != 32 || ct is! String) return null;
  try {
    final bytes = base64.decode(ct);
    if (bytes.length < 12 + 16) return null;
    final box = SecretBox(
      bytes.sublist(12, bytes.length - 16),
      nonce: bytes.sublist(0, 12),
      mac: Mac(bytes.sublist(bytes.length - 16)),
    );
    final plain = await _aes.decrypt(
      box,
      secretKey: SecretKey(key),
      aad: utf8.encode('$pushAadPrefix$pushId'),
    );
    return PushNotice.fromJson(jsonDecode(utf8.decode(plain)));
  } catch (_) {
    return null;
  }
}

/// Seals the way beacon-server does; for tests and fakes.
Future<String> sealNotice(List<int> key, String pushId, String plain) async {
  final box = await _aes.encrypt(
    utf8.encode(plain),
    secretKey: SecretKey(key),
    aad: utf8.encode('$pushAadPrefix$pushId'),
  );
  return base64.encode(box.concatenation());
}
