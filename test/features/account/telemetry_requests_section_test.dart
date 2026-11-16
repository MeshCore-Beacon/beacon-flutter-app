import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/account/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'harness.dart';

final now = DateTime.now().millisecondsSinceEpoch;

Map<String, dynamic> request(
  String id, {
  String status = 'active',
  String reason = '',
  bool hasPassword = true,
  String name = 'Hilltop',
  String? nodeId = 'n1',
  bool poller = true,
  String? state,
  bool reading = true,
}) => {
  'id': id,
  'node': {'id': nodeId, 'publicKey': 'ab' * 32, 'name': name},
  'status': status,
  'statusReason': reason,
  'hasPassword': hasPassword,
  'createdAt': now,
  'updatedAt': now,
  'poller': poller
      ? {'observerId': 'o1', 'name': 'HOWL V4.2', 'state': ?state}
      : null,
  'latestReadingAt': reading ? now - 3600000 : null,
};

Finder inner(Finder f) =>
    find.descendant(of: f, matching: find.byType(TextField));

void main() {
  setUp(loadAssets);

  late List<Map<String, dynamic>> stored;
  late bool featureOn;
  late List<String> opened;
  Harness? current;

  Harness make({Map<String, http.Response Function(http.Request)>? extra}) {
    final h = Harness((r) {
      final path = r.url.path.replaceFirst('/api/v1', '');
      final key = '${r.method} $path';
      final custom = extra?[key];
      if (custom != null) return custom(r);
      if (key == 'GET /me/telemetry-requests') {
        return json(200, {'limit': 3, 'requests': stored});
      }
      if (key == 'GET /me/sessions') return json(200, {'sessions': []});
      if (r.method == 'PATCH' || r.method == 'DELETE') return json(200, {});
      return json(404, {});
    });
    current = h;
    return h;
  }

  Future<void> open(WidgetTester tester, Harness h) async {
    tester.view.physicalSize = const Size(600, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ApiClient(
      Uri.parse(server),
      transientRetries: 0,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'features': {
              'accounts': 'on',
              'polling': true,
              'telemetryRequests': featureOn,
            },
          }),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: ProfileScreen(
          account: h.account,
          api: api,
          onOpen: (kind, id) => opened.add('$kind:$id'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    stored = [];
    featureOn = true;
    opened = [];
  });

  Future<void> press(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  testWidgets('an active row says what its poller reports', (tester) async {
    stored = [request('r1', state: 'no_reply')];
    await open(tester, make());
    expect(
      find.text('HOWL V4.2 is asking, but the repeater is not answering.'),
      findsOneWidget,
    );
    expect(find.text('Being polled'), findsNothing);
    expect(find.text('Polled by HOWL V4.2'), findsNothing);
  });

  testWidgets('shows each request with its status, reason, poller and age', (
    tester,
  ) async {
    stored = [
      request('r1', reason: 'Heard by 2 observers'),
      request(
        'r2',
        status: 'waiting',
        name: 'Ridge',
        hasPassword: false,
        poller: false,
        reading: false,
      ),
    ];
    await open(tester, make());
    expect(find.text('TELEMETRY REQUESTS'), findsOneWidget);
    expect(find.text('2 of 3'), findsOneWidget);
    expect(find.text('Hilltop'), findsOneWidget);
    expect(find.text('Being polled'), findsOneWidget);
    expect(find.text('Heard by 2 observers'), findsOneWidget);
    expect(find.text('Polled by HOWL V4.2'), findsOneWidget);
    expect(find.textContaining('Last reading'), findsOneWidget);
    expect(find.text('Guest password set'), findsOneWidget);
    expect(find.text('Ridge'), findsOneWidget);
    expect(
      find.text('Waiting for an observer that can reach it'),
      findsOneWidget,
    );
    expect(find.text('No guest password'), findsOneWidget);
    expect(find.text('No readings yet'), findsOneWidget);
  });

  testWidgets('hidden when the feature is off, and nothing is requested', (
    tester,
  ) async {
    featureOn = false;
    stored = [request('r1')];
    final h = make();
    await open(tester, h);
    expect(find.text('TELEMETRY REQUESTS'), findsNothing);
    expect(h.calls('GET', '/me/telemetry-requests'), isEmpty);
  });

  testWidgets('empty list says how to start', (tester) async {
    await open(tester, make());
    expect(find.text('0 of 3'), findsOneWidget);
    expect(
      find.text(
        'No requests yet. Open a repeater and choose Request telemetry.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping the repeater name opens it', (tester) async {
    stored = [request('r1')];
    await open(tester, make());
    await press(tester, 'request-open-r1');
    expect(opened, ['node:n1']);
  });

  testWidgets('a repeater the server could not resolve does not open', (
    tester,
  ) async {
    stored = [request('r1', nodeId: null)];
    await open(tester, make());
    await press(tester, 'request-open-r1');
    expect(opened, isEmpty);
  });

  testWidgets('change password sends it, then clears the field', (
    tester,
  ) async {
    stored = [request('r1')];
    final h = make();
    await open(tester, h);
    await press(tester, 'request-pw-r1');
    await tester.enterText(
      find.byKey(const ValueKey('request-pw-field-r1')),
      'newpw',
    );
    await press(tester, 'request-pw-save-r1');
    expect(
      jsonDecode(h.calls('PATCH', '/me/telemetry-requests/r1').single.body),
      {'password': 'newpw'},
    );
    expect(find.byKey(const ValueKey('request-pw-field-r1')), findsNothing);
    // The list is read again after the change.
    expect(h.calls('GET', '/me/telemetry-requests').length, 2);
  });

  testWidgets('an empty value removes the password', (tester) async {
    stored = [request('r1')];
    final h = make();
    await open(tester, h);
    await press(tester, 'request-pw-r1');
    await press(tester, 'request-pw-save-r1');
    expect(
      jsonDecode(h.calls('PATCH', '/me/telemetry-requests/r1').single.body),
      {'password': null},
    );
  });

  testWidgets('the password field is obscured, capped and not autofilled', (
    tester,
  ) async {
    stored = [request('r1')];
    await open(tester, make());
    await press(tester, 'request-pw-r1');
    final field = find.byKey(const ValueKey('request-pw-field-r1'));
    await tester.enterText(field, 'x' * 20);
    final input = tester.widget<TextField>(inner(field));
    expect(input.controller!.text.length, 15);
    expect(input.obscureText, true);
    expect(input.autofillHints, isNull);
  });

  testWidgets('a refused password change shows the mapped reason', (
    tester,
  ) async {
    stored = [request('r1')];
    final h = make(
      extra: {
        'PATCH /me/telemetry-requests/r1': (_) =>
            failure(422, 'password_invalid', 'raw'),
      },
    );
    await open(tester, h);
    await press(tester, 'request-pw-r1');
    await tester.enterText(
      find.byKey(const ValueKey('request-pw-field-r1')),
      'abc',
    );
    await press(tester, 'request-pw-save-r1');
    expect(
      find.text('The guest password must be 1 to 15 characters.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'an admin-stopped request offers only a new password and delete',
    (tester) async {
      stored = [request('r1', status: 'admin_stopped')];
      await open(tester, make());
      expect(
        find.text(
          'The password you entered was an admin password. Beacon deleted it. '
          'Only a guest password will start it again.',
        ),
        findsOneWidget,
      );
      expect(find.text('Enter a new password'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('request-pw-r1')),
          matching: find.text('Change password'),
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('request-enable-r1')), findsNothing);
      expect(find.byKey(const ValueKey('request-remove-r1')), findsOneWidget);
    },
  );

  testWidgets('a failed login offers a new password and delete, no enable', (
    tester,
  ) async {
    stored = [request('r1', status: 'login_failed')];
    await open(tester, make());
    expect(find.text('Enter a new password'), findsOneWidget);
    expect(find.byKey(const ValueKey('request-enable-r1')), findsNothing);
    expect(find.byKey(const ValueKey('request-remove-r1')), findsOneWidget);
  });

  testWidgets('an admin-stopped request cannot save an empty password', (
    tester,
  ) async {
    stored = [request('r1', status: 'admin_stopped')];
    final h = make();
    await open(tester, h);
    await press(tester, 'request-pw-r1');
    expect(find.textContaining('empty removes'), findsNothing);
    final save = find.byKey(const ValueKey('request-pw-save-r1'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('request-pw-field-r1')),
      'guest1',
    );
    await tester.pump();
    await press(tester, 'request-pw-save-r1');
    expect(
      jsonDecode(h.calls('PATCH', '/me/telemetry-requests/r1').single.body),
      {'password': 'guest1'},
    );
  });

  testWidgets('a refused password on a stopped request has its own message', (
    tester,
  ) async {
    stored = [request('r1', status: 'admin_stopped')];
    final h = make(
      extra: {
        'PATCH /me/telemetry-requests/r1': (_) =>
            failure(422, 'password_invalid', 'raw'),
      },
    );
    await open(tester, h);
    await press(tester, 'request-pw-r1');
    await tester.enterText(
      find.byKey(const ValueKey('request-pw-field-r1')),
      'abc',
    );
    await tester.pump();
    await press(tester, 'request-pw-save-r1');
    expect(
      find.text(
        'This request needs a guest password of 1 to 15 characters. '
        'It cannot be restarted with a blank login.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('re-enable shows only for a paused request', (tester) async {
    stored = [request('r1'), request('r2', status: 'disabled')];
    final h = make();
    await open(tester, h);
    expect(find.byKey(const ValueKey('request-enable-r1')), findsNothing);
    await press(tester, 'request-enable-r2');
    expect(
      jsonDecode(h.calls('PATCH', '/me/telemetry-requests/r2').single.body),
      {'enabled': true},
    );
  });

  testWidgets('remove asks inline first, then deletes', (tester) async {
    stored = [request('r1')];
    final h = make();
    await open(tester, h);
    await press(tester, 'request-remove-r1');
    expect(find.text('Remove this request?'), findsOneWidget);
    expect(h.calls('DELETE', '/me/telemetry-requests/r1'), isEmpty);
    await press(tester, 'request-remove-cancel-r1');
    expect(find.text('Remove this request?'), findsNothing);
    await press(tester, 'request-remove-r1');
    await press(tester, 'request-remove-confirm-r1');
    expect(h.calls('DELETE', '/me/telemetry-requests/r1').length, 1);
  });

  testWidgets('a failed load offers a retry', (tester) async {
    final h = make(extra: {'GET /me/telemetry-requests': (_) => json(500, {})});
    await open(tester, h);
    expect(find.text('Could not load your requests.'), findsOneWidget);
    expect(current, isNotNull);
  });
}
