import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'json.dart';
import 'push.dart';
import 'push_display.dart';
import 'push_store.dart';

bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Android only: a sealed message that arrives while the app is in the
/// background or not running. iOS decrypts in its Notification Service Extension.
@pragma('vm:entry-point')
Future<void> beaconBackgroundMessage(RemoteMessage message) async {
  if (!_android) return;
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await deliverNotice(
      message.data,
      store: SecurePushStore(),
      notifier: await LocalNotifier.ready(),
    );
  } catch (_) {}
}

/// Shows notices on Android through flutter_local_notifications.
class LocalNotifier implements Notifier {
  LocalNotifier._(this._plugin);
  final FlutterLocalNotificationsPlugin _plugin;

  static const _channel = AndroidNotificationChannel(
    'beacon_alerts',
    'Alerts',
    description: 'Alerts from your Beacon servers',
    importance: Importance.high,
  );

  /// Initialises the plugin in this isolate; taps go to [onTap].
  static Future<LocalNotifier> ready({
    void Function(NotificationResponse)? onTap,
  }) async {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: onTap,
    );
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(_channel);
    return LocalNotifier._(plugin);
  }

  FlutterLocalNotificationsPlugin get plugin => _plugin;

  @override
  Future<void> show(ShownNotice notice) => _plugin.show(
    id: notice.id,
    title: notice.title,
    body: notice.body,
    payload: notice.payload,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        channelDescription: _channel.description,
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(notice.body),
      ),
    ),
  );
}

/// Android push through FCM; the only file that touches the Firebase plugins.
/// Nothing runs until `available()` is asked, and without google-services.json
/// in the build it answers false and stays idle. iOS uses push_apns.dart.
class FirebasePushClient implements PushClient {
  FirebasePushClient({PushStore? store}) : _store = store ?? SecurePushStore();
  final PushStore _store;
  Future<bool>? _ready;
  final _localTaps = StreamController<Json>.broadcast();
  Json? _localLaunch;

  @override
  String get platform => 'android';

  @override
  Future<bool> available() => _ready ??= _init();

  Future<bool> _init() async {
    if (!_android) return false;
    try {
      // Reads the native configuration; throws when the build has none.
      await Firebase.initializeApp();
    } catch (_) {
      return false;
    }
    try {
      // Android gets data only; the app opens and shows each message itself.
      final notifier = await LocalNotifier.ready(
        onTap: (r) => _localTaps.add(_payload(r.payload)),
      );
      final launch = await notifier.plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        _localLaunch = _payload(launch?.notificationResponse?.payload);
      }
      FirebaseMessaging.onBackgroundMessage(beaconBackgroundMessage);
      FirebaseMessaging.onMessage.listen((m) async {
        try {
          await deliverNotice(m.data, store: _store, notifier: notifier);
        } catch (_) {}
      });
    } catch (_) {}
    return true;
  }

  static Json _payload(String? raw) {
    if (raw == null) return {};
    try {
      return object(jsonDecode(raw));
    } catch (_) {
      return {};
    }
  }

  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  static PushPermission _map(AuthorizationStatus status) => switch (status) {
    AuthorizationStatus.authorized ||
    AuthorizationStatus.provisional => PushPermission.granted,
    AuthorizationStatus.denied ||
    AuthorizationStatus.deniedPermanently => PushPermission.denied,
    AuthorizationStatus.notDetermined => PushPermission.notAsked,
  };

  @override
  Future<PushPermission> permission() async =>
      _map((await _messaging.getNotificationSettings()).authorizationStatus);

  @override
  Future<PushPermission> requestPermission() async =>
      _map((await _messaging.requestPermission()).authorizationStatus);

  @override
  Future<String?> token() => _messaging.getToken();

  @override
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

  @override
  Future<String?> apnsEnvironment() async => null;

  @override
  Stream<Json> get opened => _localTaps.stream;

  @override
  Future<Json?> initialMessage() async => _localLaunch;
}
