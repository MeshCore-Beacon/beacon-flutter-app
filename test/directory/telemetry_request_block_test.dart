import 'dart:convert';

import 'package:beacon/core/account.dart';
import 'package:beacon/core/api.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/core/token_store.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'folds.dart';

const base = 'https://test.invalid';
const notice =
    'The guest password is shared with volunteer observers so they can ask this repeater for its stats. Never enter an admin password.';

http.Response ok(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response fail(int status, String code) => ok({
  'error': {'code': code, 'message': 'raw'},
}, status);

Map<String, dynamic> existing(String status, {String? nodeId = 'node-1'}) => {
  'id': 'r1',
  'node': {'id': nodeId, 'publicKey': 'pk', 'name': 'Hill'},
  'status': status,
  'statusReason': '',
  'hasPassword': false,
  'createdAt': 1,
  'updatedAt': 1,
  'poller': null,
  'latestReadingAt': null,
};

Finder inner(Finder f) =>
    find.descendant(of: f, matching: find.byType(TextField));

/// The text of the info tip whose message contains [part].
String tipWith(WidgetTester tester, String part) => tester
    .widgetList<Tooltip>(find.byType(Tooltip))
    .map((t) => t.message ?? '')
    .firstWhere((m) => m.contains(part));

void main() {
  setUp(() async {
    await Future.wait([BeaconTheme.load(), loadStrings()]);
    language = 'en';
  });

  late List<Map<String, dynamic>> requests;
  late int limit;
  late http.Response Function(http.Request)? onPost;
  late List<http.Request> sent;
  late AccountState shown;

  Future<void> pump(
    WidgetTester tester, {
    bool signedIn = true,
    bool feature = true,
    String type = 'repeater',
    bool readings = false,
    AccountState? account,
  }) async {
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tokens = MemoryTokenStore();
    await tokens.write(base, 'tok');
    final authApi = AuthApi(
      base,
      tokens,
      client: MockClient((r) async {
        sent.add(r);
        if (r.method == 'POST') {
          return onPost?.call(r) ?? ok({'id': 'new'}, 201);
        }
        if (r.url.path.endsWith('/me/telemetry-requests')) {
          return ok({'limit': limit, 'requests': requests});
        }
        return ok({});
      }),
    );
    final state = account ?? AccountState(authApi);
    shown = state;
    if (signedIn) state.adopt({'id': 'u1', 'username': 'ridge'});
    final api = ApiClient(
      Uri.parse(base),
      transientRetries: 0,
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/info')) {
          return ok({
            'features': {
              'polling': true,
              'accounts': 'on',
              'telemetryRequests': feature,
            },
          });
        }
        if (path.endsWith('/telemetry')) {
          return ok({
            'polled': readings,
            'points': readings
                ? [
                    {
                      't': DateTime.now().millisecondsSinceEpoch,
                      'batteryMv': 4000,
                    },
                  ]
                : [],
          });
        }
        if (path.endsWith('/polling')) {
          return ok({'polled': readings, 'poller': null, 'standbys': []});
        }
        return ok(
          path.endsWith('/observations')
              ? {'items': [], 'hasMore': false}
              : path.endsWith('/neighbors')
              ? []
              : {'id': 'node-1', 'publicKey': 'pk', 'nodeTypeName': type},
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: EntityDetailScreen(
          kind: 'node',
          id: 'node-1',
          api: api,
          account: state,
          region: const {},
          onOpen: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openFolds(tester);
  }

  setUp(() {
    requests = [];
    limit = 3;
    onPost = null;
    sent = [];
  });

  Finder field() => find.byKey(const ValueKey('request-password'));

  testWidgets(
    'a typed guest password does not carry over to the next account',
    (tester) async {
      await pump(tester);
      final account = shown;
      await tester.enterText(field(), 'A-secret');
      account.adopt(null);
      await tester.pumpAndSettle();
      account.adopt({'id': 'u2', 'username': 'valley'});
      await tester.pumpAndSettle();
      await openFolds(tester);
      expect(
        tester.widget<TextField>(inner(field())).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets('a repeater with no readings gets the block on its own', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('TELEMETRY'), findsNothing);
    expect(find.text('REQUEST TELEMETRY'), findsOneWidget);
    expect(find.text(notice), findsNothing);
    expect(
      tipWith(tester, notice),
      contains('volunteer observers that can hear'),
    );
    expect(find.text('Guest password only, never admin.'), findsOneWidget);
    expect(find.text('0 of 3 used'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Request telemetry'),
      findsOneWidget,
    );
  });

  testWidgets('with readings the block sits inside the Telemetry section', (
    tester,
  ) async {
    await pump(tester, readings: true);
    expect(find.text('TELEMETRY'), findsOneWidget);
    expect(find.text('REQUEST TELEMETRY'), findsNothing);
    expect(find.text('Request telemetry'), findsWidgets);
    expect(tipWith(tester, notice), isNotEmpty);
  });

  testWidgets('a room server also gets it', (tester) async {
    await pump(tester, type: 'room server');
    expect(tipWith(tester, notice), isNotEmpty);
  });

  testWidgets(
    'nothing for a companion, a signed-out user or a server without it',
    (tester) async {
      await pump(tester, type: 'companion');
      expect(find.text(notice), findsNothing);
      await pump(tester, signedIn: false);
      expect(find.text(notice), findsNothing);
      await pump(tester, feature: false);
      expect(find.text(notice), findsNothing);
      expect(
        sent.where((r) => r.url.path.contains('telemetry-requests')),
        isEmpty,
      );
    },
  );

  testWidgets('the guest password field is obscured, capped, not autofilled', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(field(), 'y' * 20);
    final input = tester.widget<TextField>(inner(field()));
    expect(input.controller!.text.length, 15);
    expect(input.obscureText, true);
    expect(input.autofillHints, isNull);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(tester.widget<TextField>(inner(field())).obscureText, false);
  });

  testWidgets('submitting sends the node and password, then clears the field', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(field(), 'guest1');
    onPost = (_) {
      requests = [existing('waiting')];
      return ok({'id': 'r1'}, 201);
    };
    await tester.tap(find.widgetWithText(FilledButton, 'Request telemetry'));
    await tester.pumpAndSettle();
    final post = sent.firstWhere((r) => r.method == 'POST');
    expect(jsonDecode(post.body), {'nodeId': 'node-1', 'password': 'guest1'});
    // Never in a URL.
    expect(sent.any((r) => r.url.toString().contains('guest1')), isFalse);
    expect(field(), findsNothing);
    expect(
      find.text('Waiting for an observer that can reach it'),
      findsOneWidget,
    );
    expect(find.text('Manage in profile'), findsOneWidget);
  });

  testWidgets('with no password only the node is sent', (tester) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Request telemetry'));
    await tester.pumpAndSettle();
    expect(jsonDecode(sent.firstWhere((r) => r.method == 'POST').body), {
      'nodeId': 'node-1',
    });
  });

  testWidgets('a refusal shows its reason and keeps the form', (tester) async {
    await pump(tester);
    onPost = (_) => fail(409, 'no_password_blocked');
    await tester.tap(find.widgetWithText(FilledButton, 'Request telemetry'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This repeater gives admin access without a password, so it cannot be polled this way',
      ),
      findsOneWidget,
    );
    expect(field(), findsOneWidget);
  });

  testWidgets('already requested shows its status and a profile button', (
    tester,
  ) async {
    requests = [existing('active')];
    await pump(tester);
    expect(find.text('Being polled'), findsOneWidget);
    expect(field(), findsNothing);
    expect(find.text(notice), findsNothing);
    await tester.tap(find.text('Manage in profile'));
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);
  });

  testWidgets('the request block says what the poller reports', (tester) async {
    requests = [
      {
        ...existing('active'),
        'poller': {
          'observerId': 'o1',
          'name': 'HOWL',
          'state': 'not_direct',
          'stateAt': 1700000000000,
        },
      },
    ];
    await pump(tester);
    expect(
      find.text(
        'Assigned to HOWL, which cannot hear this repeater directly right now.',
      ),
      findsOneWidget,
    );
    expect(find.text('Being polled'), findsNothing);
  });

  testWidgets('a request matches the repeater by key when its id is missing', (
    tester,
  ) async {
    requests = [existing('login_failed', nodeId: null)];
    await pump(tester);
    expect(find.text('The repeater refused the password'), findsOneWidget);
  });

  testWidgets('at the limit the button is off and says so', (tester) async {
    limit = 1;
    requests = [
      {
        ...existing('active'),
        'id': 'r9',
        'node': {'id': 'other', 'publicKey': 'zz', 'name': 'Elsewhere'},
      },
    ];
    await pump(tester);
    expect(find.text('1 of 1 used'), findsOneWidget);
    expect(find.textContaining('used all your requests'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Request telemetry'),
    );
    expect(button.onPressed, isNull);
  });
}
