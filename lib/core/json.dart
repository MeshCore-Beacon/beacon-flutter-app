import 'strings.dart';

typedef Json = Map<String, dynamic>;
Json object(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<Json> rows(dynamic value) {
  final source = value is List ? value : object(value)['items'];
  return source is List
      ? source.whereType<Map>().map(object).toList()
      : <Json>[];
}

String textOf(dynamic value, [String fallback = '']) =>
    value == null ? fallback : value.toString();
double? number(dynamic value) {
  final n = value is num ? value.toDouble() : double.tryParse(textOf(value));
  return n != null && n.isFinite ? n : null;
}

String shortKey(dynamic value, [int length = 8]) {
  final s = textOf(value);
  return s.length > length ? s.substring(0, length) : s;
}

String age(dynamic value) {
  final d = epoch(value);
  if (d == null) return tr('Unknown');
  final seconds = DateTime.now().difference(d).inSeconds;
  if (seconds < 0) return tr('just now');
  final duration = seconds < 60
      ? trKey('timestamp.unit.s', count: seconds)
      : seconds < 3600
      ? trKey('timestamp.unit.m', count: seconds ~/ 60)
      : seconds < 86400
      ? trKey('timestamp.unit.h', count: seconds ~/ 3600)
      : trKey('timestamp.unit.d', count: seconds ~/ 86400);
  return tr('{{duration}} ago').replaceAll('{{duration}}', duration);
}

// DateTime throws beyond ±8.64e15 ms; server values are untrusted.
DateTime? epoch(dynamic value, {bool isUtc = false}) {
  final n = number(value);
  if (n == null || n.abs() > 8.64e15) return null;
  return DateTime.fromMillisecondsSinceEpoch(n.round(), isUtc: isUtc);
}
