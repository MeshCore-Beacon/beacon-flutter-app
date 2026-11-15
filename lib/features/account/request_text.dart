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
    }
  }
  return accountError(error);
}
