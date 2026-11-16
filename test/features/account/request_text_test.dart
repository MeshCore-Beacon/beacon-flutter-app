import 'package:beacon/core/api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/account/alert_rules.dart';
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

  Map<String, dynamic> polled(
    String? state, {
    String status = 'active',
    bool stateAt = false,
  }) => {
    'status': status,
    'poller': {
      'observerId': 'o1',
      'name': 'HOWL',
      'state': ?state,
      if (stateAt) 'stateAt': 1700000000000,
    },
  };

  test('an active request says what its poller reports', () {
    const expected = {
      'ok': 'Being polled by HOWL',
      'pending': 'Assigned to HOWL. First poll is on its way.',
      'not_direct': 'Assigned to HOWL, which cannot hear this repeater directly right now.',
      'no_reply': 'HOWL is asking, but the repeater is not answering.',
      'not_claimed': 'Assigned to HOWL. Waiting for it to pick this up.',
      'login_failed': 'HOWL reported a password problem. Checking.',
      'admin_stop': 'HOWL reported a password problem. Checking.',
    };
    expected.forEach((state, text) {
      expect(requestLineText(polled(state)), text, reason: state);
    });
  });

  test('every poller state has words in fr and sv too', () {
    for (final lang in ['fr', 'sv']) {
      language = lang;
      for (final s in [
        'ok',
        'pending',
        'not_direct',
        'no_reply',
        'not_claimed',
        'login_failed',
      ]) {
        final text = requestLineText(polled(s));
        expect(text, contains('HOWL'), reason: '$lang $s');
        expect(text, isNot(startsWith('pollerState.')), reason: '$lang $s');
        expect(text, isNot(contains('{{')), reason: '$lang $s');
      }
    }
  });

  test('a missing or unknown state keeps today\'s text', () {
    expect(requestLineText(polled(null)), 'Being polled');
    expect(requestLineText(polled('brand_new')), 'Being polled');
    expect(
      requestLineText({'status': 'active', 'poller': null}),
      'Being polled',
    );
    expect(requestLineText({'status': 'active'}), 'Being polled');
  });

  test('a state only counts while the request is active', () {
    expect(
      requestLineText(polled('no_reply', status: 'waiting')),
      'Waiting for an observer that can reach it',
    );
  });

  test('the dot is green for ok and amber for the waiting states', () {
    final c = BeaconTheme.all.first.data.extension<BeaconColors>()!;
    for (final s in ['ok', null, 'brand_new']) {
      expect(requestDotColor(polled(s), c), c.success, reason: '$s');
    }
    for (final s in [
      'pending',
      'not_direct',
      'no_reply',
      'not_claimed',
      'login_failed',
      'admin_stop',
    ]) {
      expect(requestDotColor(polled(s), c), c.warning, reason: s);
    }
    expect(requestDotColor(polled('ok', status: 'waiting'), c), c.warning);
    expect(requestDotColor(polled('ok', status: 'login_failed'), c), c.danger);
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

  // statusReasonCode as beacon-server sends it (reason-codes.md), with its
  // English sentence and the days an offline reason carries.
  const reasonCodes = [
    ('no_observer', 'No observer can reach this repeater yet.', null),
    (
      'no_seat',
      'Every observer that can reach this repeater is already polling its maximum.',
      null,
    ),
    (
      'login_failed',
      'The repeater did not accept this guest password. Enter a new one.',
      null,
    ),
    (
      'blank_login_failed',
      'The repeater did not accept a blank or hello login. Enter a guest password.',
      null,
    ),
    (
      'admin_stopped',
      'The repeater gave admin access to this password, so Beacon deleted it. Enter a guest password, never an admin one.',
      null,
    ),
    (
      'blank_blocked',
      'This repeater gives admin access to a blank login, so Beacon will not poll it without a guest password.',
      null,
    ),
    ('offline', 'Not heard by any observer for 7 days.', 7),
  ];

  Map<String, dynamic> request(String code, String sentence, [int? days]) => {
    'statusReasonCode': code,
    'statusReason': sentence,
    'statusReasonDays': ?days,
  };

  test('every reason code has words in each language, read from the code', () {
    for (final lang in supportedLanguages) {
      for (final (code, sentence, days) in reasonCodes) {
        language = 'en';
        final english = requestReasonText(request(code, 'x', days));
        language = lang;
        // The sentence is deliberately wrong: only the code may decide.
        final text = requestReasonText(request(code, 'x', days));
        expect(text, isNot(startsWith('serverText.')), reason: '$lang $code');
        expect(text, isNot('x'), reason: '$lang $code');
        if (lang == 'en') {
          expect(text, sentence);
        } else {
          expect(text, isNot(english), reason: '$lang $code');
        }
      }
    }
  });

  test('the offline reason carries its days, one day included', () {
    expect(
      requestReasonText(request('offline', '', 1)),
      'Not heard by any observer for 1 day.',
    );
    expect(requestReasonText(request('offline', '', 30)), contains('30 days'));
  });

  test(
    'no code, an unknown code, other, or offline without days show the text',
    () {
      expect(
        requestReasonText({
          'statusReason': 'No observer can reach this repeater yet.',
        }),
        'No observer can reach this repeater yet.',
      );
      expect(
        requestReasonText(request('future_code', 'Something new.')),
        'Something new.',
      );
      expect(requestReasonText(request('other', 'Odd text.')), 'Odd text.');
      expect(
        requestReasonText(request('offline', 'Not heard for ages.')),
        'Not heard for ages.',
      );
      expect(requestReasonText(request('', '')), '');
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
  // unavailableCodes as beacon-server sends them (alerts.md), with the kind
  // that carries each and its English sentence.
  const unavailableCodes = [
    (
      'observer_no_data',
      'battery_low',
      'This observer does not report a battery level.',
    ),
    ('repeaters_only', 'rebooted', 'Only repeaters report its uptime.'),
    (
      'not_polled',
      'temperature',
      'Beacon is not polling this repeater. Request telemetry for it first.',
    ),
    ('no_data', 'noise_high', 'This repeater does not report a noise floor.'),
    ('observer_no_clock', 'clock', 'Observers have no clock drift value.'),
    (
      'clock_repeaters_only',
      'clock',
      'Only repeaters and room servers report their clock.',
    ),
    (
      'needs_gone_quiet',
      'back_online',
      'Turn on the gone-quiet alert for this radio first.',
    ),
    (
      'not_applicable',
      'observer_offline',
      'This alert does not apply to this radio.',
    ),
  ];

  test('every alert reason code has words in each language', () {
    for (final lang in supportedLanguages) {
      for (final (code, kind, sentence) in unavailableCodes) {
        language = 'en';
        final english = alertReasonText(kind, code, 'x');
        language = lang;
        // The sentence is deliberately wrong: only the code may decide.
        final text = alertReasonText(kind, code, 'x');
        expect(text, isNot(startsWith('serverText.')), reason: '$lang $code');
        expect(text, isNot('x'), reason: '$lang $code');
        if (lang == 'en') {
          expect(text, sentence);
        } else {
          expect(text, isNot(english), reason: '$lang $code');
        }
      }
    }
  });

  test('an alert reason falls back to the sentence', () {
    expect(alertReasonText('clock', 'brand_new', 'As sent.'), 'As sent.');
    expect(alertReasonText('clock', null, 'As sent.'), 'As sent.');
    expect(alertReasonText('clock', '', 'As sent.'), 'As sent.');
    // A data code for a kind with no value name also falls back.
    expect(alertReasonText('clock', 'no_data', 'As sent.'), 'As sent.');
  });

  test('a kind_unavailable error is read from the reasonCode in its body', () {
    ApiException error(String? reasonCode) => ApiException(
      'Sentence.',
      status: 422,
      code: 'kind_unavailable',
      body: {
        'error': {
          'code': 'kind_unavailable',
          'message': 'Sentence.',
          'reasonCode': ?reasonCode,
        },
      },
    );
    expect(
      alertError(error('needs_gone_quiet'), 'back_online'),
      'Turn on the gone-quiet alert for this radio first.',
    );
    expect(alertError(error(null), 'back_online'), 'Sentence.');
  });
}
