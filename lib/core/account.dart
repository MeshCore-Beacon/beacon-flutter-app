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

  void _signedOut() {
    if (user == null) return;
    user = null;
    notifyListeners();
  }

  /// Takes a fresh user from a profile call.
  void adopt(Json? next) {
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
