import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/json.dart';
import 'package:beacon/core/push.dart';
import 'package:beacon/core/push_relay.dart';
import 'package:beacon/core/push_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakePush implements PushClient {
  FakePush({
    this.isAvailable = true,
    this.state = PushPermission.notAsked,
    this.deviceToken = 'tok-1',
    this.platform = 'android',
    this.environment,
  });
  @override
  String platform;
  String? environment;
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
  Future<String?> apnsEnvironment() async => environment;
  @override
  Stream<Json> get opened => taps.stream;
  @override
  Future<Json?> initialMessage() async => initial;
}

/// A hub on [push] whose push server answers every call and records it.
PushHub fakeHub(
  FakePush push, {
  PushStore? store,
  List<http.Request>? relaySeen,
}) {
  var handles = 0;
  return PushHub(
    client: push,
    store: store ?? MemoryPushStore(),
    relay: PushRelay(
      client: MockClient((r) async {
        relaySeen?.add(r);
        if (r.method != 'POST') return http.Response('', 204);
        handles++;
        return http.Response(
          jsonEncode({'handle': 'h_$handles', 'handleSecret': 's_$handles'}),
          201,
        );
      }),
    ),
  );
}
