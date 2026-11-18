import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'account.dart';
import 'api.dart';
import 'auth_api.dart';
import 'features.dart';
import 'json.dart';
import 'push_notice.dart';
import 'push_relay.dart';
import 'push_store.dart';

enum PushPermission { granted, denied, notAsked }

/// Everything the app needs from a push plugin. The Firebase one lives in
/// push_firebase.dart; tests use a fake and a build without Firebase
/// configuration answers false from `available()`.
abstract class PushClient {
  /// The OS name the push server and `/me/devices` expect: ios or android.
  String get platform;

  /// True only when this build carries Firebase configuration.
  Future<bool> available();
  Future<PushPermission> permission();
  Future<PushPermission> requestPermission();
  Future<String?> token();
  Stream<String> get tokenRefreshes;

  /// The data of each notification the user taps while the app runs: the
  /// sealed FCM data on iOS, the shown notification's payload on Android.
  Stream<Json> get opened;

  /// The same for the notification that launched the app, if any.
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
  Stream<Json> get opened => const Stream.empty();
  @override
  Future<Json?> initialMessage() async => null;
}

/// The radio a tapped notification names, on the server that sent it.
class PushTarget {
  const PushTarget(this.url, this.kind, this.publicKey, this.id);
  final String url, kind, publicKey;

  /// The radio's node or observer id; null when the notice has none.
  final String? id;
}

/// App-wide push state: the stored handles, token refreshes and taps, which
/// belong to no single server.
class PushHub {
  PushHub({
    required this.client,
    required this.store,
    required this.relay,
    int Function()? random,
  }) : _random = random ?? _secureByte;
  final PushClient client;
  final PushStore store;
  final PushRelay relay;
  final int Function() _random;
  static final _secure = Random.secure();
  static int _secureByte() => _secure.nextInt(256);

  /// The active server and how to switch to another, set by the app shell.
  String? Function() activeUrl = () => null;
  Future<void> Function(String url) selectServer = (_) async {};

  final _handlers = <String, void Function(PushTarget)>{};
  PushTarget? _pending;
  StreamSubscription<String>? _refreshes;
  StreamSubscription<Json>? _taps;
  Future<void>? _started;

  /// A fresh 32-byte payload key from a secure source.
  String newKey() => base64.encode([for (var i = 0; i < 32; i++) _random()]);

  /// Listens for token refreshes and taps; safe to call more than once.
  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    if (!await client.available()) return;
    _refreshes = client.tokenRefreshes.listen(_tokenChanged);
    _taps = client.opened.listen(tap);
    try {
      final first = await client.initialMessage();
      if (first != null) await tap(first);
    } catch (_) {}
  }

  /// The handles stay; only the token behind them moves.
  Future<void> _tokenChanged(String token) async {
    if (token.isEmpty) return;
    for (final e in await store.all()) {
      try {
        await relay.updateHandle(
          e.relay,
          e.handle,
          handleSecret: e.handleSecret,
          fcmToken: token,
        );
      } catch (_) {}
    }
  }

  /// Opens a tapped notification's radio, switching servers when needed.
  Future<void> tap(Json data) async {
    final target = await resolve(data);
    if (target == null) return;
    final handler = _handlers[target.url];
    if (activeUrl() == target.url && handler != null) return handler(target);
    _pending = target;
    if (activeUrl() != target.url) await selectServer(target.url);
  }

  /// The tap's radio, or null when it is not from a server this phone knows.
  Future<PushTarget?> resolve(Json data) async {
    final pushId = textOf(data['pushId']);
    if (pushId.isEmpty) return null;
    final entry = await store.read(pushId);
    if (entry == null) return null;
    var kind = textOf(data['targetKind']);
    var key = textOf(data['publicKey']);
    var id = textOf(data['id']);
    if (data['ct'] != null) {
      final notice = await openNotice(entry.keyBytes, pushId, data['ct']);
      if (notice == null) return null;
      (kind, key, id) = (notice.targetKind, notice.publicKey, notice.id);
    }
    if (key.isEmpty) return null;
    return PushTarget(
      entry.url,
      kind.isEmpty ? 'node' : kind,
      key,
      id.isEmpty ? null : id,
    );
  }

  /// A server's home screen takes the taps for it, and one that waited.
  void attach(String url, void Function(PushTarget) handler) {
    _handlers[url] = handler;
    final pending = _pending;
    if (pending != null && pending.url == url) {
      _pending = null;
      handler(pending);
    }
  }

  void detach(String url, void Function(PushTarget) handler) {
    if (_handlers[url] == handler) _handlers.remove(url);
  }

  /// For a server being removed: its device, then its handle, then the entry.
  Future<void> forget(String url, AuthApi api) async {
    final entry = await store.forUrl(url);
    if (entry == null) return;
    await _remove(entry, api);
  }

  Future<void> _remove(PushEntry entry, AuthApi? api) async {
    try {
      await api?.removeDevice();
    } catch (_) {}
    try {
      await relay.deleteHandle(
        entry.relay,
        entry.handle,
        handleSecret: entry.handleSecret,
      );
    } catch (_) {}
    try {
      await store.delete(entry.pushId);
    } catch (_) {}
  }

  void dispose() {
    _refreshes?.cancel();
    _taps?.cancel();
  }
}

enum PushStatus {
  /// Signed out, or the server does not send push.
  off,

  /// The server sends push, but this build has no Firebase configuration.
  notSetUp,
  needsPermission,
  denied,

  /// The user turned push off for this account; nothing is registered.
  paused,
  registered,
  failed,
}

/// Keeps this phone registered with one server through the push server, for
/// the signed-in account. Permission is only asked for by [enable].
class PushRegistration extends ChangeNotifier {
  PushRegistration({
    required this.hub,
    required this.account,
    required this.features,
    required this.serverUrl,
    required this.serverName,
  }) {
    account.addListener(_accountChanged);
  }
  final PushHub hub;
  final AccountState account;
  final Future<ServerFeatures> Function() features;

  /// The saved server this registration is for, and its current name.
  final String serverUrl;
  final String Function() serverName;

  PushClient get client => hub.client;

  PushStatus status = PushStatus.off;
  bool _disposed = false, _wasSignedIn = false;
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

  /// Works out the state and, when permission is granted and the user's push
  /// switch is on, registers.
  Future<void> refresh() async {
    if (!account.signedIn) return _set(PushStatus.off);
    final generation = ++_generation;
    final epoch = account.epoch;
    bool gone() => generation != _generation || account.epoch != epoch;
    try {
      final f = await features();
      if (gone()) return;
      final info = f.push;
      if (!f.alerts || info == null) return _set(PushStatus.off);
      if (!await client.available()) return _set(PushStatus.notSetUp);
      if (gone() || !account.signedIn) return;
      switch (await client.permission()) {
        case PushPermission.granted:
          // Registering turns the switch on, so a user who turned it off stays off.
          final channels = object((await account.api.alerts())['channels']);
          if (gone()) return;
          if (object(channels['push'])['enabled'] == false) {
            return _set(PushStatus.paused);
          }
          await _register(info);
        case PushPermission.denied:
          _set(PushStatus.denied);
        case PushPermission.notAsked:
          _set(PushStatus.needsPermission);
      }
    } catch (_) {
      if (!gone()) _set(PushStatus.failed);
    }
  }

  /// Asks the OS for permission (from the profile) and registers.
  Future<void> enable() async {
    if (!account.signedIn) return _set(PushStatus.off);
    try {
      final info = (await features()).push;
      if (info == null) return _set(PushStatus.off);
      if (!await client.available()) return _set(PushStatus.notSetUp);
      final result = await client.requestPermission();
      if (result == PushPermission.granted) {
        await _register(info);
      } else {
        _set(PushStatus.denied);
      }
    } catch (_) {
      _set(PushStatus.failed);
    }
  }

  Future<void> _register(PushServerInfo info) async {
    // A result from a session that has since ended says nothing about this one.
    final epoch = account.epoch;
    bool gone() => _disposed || account.epoch != epoch || !account.signedIn;
    final token = await client.token();
    if (gone()) return;
    if (token == null || token.isEmpty) return _set(PushStatus.failed);
    final old = await hub.store.read(info.pushId);
    final String handle, secret;
    try {
      (handle, secret) = await hub.relay.createHandle(
        info.server,
        pushId: info.pushId,
        platform: client.platform,
        fcmToken: token,
      );
    } on Exception {
      if (!gone()) _set(PushStatus.failed);
      return;
    }
    final entry = PushEntry(
      pushId: info.pushId,
      relay: info.server,
      handle: handle,
      handleSecret: secret,
      key: old?.key ?? hub.newKey(),
      url: serverUrl,
      name: serverName(),
    );
    // Stored before the server can seal anything for it.
    await hub.store.write(entry);
    if (old != null && (old.handle != handle || old.relay != info.server)) {
      try {
        await hub.relay.deleteHandle(
          old.relay,
          old.handle,
          handleSecret: old.handleSecret,
        );
      } catch (_) {}
    }
    if (gone()) return;
    try {
      await account.api.registerDevice(client.platform, handle, entry.key);
    } on ApiException catch (e) {
      if (gone()) return;
      return _set(
        e.code == 'push_disabled' ? PushStatus.off : PushStatus.failed,
      );
    }
    if (gone()) return;
    _set(PushStatus.registered);
  }

  /// Removes this phone from the account and the push server. Call before the
  /// session ends; a failure must not stop the sign-out.
  Future<void> unregister() async {
    _stop();
    PushEntry? entry;
    try {
      entry = await hub.store.forUrl(serverUrl);
      if (entry == null) {
        final info = (await features()).push;
        if (info != null) entry = await hub.store.read(info.pushId);
      }
    } catch (_) {}
    if (entry != null) await hub._remove(entry, account.api);
  }

  void _stop() {
    _generation++;
    if (status != PushStatus.notSetUp) _set(PushStatus.off);
  }

  @override
  void dispose() {
    _disposed = true;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
