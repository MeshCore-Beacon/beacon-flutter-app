import 'dart:async';

import 'package:flutter/services.dart';

import 'json.dart';
import 'push.dart';

/// iOS push straight from APNs, over the `beacon/push` channel in
/// AppDelegate.swift. The Notification Service Extension decrypts each alert.
class ApnsPushClient implements PushClient {
  ApnsPushClient({MethodChannel? channel, Duration? tokenTimeout})
    : _channel = channel ?? const MethodChannel('beacon/push'),
      _tokenTimeout = tokenTimeout ?? const Duration(seconds: 35) {
    _channel.setMethodCallHandler(_fromNative);
  }
  final MethodChannel _channel;
  final Duration _tokenTimeout;
  final _refreshes = StreamController<String>.broadcast();
  final _taps = StreamController<Json>.broadcast();
  Future<bool>? _ready;

  Future<Object?> _fromNative(MethodCall call) async {
    switch (call.method) {
      case 'onToken':
        final token = call.arguments;
        if (token is String && token.isNotEmpty) _refreshes.add(token);
      case 'onOpened':
        _taps.add(object(call.arguments));
    }
    return null;
  }

  @override
  String get platform => 'ios';

  /// APNs needs no configuration file, so only a missing channel says no.
  @override
  Future<bool> available() => _ready ??= _probe();

  Future<bool> _probe() async {
    try {
      await _channel.invokeMethod<String>('permission');
      return true;
    } catch (_) {
      return false;
    }
  }

  static PushPermission _map(String? status) => switch (status) {
    'granted' => PushPermission.granted,
    'denied' => PushPermission.denied,
    _ => PushPermission.notAsked,
  };

  @override
  Future<PushPermission> permission() async =>
      _map(await _channel.invokeMethod<String>('permission'));

  @override
  Future<PushPermission> requestPermission() async =>
      _map(await _channel.invokeMethod<String>('requestPermission'));

  /// The device token as lowercase hex; null when APNs does not answer in time
  /// (the native side gives up after 30 s, this is a backstop).
  /// A registration failure throws a [PlatformException].
  @override
  Future<String?> token() => _channel
      .invokeMethod<String>('token')
      .timeout(_tokenTimeout, onTimeout: () => null);

  @override
  Stream<String> get tokenRefreshes => _refreshes.stream;

  @override
  Future<String?> apnsEnvironment() =>
      _channel.invokeMethod<String>('apnsEnvironment');

  @override
  Stream<Json> get opened => _taps.stream;

  @override
  Future<Json?> initialMessage() async {
    final data = await _channel.invokeMethod<Object?>('initialMessage');
    return data == null ? null : object(data);
  }
}
