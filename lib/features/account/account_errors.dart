import '../../core/api.dart';
import '../../core/strings.dart';

/// The line shown under a failed account action, by the server's error code.
String accountError(Object error) {
  if (error is! ApiException) return trKey('account.errors.generic');
  if (error.status == null) return trKey('account.errors.network');
  switch (error.code) {
    case 'invalid_credentials':
      return trKey('account.errors.invalidCredentials');
    // The server's message says which rule the password broke.
    case 'weak_password':
      return error.message;
    case 'invalid_input':
      return trKey('account.errors.invalidInput');
    case 'service_unavailable':
      return trKey('serverText.errors.busy');
    case 'read_only':
      return trKey('serverText.errors.readOnly');
    case 'rate_limited':
    case 'too_many_attempts':
      return _retry(error.code!, error.retryAfter);
  }
  return trKey('account.errors.generic');
}

String _retry(String code, Duration? wait) {
  final head = trKey(
    code == 'rate_limited'
        ? 'account.errors.rateLimited'
        : 'account.errors.tooManyAttempts',
  );
  if (wait == null) return head;
  final seconds = wait.inSeconds < 1 ? 1 : wait.inSeconds;
  final when = seconds < 90
      ? trKey('account.errors.seconds', count: seconds)
      : trKey('account.errors.minutes', count: (seconds / 60).ceil());
  return '$head ${trKey('account.errors.retryIn').replaceAll('{{time}}', when)}';
}
