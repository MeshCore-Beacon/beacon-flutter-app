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
    required this.values,
    required this.airtimeTx,
    required this.airtimeRx,
    required this.sent,
    required this.rssi,
    required this.rebooted,
    required this.readings,
    required this.latestAt,
  });

  /// Per tile id: one value per reading that carried it, oldest first. Battery
  /// is volts, airtime a percent of time, packets and errors per hour, signal
  /// the SNR.
  final Map<String, List<double>> values;

  /// At the reading airtime's latest value came from.
  final double? airtimeTx, airtimeRx;

  /// Packets sent per hour, at the reading the received value came from.
  final double? sent;
  final double? rssi;

  /// Uptime fell somewhere in the window.
  final bool rebooted;

  /// Points in the window, whatever they carry.
  final int readings;

  /// Newest reading in the window, epoch ms.
  final int? latestAt;

  double? latest(String tile) => values[tile]!.lastOrNull;
  bool get hasTemperature => values['temperature']!.isNotEmpty;
}

/// Reads [telemetry] (the node readings route) into the window of [range]
/// ending at [now]. Counters become rates over their own `counterSpanSecs`,
/// never over the bucket length.
TelemetrySample summarizeTelemetry(Json? telemetry, AtlasRange range, int now) {
  final from = now - range.hours * hourMs;
  final points = [
    for (final p in rows(telemetry?['points']))
      if (finite(p['t']) case final t? when t >= from && t <= now + hourMs) p,
  ]..sort((a, b) => finite(a['t'])!.compareTo(finite(b['t'])!));
  final values = {for (final id in telemetryTileIds) id: <double>[]};
  double? rate(Json p, String key, double scale) {
    final value = finite(p[key]), span = finite(p['counterSpanSecs']);
    return value == null || span == null || span <= 0
        ? null
        : value / span * scale;
  }

  // A share over 100% cannot be real: no value, as the telemetry screen does.
  // The same goes for transmit and receive together.
  double? share(double? v) => v == null || v > 100 ? null : v;
  double? txShare, rxShare, sent, rssi;
  for (final p in points) {
    void put(String id, double? value) {
      if (value != null) values[id]!.add(value);
    }

    final mv = finite(p['batteryMv']);
    put('battery', mv != null && mv > 0 ? mv / 1000 : null);
    put('noise', finite(p['noiseFloorDb']));
    final up = finite(p['uptimeSeconds']);
    put('uptime', up != null && up >= 0 ? up : null);
    put('temperature', finite(p['temperatureC']));
    put('signal', finite(p['lastSnrDb']));
    final tx = share(rate(p, 'airtimeTxSecs', 100));
    final rx = share(rate(p, 'airtimeRxSecs', 100));
    if (tx != null && rx != null && tx + rx <= 100) {
      put('airtime', tx + rx);
      txShare = tx;
      rxShare = rx;
    }
    final received = rate(p, 'packetsReceived', 3600);
    put('packets', received);
    if (received != null) sent = rate(p, 'packetsSent', 3600);
    put('errors', rate(p, 'receiveErrors', 3600));
    if (finite(p['lastSnrDb']) != null) rssi = finite(p['lastRssiDb']);
  }
  final uptime = values['uptime']!;
  return TelemetrySample(
    values: values,
    airtimeTx: txShare,
    airtimeRx: rxShare,
    sent: sent,
    rssi: rssi,
    rebooted: [
      for (var i = 1; i < uptime.length; i++)
        if (uptime[i] < uptime[i - 1]) i,
    ].isNotEmpty,
    readings: points.length,
    latestAt: points.isEmpty ? null : finite(points.last['t'])?.toInt(),
  );
}
