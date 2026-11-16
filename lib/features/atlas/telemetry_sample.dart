import '../../core/json.dart';
import '../directory/node_telemetry.dart';
import 'atlas.dart';

/// The readings call for an Atlas range. Three days is its own range on a
/// server that offers it; otherwise a week is read and trimmed to the window.
({String range, String interval}) telemetryRequest(
  AtlasRange range,
  bool atlasTelemetry,
) => switch (range) {
  AtlasRange.day => (range: '24h', interval: '1h'),
  AtlasRange.threeDays =>
    atlasTelemetry
        ? (range: '72h', interval: '1h')
        : (range: '168h', interval: '6h'),
};

/// A node card gets the tab when Beacon has readings for it or is polling it.
bool hasTelemetryTab({
  required String? typeName,
  required bool polling,
  Json? readings,
  Json? poller,
}) =>
    isPolledNodeType(typeName) &&
    polling &&
    (rows(readings?['points']).isNotEmpty || poller?['polled'] == true);

const dotsBelow = 8;

/// Few readings read better as dots than as a line.
bool useDots(List<double?> values) =>
    values.whereType<double>().length < dotsBelow;

class TelemetrySample {
  const TelemetrySample({
    required this.hourly,
    required this.battery,
    required this.noise,
    required this.uptime,
    required this.temperature,
    required this.airtime,
    required this.airtimeTx,
    required this.airtimeRx,
    required this.received,
    required this.sent,
    required this.snr,
    required this.rssi,
    required this.errors,
    required this.latestAt,
  });

  /// Per tile id: one value per hour of the window, oldest first, null where
  /// there was none.
  final Map<String, List<double?>> hourly;

  /// Latest value in the window. Battery is volts, airtime a percent of time,
  /// packets and errors per hour.
  final double? battery,
      noise,
      uptime,
      temperature,
      airtime,
      airtimeTx,
      airtimeRx,
      received,
      sent,
      snr,
      rssi,
      errors;

  /// Newest reading in the window, epoch ms.
  final int? latestAt;
  bool get hasTemperature => temperature != null;
}

/// Reads [telemetry] (the node readings route) into the window of [range]
/// ending at [now]. Counters become rates over their own `counterSpanSecs`,
/// never over the bucket length.
TelemetrySample summarizeTelemetry(Json? telemetry, AtlasRange range, int now) {
  final slots = HourSlots(range, now);
  final points = [
    for (final p in rows(telemetry?['points']))
      if (slots.inWindow(finite(p['t']))) p,
  ]..sort((a, b) => finite(a['t'])!.compareTo(finite(b['t'])!));
  final hourly = {
    for (final id in telemetryTileIds)
      id: List<double?>.filled(slots.hours, null),
  };
  final latest = <String, double>{};
  void put(String id, Json p, double? value) {
    if (value == null) return;
    hourly[id]![slots.bin(finite(p['t'])!)] = value;
    latest[id] = value;
  }

  double? rate(Json p, String key, double scale) {
    final value = finite(p[key]), span = finite(p['counterSpanSecs']);
    return value == null || span == null || span <= 0
        ? null
        : value / span * scale;
  }

  // A share over 100% cannot be real: no value, as the telemetry screen does.
  // The same goes for transmit and receive together.
  double? share(double? v) => v == null || v > 100 ? null : v;
  double? txShare, rxShare;
  for (final p in points) {
    final mv = finite(p['batteryMv']);
    put('battery', p, mv != null && mv > 0 ? mv / 1000 : null);
    put('noise', p, finite(p['noiseFloorDb']));
    put('uptime', p, finite(p['uptimeSeconds']));
    put('temperature', p, finite(p['temperatureC']));
    put('signal', p, finite(p['lastSnrDb']));
    final tx = share(rate(p, 'airtimeTxSecs', 100));
    final rx = share(rate(p, 'airtimeRxSecs', 100));
    if (tx != null && rx != null && tx + rx <= 100) {
      put('airtime', p, tx + rx);
      txShare = tx;
      rxShare = rx;
    }
    put('packets', p, rate(p, 'packetsReceived', 3600));
    put('errors', p, rate(p, 'receiveErrors', 3600));
    final sent = rate(p, 'packetsSent', 3600);
    if (sent != null) latest['sent'] = sent;
    final rssi = finite(p['lastRssiDb']);
    if (rssi != null) latest['rssi'] = rssi;
  }
  return TelemetrySample(
    hourly: hourly,
    battery: latest['battery'],
    noise: latest['noise'],
    uptime: latest['uptime'],
    temperature: latest['temperature'],
    airtime: latest['airtime'],
    airtimeTx: txShare,
    airtimeRx: rxShare,
    received: latest['packets'],
    sent: latest['sent'],
    snr: latest['signal'],
    rssi: latest['rssi'],
    errors: latest['errors'],
    latestAt: points.isEmpty ? null : finite(points.last['t'])?.toInt(),
  );
}
