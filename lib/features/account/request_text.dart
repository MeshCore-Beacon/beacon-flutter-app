import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
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

// poller.state values that mean the observer is not yet reading the repeater,
// mapped to the catalog key that words each.
const _pollerKeys = {
  'ok': 'ok',
  'pending': 'pending',
  'not_direct': 'notDirect',
  'no_reply': 'noReply',
  'not_claimed': 'notClaimed',
  'login_failed': 'passwordProblem',
  'admin_stop': 'passwordProblem',
};

String? _pollerKey(Json request) {
  if (request['status'] != 'active') return null;
  return _pollerKeys[textOf(object(request['poller'])['state'])];
}

/// A request's status line. While active it says what the assigned observer
/// reports; no poller state (an older server) or an unknown one shows the
/// plain status.
String requestLineText(Json request) {
  final key = _pollerKey(request);
  if (key == null) return requestStatusText(textOf(request['status']));
  final name = textOf(object(request['poller'])['name'], '?');
  return trKey('pollerState.$key').replaceAll('{{name}}', name);
}

/// Whether [requestLineText] already names the poller.
bool requestLineNamesPoller(Json request) => _pollerKey(request) != null;

/// The status dot: green only when polling works, amber while waiting.
Color requestDotColor(Json request, BeaconColors colors) {
  final status = textOf(request['status']);
  if (status == 'active') {
    final key = _pollerKey(request);
    return key == null || key == 'ok' ? colors.success : colors.warning;
  }
  if (status == 'login_failed' || status == 'admin_stopped') {
    return colors.danger;
  }
  return colors.warning;
}
