import 'dart:async';

import 'package:beacon/core/json.dart';
import 'package:beacon/core/push.dart';

class FakePush implements PushClient {
  FakePush({
    this.isAvailable = true,
    this.state = PushPermission.notAsked,
    this.deviceToken = 'tok-1',
  });
  bool isAvailable;
  PushPermission state;
  String? deviceToken;
  PushPermission afterRequest = PushPermission.granted;
  final calls = <String>[];
  final refresh = StreamController<String>.broadcast();
  final taps = StreamController<Json>.broadcast();
  Json? initial;
  Future<void> close() async {
    await refresh.close();
    await taps.close();
  }

  @override
  String get platform => 'android';
  @override
  Future<bool> available() async {
    calls.add('available');
    return isAvailable;
  }

  @override
  Future<PushPermission> permission() async {
    calls.add('permission');
    return state;
  }

  @override
  Future<PushPermission> requestPermission() async {
    calls.add('request');
    return state = afterRequest;
  }

  @override
  Future<String?> token() async {
    calls.add('token');
    return deviceToken;
  }

  @override
  Stream<String> get tokenRefreshes => refresh.stream;
  @override
  Future<void> deleteToken() async => calls.add('deleteToken');
  @override
  Stream<Json> get opened => taps.stream;
  @override
  Future<Json?> initialMessage() async => initial;
}
