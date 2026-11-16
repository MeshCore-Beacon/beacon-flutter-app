import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'json.dart';
import 'push.dart';

/// The only file that touches the Firebase plugins. Nothing here runs until
/// `available()` is asked, and without google-services.json or
/// GoogleService-Info.plist in the build it answers false and stays idle.
class FirebasePushClient implements PushClient {
  Future<bool>? _ready;

  @override
  String get platform =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  @override
  Future<bool> available() => _ready ??= _init();

  Future<bool> _init() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return false;
    }
    try {
      // Reads the native configuration; throws when the build has none.
      await Firebase.initializeApp();
      return true;
    } catch (_) {
      return false;
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
  Future<void> deleteToken() => _messaging.deleteToken();

  @override
  Stream<Json> get opened =>
      FirebaseMessaging.onMessageOpenedApp.map((m) => object(m.data));

  @override
  Future<Json?> initialMessage() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : object(message.data);
  }
}
