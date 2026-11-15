import 'package:beacon/core/api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/features/account/request_text.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUp(loadAssets);
  tearDown(() => language = 'en');

  test('every status has its words', () {
    expect(
      requestStatusText('waiting'),
      'Waiting for an observer that can reach it',
    );
    expect(requestStatusText('active'), 'Being polled');
    expect(
      requestStatusText('login_failed'),
      'The repeater refused the password',
    );
    expect(
      requestStatusText('admin_stopped'),
      'Stopped: that password gave admin access and was deleted',
    );
    expect(
      requestStatusText('disabled'),
      'Paused: the repeater has not been heard recently',
    );
  });

  test('an unknown status is shown as it came', () {
    expect(requestStatusText('mystery'), 'mystery');
  });

  test('each error code has its own line', () {
    String of(String code, int status) => requestError(
      ApiException('raw server text', status: status, code: code),
    );
    expect(of('request_limit', 409), 'You have used all your requests.');
    expect(
      of('already_requested', 409),
      'You already requested this repeater.',
    );
    expect(
      of('not_a_repeater', 422),
      'Only repeaters and room servers can be polled.',
    );
    expect(
      of('password_invalid', 422),
      'The guest password must be 1 to 15 characters.',
    );
    expect(
      of('no_password_blocked', 409),
      'This repeater gives admin access without a password, so it cannot be polled this way',
    );
    expect(
      of('requests_disabled', 404),
      'Telemetry requests are turned off on this server.',
    );
  });

  // Every statusReason beacon-server's polling code can emit.
  const serverReasons = [
    'No observer can reach this repeater yet.',
    'Every observer that can reach this repeater is already polling its maximum.',
    'The repeater did not accept this guest password. Enter a new one.',
    'The repeater did not accept a blank or hello login. Enter a guest password.',
    'The repeater gave admin access to this password, so Beacon deleted it. Enter a guest password, never an admin one.',
    'This repeater gives admin access to a blank login, so Beacon will not poll it without a guest password.',
    'Not heard by any observer for 7 days.',
  ];

  test('every server reason has words in each language', () {
    for (final code in supportedLanguages) {
      language = code;
      for (final reason in serverReasons) {
        final text = requestReasonText(reason);
        expect(text, isNot(startsWith('serverText.')), reason: '$code $reason');
        expect(text, isNotEmpty);
        if (code == 'en') {
          expect(text, reason);
        } else {
          expect(text, isNot(reason), reason: '$code $reason');
        }
      }
    }
  });

  test(
    'the offline reason carries its days, and an unknown one shows as sent',
    () {
      expect(
        requestReasonText('Not heard by any observer for 1 days.'),
        contains('1 day'),
      );
      expect(
        requestReasonText('Not heard by any observer for 30 days.'),
        contains('30'),
      );
      expect(requestReasonText('Something new.'), 'Something new.');
      expect(requestReasonText(''), '');
    },
  );

  test('busy, read-only and missing-request answers have their own line', () {
    for (final code in supportedLanguages) {
      language = code;
      final lines = {
        for (final c in ['service_unavailable', 'read_only', 'not_found'])
          requestError(
            ApiException('raw', status: c == 'not_found' ? 404 : 503, code: c),
          ),
      };
      expect(lines, hasLength(3), reason: code);
      expect(
        lines,
        isNot(contains(trKey('account.errors.generic'))),
        reason: code,
      );
      expect(lines.any((l) => l.startsWith('serverText.')), isFalse);
    }
  });

  test('other failures use the account wording', () {
    expect(
      requestError(const ApiException('x', status: 500, code: 'boom')),
      'Something went wrong. Try again.',
    );
    expect(
      requestError(const ApiException('offline')),
      'Could not reach the server. Check your connection.',
    );
  });

  test(
    'the shared-password notice reads the same meaning in all languages',
    () {
      expect(
        trKey('telemetryRequests.notice'),
        'The guest password is shared with volunteer observers so they can ask this repeater for its stats. Never enter an admin password.',
      );
      language = 'fr';
      expect(trKey('telemetryRequests.notice'), contains('administrateur'));
      language = 'sv';
      expect(
        trKey('telemetryRequests.notice'),
        contains('administratörslösenord'),
      );
    },
  );
}
