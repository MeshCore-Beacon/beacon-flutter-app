import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/json.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/account/profile_screen.dart';
import 'package:beacon/features/account/sign_in.dart';
import 'package:beacon/features/atlas/atlas.dart';
import 'package:beacon/features/atlas/atlas_alerts.dart';
import 'package:beacon/features/atlas/atlas_screen.dart';
import 'package:beacon/features/atlas/atlas_store.dart';
import 'package:beacon/features/atlas/atlas_sync.dart';
import 'package:beacon/features/atlas/atlas_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/account/harness.dart';

final quiet = 'aa' * 32, busy = 'bb' * 32, roof = 'cc' * 32;
const roofId = '44444444-4444-4444-8444-444444444444';

Map<String, dynamic> rule(
  String kind, {
  int? threshold,
  bool enabled = true,
  String state = 'ok',
}) => {
  'id': 'r-$kind',
  'kind': kind,
  'threshold': threshold,
  'thresholdHigh': null,
  'enabled': enabled,
  'state': state,
  'stateChangedAt': 1794700000000,
  'lastSentAt': null,
};

Map<String, dynamic> target(
  String key, {
  String kind = 'node',
  String? id,
  String name = 'Radio',
  List<Map<String, dynamic>> rules = const [],
}) => {
  'id': id,
  'kind': kind,
  'publicKey': key,
  'name': name,
  'polled': false,
  'available': ['gone_quiet', 'back_online'],
  'unavailable': {'battery_low': 'Not polled.'},
  'unavailableCodes': {'battery_low': 'not_polled'},
  'rules': rules,
};

Map<String, dynamic> serverNode(String key, String name) => {
  'kind': 'node',
  'publicKey': key,
  'id': null,
  'name': name,
};

const emailOn = {
  'email': {'available': true, 'enabled': true, 'reason': ''},
  'push': {'available': false, 'enabled': true, 'hasDevice': false},
};

class Rig {
  Rig(this.h, this.prefs, this.store);
  final Harness h;
  final Preferences prefs;
  final AtlasStore store;
}

/// What `/me/alerts` answers; a test swaps it before or between loads.
late Map<String, dynamic> alerts;
late List<Map<String, dynamic>> rulePuts;
bool exchangeFails = false;

/// Three pins on the account: two nodes and an observer.
/// Holds the first `/me/atlas` answer of a rig made with `hold`.
Completer<void>? atlasGate;

Future<Rig> rig({bool signedIn = true, String? name, bool hold = false}) async {
  atlasGate = hold ? Completer<void>() : null;
  var revision = 1;
  var nodes = [
    serverNode(quiet, name ?? 'Quiet'),
    serverNode(busy, 'Busy'),
    {
      'kind': 'observer',
      'observerPublicKey': roof,
      'observerId': roofId,
      'name': 'Roof',
    },
  ];
  SharedPreferences.setMockInitialValues({
    'beacon.servers': jsonEncode([
      {'name': 'Home mesh', 'url': server},
    ]),
    'beacon.active': server,
    'beacon.atlas.synced.$server.u1': true,
    // Signed out, the cards come from this phone.
    if (!signedIn)
      'beacon.atlas.$server': jsonEncode({
        'version': 2,
        'range': '24h',
        'pins': [
          {'kind': 'node', 'id': nilId, 'publicKey': quiet, 'name': 'Quiet'},
        ],
      }),
  });
  final prefs = await Preferences.load();
  rulePuts = [];
  final h = Harness((r) {
    final path = r.url.path.replaceFirst('/api/v1', '');
    // The store takes the account copy only once /info has answered.
    if (path == '/info') return json(200, {'features': <String, dynamic>{}});
    if (path == '/me/atlas') {
      if (r.method == 'PUT') {
        // The account keeps the pins the phone sent, in its order.
        final sent = [
          for (final pin in (jsonDecode(r.body) as Map)['pins'] as List)
            pin['publicKey'] ?? pin['observerId'],
        ];
        nodes = [
          for (final id in sent)
            nodes.firstWhere(
              (n) => n['publicKey'] == id || n['observerId'] == id,
            ),
        ];
        revision++;
      }
      return json(200, {'revision': revision, 'range': '24h', 'pins': nodes});
    }
    if (path == '/me/alerts' && r.method == 'GET') {
      // A copy, so an answer held by a test keeps what it read.
      return json(200, jsonDecode(jsonEncode(alerts)));
    }
    if (path == '/auth/app/token') {
      return exchangeFails
          ? failure(503, 'service_down', 'The server is having a bad day.')
          : json(200, {'token': 'tok', 'user': user()});
    }
    if (path == '/me/alerts/rules') {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      rulePuts.add(body);
      // The next read shows the rule the user just saved.
      final key = (body['target'] as Map)['publicKey'];
      for (final t in alerts['targets'] as List) {
        if (t['publicKey'] != key) continue;
        t['rules'] = [
          for (final r in t['rules'] as List)
            if (r['kind'] != body['kind']) r,
          rule(
            body['kind'] as String,
            threshold: body['threshold'] as int?,
            enabled: body['enabled'] as bool,
            state: 'unknown',
          ),
        ];
      }
      return json(200, rule(body['kind'] as String));
    }
    return json(404, {});
  }, signedIn: signedIn);
  if (hold) {
    h.hold = (r) => r.url.path.endsWith('/me/atlas') && !atlasGate!.isCompleted
        ? atlasGate!.future.then((_) => h.handler(r))
        : null;
  }
  return Rig(h, prefs, AtlasStore(prefs, server, account: h.account));
}

ApiClient api({bool alertsOn = true}) => ApiClient(
  Uri.parse(server),
  transientRetries: 0,
  client: MockClient((r) async {
    if (r.url.path.endsWith('/info')) {
      return json(200, {
        'features': {'accounts': 'local', 'alerts': alertsOn},
      });
    }
    return http.Response('{"error":{}}', 404);
  }),
);

Future<void> pump(
  WidgetTester tester,
  Rig r, {
  bool alertsOn = true,
  Size size = const Size(390, 844),
  SignInFlow? flow,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final app = MaterialApp(
    theme: BeaconTheme.all.first.data,
    home: Scaffold(
      body: AtlasScreen(
        api: api(alertsOn: alertsOn),
        preferences: r.prefs,
        store: r.store,
        onOpen: (_, _) {},
      ),
    ),
  );
  await tester.pumpWidget(
    flow == null ? app : SignInScope(flow: flow, child: app),
  );
  if (settle) await tester.pumpAndSettle();
}

/// Unmounts the page so its poll timers end with the test.
Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  expect(tester.takeException(), isNull);
}

Finder bell(String key) => find.byKey(ValueKey('atlas-bell-$key'));
AtlasIconButton button(WidgetTester tester, String key) =>
    tester.widget<AtlasIconButton>(bell(key));
bool filled(AtlasIconButton b) => (b.icon(Colors.black) as BellIcon).filled;
Finder k(String id) => find.byKey(ValueKey(id));

/// Switches the cards to their edit buttons: pin, drag and remove.
Future<void> edit(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('atlas-edit')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    await loadAssets();
    exchangeFails = false;
    alerts = {
      'channels': emailOn,
      'targets': [
        target(quiet, name: 'Quiet'),
        target(
          busy,
          name: 'Busy',
          rules: [
            rule('gone_quiet', threshold: 24),
            rule('back_online'),
            rule('battery_low', threshold: 3500, enabled: false),
          ],
        ),
        target(
          roof,
          kind: 'observer',
          id: roofId,
          name: 'Roof',
          rules: [
            rule('gone_quiet', threshold: 12, state: 'firing'),
            rule('back_online'),
          ],
        ),
      ],
    };
  });

  group('matching a pin to its target', () {
    final targets = [target(quiet), target(roof, kind: 'observer', id: roofId)];

    test('a node pin matches on its public key, whatever the case', () {
      final pin = AtlasPin.node(id: nilId, publicKey: quiet, name: '');
      final upper = [target(quiet.toUpperCase())];
      expect(alertTargetFor(pin, upper)?['publicKey'], quiet.toUpperCase());
      expect(
        alertTargetFor(
          AtlasPin.node(id: nilId, publicKey: busy, name: ''),
          targets,
        ),
        isNull,
      );
    });

    test('an observer pin matches the observer target with its id', () {
      const pin = AtlasPin.observer(observerId: roofId, name: '');
      expect(alertTargetFor(pin, targets)?['publicKey'], roof);
      // A node that happens to carry the same id is not the observer.
      expect(alertTargetFor(pin, [target(quiet, id: roofId)]), isNull);
    });

    test('an observer the server could not resolve matches on its key', () {
      final pin = AtlasPin.observer(
        observerId: placeholderObserverId(roof),
        name: '',
      );
      final gone = [target(roof, kind: 'observer')];
      expect(alertTargetFor(pin, gone), isNull);
      expect(alertTargetFor(pin, gone, observerKey: roof)?['publicKey'], roof);
    });

    test('channels reach the user by email, or by push with a device', () {
      Map<String, dynamic> channels({
        bool email = false,
        bool push = false,
        bool device = false,
      }) => {
        'email': {'available': true, 'enabled': email},
        'push': {'available': true, 'enabled': push, 'hasDevice': device},
      };
      expect(alertsReachUser(channels(email: true)), isTrue);
      expect(alertsReachUser(channels(push: true)), isFalse);
      expect(alertsReachUser(channels(push: true, device: true)), isTrue);
      expect(alertsReachUser(channels()), isFalse);
      // A server older than the switches sends none.
      expect(alertsReachUser(const {}), isTrue);
    });
  });

  testWidgets('no bell when the server has alerts off', (tester) async {
    final r = await rig();
    await pump(tester, r, alertsOn: false);
    expect(find.text('Busy'), findsOneWidget);
    expect(find.byType(AtlasIconButton), findsWidgets);
    expect(bell(busy), findsNothing);
    expect(r.h.calls('GET', '/me/alerts'), isEmpty);
    await close(tester);
  });

  testWidgets('the bell is an outline, filled or red by the rules', (
    tester,
  ) async {
    final r = await rig();
    await pump(tester, r);
    final danger = BeaconColors.of(tester.element(bell(quiet))).danger;

    final none = button(tester, quiet);
    expect(none.label, 'Alerts');
    expect(filled(none), isFalse);
    expect(none.tinted, isFalse);
    expect(none.color, isNull);

    final on = button(tester, busy);
    expect(on.label, 'Alerts: 2 on');
    expect(filled(on), isTrue);
    expect(on.tinted, isTrue);
    expect(on.color, isNull);

    final firing = button(tester, roofId);
    expect(firing.label, 'Alerts: 1 firing');
    expect(filled(firing), isTrue);
    expect(firing.color, danger);
    expect(find.byTooltip('Alerts: 1 firing'), findsOneWidget);

    // Three cards, one request.
    expect(r.h.calls('GET', '/me/alerts'), hasLength(1));
    await close(tester);
  });

  testWidgets('open comes first, then the bell; the rest wait for edit mode', (
    tester,
  ) async {
    final r = await rig();
    await pump(tester, r);
    final card = find.ancestor(
      of: bell(busy),
      matching: find.byType(AtlasPanel),
    );
    final labels = [
      for (final b in tester.widgetList<AtlasIconButton>(
        find.descendant(of: card, matching: find.byType(AtlasIconButton)),
      ))
        b.label,
    ];
    expect(labels, ['Open node Busy', 'Alerts: 2 on']);
    await close(tester);
  });

  testWidgets('a long name gives way to four buttons at 360 wide', (
    tester,
  ) async {
    final r = await rig(name: 'A very long repeater name on a far ridge');
    await pump(tester, r, size: const Size(360, 800));
    expect(bell(quiet), findsOneWidget);
    final panel = tester.getRect(
      find.ancestor(of: bell(quiet), matching: find.byType(AtlasPanel)),
    );
    final name = tester.getRect(
      find.text('A very long repeater name on a far ridge'),
    );
    expect(name.right, lessThan(tester.getRect(bell(quiet)).left));
    expect(panel.right, lessThanOrEqualTo(360));
    // An overflow would have thrown.
    await close(tester);
  });

  testWidgets('signed out, the bell opens a sign-in prompt', (tester) async {
    final r = await rig(signedIn: false);
    final launched = <Uri>[];
    final flow = SignInFlow(
      apiFor: (_) => r.h.account.api,
      accountFor: (_) => r.h.account,
      launch: (uri) async {
        launched.add(uri);
        return true;
      },
      now: DateTime.now,
    );
    await pump(tester, r, flow: flow);
    final b = button(tester, quiet);
    expect(b.label, 'Alerts');
    expect(filled(b), isFalse);

    await tester.tap(bell(quiet));
    await tester.pumpAndSettle();
    expect(find.text('Alerts for Quiet'), findsOneWidget);
    expect(find.text('Sign in to set alerts for this radio.'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(k('atlas-alerts-profile'), findsNothing);
    expect(r.h.calls('GET', '/me/alerts'), isEmpty);

    await tester.tap(k('account-sign-in'));
    await tester.pump();
    expect(launched.single.queryParameters['view'], 'signin');
    // The browser is open: the sheet waits, and can give up.
    expect(k('account-waiting'), findsOneWidget);
    await tester.tap(k('account-cancel'));
    await tester.pump();
    expect(k('account-waiting'), findsNothing);
    expect(k('account-sign-in'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a sign-in that fails after the browser says why', (
    tester,
  ) async {
    final r = await rig(signedIn: false);
    final flow = SignInFlow(
      apiFor: (_) => r.h.account.api,
      accountFor: (_) => r.h.account,
      launch: (_) async => true,
      now: DateTime.now,
    );
    Uri callback() =>
        Uri.parse('meshcorebeacon://auth?code=c&state=${flow.pending!.state}');
    await pump(tester, r, flow: flow);
    await tester.tap(bell(quiet));
    await tester.pumpAndSettle();

    exchangeFails = true;
    await tester.tap(k('account-sign-in'));
    await tester.pump();
    await tester.runAsync(() => flow.handleCallback(callback()));
    await tester.pump();
    expect(find.text('The server is having a bad day.'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);

    // The retry works, and the same sheet turns into the radio's rules.
    exchangeFails = false;
    await tester.tap(k('account-sign-in'));
    await tester.pump();
    await tester.runAsync(() async {
      await flow.handleCallback(callback());
      await r.store.idle;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(r.h.account.signedIn, isTrue);
    expect(find.text('The server is having a bad day.'), findsNothing);
    expect(k('alert-switch-$quiet-gone_quiet'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the sheet lists that radio\'s rules and saves them', (
    tester,
  ) async {
    final r = await rig();
    await pump(tester, r);
    await tester.tap(bell(busy));
    await tester.pumpAndSettle();

    expect(find.text('Alerts for Busy'), findsOneWidget);
    expect(k('alert-switch-$busy-gone_quiet'), findsOneWidget);
    expect(k('alert-switch-$busy-back_online'), findsOneWidget);
    expect(k('alert-switch-$quiet-gone_quiet'), findsNothing);
    expect(k('alert-switch-$roof-gone_quiet'), findsNothing);
    expect(
      tester.widget<Switch>(k('alert-switch-$busy-gone_quiet')).value,
      isTrue,
    );
    // An unavailable kind keeps its reason and has no switch.
    expect(k('alert-switch-$busy-battery_low'), findsNothing);
    expect(find.text('Battery low'), findsOneWidget);
    // Email is on, so the channel line is the plain link.
    expect(k('atlas-alerts-profile'), findsOneWidget);
    expect(k('atlas-alerts-no-channel'), findsNothing);

    await tester.tap(k('alert-switch-$busy-back_online'));
    await tester.pumpAndSettle();
    expect(rulePuts.single, {
      'target': {'kind': 'node', 'publicKey': busy},
      'kind': 'back_online',
      'threshold': null,
      'thresholdHigh': null,
      'enabled': false,
    });
    // The card behind the sheet reads the same reload.
    expect(button(tester, busy).label, 'Alerts: 1 on');
    await close(tester);
  });

  testWidgets('an observer card opens the observer\'s rules', (tester) async {
    final r = await rig();
    await pump(tester, r);
    await tester.ensureVisible(bell(roofId));
    await tester.tap(bell(roofId));
    await tester.pumpAndSettle();
    expect(find.text('Alerts for Roof'), findsOneWidget);
    expect(k('alert-switch-$roof-gone_quiet'), findsOneWidget);
    await tester.tap(k('alert-switch-$roof-back_online'));
    await tester.pumpAndSettle();
    expect(rulePuts.single['target'], {'kind': 'observer', 'publicKey': roof});
    await close(tester);
  });

  testWidgets('with no channel on, the profile line is a warning', (
    tester,
  ) async {
    alerts['channels'] = {
      'email': {'available': true, 'enabled': false, 'reason': ''},
      // On, but no phone has registered for push.
      'push': {'available': true, 'enabled': true, 'hasDevice': false},
    };
    final r = await rig();
    await pump(tester, r);
    await tester.tap(bell(busy));
    await tester.pumpAndSettle();
    expect(k('atlas-alerts-no-channel'), findsOneWidget);
    expect(
      find.text(
        'Email and push are both off, so alerts won\'t reach you. '
        'Turn one on in your profile.',
      ),
      findsOneWidget,
    );
    await close(tester);
  });

  testWidgets('a server without channels shows the plain profile link', (
    tester,
  ) async {
    alerts.remove('channels');
    final r = await rig();
    await pump(tester, r);
    await tester.tap(bell(busy));
    await tester.pumpAndSettle();
    expect(k('atlas-alerts-no-channel'), findsNothing);
    expect(
      find.text('Choose how alerts reach you in your profile'),
      findsOneWidget,
    );

    await tester.tap(k('atlas-alerts-profile'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(find.text('Alerts for Busy'), findsNothing);
    await close(tester);
  });

  testWidgets('a pin the server lists no target for says so', (tester) async {
    (alerts['targets'] as List).removeAt(0);
    final r = await rig();
    await pump(tester, r);
    expect(button(tester, quiet).label, 'Alerts');
    await tester.tap(bell(quiet));
    await tester.pumpAndSettle();
    expect(find.textContaining('not available yet'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);

    // Retry reads again and finds it.
    (alerts['targets'] as List).add(target(quiet, name: 'Quiet'));
    await tester.tap(k('atlas-alerts-retry'));
    await tester.pumpAndSettle();
    expect(k('alert-switch-$quiet-gone_quiet'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a failed load shows the error and a retry', (tester) async {
    final r = await rig();
    final good = alerts;
    var fail = true;
    r.h.hold = (request) => fail && request.url.path.endsWith('/me/alerts')
        ? Future.value(failure(500, 'internal', 'boom'))
        : null;
    await pump(tester, r);
    expect(button(tester, busy).label, 'Alerts');
    await tester.tap(bell(busy));
    await tester.pumpAndSettle();
    expect(k('atlas-alerts-retry'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);

    fail = false;
    alerts = good;
    await tester.tap(k('atlas-alerts-retry'));
    await tester.pumpAndSettle();
    expect(k('alert-switch-$busy-gone_quiet'), findsOneWidget);
    expect(button(tester, busy).label, 'Alerts: 2 on');
    await close(tester);
  });

  group('a channel change', () {
    Map<String, dynamic> emailOff() => {
      'email': {'available': true, 'enabled': false, 'reason': ''},
      'push': {'available': false, 'enabled': true, 'hasDevice': false},
    };

    test('wins over a read that started before it', () async {
      final r = await rig();
      final state = r.h.account.alerts;
      await state.load();
      expect(object(state.channels['email'])['enabled'], isTrue);

      // A refresh is on its way when the user turns email off.
      final held = Completer<http.Response>();
      r.h.hold = (request) =>
          request.url.path.endsWith('/me/alerts') ? held.future : null;
      final refresh = state.load();
      r.h.hold = null;
      final stale = json(200, jsonDecode(jsonEncode(alerts)));
      alerts['channels'] = emailOff();
      state.setChannels(emailOff());
      expect(object(state.channels['email'])['enabled'], isFalse);

      held.complete(stale);
      await refresh;
      await state.settled;
      expect(object(state.channels['email'])['enabled'], isFalse);
      // The read after the save is the one that counts.
      expect(r.h.calls('GET', '/me/alerts'), hasLength(3));
    });

    test('a rule save also outranks an older read', () async {
      final r = await rig();
      final state = r.h.account.alerts;
      await state.load();
      final held = Completer<http.Response>();
      r.h.hold = (request) =>
          request.url.path.endsWith('/me/alerts') ? held.future : null;
      final refresh = state.load();
      r.h.hold = null;
      final stale = json(200, jsonDecode(jsonEncode(alerts)));
      ((alerts['targets'] as List)[1] as Map)['rules'] = <dynamic>[];
      final seen = <int>[];
      state.addListener(() => seen.add(alertCounts(state.targets[1]).on));
      final saved = state.saved();
      held.complete(stale);
      await refresh;
      await saved;
      await state.settled;
      // The old answer is never shown again as if it were new.
      expect(seen, isNotEmpty);
      expect(seen.last, 0);
      expect(seen.skipWhile((n) => n == 2), everyElement(0));
    });
  });

  group('the bells keep up with the server', () {
    void fire(bool on) {
      final rules = ((alerts['targets'] as List)[1] as Map)['rules'] as List;
      (rules.first as Map)['state'] = on ? 'firing' : 'ok';
    }

    testWidgets('on the minute tick, to firing and back', (tester) async {
      final r = await rig();
      await pump(tester, r);
      expect(button(tester, busy).label, 'Alerts: 2 on');

      fire(true);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(button(tester, busy).label, 'Alerts: 1 firing');
      expect(button(tester, busy).color, isNotNull);

      fire(false);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(button(tester, busy).label, 'Alerts: 2 on');
      expect(button(tester, busy).color, isNull);
      await close(tester);
    });

    testWidgets('on resume, and not while backgrounded', (tester) async {
      final r = await rig();
      await pump(tester, r);
      final before = r.h.calls('GET', '/me/alerts').length;

      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      fire(true);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(r.h.calls('GET', '/me/alerts'), hasLength(before));
      expect(button(tester, busy).label, 'Alerts: 2 on');

      for (final state in const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(button(tester, busy).label, 'Alerts: 1 firing');
      await close(tester);
    });

    testWidgets('a covered Atlas waits until it shows again', (tester) async {
      final r = await rig();
      await pump(tester, r);
      final before = r.h.calls('GET', '/me/alerts').length;
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      fire(true);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(r.h.calls('GET', '/me/alerts'), hasLength(before));

      navigator.pop();
      await tester.pumpAndSettle();
      expect(button(tester, busy).label, 'Alerts: 1 firing');
      await close(tester);
    });

    testWidgets('a reload leaves a threshold being typed alone', (
      tester,
    ) async {
      (alerts['targets'] as List)[1] = target(
        busy,
        name: 'Busy',
        rules: [rule('battery_low', threshold: 3500)],
      )..['available'] = ['gone_quiet', 'back_online', 'battery_low'];
      ((alerts['targets'] as List)[1] as Map)['unavailable'] =
          <String, String>{};
      final r = await rig();
      await pump(tester, r);
      await tester.tap(bell(busy));
      await tester.pumpAndSettle();
      final field = k('alert-input-$busy-battery_low');
      await tester.enterText(field, '3.7');
      await r.h.account.alerts.load();
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '3.7');
      await close(tester);
    });

    testWidgets('a failed refresh shows above the rules it could not renew', (
      tester,
    ) async {
      final r = await rig();
      await pump(tester, r);
      r.h.hold = (request) => request.url.path.endsWith('/me/alerts')
          ? Future.value(failure(500, 'internal', 'boom'))
          : null;
      await tester.tap(bell(busy));
      await tester.pumpAndSettle();
      expect(k('alert-switch-$busy-gone_quiet'), findsOneWidget);
      expect(k('atlas-alerts-retry'), findsOneWidget);
      expect(
        tester.getTopLeft(k('atlas-alerts-retry')).dy,
        lessThan(tester.getTopLeft(k('alert-switch-$busy-gone_quiet')).dy),
      );

      r.h.hold = null;
      await tester.tap(k('atlas-alerts-retry'));
      await tester.pumpAndSettle();
      expect(k('atlas-alerts-retry'), findsNothing);
      expect(k('alert-switch-$busy-gone_quiet'), findsOneWidget);
      await close(tester);
    });
  });

  testWidgets('a slow Atlas sync still means one alerts load', (tester) async {
    final r = await rig(hold: true);
    await pump(tester, r, settle: false);
    // /info has answered; the account's pins have not.
    await tester.pump();
    await tester.pump();
    expect(r.h.calls('GET', '/me/alerts'), isEmpty);
    atlasGate!.complete();
    await tester.pumpAndSettle();
    expect(button(tester, busy).label, 'Alerts: 2 on');
    expect(r.h.calls('GET', '/me/alerts'), hasLength(1));
    await close(tester);
  });

  group('header buttons take a finger', () {
    testWidgets('the painted box and the header keep their size', (
      tester,
    ) async {
      final r = await rig();
      await pump(tester, r, size: const Size(360, 800));
      final card = find.ancestor(
        of: bell(busy),
        matching: find.byType(AtlasPanel),
      );
      final boxes = [
        for (final e
            in find
                .descendant(of: card, matching: find.byType(AtlasIconButton))
                .evaluate())
          tester.getRect(find.byWidget(e.widget)),
      ];
      expect(boxes, hasLength(2));
      for (final (i, box) in boxes.indexed) {
        expect(box.size, const Size(28, 26));
        if (i > 0) expect(box.left - boxes[i - 1].right, 4);
        expect(box.top, boxes.first.top);
      }
      final panel = tester.getRect(card);
      expect(boxes.first.top - panel.top, 15);
      expect(panel.right - boxes.last.right, 15);
      await close(tester);
    });

    testWidgets('a tap just outside the painted bell still opens it', (
      tester,
    ) async {
      final r = await rig();
      await pump(tester, r, size: const Size(360, 800));
      final box = tester.getRect(bell(busy));
      for (final point in [
        box.bottomCenter + const Offset(0, 8),
        box.topCenter - const Offset(0, 10),
        box.centerLeft - const Offset(1, 0),
      ]) {
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(find.text('Alerts for Busy'), findsOneWidget, reason: '$point');
        await tester.tapAt(const Offset(180, 20));
        await tester.pumpAndSettle();
        expect(find.text('Alerts for Busy'), findsNothing);
      }
      // Further down is the card's body, not the bell.
      await tester.tapAt(box.bottomCenter + const Offset(0, 12));
      await tester.pumpAndSettle();
      expect(find.text('Alerts for Busy'), findsNothing);
      await close(tester);
    });

    testWidgets('a tap in the gap goes to one button only', (tester) async {
      final r = await rig();
      await pump(tester, r, size: const Size(360, 800));
      final card = find.ancestor(
        of: find.text('Busy'),
        matching: find.byType(AtlasPanel),
      );
      final remove = find.descendant(
        of: card,
        matching: find.byWidgetPredicate(
          (w) => w is AtlasIconButton && w.label == 'Remove',
        ),
      );
      final grip = find.descendant(
        of: card,
        matching: find.byWidgetPredicate(
          (w) => w is AtlasIconButton && w.label == 'Drag to reorder',
        ),
      );
      // Bell side of the gap between the bell and the pin.
      await tester.tapAt(
        tester.getRect(bell(busy)).centerRight + const Offset(1, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alerts for Busy'), findsOneWidget);
      expect(r.store.saved.pins, hasLength(3));
      await tester.tapAt(const Offset(180, 20));
      await tester.pumpAndSettle();

      // Remove side of the gap between the grip and remove: only remove fires.
      await edit(tester);
      // Remove stands off from the grip, and the space between does nothing.
      final gap = tester.getRect(remove).left - tester.getRect(grip).right;
      expect(gap, greaterThanOrEqualTo(16));
      await tester.tapAt(tester.getRect(grip).centerRight + Offset(gap / 2, 0));
      await tester.pumpAndSettle();
      expect(r.store.saved.pins, hasLength(3));
      await tester.tapAt(
        tester.getRect(remove).centerLeft - const Offset(1, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alerts for Busy'), findsNothing);
      expect(r.store.saved.pins.map((p) => p.key), [quiet, roofId]);
      await close(tester);
    });

    testWidgets('the grip still drags a card from outside its box', (
      tester,
    ) async {
      final r = await rig();
      await pump(tester, r, size: const Size(360, 800));
      await edit(tester);
      final card = find.ancestor(
        of: find.text('Quiet'),
        matching: find.byType(AtlasPanel),
      );
      final grip = find.descendant(
        of: card,
        matching: find.byWidgetPredicate(
          (w) => w is AtlasIconButton && w.label == 'Drag to reorder',
        ),
      );
      final start = tester.getRect(grip).bottomCenter + const Offset(0, 6);
      final last = tester.getCenter(find.byTooltip('Drag to reorder').last);
      final drag = await tester.startGesture(start);
      await tester.pump();
      await drag.moveTo(last + const Offset(0, 20));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(r.store.saved.pins.first.key, isNot(quiet));
      await close(tester);
    });
  });

  testWidgets('the profile link lands on the alerts', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final r = await rig();
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: ProfileScreen(account: r.h.account, api: api(), showAlerts: true),
      ),
    );
    await tester.pumpAndSettle();
    final title = tester.getRect(find.text('HOW ALERTS REACH YOU'));
    // Scrolled past the account forms, to the top of the list.
    expect(title.top, greaterThan(0));
    expect(title.top, lessThan(200));
  });
}
