import 'dart:convert';

import 'package:beacon/core/api.dart';
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

/// Three pins on the account: two nodes and an observer.
Future<Rig> rig({bool signedIn = true, String? name}) async {
  final nodes = [
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
    if (path == '/me/atlas') {
      return json(200, {'revision': 1, 'range': '24h', 'pins': nodes});
    }
    if (path == '/me/alerts' && r.method == 'GET') return json(200, alerts);
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
  await tester.pumpAndSettle();
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

void main() {
  setUp(() async {
    await loadAssets();
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

  testWidgets('the bell comes first, before pin, remove and drag', (
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
    expect(labels, [
      'Alerts: 2 on',
      'Open on this tab',
      'Remove',
      'Drag to reorder',
    ]);
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

    await tester.tap(k('atlas-alerts-sign-in'));
    await tester.pumpAndSettle();
    expect(launched.single.queryParameters['view'], 'signin');
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
