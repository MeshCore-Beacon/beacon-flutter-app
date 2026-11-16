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
      alertDelivery = null,
      portalUrl = null;

  factory ServerFeatures.fromInfo(Json? info) {
    final f = object(info?['features']);
    return ServerFeatures(
      polling: f['polling'] == true,
      accounts: f['accounts'] is String ? f['accounts'] as String : 'off',
      telemetryRequests: f['telemetryRequests'] == true,
      alerts: f['alerts'] == true,
      registration: f['registration'] == true,
      atlasTelemetry: f['atlasTelemetry'] == true,
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

  /// "push" or "email" when alerts are on.
  final String? alertDelivery;

  /// Where portal users manage their sign-in, in portal mode.
  final String? portalUrl;
  bool get portal => accounts == 'portal';
}
