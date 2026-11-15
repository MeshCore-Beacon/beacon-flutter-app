import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import 'account_errors.dart';

/// A request's status in words; a status this build does not know shows as sent.
String requestStatusText(String status) {
  const known = {
    'waiting',
    'active',
    'login_failed',
    'admin_stopped',
    'disabled',
  };
  return known.contains(status)
      ? trKey('telemetryRequests.status.$status')
      : status;
}

// beacon-server's statusReasonCode, by the catalog key that carries each.
const _reasonKeys = {
  'no_observer': 'noObserver',
  'no_seat': 'noSeat',
  'login_failed': 'loginFailed',
  'blank_login_failed': 'blankFailed',
  'admin_stopped': 'adminStopped',
  'blank_blocked': 'blankBlocked',
};

/// A request's reason in the user's language, read from its statusReasonCode
/// (and statusReasonDays for offline). No code (an older server) or one this
/// build does not know shows statusReason as sent.
String requestReasonText(Json request) {
  final code = textOf(request['statusReasonCode']);
  final key = _reasonKeys[code];
  if (key != null) return trKey('serverText.requestReason.$key');
  final days = request['statusReasonDays'];
  if (code == 'offline' && days is int && days >= 0) {
    return trKey('serverText.requestReason.offline', count: days);
  }
  return textOf(request['statusReason']);
}

/// The line under a failed request action, by the server's error code.
String requestError(Object error) {
  if (error is ApiException && error.status != null) {
    switch (error.code) {
      case 'request_limit':
      case 'already_requested':
      case 'not_a_repeater':
      case 'password_invalid':
      case 'no_password_blocked':
      case 'requests_disabled':
        return trKey('telemetryRequests.errors.${error.code}');
      case 'not_found':
        return trKey('serverText.errors.requestNotFound');
    }
  }
  return accountError(error);
}
