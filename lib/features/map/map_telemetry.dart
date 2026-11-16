import '../../core/json.dart';
import '../../core/units.dart';

typedef TelemetryLabel = ({String text, bool old});

/// Battery, temperature and age for one reading, or null with neither value.
TelemetryLabel? telemetryLabel(
  Map<String, dynamic> reading,
  String unit,
  int nowMs,
) {
  final mv = number(reading['batteryMv']);
  final c = number(reading['temperatureC']);
  final at = number(reading['sampledAt']);
  if (at == null || (mv == null && c == null)) return null;
  final minutes = ((nowMs - at) / 60000).floor().clamp(0, 1 << 30);
  final hours = minutes ~/ 60;
  final age = minutes < 60
      ? '${minutes}m'
      : hours < 48
      ? '${hours}h'
      : '${hours ~/ 24}d';
  // int rounding, so -0.4 reads 0 and never -0
  final deg = c == null ? null : toDisplayTemp(c, unit).round();
  final parts = [
    if (mv != null) '${(mv / 1000).toStringAsFixed(2)}V',
    if (deg != null) '$deg°',
    age,
  ];
  return (text: parts.join('  '), old: hours >= 48);
}

/// Labels keyed by nodeId; readings without a label are dropped.
Map<String, TelemetryLabel> telemetryLabels(
  List<Map<String, dynamic>> items,
  String unit,
  int nowMs,
) {
  final out = <String, TelemetryLabel>{};
  for (final item in items) {
    final label = telemetryLabel(item, unit, nowMs);
    final id = textOf(item['nodeId']);
    if (label != null && id.isNotEmpty) out[id] = label;
  }
  return out;
}

/// The previous map when nothing visible changed, so an idle tick pushes no data.
Map<String, TelemetryLabel> keepLabels(
  Map<String, TelemetryLabel> previous,
  Map<String, TelemetryLabel> next,
) {
  if (previous.length != next.length) return next;
  for (final e in next.entries) {
    final p = previous[e.key];
    if (p == null || p.text != e.value.text || p.old != e.value.old) {
      return next;
    }
  }
  return previous;
}
