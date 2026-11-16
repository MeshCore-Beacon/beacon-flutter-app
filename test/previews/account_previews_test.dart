// Renders the account screens to PNGs for review. Off in the normal run:
//   BEACON_PREVIEW=1 flutter test test/previews/account_previews_test.dart
// Output goes to BEACON_PREVIEW_DIR (default ../graphics/app-account).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:beacon/core/api.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/account/account_section.dart';
import 'package:beacon/features/account/profile_screen.dart';
import 'package:beacon/features/account/sign_in.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import '../features/account/harness.dart';

final _on = Platform.environment['BEACON_PREVIEW'] != null;
final _dir =
    Platform.environment['BEACON_PREVIEW_DIR'] ?? '../graphics/app-account';
final _now = DateTime.now().millisecondsSinceEpoch;
final _shot = GlobalKey();

Map<String, dynamic> _request(
  String id,
  String name,
  String status, {
  bool reading = true,
  String? state,
}) => {
  'id': id,
  'node': {'id': 'n$id', 'publicKey': 'ab' * 32, 'name': name},
  'status': status,
  'statusReason': '',
  'hasPassword': status != 'waiting',
  'poller': status == 'active'
      ? {'observerId': 'o1', 'name': 'HOWL V4.2', 'state': ?state}
      : null,
  'latestReadingAt': reading ? _now - 3600000 : null,
};

Map<String, dynamic> _rule(
  String kind, {
  int? t,
  int? high,
  bool on = true,
  String state = 'ok',
}) => {
  'id': 'r-$kind',
  'kind': kind,
  'threshold': t,
  'thresholdHigh': high,
  'enabled': on,
  'state': state,
  'stateChangedAt': _now - 7200000,
};

void main() {
  setUpAll(() async {
    // The theme's own families, so text is real glyphs and not boxes.
    for (final (family, file) in [
      ('Inter', 'assets/fonts/Inter.ttf'),
      ('JetBrainsMono', 'assets/fonts/JetBrainsMono.ttf'),
    ]) {
      final bytes = File(file).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    // Icons come from the SDK's font; found through the flutter binary.
    final sdk =
        Platform.environment['FLUTTER_ROOT'] ??
        File(Platform.resolvedExecutable)
            .parent
            .parent
            .parent
            .parent
            .parent
            .path;
    final icons = File(
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(icons.readAsBytesSync())),
          ))
          .load();
    }
    Directory(_dir).createSync(recursive: true);
    await loadAssets();
  });

  // The app's light theme is hidden, so only the default dark one is shown.
  for (final dark in [true]) {
    final mode = dark ? 'dark' : 'light';
    ThemeData theme() => BeaconTheme.all
        .firstWhere((t) => t.id == (dark ? 'neutral-blue' : 'meshmapper_light'))
        .data;

    Future<void> size(WidgetTester tester, {double h = 844}) async {
      tester.view.physicalSize = Size(390 * 3, h * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<void> save(WidgetTester tester, String name) async {
      await tester.pump(const Duration(milliseconds: 600));
      await tester.runAsync(() async {
        final boundary =
            _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 3);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$_dir/$name-$mode.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
      });
    }

    ApiClient apiFor(String accounts) => ApiClient(
      Uri.parse(server),
      transientRetries: 0,
      client: MockClient(
        (_) async => json(200, {
          'features': {
            'accounts': accounts,
            'telemetryRequests': true,
            'alerts': true,
            'alertDelivery': 'email',
          },
        }),
      ),
    );

    Harness harness({
      bool signedIn = true,
      List<Map<String, dynamic>> requests = const [],
      bool alerts = false,
    }) => Harness((r) {
      final key = '${r.method} ${r.url.path.replaceFirst('/api/v1', '')}';
      switch (key) {
        case 'GET /me/sessions':
          return json(200, {
            'sessions': [
              session('s1', current: true),
              session('s2', kind: 'app'),
              session('s3'),
            ],
          });
        case 'GET /me/telemetry-requests':
          return json(200, {'limit': 3, 'requests': requests});
        case 'GET /me/alerts':
          return json(200, {
            'delivery': 'email',
            'targets': alerts
                ? [
                    {
                      'id': 'a',
                      'kind': 'node',
                      'publicKey': 'aabb',
                      'name': 'Hilltop',
                      'polled': true,
                      'available': [
                        'gone_quiet',
                        'battery_low',
                        'temperature',
                        'noise_high',
                      ],
                      'unavailable': {},
                      'unavailableCodes': {},
                      'rules': [
                        _rule('gone_quiet', t: 6),
                        _rule('battery_low', t: 3400),
                        _rule('temperature', t: 0, high: 400, on: false),
                      ],
                    },
                    {
                      'id': 'b',
                      'kind': 'node',
                      'publicKey': 'ccdd',
                      'name': 'Ridge',
                      'polled': true,
                      'available': ['gone_quiet', 'battery_low'],
                      'unavailable': {},
                      'unavailableCodes': {},
                      'rules': [
                        _rule('gone_quiet', t: 6),
                        _rule('battery_low', t: 3400, state: 'firing'),
                      ],
                    },
                  ]
                : [],
          });
      }
      return json(404, {});
    }, signedIn: signedIn);

    Future<void> shell(WidgetTester tester, Widget home) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: _shot,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme(),
            home: home,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
    }

    Widget settings(Harness h, String accounts, SignInFlow flow) => SignInScope(
      flow: flow,
      child: Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          children: [
            AccountSection(
              account: h.account,
              api: apiFor(accounts),
              serverName: 'Home mesh',
            ),
          ],
        ),
      ),
    );

    SignInFlow flowFor(Harness h) => SignInFlow(
      apiFor: (_) => h.account.api,
      launch: (_) async => true,
      now: DateTime.now,
    );

    Future<void> profile(
      WidgetTester tester,
      Harness h, {
      String scrollTo = '',
    }) async {
      await shell(
        tester,
        ProfileScreen(account: h.account, api: apiFor('local')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      if (scrollTo.isNotEmpty) {
        final target = find.byKey(ValueKey(scrollTo));
        await tester.scrollUntilVisible(
          target,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(
          tester.element(target.first),
          alignment: .15,
        );
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    testWidgets('signed out ($mode)', (tester) async {
      await size(tester, h: 420);
      final h = harness(signedIn: false);
      await shell(tester, settings(h, 'local', flowFor(h)));
      await save(tester, '01-signed-out');
    }, skip: !_on);

    testWidgets('signed out portal ($mode)', (tester) async {
      await size(tester, h: 420);
      final h = harness(signedIn: false);
      await shell(tester, settings(h, 'portal', flowFor(h)));
      await save(tester, '01b-signed-out-portal');
    }, skip: !_on);

    testWidgets('waiting ($mode)', (tester) async {
      await size(tester, h: 420);
      final h = harness(signedIn: false);
      final flow = flowFor(h);
      await shell(tester, settings(h, 'local', flow));
      await tester.tap(find.byKey(const ValueKey('account-sign-in')));
      await tester.pump(const Duration(milliseconds: 100));
      await save(tester, '02-waiting');
    }, skip: !_on);

    testWidgets('rejected ($mode)', (tester) async {
      await size(tester, h: 420);
      final h = harness(signedIn: false);
      final flow = flowFor(h);
      await shell(tester, settings(h, 'local', flow));
      await flow.handleCallback(
        Uri.parse('meshcorebeacon://auth?code=c&state=x'),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await save(tester, '02b-rejected');
    }, skip: !_on);

    testWidgets('signed in ($mode)', (tester) async {
      await size(tester, h: 420);
      final h = harness();
      await shell(tester, settings(h, 'local', flowFor(h)));
      await save(tester, '03-signed-in');
    }, skip: !_on);

    testWidgets('profile top ($mode)', (tester) async {
      await size(tester);
      await profile(tester, harness());
      await save(tester, '04-profile-top');
    }, skip: !_on);

    testWidgets('password error ($mode)', (tester) async {
      await size(tester);
      await profile(tester, harness(), scrollTo: 'pw-current');
      await tester.enterText(
        find.byKey(const ValueKey('pw-current')),
        'old-password-1',
      );
      await tester.enterText(find.byKey(const ValueKey('pw-new')), 'short');
      await tester.pump(const Duration(milliseconds: 400));
      await save(tester, '05-password-error');
    }, skip: !_on);

    testWidgets('devices ($mode)', (tester) async {
      await size(tester);
      await profile(tester, harness(), scrollTo: 'devices-others');
      await save(tester, '06-devices');
    }, skip: !_on);

    testWidgets('requests empty ($mode)', (tester) async {
      await size(tester);
      await profile(tester, harness());
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -1250));
      await tester.pump(const Duration(milliseconds: 400));
      await save(tester, '07a-requests-empty');
    }, skip: !_on);

    testWidgets('requests rows ($mode)', (tester) async {
      await size(tester, h: 1000);
      final h = harness(
        requests: [
          _request('1', 'Hilltop', 'active'),
          _request('2', 'Lakeside', 'admin_stopped', reading: false),
          _request('3', 'North ridge', 'waiting', reading: false),
          _request('4', 'Pine bluff', 'active', state: 'not_direct'),
        ],
      );
      await profile(tester, h, scrollTo: 'request-row-1');
      await save(tester, '07b-requests-rows');
    }, skip: !_on);

    testWidgets('alerts ($mode)', (tester) async {
      await size(tester, h: 1000);
      await profile(
        tester,
        harness(alerts: true),
        scrollTo: 'alert-target-aabb',
      );
      await save(tester, '08-alerts');
    }, skip: !_on);

    testWidgets('alerts expanded ($mode)', (tester) async {
      await size(tester, h: 1000);
      await profile(
        tester,
        harness(alerts: true),
        scrollTo: 'alert-target-aabb',
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('alert-tile-aabb')),
          matching: find.byType(ListTile),
        ),
      );
      await tester.pumpAndSettle();
      await save(tester, '08b-alerts-expanded');
    }, skip: !_on);

    testWidgets('delete ($mode)', (tester) async {
      await size(tester);
      await profile(tester, harness(), scrollTo: 'delete-password');
      await tester.enterText(
        find.byKey(const ValueKey('delete-password')),
        'old-password-1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('delete-username')),
        'ridgewalker',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await save(tester, '09-delete');
    }, skip: !_on);

    testWidgets('narrow and large text ($mode)', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 900 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = harness(
        requests: [_request('2', 'Lakeside', 'admin_stopped', reading: false)],
        alerts: true,
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: _shot,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: ProfileScreen(account: h.account, api: apiFor('local')),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await save(tester, '10-narrow-large-text');
    }, skip: !_on);
  }
}
