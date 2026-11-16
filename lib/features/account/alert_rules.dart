import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/units.dart';
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

/// Gone quiet also offers 3 and 6 hours for observers and polled repeaters;
/// `polled` is the server's own answer for the radio.
List<int> goneQuietHours(String targetKind, bool polled) {
  final short = targetKind == 'observer' || polled;
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

/// Degrees in [unit] as typed to tenths of a degree C; null when not a number
/// or a fraction of a degree F (those do not survive the round trip).
int? parseTenths(String text, [String unit = 'c']) {
  final v = _parse(text);
  if (v == null) return null;
  if (unit != 'f') return (v * 10).round();
  if (v != v.roundToDouble()) return null;
  return (fromDisplayTemp(v, 'f') * 10).round();
}

/// The limits and the least gap between them, as the user reads them in [unit].
/// The F gap is 4 because 3 F is under the 2.0 C the server takes.
({String min, String max, String width}) tempLimitText(String unit) =>
    unit == 'f'
    ? (min: '-58', max: '302', width: '4')
    : (min: '-50', max: '150', width: '2.0');

/// Whether tenths of a degree are inside what the server takes, -50 to 150 C.
bool tenthsInRange(int tenths) => tenths >= -500 && tenths <= 1500;

/// A duration of whole minutes in words: hours when it is a whole number of them.
String minutesLabel(int minutes) => minutes % 60 == 0
    ? trKey('alerts.hours', count: minutes ~/ 60)
    : trKey('alerts.minutes', count: minutes);

String voltsText(int? mv) => ((mv ?? 3500) / 1000).toStringAsFixed(2);

/// Tenths of a degree C in [unit]: one decimal in C, whole degrees in F.
String tenthsText(int? tenths, [String unit = 'c']) {
  if (tenths == null) return '';
  final celsius = tenths / 10;
  return unit == 'f'
      ? toDisplayTemp(celsius, 'f').round().toString()
      : celsius.toStringAsFixed(1);
}

/// A rule's state in words; `inactive` and `unknown` mean the server has no
/// data yet, `ok` and `firing` are the checked states.
String alertStateText(String state, String since) => switch (state) {
  'ok' => trKey('alerts.state.ok'),
  'firing' => trKey('alerts.state.firing').replaceAll('{{when}}', since),
  'inactive' => trKey('alerts.state.inactive'),
  _ => trKey('alerts.state.unknown'),
};

// beacon-server's unavailableCodes, by the catalog key that carries each.
const _reasonKeys = {
  'observer_no_data': 'observerNoData',
  'repeaters_only': 'repeatersOnly',
  'not_polled': 'notPolled',
  'no_data': 'noData',
  'observer_no_clock': 'observerNoClock',
  'clock_repeaters_only': 'clockRepeatersOnly',
  'needs_gone_quiet': 'needsGoneQuiet',
  'not_applicable': 'notApplicable',
};

// The codes whose sentence names the value the kind reads.
const _needsWhat = {'observer_no_data', 'repeaters_only', 'no_data'};
const _what = {
  'battery_low': 'battery',
  'battery_falling': 'battery',
  'rebooted': 'uptime',
  'temperature': 'temperature',
  'noise_high': 'noise',
};

/// Why a kind is unavailable, in the user's language, read from the code. No
/// code (an older server) or one this build does not know shows [sentence] as
/// the server sent it.
String alertReasonText(String kind, String? code, String sentence) {
  final key = _reasonKeys[code];
  if (key == null) return sentence;
  if (!_needsWhat.contains(code)) return trKey('serverText.alertReason.$key');
  final what = _what[kind];
  if (what == null) return sentence;
  return trKey('serverText.alertReason.$key')
      .replaceAll('{{what}}', trKey('serverText.alertWhat.$what'));
}

/// The line under a failed alert change, by the server's error code. [kind] is
/// the rule's kind, which names the value in some kind_unavailable reasons.
String alertError(Object error, [String kind = '']) {
  if (error is ApiException && error.status != null) {
    switch (error.code) {
      case 'kind_unavailable':
        final reason = object(object(error.body)['error'])['reasonCode'];
        final text = alertReasonText(
          kind,
          reason is String ? reason : null,
          error.message,
        );
        return text.isNotEmpty ? text : trKey('alerts.errors.kind_unavailable');
      case 'invalid_threshold':
      case 'not_on_atlas':
      case 'alerts_disabled':
      case 'not_found':
      case 'app_session_required':
        return trKey('alerts.errors.${error.code}');
    }
  }
  return accountError(error);
}
