import 'dart:async';

import 'package:flutter/foundation.dart';

import 'account.dart';
import 'api.dart';
import 'features.dart';
import 'json.dart';

enum PushPermission { granted, denied, notAsked }

/// Everything the app needs from a push plugin. The Firebase one lives in
/// push_firebase.dart; tests use a fake and a build without Firebase
/// configuration answers false from `available()`.
abstract class PushClient {
  /// The OS name the server's `/me/devices` expects: ios or android.
  String get platform;

  /// True only when this build carries Firebase configuration.
  Future<bool> available();
  Future<PushPermission> permission();
  Future<PushPermission> requestPermission();
  Future<String?> token();
  Stream<String> get tokenRefreshes;
  Future<void> deleteToken();

  /// The data payload of each notification the user taps while the app runs.
  Stream<Json> get opened;

  /// The payload of the notification that launched the app, if any.
  Future<Json?> initialMessage();
}

/// For tests and builds that have no push plugin.
class NoPush implements PushClient {
  const NoPush();
  @override
  String get platform => 'android';
  @override
  Future<bool> available() async => false;
  @override
  Future<PushPermission> permission() async => PushPermission.notAsked;
  @override
  Future<PushPermission> requestPermission() async => PushPermission.notAsked;
  @override
  Future<String?> token() async => null;
  @override
  Stream<String> get tokenRefreshes => const Stream.empty();
  @override
  Future<void> deleteToken() async {}
  @override
  Stream<Json> get opened => const Stream.empty();
  @override
  Future<Json?> initialMessage() async => null;
}

enum PushStatus {
  /// Signed out, or the server does not deliver alerts by push.
  off,

  /// Push delivery, but this build has no Firebase configuration.
  notSetUp,
  needsPermission,
  denied,
  registered,
  failed,
}

/// Keeps this phone's push token registered for the signed-in account.
/// Permission is only ever asked for by [enable], never by [refresh].
class PushRegistration extends ChangeNotifier {
  PushRegistration({
    required this.client,
    required this.account,
    required this.features,
  }) {
    account.addListener(_accountChanged);
  }
  final PushClient client;
  final AccountState account;
  final Future<ServerFeatures> Function() features;

  /// Called with (targetKind, publicKey) when a notification is tapped.
  void Function(String kind, String publicKey)? onOpened;

  PushStatus status = PushStatus.off;
  StreamSubscription<String>? _refreshes;
  StreamSubscription<Json>? _taps;
  bool _launchChecked = false, _disposed = false, _wasSignedIn = false;
  int _generation = 0;

  void _accountChanged() {
    final signedIn = account.signedIn;
    if (signedIn == _wasSignedIn) return;
    _wasSignedIn = signedIn;
    if (signedIn) {
      unawaited(refresh());
    } else {
      _stop();
    }
  }

  void _set(PushStatus next) {
    if (_disposed) return;
    status = next;
    notifyListeners();
  }

  /// Works out the state and, when permission is already granted, registers.
  Future<void> refresh() async {
    if (!account.signedIn) return _set(PushStatus.off);
    final generation = ++_generation;
    try {
      final f = await features();
      if (!f.alerts || f.alertDelivery != 'push') return _set(PushStatus.off);
      if (!await client.available()) return _set(PushStatus.notSetUp);
      if (generation != _generation || !account.signedIn) return;
      _listenForTaps();
      switch (await client.permission()) {
        case PushPermission.granted:
          await _register();
        case PushPermission.denied:
          _set(PushStatus.denied);
        case PushPermission.notAsked:
          _set(PushStatus.needsPermission);
      }
    } catch (_) {
      _set(PushStatus.failed);
    }
  }

  /// Asks the OS for permission (from the Alerts section) and registers.
  Future<void> enable() async {
    if (!account.signedIn || !await client.available()) {
      return _set(PushStatus.notSetUp);
    }
    try {
      final result = await client.requestPermission();
      if (result == PushPermission.granted) {
        await _register();
      } else {
        _set(PushStatus.denied);
      }
    } catch (_) {
      _set(PushStatus.failed);
    }
  }

  Future<void> _register() async {
    final token = await client.token();
    if (token == null || token.isEmpty) return _set(PushStatus.failed);
    try {
      await account.api.registerDevice(client.platform, token);
    } on ApiException {
      return _set(PushStatus.failed);
    }
    _refreshes ??= client.tokenRefreshes.listen((next) async {
      if (!account.signedIn || next.isEmpty) return;
      try {
        await account.api.registerDevice(client.platform, next);
      } on ApiException {
        _set(PushStatus.failed);
      }
    });
    _set(PushStatus.registered);
  }

  void _listenForTaps() {
    _taps ??= client.opened.listen(_tapped);
    if (_launchChecked) return;
    _launchChecked = true;
    client.initialMessage().then((m) {
      if (m != null) _tapped(m);
    }, onError: (_) {});
  }

  void _tapped(Json data) {
    final kind = textOf(data['targetKind'], textOf(data['kind']));
    final key = textOf(data['publicKey']);
    if (kind.isEmpty || key.isEmpty) return;
    onOpened?.call(kind, key);
  }

  /// Removes this phone from the account. Call before the session ends; a
  /// failure must not stop the sign-out.
  Future<void> unregister() async {
    final active = status == PushStatus.registered;
    _stop();
    if (!active) return;
    try {
      await account.api.removeDevice();
    } catch (_) {}
    try {
      await client.deleteToken();
    } catch (_) {}
  }

  void _stop() {
    _generation++;
    _refreshes?.cancel();
    _refreshes = null;
    if (status != PushStatus.notSetUp) _set(PushStatus.off);
  }

  @override
  void dispose() {
    _disposed = true;
    account.removeListener(_accountChanged);
    _refreshes?.cancel();
    _taps?.cancel();
    super.dispose();
  }
}
