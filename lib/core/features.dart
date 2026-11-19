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
    this.appDeviceLabel = false,
    this.temperatureUnit = 'c',
    this.distanceUnit = 'metric',
    this.atlasLimit = 12,
    this.alertEmail = false,
    this.alertPush = false,
    this.push,
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
      appDeviceLabel = false,
      temperatureUnit = 'c',
      distanceUnit = 'metric',
      atlasLimit = 12,
      alertEmail = false,
      alertPush = false,
      push = null,
      portalUrl = null;

  factory ServerFeatures.fromInfo(Json? info) {
    final f = object(info?['features']);
    final d = object(info?['display']);
    final atlas = object(info?['limits'])['atlas'];
    final channels = object(f['alertChannels']);
    return ServerFeatures(
      polling: f['polling'] == true,
      accounts: f['accounts'] is String ? f['accounts'] as String : 'off',
      telemetryRequests: f['telemetryRequests'] == true,
      alerts: f['alerts'] == true,
      registration: f['registration'] == true,
      atlasTelemetry: f['atlasTelemetry'] == true,
      mapTelemetry: f['mapTelemetry'] == true,
      appDeviceLabel: f['appDeviceLabel'] == true,
      temperatureUnit: d['temperatureUnit'] == 'f' ? 'f' : 'c',
      distanceUnit: d['distanceUnit'] == 'imperial' ? 'imperial' : 'metric',
      atlasLimit: atlas is int && atlas >= 1 && atlas <= 100 ? atlas : 12,
      alertEmail: channels['email'] == true,
      alertPush: channels['push'] == true,
      push: PushServerInfo.fromJson(f['push']),
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

  /// The app sign-in takes the app's own device label.
  final bool appDeviceLabel;

  /// Instance display units: 'c' or 'f', 'metric' or 'imperial'.
  final String temperatureUnit, distanceUnit;

  /// The most cards one Atlas holds; 12 on a server that does not say.
  final int atlasLimit;

  /// The channels this server sends alerts by.
  final bool alertEmail, alertPush;

  /// The push server to get a device handle from; null when there is no push.
  final PushServerInfo? push;

  /// Where portal users manage their sign-in, in portal mode.
  final String? portalUrl;
  bool get portal => accounts == 'portal';
}

/// `features.push`: where this phone gets its device handle for this server.
class PushServerInfo {
  const PushServerInfo(this.server, this.pushId);
  final Uri server;
  final String pushId;

  /// Only https: the handle request carries this phone's FCM token.
  static PushServerInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final server = json['server'], id = json['pushId'];
    if (server is! String || id is! String || id.isEmpty) return null;
    final uri = Uri.tryParse(server);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return PushServerInfo(uri, id);
  }
}
