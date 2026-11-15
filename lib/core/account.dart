import 'package:flutter/foundation.dart';

import 'api.dart';
import 'auth_api.dart';
import 'json.dart';
import 'push.dart';

/// The signed-in user for one server. Built per active server, like LiveConnection.
class AccountState extends ChangeNotifier {
  AccountState(this.api) {
    api.onSignedOut = _signedOut;
  }
  final AuthApi api;
  Json? user;
  bool get signedIn => user != null;

  /// Bumped whenever the signed-in account changes or ends. A caller notes it
  /// before an await and drops the result if it moved.
  int epoch = 0;

  /// Keeps this phone's push token registered; removed on [signOut].
  PushRegistration? push;
  bool _disposed = false;

  /// A call still in flight when its screen closes must not notify.
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _signedOut() {
    if (user == null || _disposed) return;
    epoch++;
    user = null;
    notifyListeners();
  }

  /// Takes a fresh user from a profile call.
  void adopt(Json? next) {
    if (_disposed) return;
    if (user?['id'] != next?['id'] || signedIn != (next != null)) epoch++;
    user = next;
    notifyListeners();
  }

  /// A network error keeps what we know; only the server saying so signs out.
  Future<void> refresh() async {
    final started = epoch;
    try {
      final next = await api.me();
      // A sign-in or sign-out finished while this was reading; it wins.
      if (epoch == started) adopt(next);
    } on ApiException {
      // Keep the current user until the server answers.
    }
  }

  Future<void> signIn(String code, String verifier) async {
    try {
      final result = await api.exchangeAppCode(code, verifier);
      adopt(object(result['user']));
    } on SignInSuperseded {
      // A newer sign-in or a sign-out owns the account now.
    }
  }

  Future<void> signOut() async {
    // The token must go while the session still authorizes the call.
    await push?.unregister();
    await api.signOut();
  }
}

/// The live [AccountState] of each server whose home screen is open, so the
/// sign-in flow can reach the one that is active.
class AccountRegistry {
  final _states = <String, AccountState>{};
  AccountState? operator [](String serverUrl) => _states[serverUrl];
  void register(String serverUrl, AccountState state) =>
      _states[serverUrl] = state;
  void unregister(String serverUrl, AccountState state) {
    if (identical(_states[serverUrl], state)) _states.remove(serverUrl);
  }
}
