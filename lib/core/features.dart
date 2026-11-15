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
  });
  const ServerFeatures.off()
    : polling = false,
      accounts = 'off',
      telemetryRequests = false,
      alerts = false,
      registration = false;

  factory ServerFeatures.fromInfo(Json? info) {
    final f = object(info?['features']);
    return ServerFeatures(
      polling: f['polling'] == true,
      accounts: f['accounts'] is String ? f['accounts'] as String : 'off',
      telemetryRequests: f['telemetryRequests'] == true,
      alerts: f['alerts'] == true,
      registration: f['registration'] == true,
    );
  }

  final bool polling;
  final String accounts;
  final bool telemetryRequests;
  final bool alerts;
  final bool registration;
}
