import '../../core/api.dart';
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

// The sentences beacon-server's polling code puts in statusReason.
const _reasonKeys = {
  'No observer can reach this repeater yet.': 'noObserver',
  'Every observer that can reach this repeater is already polling its maximum.':
      'noSeat',
  'The repeater did not accept this guest password. Enter a new one.':
      'loginFailed',
  'The repeater did not accept a blank or hello login. Enter a guest password.':
      'blankFailed',
  'The repeater gave admin access to this password, so Beacon deleted it. Enter a guest password, never an admin one.':
      'adminStopped',
  'This repeater gives admin access to a blank login, so Beacon will not poll it without a guest password.':
      'blankBlocked',
};
final _offline = RegExp(r'^Not heard by any observer for (\d+) days?\.$');

/// A status reason in the user's language; one this build does not know shows as sent.
String requestReasonText(String reason) {
  final key = _reasonKeys[reason];
  if (key != null) return trKey('serverText.requestReason.$key');
  final days = _offline.firstMatch(reason)?.group(1);
  if (days != null) {
    return trKey('serverText.requestReason.offline', count: int.parse(days));
  }
  return reason;
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
