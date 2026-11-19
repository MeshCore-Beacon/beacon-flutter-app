import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/push.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/account/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../fake_push.dart';
import 'harness.dart';

const full = [
  'gone_quiet',
  'back_online',
  'clock',
  'battery_low',
  'battery_falling',
  'rebooted',
  'temperature',
  'noise_high',
];

Map<String, dynamic> rule(
  String kind, {
  int? threshold,
  int? high,
  bool enabled = true,
  String state = 'ok',
}) => {
  'id': 'r-$kind',
  'kind': kind,
  'threshold': threshold,
  'thresholdHigh': high,
  'enabled': enabled,
  'state': state,
  'stateChangedAt': 1794700000000,
  'lastSentAt': null,
};

Map<String, dynamic> target({
  String name = 'Hilltop',
  String key = 'aabb',
  String kind = 'node',
  String? id = '11111111-1111-1111-1111-111111111111',
  bool polled = true,
  List<String> available = full,
  Map<String, String> unavailable = const {},
  Map<String, String> unavailableCodes = const {},
  List<Map<String, dynamic>> rules = const [],
}) => {
  'id': id,
  'kind': kind,
  'publicKey': key,
  'name': name,
  'polled': polled,
  'available': available,
  'unavailable': unavailable,
  'unavailableCodes': unavailableCodes,
  'rules': rules,
};

Finder k(String id) => find.byKey(ValueKey(id));

void main() {
  setUp(loadAssets);

  late Map<String, dynamic> data;
  late List<http.Request> puts;
  late http.Response Function(http.Request)? putAnswer;
  late List<Map<String, dynamic>> channelPuts;
  late http.Response? Function(http.Request)? channelAnswer;

  Map<String, dynamic> channels({
    bool emailAvailable = true,
    bool emailOn = true,
    String reason = '',
    bool pushAvailable = false,
    bool pushOn = true,
    bool hasDevice = false,
  }) => {
    'email': {
      'available': emailAvailable,
      'enabled': emailOn,
      'reason': reason,
    },
    'push': {
      'available': pushAvailable,
      'enabled': pushOn,
      'hasDevice': hasDevice,
    },
  };

  Future<Harness> open(
    WidgetTester tester, {
    bool alerts = true,
    bool email = true,
    bool pushChannel = false,
    FakePush? push,
    bool collapsed = false,
    String unit = 'c',
  }) async {
    tester.view.physicalSize = const Size(600, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = Harness((r) {
      final key = '${r.method} ${r.url.path.replaceFirst('/api/v1', '')}';
      if (key == 'GET /me/sessions') return json(200, {'sessions': []});
      if (key == 'GET /me/alerts') return json(200, data);
      if (key == 'PUT /me/alerts/channels') {
        channelPuts.add(jsonDecode(r.body) as Map<String, dynamic>);
        final answer = channelAnswer?.call(r);
        if (answer != null) return answer;
        final next = {
          for (final MapEntry(:key, :value)
              in (data['channels'] as Map).entries)
            key as String: {...value as Map},
        };
        for (final MapEntry(:key, :value) in channelPuts.last.entries) {
          next[key]!['enabled'] = value;
        }
        data['channels'] = next;
        return json(200, next);
      }
      if (key == 'PUT /me/alerts/rules') {
        puts.add(r);
        return putAnswer?.call(r) ?? json(200, rule('x'));
      }
      return json(404, {});
    });
    final api = ApiClient(
      Uri.parse(server),
      transientRetries: 0,
      client: MockClient(
        (_) async => json(200, {
          'features': {
            'accounts': 'local',
            'alerts': alerts,
            'alertChannels': {'email': email, 'push': pushChannel},
            if (pushChannel)
              'push': {'server': 'https://push.example', 'pushId': 'inst_a'},
          },
          'display': {'temperatureUnit': unit},
        }),
      ),
    );
    if (push != null) {
      h.account.push = PushRegistration(
        hub: fakeHub(push),
        account: h.account,
        features: api.features,
        serverUrl: server,
        serverName: () => 'Ottawa Mesh',
      );
      addTearDown(h.account.push!.dispose);
      await h.account.push!.refresh();
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: ProfileScreen(
          account: h.account,
          api: api,
          serverName: 'Ottawa Mesh',
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (!collapsed) {
      for (final tile in find.byType(ExpansionTile).evaluate().toList()) {
        await tester.tap(
          find.descendant(
            of: find.byWidget(tile.widget),
            matching: find.byType(ListTile),
          ),
        );
        await tester.pumpAndSettle();
      }
    }
    return h;
  }

  setUp(() {
    puts = [];
    putAnswer = null;
    channelPuts = [];
    channelAnswer = null;
    data = {
      'channels': channels(),
      'targets': [
        target(),
        target(
          name: 'Ridge',
          key: 'ccdd',
          id: null,
          polled: false,
          available: ['gone_quiet', 'back_online'],
          unavailable: {
            'temperature': 'This repeater does not report a temperature.',
          },
          unavailableCodes: {'temperature': 'no_data'},
        ),
      ],
    };
  });

  Map<String, dynamic> body(int i) =>
      jsonDecode(puts[i].body) as Map<String, dynamic>;
  Future<void> tap(WidgetTester tester, String id) async {
    await tester.ensureVisible(k(id));
    await tester.tap(k(id));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, String id, String text) async {
    await tester.ensureVisible(k(id));
    await tester.tap(k(id));
    await tester.pumpAndSettle();
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String id, String text) async {
    await tester.ensureVisible(k(id));
    await tester.enterText(k(id), text);
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  group('collapsed radios', () {
    Finder head(String key) => find.descendant(
      of: k('alert-tile-$key'),
      matching: find.byType(ListTile),
    );
    Future<void> flip(WidgetTester tester, String key) async {
      await tester.ensureVisible(head(key));
      await tester.tap(head(key));
      await tester.pumpAndSettle();
    }

    testWidgets('start collapsed with no switches, even for one radio', (
      tester,
    ) async {
      data['targets'] = [target()];
      await open(tester, collapsed: true);
      expect(
        find.descendant(
          of: find.byType(ExpansionTile),
          matching: find.byType(Switch),
        ),
        findsNothing,
      );
      expect(find.text('Hilltop'), findsOneWidget);
      expect(find.textContaining('always told'), findsOneWidget);
      expect(find.text('Alerts are sent to a@example.org'), findsOneWidget);
    });

    testWidgets('summarise none, one, several and firing', (tester) async {
      data['targets'] = [
        target(name: 'None', key: 'n1'),
        target(
          name: 'One',
          key: 'o1',
          rules: [rule('gone_quiet', threshold: 24)],
        ),
        target(
          name: 'Many',
          key: 'm1',
          rules: [
            rule('gone_quiet', threshold: 24),
            rule('battery_low', threshold: 3500),
            rule('rebooted', enabled: false),
          ],
        ),
        target(
          name: 'Fire',
          key: 'f1',
          rules: [
            rule('battery_low', threshold: 3500, state: 'firing'),
            rule('rebooted'),
          ],
        ),
        target(
          name: 'Fires',
          key: 'f2',
          rules: [
            rule('battery_low', threshold: 3500, state: 'firing'),
            rule('rebooted', state: 'firing'),
          ],
        ),
      ];
      await open(tester, collapsed: true);
      expect(find.text('No alerts on'), findsOneWidget);
      expect(find.text('1 alert on'), findsOneWidget);
      expect(find.text('2 alerts on'), findsOneWidget);
      expect(
        find.textContaining('Alerting: Battery low · 2 alerts on'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Alerting: 2 alerts · 2 alerts on'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ExpansionTile),
          matching: find.byType(Switch),
        ),
        findsNothing,
      );
    });

    testWidgets(
      'open to the rows, several at once, with an accessible tap size',
      (tester) async {
        await open(tester, collapsed: true);
        expect(tester.getSize(head('aabb')).height, greaterThanOrEqualTo(48));
        await flip(tester, 'aabb');
        await flip(tester, 'ccdd');
        expect(k('alert-switch-aabb-gone_quiet'), findsOneWidget);
        expect(k('alert-switch-ccdd-gone_quiet'), findsOneWidget);
        await flip(tester, 'aabb');
        expect(k('alert-switch-aabb-gone_quiet'), findsNothing);
        expect(k('alert-switch-ccdd-gone_quiet'), findsOneWidget);
      },
    );

    testWidgets(
      'an unsaved threshold survives collapse and expand, no refetch',
      (tester) async {
        data['targets'] = [
          target(rules: [rule('noise_high', threshold: -90)]),
        ];
        final h = await open(tester, collapsed: true);
        await flip(tester, 'aabb');
        await tester.enterText(k('alert-input-aabb-noise_high'), '-77');
        await tester.pump();
        await flip(tester, 'aabb');
        await flip(tester, 'aabb');
        expect(find.text('-77'), findsOneWidget);
        expect(h.calls('GET', '/me/alerts'), hasLength(1));
        expect(puts, isEmpty);
      },
    );

    testWidgets('a toggle updates the summary once collapsed', (tester) async {
      await open(tester, collapsed: true);
      await flip(tester, 'ccdd');
      data['targets'] = [
        target(),
        target(
          name: 'Ridge',
          key: 'ccdd',
          id: null,
          polled: false,
          available: ['gone_quiet', 'back_online'],
          rules: [rule('gone_quiet', threshold: 24)],
        ),
      ];
      await tap(tester, 'alert-switch-ccdd-gone_quiet');
      await flip(tester, 'ccdd');
      expect(find.text('1 alert on'), findsOneWidget);
      expect(k('alert-switch-ccdd-gone_quiet'), findsNothing);
    });
  });

  testWidgets('is absent and fetches nothing when the feature is off', (
    tester,
  ) async {
    final h = await open(tester, alerts: false);
    expect(find.text('Alerts'), findsNothing);
    expect(h.calls('GET', '/me/alerts'), isEmpty);
  });

  Finder switchOf(String id) =>
      find.descendant(of: k(id), matching: find.byType(Switch));
  bool on(WidgetTester tester, String id) =>
      tester.widget<Switch>(switchOf(id)).value;
  bool live(WidgetTester tester, String id) =>
      tester.widget<Switch>(switchOf(id)).onChanged != null;

  testWidgets('only one channel change can be sent while a save is pending', (
    tester,
  ) async {
    data['channels'] = channels(pushAvailable: true, pushOn: false);
    final h = await open(tester, pushChannel: true);
    final save = Completer<http.Response>();
    h.hold = (r) => r.method == 'PUT' ? save.future : null;
    final pushSwitch = tester.widget<Switch>(switchOf('channel-push'));
    await tester.tap(switchOf('channel-email'));
    pushSwitch.onChanged!(true);
    await tester.pump();
    expect(h.calls('PUT', '/me/alerts/channels'), hasLength(1));
    expect(live(tester, 'channel-email'), isFalse);
    expect(live(tester, 'channel-push'), isFalse);
    save.complete(
      json(200, channels(emailOn: false, pushAvailable: true, pushOn: false)),
    );
    await tester.pumpAndSettle();
    expect(on(tester, 'channel-email'), isFalse);
    expect(live(tester, 'channel-push'), isTrue);
  });

  testWidgets('push stays busy until device registration completes', (
    tester,
  ) async {
    data['channels'] = channels(pushAvailable: true, pushOn: false);
    final h = await open(tester, pushChannel: true, push: FakePush());
    final registration = Completer<http.Response>();
    h.hold = (r) => r.method == 'POST' && r.url.path.endsWith('/me/devices')
        ? registration.future
        : null;
    await tester.tap(switchOf('channel-push'));
    await tester.pumpAndSettle();
    expect(h.calls('POST', '/me/devices'), hasLength(1));
    expect(on(tester, 'channel-push'), isTrue);
    expect(live(tester, 'channel-push'), isFalse);
    expect(live(tester, 'channel-email'), isFalse);
    registration.complete(http.Response('', 204));
    await tester.pumpAndSettle();
    expect(live(tester, 'channel-push'), isTrue);
    expect(on(tester, 'channel-push'), isTrue);
  });

  testWidgets('email on names the address; push off without a push server', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('HOW ALERTS REACH YOU'), findsOneWidget);
    expect(on(tester, 'channel-email'), isTrue);
    expect(live(tester, 'channel-email'), isTrue);
    expect(find.text('Alerts are sent to a@example.org'), findsOneWidget);
    expect(live(tester, 'channel-push'), isFalse);
    expect(
      find.text("This server doesn't send push notifications."),
      findsOneWidget,
    );
  });

  for (final (reason, text) in [
    ('server_off', "This server doesn't send alert emails."),
    (
      'portal_account',
      'Accounts that sign in through the portal have no email address here.',
    ),
    ('unverified_email', 'Confirm your email address to get alert emails.'),
  ]) {
    testWidgets('email unavailable for $reason says why', (tester) async {
      data['channels'] = channels(emailAvailable: false, reason: reason);
      await open(tester);
      expect(live(tester, 'channel-email'), isFalse);
      expect(find.text(text), findsOneWidget);
      expect(find.text('Alerts are sent to a@example.org'), findsNothing);
    });
  }

  testWidgets('turning email off is sent at once and kept', (tester) async {
    data['channels'] = channels(pushAvailable: true);
    await open(tester, pushChannel: true);
    await tester.tap(switchOf('channel-email'));
    await tester.pump();
    expect(on(tester, 'channel-email'), isFalse);
    await tester.pumpAndSettle();
    expect(channelPuts, [
      {'email': false},
    ]);
    expect(on(tester, 'channel-email'), isFalse);
  });

  testWidgets('a failed change rolls the switch back and says so', (
    tester,
  ) async {
    channelAnswer = (_) => json(500, {
      'error': {'code': 'internal', 'message': 'x'},
    });
    await open(tester);
    await tester.tap(switchOf('channel-email'));
    await tester.pumpAndSettle();
    expect(on(tester, 'channel-email'), isTrue);
    expect(find.text('Could not change this. Try again.'), findsOneWidget);
  });

  testWidgets('push names the push server and what it sees', (tester) async {
    data['channels'] = channels(pushAvailable: true);
    await open(
      tester,
      pushChannel: true,
      push: FakePush(state: PushPermission.granted),
    );
    expect(on(tester, 'channel-push'), isTrue);
    expect(
      find.text(
        'Alerts from Ottawa Mesh are delivered via the MeshCore Beacon push '
        'server. It sees which server sent them, not what they say.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('push without Firebase configuration says it is not set up', (
    tester,
  ) async {
    data['channels'] = channels(pushAvailable: true);
    final push = FakePush(isAvailable: false);
    await open(tester, pushChannel: true, push: push);
    expect(
      find.text('Push notifications are not set up in this build.'),
      findsOneWidget,
    );
    expect(k('alerts-enable-push'), findsNothing);
  });

  testWidgets('turning push on asks for permission, then registers', (
    tester,
  ) async {
    data['channels'] = channels(pushAvailable: true, pushOn: false);
    final push = FakePush();
    final h = await open(tester, pushChannel: true, push: push);
    expect(push.calls, isNot(contains('request')));
    expect(on(tester, 'channel-push'), isFalse);
    await tester.tap(switchOf('channel-push'));
    await tester.pumpAndSettle();
    expect(channelPuts, [
      {'push': true},
    ]);
    expect(push.calls, contains('request'));
    expect(h.calls('POST', '/me/devices'), hasLength(1));
    expect(on(tester, 'channel-push'), isTrue);
    expect(k('alerts-enable-push'), findsNothing);
  });

  testWidgets('push on without permission offers the button', (tester) async {
    data['channels'] = channels(pushAvailable: true);
    final push = FakePush();
    final h = await open(tester, pushChannel: true, push: push);
    expect(k('alerts-enable-push'), findsOneWidget);
    await tap(tester, 'alerts-enable-push');
    expect(push.calls, contains('request'));
    expect(h.calls('POST', '/me/devices'), hasLength(1));
    expect(k('alerts-enable-push'), findsNothing);
  });

  testWidgets('refused permission points to the phone settings', (
    tester,
  ) async {
    data['channels'] = channels(pushAvailable: true, pushOn: false);
    final push = FakePush()..afterRequest = PushPermission.denied;
    await open(tester, pushChannel: true, push: push);
    await tester.tap(switchOf('channel-push'));
    await tester.pumpAndSettle();
    expect(find.textContaining('turned off for Beacon'), findsOneWidget);
  });

  testWidgets('turning push off is sent and registers nothing', (tester) async {
    data['channels'] = channels(pushAvailable: true);
    final push = FakePush(state: PushPermission.granted);
    final h = await open(tester, pushChannel: true, push: push);
    final before = h.calls('POST', '/me/devices').length;
    await tester.tap(switchOf('channel-push'));
    await tester.pumpAndSettle();
    expect(channelPuts, [
      {'push': false},
    ]);
    expect(h.calls('POST', '/me/devices'), hasLength(before));
    expect(
      find.textContaining('delivered via the MeshCore Beacon push server'),
      findsOneWidget,
    );
  });

  testWidgets('both off with rules on warns that nothing arrives', (
    tester,
  ) async {
    const warning =
        "Email and push are both off, so your alerts won't reach you.";
    data['channels'] = channels(emailOn: false);
    (data['targets'] as List)[0] = target(rules: [rule('battery_low')]);
    await open(tester);
    expect(find.text(warning), findsOneWidget);
    await tester.tap(switchOf('channel-email'));
    await tester.pumpAndSettle();
    expect(find.text(warning), findsNothing);
  });

  testWidgets('both off without rules does not warn', (tester) async {
    data['channels'] = channels(emailOn: false);
    await open(tester);
    expect(find.textContaining('both off'), findsNothing);
  });

  testWidgets('the empty Atlas line', (tester) async {
    data = {'channels': channels(), 'targets': []};
    await open(tester);
    expect(find.textContaining('set on radios in your Atlas'), findsOneWidget);
  });

  testWidgets('one block per target, rows in table order, closing sentence', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Hilltop'), findsOneWidget);
    expect(find.text('Ridge'), findsOneWidget);
    double y(String id) => tester.getTopLeft(k(id)).dy;
    final order = [
      'gone_quiet',
      'back_online',
      'battery_low',
      'battery_falling',
      'rebooted',
      'temperature',
      'noise_high',
      'clock',
    ];
    final ys = [for (final kind in order) y('alert-aabb-$kind')];
    expect([...ys]..sort(), ys);
    expect(
      find.textContaining(
        'always told when one of your telemetry requests needs attention',
      ),
      findsOneWidget,
    );
  });

  testWidgets('unavailable kinds are dimmed with the server reason', (
    tester,
  ) async {
    await open(tester);
    expect(
      find.text('This repeater does not report a temperature.'),
      findsOneWidget,
    );
    final opacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('This repeater does not report a temperature.'),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacity.opacity, lessThan(1));
    expect(k('alert-switch-ccdd-temperature'), findsNothing);
  });

  testWidgets('a reason is read from its code, else the server sentence', (
    tester,
  ) async {
    data['targets'] = [
      target(
        key: 'eeff',
        available: ['gone_quiet'],
        unavailable: {
          'clock': 'Server sentence one.',
          'noise_high': 'Server sentence two.',
          'battery_low': 'Server sentence three.',
        },
        unavailableCodes: {
          'clock': 'brand_new_code',
          'noise_high': 'not_polled',
        },
      ),
    ];
    await open(tester);
    expect(find.text('Server sentence one.'), findsOneWidget);
    expect(
      find.text(
        'Beacon is not polling this repeater. Request telemetry for it first.',
      ),
      findsOneWidget,
    );
    expect(find.text('Server sentence three.'), findsOneWidget);
    expect(find.text('Server sentence two.'), findsNothing);
  });

  testWidgets('rule states read in words and only for enabled rules', (
    tester,
  ) async {
    data['targets'] = [
      target(
        rules: [
          rule('gone_quiet', threshold: 24),
          rule('battery_low', threshold: 3500, state: 'firing'),
          rule('noise_high', threshold: -90, state: 'inactive'),
          rule('clock', threshold: 3600, state: 'unknown'),
          rule('rebooted', enabled: false),
        ],
      ),
    ];
    await open(tester);
    expect(find.text('OK'), findsOneWidget);
    expect(find.textContaining('Alerting since'), findsOneWidget);
    expect(find.text('No data right now'), findsOneWidget);
    expect(find.text('Not checked yet'), findsOneWidget);
  });

  group('gone quiet hours', () {
    Future<List<int?>> options(WidgetTester tester, String id) async {
      final menu = tester.widget<DropdownButton<int>>(k(id));
      return menu.items!.map((i) => i.value).toList();
    }

    testWidgets('3 and 6 for a target that reports telemetry', (tester) async {
      await open(tester);
      expect(await options(tester, 'alert-input-aabb-gone_quiet'), [
        3,
        6,
        12,
        24,
        48,
      ]);
    });

    testWidgets('3 and 6 for a polled repeater that lists no telemetry kind', (
      tester,
    ) async {
      data['targets'] = [
        target(available: ['gone_quiet', 'clock']),
      ];
      await open(tester);
      expect(await options(tester, 'alert-input-aabb-gone_quiet'), [
        3,
        6,
        12,
        24,
        48,
      ]);
    });

    testWidgets('only 12, 24 and 48 when not polled, whatever it lists', (
      tester,
    ) async {
      data['targets'] = [target(polled: false)];
      await open(tester);
      expect(await options(tester, 'alert-input-aabb-gone_quiet'), [
        12,
        24,
        48,
      ]);
    });

    testWidgets('3 and 6 for an observer', (tester) async {
      data['targets'] = [
        target(kind: 'observer', available: ['gone_quiet']),
      ];
      await open(tester);
      expect(await options(tester, 'alert-input-aabb-gone_quiet'), [
        3,
        6,
        12,
        24,
        48,
      ]);
    });

    testWidgets('only 12, 24 and 48 otherwise', (tester) async {
      await open(tester);
      expect(await options(tester, 'alert-input-ccdd-gone_quiet'), [
        12,
        24,
        48,
      ]);
    });
  });

  group('turning rules on and off', () {
    testWidgets('on sends the shown value, then the list is read again', (
      tester,
    ) async {
      final h = await open(tester);
      await pick(tester, 'alert-input-aabb-gone_quiet', '48 hours');
      expect(puts, isEmpty);
      await tap(tester, 'alert-switch-aabb-gone_quiet');
      expect(body(0), {
        'target': {'kind': 'node', 'publicKey': 'aabb'},
        'kind': 'gone_quiet',
        'threshold': 48,
        'thresholdHigh': null,
        'enabled': true,
      });
      expect(h.calls('GET', '/me/alerts'), hasLength(2));
    });

    testWidgets('off sends enabled false with the stored values', (
      tester,
    ) async {
      data['targets'] = [
        target(rules: [rule('rebooted')]),
      ];
      await open(tester);
      await tap(tester, 'alert-switch-aabb-rebooted');
      expect(body(0)['enabled'], false);
      expect(body(0)['threshold'], isNull);
    });

    testWidgets('battery_low shows volts and sends millivolts', (tester) async {
      data['targets'] = [
        target(rules: [rule('battery_low', threshold: 3500, enabled: false)]),
      ];
      await open(tester);
      expect(
        tester
            .widget<TextField>(k('alert-input-aabb-battery_low'))
            .controller!
            .text,
        '3.50',
      );
      await type(tester, 'alert-input-aabb-battery_low', '3.65');
      await tap(tester, 'alert-switch-aabb-battery_low');
      expect(body(0)['threshold'], 3650);
      expect(body(0)['enabled'], true);
    });

    testWidgets('battery volts outside 2.50 to 5.00 are refused inline', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'alert-input-aabb-battery_low', '2.4');
      await tap(tester, 'alert-switch-aabb-battery_low');
      expect(find.textContaining('2.50 and 5.00'), findsOneWidget);
      expect(puts, isEmpty);
    });

    testWidgets('selects send their own units', (tester) async {
      data['targets'] = [
        target(
          kind: 'observer',
          available: ['battery_falling', 'clock', 'observer_offline'],
        ),
      ];
      await open(tester);
      await pick(tester, 'alert-input-aabb-battery_falling', '0.3 V per day');
      await tap(tester, 'alert-switch-aabb-battery_falling');
      expect(body(0)['threshold'], 300);
      await pick(tester, 'alert-input-aabb-clock', '1 day');
      await tap(tester, 'alert-switch-aabb-clock');
      expect(body(1)['threshold'], 86400);
      await pick(tester, 'alert-input-aabb-observer_offline', '3 hours');
      await tap(tester, 'alert-switch-aabb-observer_offline');
      expect(body(2)['threshold'], 180);
    });

    testWidgets('temperature outside -50 to 150 degrees is refused', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'alert-input-aabb-temperature-high', '150.5');
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(find.textContaining('between -50 and 150'), findsOneWidget);
      await type(tester, 'alert-input-aabb-temperature-high', '');
      await type(tester, 'alert-input-aabb-temperature-low', '-50.1');
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(find.textContaining('between -50 and 150'), findsOneWidget);
      expect(puts, isEmpty);
    });

    testWidgets('temperature limits under 2 degrees apart are refused', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'alert-input-aabb-temperature-low', '10');
      await type(tester, 'alert-input-aabb-temperature-high', '11.9');
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(
        find.text(
          'The high limit must be at least 2.0 degrees above the low limit.',
        ),
        findsOneWidget,
      );
      expect(puts, isEmpty);
      await type(tester, 'alert-input-aabb-temperature-high', '12');
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(body(0)['threshold'], 100);
      expect(body(0)['thresholdHigh'], 120);
    });

    testWidgets('an f instance shows and sends whole degrees F', (
      tester,
    ) async {
      data['targets'] = [
        target(
          rules: [
            rule('temperature', threshold: 100, high: 350, enabled: false),
          ],
        ),
      ];
      await open(tester, unit: 'f');
      expect(find.text('Low (°F)'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(k('alert-input-aabb-temperature-low'))
            .controller!
            .text,
        '50',
      );
      await type(tester, 'alert-input-aabb-temperature-low', '14');
      await type(tester, 'alert-input-aabb-temperature-high', '95');
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(body(0)['threshold'], -100);
      expect(body(0)['thresholdHigh'], 350);
      await type(tester, 'alert-input-aabb-temperature-high', '303');
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(
        find.textContaining('between -58 and 302 degrees F'),
        findsOneWidget,
      );
      await type(tester, 'alert-input-aabb-temperature-high', '17');
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(find.textContaining('at least 4 degrees'), findsOneWidget);
      await type(tester, 'alert-input-aabb-temperature-high', '95.5');
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(
        find.textContaining('whole number of degrees F, such as 95'),
        findsOneWidget,
      );
      expect(puts, hasLength(1));
    });

    // 355 tenths is 95.9 F and 412 is 106.2 F: both off the whole-F grid.
    List<Map<String, dynamic>> offGrid({bool enabled = true}) => [
      target(
        rules: [
          rule('temperature', threshold: 355, high: 412, enabled: enabled),
        ],
      ),
    ];

    testWidgets('an unedited f limit is not re-sent on blur', (tester) async {
      data['targets'] = offGrid();
      await open(tester, unit: 'f');
      await tester.tap(k('alert-input-aabb-temperature-low'));
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(puts, isEmpty);
    });

    testWidgets('toggling an f limit off and on keeps its exact tenths', (
      tester,
    ) async {
      data['targets'] = offGrid();
      await open(tester, unit: 'f');
      putAnswer = (_) {
        data['targets'] = offGrid(enabled: false);
        return json(200, rule('x'));
      };
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(body(0)['enabled'], false);
      putAnswer = null;
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(body(1)['enabled'], true);
      expect(body(1)['threshold'], 355);
      expect(body(1)['thresholdHigh'], 412);
    });

    testWidgets('editing only the high f limit keeps the low one exact', (
      tester,
    ) async {
      data['targets'] = offGrid();
      await open(tester, unit: 'f');
      await type(tester, 'alert-input-aabb-temperature-high', '100');
      await submit(tester);
      expect(puts, hasLength(1));
      expect(body(0)['threshold'], 355);
      expect(body(0)['thresholdHigh'], 378);
    });

    testWidgets('noise_high sends dBm and refuses out of range', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'alert-input-aabb-noise_high', '-20');
      await tap(tester, 'alert-switch-aabb-noise_high');
      expect(find.textContaining('-130 and -50'), findsOneWidget);
      expect(puts, isEmpty);
      await type(tester, 'alert-input-aabb-noise_high', '-95');
      await tap(tester, 'alert-switch-aabb-noise_high');
      expect(body(0)['threshold'], -95);
    });

    testWidgets('temperature needs one side and sends tenths', (tester) async {
      await open(tester);
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(find.textContaining('low or a high'), findsOneWidget);
      expect(puts, isEmpty);
      await type(tester, 'alert-input-aabb-temperature-high', '45.5');
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(body(0)['threshold'], isNull);
      expect(body(0)['thresholdHigh'], 455);
      await type(tester, 'alert-input-aabb-temperature-low', '-5');
      await type(tester, 'alert-input-aabb-temperature-high', '40.2');
      await tap(tester, 'alert-switch-aabb-temperature');
      expect(body(1)['threshold'], -50);
      expect(body(1)['thresholdHigh'], 402);
    });
  });

  group('editing an enabled rule', () {
    List<Map<String, dynamic>> noise() => [
      target(rules: [rule('noise_high', threshold: -90)]),
    ];

    testWidgets('a text value is sent on submit, once', (tester) async {
      data['targets'] = noise();
      await open(tester);
      await type(tester, 'alert-input-aabb-noise_high', '-85');
      expect(puts, isEmpty);
      await submit(tester);
      expect(puts, hasLength(1));
      expect(body(0)['threshold'], -85);
      expect(body(0)['enabled'], true);
    });

    testWidgets('an unchanged value sends nothing', (tester) async {
      data['targets'] = noise();
      await open(tester);
      await tester.ensureVisible(k('alert-input-aabb-noise_high'));
      await tester.tap(k('alert-input-aabb-noise_high'));
      await tester.pump();
      await submit(tester);
      expect(puts, isEmpty);
    });

    testWidgets('a changed select is sent at once', (tester) async {
      data['targets'] = [
        target(rules: [rule('gone_quiet', threshold: 24)]),
      ];
      await open(tester);
      await pick(tester, 'alert-input-aabb-gone_quiet', '12 hours');
      expect(body(0)['threshold'], 12);
      expect(body(0)['enabled'], true);
    });

    testWidgets('an out of range edit shows an error and sends nothing', (
      tester,
    ) async {
      data['targets'] = noise();
      await open(tester);
      await type(tester, 'alert-input-aabb-noise_high', '-20');
      await submit(tester);
      expect(find.textContaining('-130 and -50'), findsOneWidget);
      expect(puts, isEmpty);
    });
  });

  group('wording shared with the web', () {
    testWidgets('each row says what the alert is for', (tester) async {
      await open(tester);
      expect(
        find.descendant(
          of: k('alert-aabb-battery_low'),
          matching: find.text('When the battery stays below this voltage.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: k('alert-aabb-rebooted'),
          matching: find.text('When the radio restarts.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the observer offline choices read as durations', (
      tester,
    ) async {
      data['targets'] = [
        target(kind: 'observer', available: ['observer_offline']),
      ];
      await open(tester);
      await tester.ensureVisible(k('alert-input-aabb-observer_offline'));
      await tester.tap(k('alert-input-aabb-observer_offline'));
      await tester.pumpAndSettle();
      for (final text in ['30 minutes', '1 hour', '3 hours', '6 hours']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
    });
  });

  group('back online', () {
    testWidgets('is off with a hint until gone quiet is on', (tester) async {
      await open(tester);
      expect(
        tester.widget<Switch>(k('alert-switch-aabb-back_online')).onChanged,
        isNull,
      );
      expect(find.textContaining('Turn on Gone quiet first'), findsWidgets);
    });

    testWidgets('works with gone quiet on and sends no threshold', (
      tester,
    ) async {
      data['targets'] = [
        target(rules: [rule('gone_quiet', threshold: 24)]),
      ];
      await open(tester);
      await tap(tester, 'alert-switch-aabb-back_online');
      expect(body(0), {
        'target': {'kind': 'node', 'publicKey': 'aabb'},
        'kind': 'back_online',
        'threshold': null,
        'thresholdHigh': null,
        'enabled': true,
      });
    });

    testWidgets('stays off when the gone quiet rule is disabled', (
      tester,
    ) async {
      data['targets'] = [
        target(rules: [rule('gone_quiet', threshold: 24, enabled: false)]),
      ];
      await open(tester);
      expect(
        tester.widget<Switch>(k('alert-switch-aabb-back_online')).onChanged,
        isNull,
      );
    });
  });

  group('server errors show on their own row', () {
    const cases = <(String, int, String, String, String?)>[
      (
        'kind_unavailable',
        422,
        'This repeater does not report a temperature.',
        'does not report a temperature',
        null,
      ),
      (
        'kind_unavailable',
        422,
        'English sentence.',
        'Turn on the gone-quiet alert',
        'needs_gone_quiet',
      ),
      ('invalid_threshold', 422, 'bad', 'not an allowed value', null),
      ('not_on_atlas', 409, 'x', 'no longer in your Atlas', null),
      ('alerts_disabled', 404, 'x', 'turned off on this server', null),
      ('not_found', 404, 'No such rule.', 'no longer exists', null),
      ('app_session_required', 403, 'x', 'Only the Beacon app', null),
      ('invalid_input', 422, 'x', 'Check what you entered', null),
    ];
    for (final (code, status, message, text, reasonCode) in cases) {
      testWidgets('$code ${reasonCode ?? ''}', (tester) async {
        await open(tester);
        putAnswer = (_) =>
            failure(status, code, message, reasonCode: reasonCode);
        await tap(tester, 'alert-switch-aabb-rebooted');
        final row = find.descendant(
          of: k('alert-aabb-rebooted'),
          matching: find.textContaining(text),
        );
        expect(row, findsOneWidget);
        expect(
          find.descendant(
            of: k('alert-aabb-clock'),
            matching: find.textContaining(text),
          ),
          findsNothing,
        );
      });
    }
  });
}
