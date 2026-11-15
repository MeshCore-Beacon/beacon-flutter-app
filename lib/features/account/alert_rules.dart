import '../../core/api.dart';
import '../../core/strings.dart';
import 'account_errors.dart';

/// How a kind's threshold is entered.
enum AlertInput { none, hours, volts, drop, dbm, temperature, drift, minutes }

class AlertKindSpec {
  const AlertKindSpec(this.kind, this.input, [this.options = const []]);
  final String kind;
  final AlertInput input;

  /// The choices of a select, in the unit the server stores.
  final List<int> options;
}

/// The kinds in the order the rows are shown (the plan's table order).
const alertKinds = [
  AlertKindSpec('gone_quiet', AlertInput.hours, [12, 24, 48]),
  AlertKindSpec('back_online', AlertInput.none),
  AlertKindSpec('battery_low', AlertInput.volts),
  AlertKindSpec('battery_falling', AlertInput.drop, [100, 200, 300]),
  AlertKindSpec('rebooted', AlertInput.none),
  AlertKindSpec('temperature', AlertInput.temperature),
  AlertKindSpec('noise_high', AlertInput.dbm),
  AlertKindSpec('clock', AlertInput.drift, [300, 3600, 86400]),
  AlertKindSpec('observer_offline', AlertInput.minutes, [30, 60, 180, 360]),
];

/// Kinds that only exist for targets that report telemetry.
const _telemetryKinds = {
  'battery_low',
  'battery_falling',
  'rebooted',
  'temperature',
  'noise_high',
};

/// Gone quiet also offers 3 and 6 hours for observers and polled repeaters.
List<int> goneQuietHours(String targetKind, List<String> available) {
  final short =
      targetKind == 'observer' || available.any(_telemetryKinds.contains);
  return [
    if (short) ...[3, 6],
    12,
    24,
    48,
  ];
}

const defaultThreshold = {
  'gone_quiet': 24,
  'battery_low': 3500,
  'battery_falling': 200,
  'noise_high': -90,
  'clock': 3600,
  'observer_offline': 60,
};

final _number = RegExp(r'^[+-]?\d+([.,]\d+)?$');

double? _parse(String text) {
  final t = text.trim();
  return _number.hasMatch(t) ? double.tryParse(t.replaceFirst(',', '.')) : null;
}

/// Volts as typed to millivolts, or null outside 2.50 to 5.00.
int? parseVolts(String text) {
  final v = _parse(text);
  if (v == null) return null;
  final mv = (v * 1000).round();
  return mv >= 2500 && mv <= 5000 ? mv : null;
}

/// Whole dBm, or null outside -130 to -50.
int? parseDbm(String text) {
  final v = _parse(text);
  if (v == null || v != v.roundToDouble()) return null;
  return v >= -130 && v <= -50 ? v.round() : null;
}

/// Degrees C as typed to tenths of a degree; null when not a number. An empty
/// text is a side left open and is the caller's to handle.
int? parseTenths(String text) {
  final v = _parse(text);
  return v == null ? null : (v * 10).round();
}

String voltsText(int? mv) => ((mv ?? 3500) / 1000).toStringAsFixed(2);

String tenthsText(int? tenths) =>
    tenths == null ? '' : (tenths / 10).toStringAsFixed(1);

/// A rule's state in words; `inactive` and `unknown` mean the server has no
/// data yet, `ok` and `firing` are the checked states.
String alertStateText(String state, String since) => switch (state) {
  'ok' => trKey('alerts.state.ok'),
  'firing' => trKey('alerts.state.firing').replaceAll('{{when}}', since),
  'inactive' => trKey('alerts.state.inactive'),
  _ => trKey('alerts.state.unknown'),
};

/// The line under a failed alert change, by the server's error code.
String alertError(Object error) {
  if (error is ApiException && error.status != null) {
    switch (error.code) {
      case 'kind_unavailable':
        if (error.message.isNotEmpty) return error.message;
        return trKey('alerts.errors.kind_unavailable');
      case 'invalid_threshold':
      case 'not_on_atlas':
      case 'alerts_disabled':
        return trKey('alerts.errors.${error.code}');
    }
  }
  return accountError(error);
}
