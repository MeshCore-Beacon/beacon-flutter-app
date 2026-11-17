import 'json.dart';

/// Optional server features from `/info`. Anything missing reads as off, so an older
/// server shows nothing new.
class ServerFeatures {
  const ServerFeatures({
    required this.polling,
    required this.accounts,
    required this.telemetryRequests,
    required this.alerts,
    this.registration = false,
    this.atlasTelemetry = false,
    this.mapTelemetry = false,
    this.temperatureUnit = 'c',
    this.distanceUnit = 'metric',
    this.atlasLimit = 12,
    this.alertDelivery,
    this.portalUrl,
  });
  const ServerFeatures.off()
    : polling = false,
      accounts = 'off',
      telemetryRequests = false,
      alerts = false,
      registration = false,
      atlasTelemetry = false,
      mapTelemetry = false,
      temperatureUnit = 'c',
      distanceUnit = 'metric',
      atlasLimit = 12,
      alertDelivery = null,
      portalUrl = null;

  factory ServerFeatures.fromInfo(Json? info) {
    final f = object(info?['features']);
    final d = object(info?['display']);
    final atlas = object(info?['limits'])['atlas'];
    return ServerFeatures(
      polling: f['polling'] == true,
      accounts: f['accounts'] is String ? f['accounts'] as String : 'off',
      telemetryRequests: f['telemetryRequests'] == true,
      alerts: f['alerts'] == true,
      registration: f['registration'] == true,
      atlasTelemetry: f['atlasTelemetry'] == true,
      mapTelemetry: f['mapTelemetry'] == true,
      temperatureUnit: d['temperatureUnit'] == 'f' ? 'f' : 'c',
      distanceUnit: d['distanceUnit'] == 'imperial' ? 'imperial' : 'metric',
      atlasLimit: atlas is int && atlas >= 1 && atlas <= 100 ? atlas : 12,
      alertDelivery:
          f['alertDelivery'] == 'push' || f['alertDelivery'] == 'email'
          ? f['alertDelivery'] as String
          : null,
      portalUrl: f['portalUrl'] is String && (f['portalUrl'] as String) != ''
          ? f['portalUrl'] as String
          : null,
    );
  }

  final bool polling;
  final String accounts;
  final bool telemetryRequests;
  final bool alerts;
  final bool registration;

  /// The account Atlas stores Telemetry tiles and a pinned Telemetry view, and
  /// the readings route takes range=72h.
  final bool atlasTelemetry;

  /// Map labels may carry the latest telemetry; the toggle hides without it.
  final bool mapTelemetry;

  /// Instance display units: 'c' or 'f', 'metric' or 'imperial'.
  final String temperatureUnit, distanceUnit;

  /// The most cards one Atlas holds; 12 on a server that does not say.
  final int atlasLimit;

  /// "push" or "email" when alerts are on.
  final String? alertDelivery;

  /// Where portal users manage their sign-in, in portal mode.
  final String? portalUrl;
  bool get portal => accounts == 'portal';
}
