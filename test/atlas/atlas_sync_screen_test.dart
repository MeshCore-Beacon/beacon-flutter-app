import 'dart:convert';

import 'package:beacon/core/account.dart';
import 'package:beacon/core/api.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/core/token_store.dart';
import 'package:beacon/features/atlas/atlas.dart';
import 'package:beacon/features/atlas/atlas_screen.dart';
import 'package:beacon/features/atlas/atlas_settings.dart';
import 'package:beacon/features/atlas/atlas_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const server = 'https://test.invalid';
final key = 'ab' * 32;

class Files implements AtlasFiles {
  String? picked;
  @override
  Future<String?> pick() async => picked;
  @override
  Future<bool> save(String name, String text) async => true;
}

class Rig {
  Rig(this.prefs, this.store, this.puts, this.account);
  final Preferences prefs;
  final AtlasStore store;
  final List<Map<String, dynamic>> puts;
  final AccountState account;
}

/// A signed-in account whose Atlas holds [pins] at [revision].
Future<Rig> rig(
  List<Map<String, dynamic>> initial, {
  int revision = 1,
  bool conflict = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'beacon.servers': jsonEncode([
      {'name': 'Home mesh', 'url': server},
    ]),
    'beacon.active': server,
    'beacon.atlas.synced.$server.u1': true,
  });
  final prefs = await Preferences.load();
  final tokens = MemoryTokenStore();
  await tokens.write(server, 'tok');
  final puts = <Map<String, dynamic>>[];
  var pins = initial;
  var current = revision;
  http.Response ok(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
  final account = AccountState(
    AuthApi(
      server,
      tokens,
      client: MockClient((r) async {
        if (r.method == 'GET') {
          return ok({'revision': current, 'range': '24h', 'pins': pins});
        }
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        puts.add(body);
        if (conflict) {
          return http.Response(
            jsonEncode({
              'error': {'code': 'atlas_conflict', 'message': 'x'},
              'current': {
                'revision': 9,
                'range': '24h',
                'pins': [
                  {
                    'kind': 'node',
                    'publicKey': 'cd' * 32,
                    'id': null,
                    'name': 'Elsewhere',
                  },
                ],
              },
            }),
            409,
            headers: {'content-type': 'application/json'},
          );
        }
        current++;
        pins = [
          for (final raw in body['pins'] as List)
            {
              ...(raw as Map<String, dynamic>),
              'id': '11111111-1111-4111-8111-111111111111',
            },
        ];
        return ok({'revision': current, 'range': body['range'], 'pins': pins});
      }),
    ),
  )..adopt({'id': 'u1'});
  return Rig(prefs, AtlasStore(prefs, server, account: account), puts, account);
}

Widget screen(Rig r) => MaterialApp(
  theme: BeaconTheme.all.first.data,
  home: Scaffold(
    body: AtlasScreen(
      api: ApiClient(
        Uri.parse(server),
        client: MockClient((_) async => http.Response('{"error":{}}', 404)),
      ),
      preferences: r.prefs,
      store: r.store,
      onOpen: (_, _) {},
    ),
  ),
);

void main() {
  setUp(BeaconTheme.load);

  testWidgets('signed in, the toolbar note says synced to the account', (
    tester,
  ) async {
    final r = await rig([]);
    await tester.pumpWidget(screen(r));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Synced to your account'), findsOneWidget);
    expect(find.byTooltip('Saved on this device'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a node the server could not resolve shows the not-found state', (
    tester,
  ) async {
    final r = await rig([
      {'kind': 'node', 'publicKey': key, 'id': null, 'name': 'Gone'},
    ]);
    await tester.pumpWidget(screen(r));
    await tester.pumpAndSettle();
    expect(find.text('Node not found'), findsOneWidget);
    expect(r.puts, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a conflict shows one inline line and the latest cards', (
    tester,
  ) async {
    final r = await rig([
      {'kind': 'node', 'publicKey': key, 'id': null, 'name': 'Mine'},
    ], conflict: true);
    await tester.pumpWidget(screen(r));
    await tester.pumpAndSettle();
    r.store.update((v) => v.copyWith(range: AtlasRange.threeDays));
    await tester.pumpAndSettle();
    expect(
      find.text('Atlas was changed on another device. Showing the latest.'),
      findsOneWidget,
    );
    expect(find.text('Elsewhere'), findsOneWidget);
    expect(r.puts.length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('says how many local cards did not fit', (tester) async {
    final r = await rig([]);
    await r.store.idle;
    r.store.notice = const AtlasNotice(AtlasNoticeKind.overflow, 2);
    await tester.pumpWidget(screen(r));
    expect(
      find.text('2 cards from this device did not fit and were not added.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed save says the change is kept on this device', (
    tester,
  ) async {
    final r = await rig([]);
    await r.store.idle;
    r.store.notice = const AtlasNotice(AtlasNoticeKind.failed);
    await tester.pumpWidget(screen(r));
    expect(
      find.text(
        'Could not save to your account. Your changes are kept on this device.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('import in Settings goes to the account when signed in', (
    tester,
  ) async {
    final r = await rig([]);
    await r.store.idle;
    final files = Files()
      ..picked = jsonEncode({
        'format': 'beacon-atlas',
        'version': 2,
        'range': '3d',
        'pins': [
          {
            'kind': 'node',
            'id': '11111111-1111-4111-8111-111111111111',
            'publicKey': key,
            'name': 'Hill',
          },
        ],
      });
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: Scaffold(
          body: AtlasSettings(
            preferences: r.prefs,
            files: files,
            store: r.store,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('atlas-import')));
    await tester.pumpAndSettle();
    await r.store.idle;
    expect(r.puts.length, 1);
    expect(r.puts.single['range'], '3d');
    expect((r.puts.single['pins'] as List).single['publicKey'], key);
    expect(parseAtlas(r.prefs.atlasFor(server)).pins.length, 1);
  });
}
