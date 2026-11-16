import '../../core/json.dart';
import 'atlas.dart';

/// One bucket per hour for both observer series.
const observerInterval = '1h';

class PayloadShare {
  const PayloadShare(this.name, this.count);
  final String name;
  final double count;
}

class ObserverSample {
  const ObserverSample({
    required this.heard,
    required this.partial,
    required this.counts,
    required this.types,
    required this.airtime,
    required this.airtimeTx,
    required this.airtimeRx,
    required this.airtimeHourly,
    required this.airtimeSource,
    required this.noiseHourly,
    required this.noise,
    required this.batteryHourly,
    required this.battery,
    required this.uptime,
    required this.uptimeHourly,
    required this.snr,
    required this.snrHourly,
    required this.rssi,
    required this.rssiHourly,
    required this.queue,
    required this.queueHourly,
    required this.errors,
    required this.errorsHourly,
  });
  final double? heard;
  final bool partial;
  final List<double?> counts;

  /// Busiest first.
  final List<PayloadShare> types;

  /// Percent of the window on air, TX + RX.
  final double? airtime, airtimeTx, airtimeRx;
  final List<double?> airtimeHourly;

  /// 'radio': the device's own TX/RX counters; 'heard': RX estimated from the
  /// packets it heard.
  final String? airtimeSource;
  final List<double?> noiseHourly, batteryHourly, uptimeHourly;
  final double? noise, battery, uptime;

  /// Window means weighted by each hour's packet count: the response carries
  /// hourly averages, not sums.
  final double? snr, rssi;
  final List<double?> snrHourly, rssiHourly;

  /// Latest reading.
  final double? queue;
  final List<double?> queueHourly;

  /// Receive errors counted inside the window.
  final double? errors;
  final List<double?> errorsHourly;
}

const _telemetryKeys = [
  'batteryMv',
  'airtimeTxSecs',
  'airtimeRxSecs',
  'noiseFloorDb',
  'uptimeSeconds',
  'queueLength',
  'receiveErrors',
];

/// The status record's own noise floor, as the Observers page reads it.
double? observerNoiseFloor(Json observer) =>
    finite(object(object(observer['statusMetadata'])['stats'])['noise_floor']);

ObserverSample summarizeObserver(
  Json? activity,
  Json? telemetry,
  Json? observer,
  AtlasRange range,
  int now,
) {
  final slots = HourSlots(range, now);
  final hours = slots.hours;
  List<double?> blank() => List<double?>.filled(hours, null);
  final counts = slots.counts(activity);
  // Hours the server read but has no bucket for were quiet: on air 0% of the time.
  final heardAir = [for (final v in counts) v == null ? null : 0.0];
  double? heard = counts.any((v) => v != null) ? 0 : null;
  var heardMs = 0.0;
  var costed = false;
  final sums = {'snrAvg': 0.0, 'rssiAvg': 0.0};
  final weights = {'snrAvg': 0.0, 'rssiAvg': 0.0};
  final hourly = {'snrAvg': blank(), 'rssiAvg': blank()};
  for (final p in rows(activity?['points'])) {
    final t = finite(p['t']);
    if (!slots.inWindow(t)) continue;
    final i = slots.bin(t!);
    final observations = finite(p['observations']);
    if (observations == null) {
      counts[i] = null;
      heardAir[i] = null;
      continue;
    }
    counts[i] = (counts[i] ?? 0) + observations;
    heard = (heard ?? 0) + observations;
    for (final key in sums.keys) {
      final value = finite(p[key]);
      if (value == null) continue;
      hourly[key]![i] = value;
      sums[key] = sums[key]! + value * observations;
      weights[key] = weights[key]! + observations;
    }
    final airtimeMs = finite(p['airtimeMs']);
    if (airtimeMs != null) {
      costed = true;
      heardMs += airtimeMs;
      heardAir[i] = (heardAir[i] ?? 0) + airtimeMs / hourMs * 100;
    }
  }
  final types = [
    for (final p in rows(activity?['payloadTypes']))
      if (finite(p['count']) case final double count when count > 0)
        PayloadShare(textOf(p['payloadTypeName']), count),
  ];
  // A stable sort keeps the server's order among equal counts, as the web does.
  final ordered = [for (var i = 0; i < types.length; i++) (i, types[i])]
    ..sort((a, b) {
      final byCount = b.$2.count.compareTo(a.$2.count);
      return byCount != 0 ? byCount : a.$1.compareTo(b.$1);
    });

  // A stray all-zero status row is "no reading", not a 0 dB floor or an empty battery.
  bool reads(Json p) => _telemetryKeys.any((key) {
    final value = p[key];
    return value != null && value != 0;
  });
  final points = rows(telemetry?['points']);
  final live =
      [
        for (var i = 0; i < points.length; i++)
          if (slots.inWindow(finite(points[i]['t'])) && reads(points[i]))
            (i, points[i]),
      ]..sort((a, b) {
        final byTime = finite(a.$2['t'])!.compareTo(finite(b.$2['t'])!);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
  final readings = [for (final entry in live) entry.$2];
  double time(Json p) => finite(p['t'])!;
  List<double?> series(String key) {
    final out = blank();
    for (final p in readings) {
      final value = finite(p[key]);
      if (value != null) out[slots.bin(time(p))] = value;
    }
    return out;
  }

  double? latest(String key) {
    for (final p in readings.reversed) {
      final value = finite(p[key]);
      if (value != null) return value;
    }
    return null;
  }

  // Mains-powered observers report 0 mV; a battery never reads zero, so that is "no battery".
  double? volts(double? mv) => mv != null && mv > 0 ? mv / 1000 : null;
  final level = observer?['batteryLevel'];
  final battery = level == null
      ? volts(latest('batteryMv'))
      : (finite(level) ?? 0) > 0
      ? finite(level)
      : null;
  final uptime = finite(observer?['uptimeSeconds']) ?? latest('uptimeSeconds');

  // 1h telemetry points carry on-air seconds since boot: each step between
  // readings is time on air over the time between them. A counter that went
  // backwards was a reboot, so that step counts as 0.
  var txSecs = 0.0, rxSecs = 0.0, spanSecs = 0.0;
  final radioAir = blank();
  final counted = [
    for (final p in readings)
      if (finite(p['airtimeTxSecs']) != null &&
          finite(p['airtimeRxSecs']) != null)
        p,
  ];
  double step(Json cur, Json prev, String key) {
    final delta = finite(cur[key])! - finite(prev[key])!;
    return delta < 0 ? 0 : delta;
  }

  for (var i = 1; i < counted.length; i++) {
    final prev = counted[i - 1], cur = counted[i];
    final gap = (time(cur) - time(prev)) / 1000;
    if (gap <= 0) continue;
    final tx = step(cur, prev, 'airtimeTxSecs');
    final rx = step(cur, prev, 'airtimeRxSecs');
    txSecs += tx;
    rxSecs += rx;
    spanSecs += gap;
    radioAir[slots.bin(time(cur))] = (tx + rx) / gap * 100;
  }
  // The 1h points carry receive errors since boot, as the Observers tab charts
  // them: count the steps.
  double? errors;
  final errorsHourly = blank();
  final errored = [
    for (final p in readings)
      if (finite(p['receiveErrors']) != null) p,
  ];
  for (var i = 1; i < errored.length; i++) {
    final delta = step(errored[i], errored[i - 1], 'receiveErrors');
    final slot = slots.bin(time(errored[i]));
    errorsHourly[slot] = (errorsHourly[slot] ?? 0) + delta;
    errors = (errors ?? 0) + delta;
  }

  final radio = spanSecs > 0;
  final readHours = heardAir.where((v) => v != null).length;
  final estimated = !radio && costed && readHours > 0;
  final heardShare = estimated
      ? heardMs / 1000 / (readHours * 3600) * 100
      : null;
  double? mean(String key) =>
      weights[key]! > 0 ? sums[key]! / weights[key]! : null;

  return ObserverSample(
    heard: heard,
    partial: activity != null && counts.contains(null),
    counts: counts,
    types: [for (final entry in ordered) entry.$2],
    airtime: radio ? (txSecs + rxSecs) / spanSecs * 100 : heardShare,
    airtimeTx: radio ? txSecs / spanSecs * 100 : null,
    airtimeRx: radio ? rxSecs / spanSecs * 100 : heardShare,
    airtimeHourly: radio
        ? radioAir
        : estimated
        ? heardAir
        : blank(),
    airtimeSource: radio
        ? 'radio'
        : estimated
        ? 'heard'
        : null,
    noiseHourly: series('noiseFloorDb'),
    // The status record's reading first, as the Observers page does; telemetry when it has none.
    noise:
        (observer == null ? null : observerNoiseFloor(observer)) ??
        latest('noiseFloorDb'),
    batteryHourly: [for (final mv in series('batteryMv')) volts(mv)],
    battery: battery,
    uptime: uptime,
    uptimeHourly: series('uptimeSeconds'),
    snr: mean('snrAvg'),
    snrHourly: hourly['snrAvg']!,
    rssi: mean('rssiAvg'),
    rssiHourly: hourly['rssiAvg']!,
    queue: latest('queueLength'),
    queueHourly: series('queueLength'),
    errors: errors,
    errorsHourly: errorsHourly,
  );
}
