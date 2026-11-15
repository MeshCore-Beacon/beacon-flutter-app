import 'package:flutter/foundation.dart';

import 'api.dart';
import 'auth_api.dart';
import 'json.dart';

/// The signed-in user for one server. Built per active server, like LiveConnection.
class AccountState extends ChangeNotifier {
  AccountState(this.api) {
    api.onSignedOut = _signedOut;
  }
  final AuthApi api;
  Json? user;
  bool get signedIn => user != null;
  bool _disposed = false;

  /// A call still in flight when its screen closes must not notify.
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _signedOut() {
    if (user == null || _disposed) return;
    user = null;
    notifyListeners();
  }

  /// Takes a fresh user from a profile call.
  void adopt(Json? next) {
    if (_disposed) return;
    user = next;
    notifyListeners();
  }

  /// A network error keeps what we know; only the server saying so signs out.
  Future<void> refresh() async {
    try {
      adopt(await api.me());
    } on ApiException {
      // Keep the current user until the server answers.
    }
  }

  Future<void> signIn(String code, String verifier) async {
    final result = await api.exchangeAppCode(code, verifier);
    adopt(object(result['user']));
  }

  Future<void> signOut() => api.signOut();
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
