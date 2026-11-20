import 'package:flutter/foundation.dart';

import 'account.dart';
import 'json.dart';

/// The signed-in user's `/me/alerts` answer. One copy per account, so Profile
/// and every Atlas card read the same load.
class AlertsState extends ChangeNotifier {
  AlertsState(this.account) : _epoch = account.epoch {
    account.addListener(_accountChanged);
  }
  final AccountState account;

  /// The last answer; kept while a later load fails.
  Json? data;
  Object? error;
  bool loading = false;

  int _epoch;
  bool _again = false, _disposed = false;
  Future<void>? _job;

  List<Json> get targets => rows(data?['targets']);

  /// Empty from a server older than the channel switches.
  Json get channels => object(data?['channels']);

  /// Fetches again. A call made while one is running queues one more, so a
  /// reload after a save never returns the answer from before it.
  Future<void> load() {
    if (_disposed || !account.signedIn) return Future.value();
    final running = _job;
    if (running != null) {
      _again = true;
      return running;
    }
    return _job = _run().whenComplete(() => _job = null);
  }

  /// Drops the error first, so the caller shows loading and not the old failure.
  Future<void> retry() {
    error = null;
    _notify();
    return load();
  }

  /// The server's answer to a channel change.
  void setChannels(Json next) {
    data = {...?data, 'channels': next};
    _notify();
  }

  Future<void> _run() async {
    loading = true;
    do {
      _again = false;
      final epoch = account.epoch;
      try {
        final next = await account.api.alerts();
        if (_disposed) return;
        if (account.epoch == epoch) {
          data = next;
          error = null;
        }
      } catch (e) {
        if (_disposed) return;
        if (account.epoch == epoch) error = e;
      }
    } while (_again && account.signedIn);
    loading = false;
    _notify();
  }

  // Another user's rules must never show under this account.
  void _accountChanged() {
    if (account.epoch == _epoch) return;
    _epoch = account.epoch;
    data = null;
    error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
