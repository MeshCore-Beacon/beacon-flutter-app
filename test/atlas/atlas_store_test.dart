import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/account.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/token_store.dart';
import 'package:beacon/features/atlas/atlas.dart';
import 'package:beacon/features/atlas/atlas_store.dart';
import 'package:beacon/features/atlas/atlas_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const server = 'https://test.invalid';
const cacheKey = 'beacon.atlas.$server';
const markerKey = 'beacon.atlas.synced.$server.u1';
const nodeId = '11111111-1111-4111-8111-111111111111';
const obsId = '44444444-4444-4444-8444-444444444444';
final key = 'ab' * 32, otherKey = 'cd' * 32, obsKey = 'ef' * 32;

String keyN(int i) => i.toRadixString(16).padLeft(2, '0') * 32;

AtlasPin node(String publicKey, [String name = 'Hill']) =>
    AtlasPin.node(id: nodeId, publicKey: publicKey, name: name);

Map<String, dynamic> serverNode(String publicKey, [String name = 'Hill']) => {
  'kind': 'node',
  'publicKey': publicKey,
  'id': nodeId,
  'name': name,
  'observerId': null,
};

/// The server's side of /me/atlas: one revision counter, last PUT wins.
class FakeServer {
  int revision = 0;
  String range = '24h';
  List<Map<String, dynamic>> pins = [];
  final requests = <http.Request>[];
  Completer<void>? hold, holdGet;
  bool bareConflict = false;
  bool offline = false;
  int? staleAfter;
  bool atlasTelemetry = false;

  Map<String, dynamic> get doc => {
    'revision': revision,
    'range': range,
    'limit': 12,
    'pins': pins,
  };

  List<http.Request> get puts => [
    for (final r in requests)
      if (r.method == 'PUT') r,
  ];

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    if (offline) throw http.ClientException('down');
    final gate = hold;
    if (gate != null && r.method == 'PUT') await gate.future;
    if (r.url.path.endsWith('/info')) {
      return _ok({
        'features': {'atlasTelemetry': atlasTelemetry},
      });
    }
    if (r.method == 'GET') {
      await holdGet?.future;
      return _ok(doc);
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    if (body['baseRevision'] != revision) {
      if (bareConflict) {
        return http.Response(
          jsonEncode({
            'error': {'code': 'atlas_conflict', 'message': 'changed'},
          }),
          409,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'error': {'code': 'atlas_conflict', 'message': 'changed'},
          'current': doc,
        }),
        409,
        headers: {'content-type': 'application/json'},
      );
    }
    revision++;
    range = body['range'] as String;
    pins = [
      for (final raw in (body['pins'] as List).cast<Map<String, dynamic>>())
        if (raw['kind'] == 'node')
          {
            ...raw,
            'id': nodeId,
            'observerId': null,
            // An older server stores neither, so they never come back.
            if (!atlasTelemetry) ...{'telemetryTiles': null, 'view': null},
          }
        else
          {
            'kind': 'observer',
            'observerPublicKey': raw['observerPublicKey'] ?? obsKey,
            'observerId': raw['observerId'],
            'name': raw['name'],
            'tiles': ?raw['tiles'],
          },
    ];
    return _ok(doc);
  }

  http.Response _ok(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}

class Rig {
  Rig(this.prefs, this.fake, this.account);
  final Preferences prefs;
  final FakeServer fake;
  final AccountState account;
  late AtlasStore store = AtlasStore(prefs, server, account: account);
}

Future<Rig> rig({
  bool signedIn = true,
  List<AtlasPin>? local,
  AtlasRange range = AtlasRange.day,
  bool marked = false,
  String? owner,
  FakeServer? fake,
}) async {
  SharedPreferences.setMockInitialValues({
    if (local != null) cacheKey: SavedAtlas(range: range, pins: local).encode(),
    if (marked) markerKey: true,
    'beacon.atlas.owner.$server': ?owner,
  });
  final prefs = await Preferences.load();
  fake ??= FakeServer();
  final tokens = MemoryTokenStore();
  await tokens.write(server, 'tok');
  final account = AccountState(
    AuthApi(server, tokens, client: MockClient(fake.handle)),
  );
  if (signedIn) account.adopt({'id': 'u1', 'username': 'ridge'});
  return Rig(prefs, fake, account);
}

List<dynamic> cachedPins(Preferences prefs) =>
    (jsonDecode(prefs.atlasFor(server)!) as Map)['pins'] as List;

/// Another device commits right before this client's second PUT.
class OtherDeviceServer extends FakeServer {
  int puts_ = 0;
  @override
  Future<http.Response> handle(http.Request r) async {
    if (r.method == 'PUT' && ++puts_ == 2) {
      revision++;
      pins.add(serverNode(keyN(3), 'Other device'));
    }
    return super.handle(r);
  }
}

void main() {
  test('a queued edit keeps the committed revision, so another device is not overwritten', () async {
    final fake = OtherDeviceServer()
      ..revision = 4
      ..pins = [serverNode(keyN(1))];
    final gate = Completer<void>();
    fake.hold = gate;
    final r = await rig(marked: true, fake: fake);
    final store = r.store;
    await Future<void>.delayed(Duration.zero);
    store.update((v) => v.appended(node(keyN(2))));
    await Future<void>.delayed(Duration.zero);
    store.update((v) => v.copyWith(range: AtlasRange.threeDays));
    gate.complete();
    await store.idle;
    final puts = fake.puts;
    expect(jsonDecode(puts[0].body)['baseRevision'], 4);
    expect(jsonDecode(puts[1].body)['baseRevision'], 5);
    expect(fake.pins.any((p) => p['publicKey'] == keyN(3)), isTrue);
    expect(store.saved.pins.any((p) => p.key == keyN(3)), isTrue);
  });

  group('Telemetry fields', () {
    AtlasPin telemetryPin() => AtlasPin.node(
      id: nodeId,
      publicKey: key,
      name: 'Hill',
      telemetryTiles: const ['noise', 'battery', 'uptime', 'airtime'],
      view: AtlasView.telemetry,
    );

    test(
      'an older server is sent neither and the local copy keeps them',
      () async {
        final r = await rig(marked: true);
        final store = r.store;
        await store.idle;
        store.update((v) => v.appended(telemetryPin()));
        await store.idle;
        final sent = (jsonDecode(r.fake.puts.last.body)['pins'] as List).single;
        expect((sent as Map).containsKey('telemetryTiles'), false);
        expect(sent.containsKey('view'), false);
        expect(store.saved.pins.single.view, AtlasView.telemetry);
        expect(store.saved.pins.single.telemetryTiles, [
          'noise',
          'battery',
          'uptime',
          'airtime',
        ]);
        expect(cachedPins(r.prefs).single['view'], 'telemetry');
      },
    );

    test('a server with the flag gets both', () async {
      final fake = FakeServer()..atlasTelemetry = true;
      final r = await rig(marked: true, fake: fake);
      final store = r.store;
      await store.idle;
      store.update((v) => v.appended(telemetryPin()));
      await store.idle;
      final sent = (jsonDecode(fake.puts.last.body)['pins'] as List).single;
      expect(sent['view'], 'telemetry');
      expect(sent['telemetryTiles'], ['noise', 'battery', 'uptime', 'airtime']);
    });
  });

  group('signed out', () {
    test('stored JSON after a sequence of actions is what it always was', () async {
      final r = await rig(signedIn: false);
      final store = r.store;
      store.update((v) => v.appended(node(key, 'Hill')));
      store.update(
        (v) => v.appended(
          const AtlasPin.observer(observerId: obsId, name: 'Roof'),
        ),
      );
      store.update((v) => v.appended(node(otherKey, 'Ridge')));
      store.update((v) => v.copyWith(range: AtlasRange.threeDays));
      store.update((v) {
        final pins = [...v.pins];
        pins.insert(0, pins.removeAt(2));
        return v.copyWith(pins: pins);
      });
      store.update(
        (v) => v.copyWith(
          pins: [
            for (final p in v.pins)
              if (p.key != key) p,
          ],
        ),
      );
      await store.idle;
      expect(
        r.prefs.atlasFor(server),
        '{"version":2,"range":"3d","pins":['
        '{"kind":"node","id":"$nodeId","publicKey":"$otherKey","name":"Ridge"},'
        '{"kind":"observer","observerId":"$obsId","name":"Roof"}]}',
      );
      expect(r.fake.requests, isEmpty);
      expect(store.notice, isNull);
      expect(store.signedIn, false);
    });

    test('a relink still writes locally', () async {
      final r = await rig(signedIn: false, local: [node(key)]);
      r.store.relink(
        (v) => v.copyWith(
          pins: [
            v.pins.single.relinked(
              otherKey.substring(0, 8) + nodeId.substring(8),
              null,
            ),
          ],
        ),
      );
      expect(
        cachedPins(r.prefs).single['id'],
        startsWith(otherKey.substring(0, 8)),
      );
    });

    test('a signed-out account makes no request', () async {
      final r = await rig(signedIn: false, local: [node(key)]);
      r.store.update((v) => v.copyWith(range: AtlasRange.threeDays));
      await r.store.idle;
      expect(r.fake.requests, isEmpty);
    });
  });

  group('loading', () {
    test('adopts the server collection and caches it', () async {
      final fake = FakeServer()
        ..revision = 5
        ..range = '3d'
        ..pins = [serverNode(key, 'Hill'), serverNode(otherKey, 'Ridge')];
      final r = await rig(fake: fake, local: const []);
      await r.store.idle;
      expect([for (final p in r.store.saved.pins) p.name], ['Hill', 'Ridge']);
      expect(r.store.saved.range, AtlasRange.threeDays);
      expect(cachedPins(r.prefs).length, 2);
      expect(fake.puts, isEmpty);
      expect(r.prefs.atlasSyncedFor(server, 'u1'), true);
    });

    test('shows the cache until the server answers', () async {
      final r = await rig(local: [node(key, 'Cached')]);
      expect(r.store.saved.pins.single.name, 'Cached');
      await r.store.idle;
    });

    test('a failed load keeps the cache and sends nothing', () async {
      final fake = FakeServer()..offline = true;
      final r = await rig(fake: fake, local: [node(key, 'Cached')]);
      await r.store.idle;
      expect(r.store.saved.pins.single.name, 'Cached');
      expect(fake.puts, isEmpty);
      expect(r.prefs.atlasSyncedFor(server, 'u1'), false);
    });

    test('a later load picks up another device\'s change', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [serverNode(key)];
      final r = await rig(fake: fake, marked: true);
      await r.store.idle;
      fake
        ..revision = 2
        ..pins = [serverNode(key), serverNode(otherKey, 'Ridge')];
      await r.store.sync();
      expect(r.store.saved.pins.length, 2);
    });

    test('a node pin the server could not resolve is kept', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [
          {'kind': 'node', 'publicKey': key, 'id': null, 'name': 'Gone'},
        ];
      final r = await rig(fake: fake);
      await r.store.idle;
      expect(r.store.saved.pins.single.id, nilId);
    });
  });

  group('first sign-in', () {
    test('uploads the local Atlas to an empty server, once', () async {
      final fake = FakeServer();
      final r = await rig(
        fake: fake,
        local: [node(key), node(otherKey, 'Ridge')],
        range: AtlasRange.threeDays,
      );
      await r.store.idle;
      expect(fake.puts.length, 1);
      final body = jsonDecode(fake.puts.single.body) as Map;
      expect(body['baseRevision'], 0);
      expect(body['range'], '3d');
      expect((body['pins'] as List).length, 2);
      expect(fake.revision, 1);
      expect(r.prefs.atlasSyncedFor(server, 'u1'), true);
      expect(r.store.notice, isNull);
      await r.store.sync();
      expect(fake.puts.length, 1);
    });

    test('merges: server pins first, then local ones not there', () async {
      final fake = FakeServer()
        ..revision = 2
        ..pins = [serverNode(key, 'S1'), serverNode(otherKey, 'S2')];
      final r = await rig(
        fake: fake,
        local: [node(otherKey, 'L1'), node(keyN(9), 'L2')],
      );
      await r.store.idle;
      expect([for (final p in r.store.saved.pins) p.name], ['S1', 'S2', 'L2']);
      final body = jsonDecode(fake.puts.single.body) as Map;
      expect(body['baseRevision'], 2);
      expect(fake.pins.length, 3);
      expect(r.prefs.atlasSyncedFor(server, 'u1'), true);
    });

    test('says how many local cards did not fit', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [for (var i = 0; i < 11; i++) serverNode(keyN(i), 'S$i')];
      final r = await rig(
        fake: fake,
        local: [for (var i = 20; i < 23; i++) node(keyN(i), 'L$i')],
      );
      await r.store.idle;
      expect(r.store.saved.pins.length, 12);
      expect(r.store.notice?.kind, AtlasNoticeKind.overflow);
      expect(r.store.notice?.count, 2);
    });

    test('only the server has pins: no upload', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [serverNode(key)];
      final r = await rig(fake: fake);
      await r.store.idle;
      expect(fake.puts, isEmpty);
      expect(r.prefs.atlasSyncedFor(server, 'u1'), true);
    });

    test('after the marker is set the server wins over local pins', () async {
      final fake = FakeServer()
        ..revision = 3
        ..pins = [serverNode(key, 'S1')];
      final r = await rig(
        fake: fake,
        local: [node(otherKey, 'L1')],
        marked: true,
      );
      await r.store.idle;
      expect([for (final p in r.store.saved.pins) p.name], ['S1']);
      expect(fake.puts, isEmpty);
    });

    test('a failed upload leaves the marker unset for next time', () async {
      final fake = FakeServer()..offline = true;
      final r = await rig(fake: fake, local: [node(key)]);
      await r.store.idle;
      expect(r.prefs.atlasSyncedFor(server, 'u1'), false);
      expect(r.store.saved.pins.single.publicKey, key);
      fake.offline = false;
      await r.store.sync();
      expect(fake.puts.length, 1);
      expect(r.prefs.atlasSyncedFor(server, 'u1'), true);
    });

    test('signing in after the store exists runs the merge', () async {
      final fake = FakeServer();
      final r = await rig(fake: fake, local: [node(key)], signedIn: false);
      unawaited(r.store.idle);
      r.account.adopt({'id': 'u1'});
      await r.store.idle;
      expect(fake.puts.length, 1);
    });
  });

  group('writes', () {
    test(
      'a change sends one PUT with the last revision and the whole collection',
      () async {
        final fake = FakeServer()
          ..revision = 4
          ..pins = [serverNode(key)];
        final r = await rig(fake: fake, marked: true);
        await r.store.idle;
        r.store.update((v) => v.appended(node(otherKey, 'Ridge')));
        expect(r.store.saved.pins.length, 2);
        await r.store.idle;
        final body = jsonDecode(fake.puts.single.body) as Map;
        expect(body['baseRevision'], 4);
        expect((body['pins'] as List).map((p) => (p as Map)['publicKey']), [
          key,
          otherKey,
        ]);
        expect(fake.revision, 5);
        expect(cachedPins(r.prefs).length, 2);
      },
    );

    test('writes go one at a time, each with the latest revision', () async {
      final fake = FakeServer()
        ..revision = 4
        ..pins = [serverNode(key)];
      final r = await rig(fake: fake, marked: true);
      await r.store.idle;
      fake.hold = Completer();
      r.store.update((v) => v.appended(node(otherKey, 'Ridge')));
      r.store.update((v) => v.copyWith(range: AtlasRange.threeDays));
      r.store.update((v) => v.appended(node(keyN(9), 'Third')));
      await Future<void>.delayed(Duration.zero);
      expect(fake.puts.length, 1);
      fake.hold!.complete();
      await r.store.idle;
      expect(fake.puts.length, 2);
      final last = jsonDecode(fake.puts.last.body) as Map;
      expect(last['baseRevision'], 5);
      expect(last['range'], '3d');
      expect((last['pins'] as List).length, 3);
      expect(fake.revision, 6);
      expect(r.store.notice, isNull);
    });

    test(
      'a conflict adopts the server copy, drops the change, notes it',
      () async {
        final fake = FakeServer()
          ..revision = 4
          ..pins = [serverNode(key)];
        final r = await rig(fake: fake, marked: true);
        await r.store.idle;
        fake
          ..revision = 5
          ..pins = [serverNode(key), serverNode(otherKey, 'Elsewhere')];
        r.store.update((v) => v.appended(node(keyN(9), 'Mine')));
        await r.store.idle;
        expect(
          [for (final p in r.store.saved.pins) p.name],
          ['Hill', 'Elsewhere'],
        );
        expect(r.store.notice?.kind, AtlasNoticeKind.conflict);
        expect(fake.puts.length, 1);
        expect(cachedPins(r.prefs).length, 2);
        // The next change carries the adopted revision and clears the line.
        r.store.update((v) => v.copyWith(range: AtlasRange.threeDays));
        expect(r.store.notice, isNull);
        await r.store.idle;
        expect(jsonDecode(fake.puts.last.body)['baseRevision'], 5);
      },
    );

    test(
      'a failed write keeps the change and the next one resends it all',
      () async {
        final fake = FakeServer()
          ..revision = 1
          ..pins = [serverNode(key)];
        final r = await rig(fake: fake, marked: true);
        await r.store.idle;
        fake.offline = true;
        r.store.update((v) => v.appended(node(otherKey, 'Ridge')));
        await r.store.idle;
        expect(r.store.notice?.kind, AtlasNoticeKind.failed);
        expect(r.store.saved.pins.length, 2);
        fake.offline = false;
        r.store.update((v) => v.copyWith(range: AtlasRange.threeDays));
        await r.store.idle;
        expect(r.store.notice, isNull);
        expect(fake.pins.length, 2);
        expect(fake.range, '3d');
      },
    );

    test('an observer pin goes out by id; a stand-in by key', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [
          {
            'kind': 'observer',
            'observerPublicKey': obsKey,
            'observerId': null,
            'name': 'Roof',
          },
        ];
      final r = await rig(fake: fake, marked: true);
      await r.store.idle;
      r.store.update(
        (v) => v.appended(
          const AtlasPin.observer(observerId: obsId, name: 'Other'),
        ),
      );
      await r.store.idle;
      final pins = jsonDecode(fake.puts.single.body)['pins'] as List;
      expect(pins[0], {
        'kind': 'observer',
        'observerPublicKey': obsKey,
        'name': 'Roof',
      });
      expect(pins[1], {
        'kind': 'observer',
        'observerId': obsId,
        'name': 'Other',
      });
    });

    test('a change made before the first load is sent after it', () async {
      final fake = FakeServer()
        ..revision = 2
        ..pins = [serverNode(key)];
      final r = await rig(fake: fake, marked: true);
      r.store.update((v) => v.appended(node(otherKey, 'Ridge')));
      await r.store.idle;
      expect(fake.puts.length, 1);
      expect(jsonDecode(fake.puts.single.body)['baseRevision'], 2);
    });

    test('a change made while the first load runs lands on the loaded copy, in one write', () async {
      final fake = FakeServer()
        ..revision = 2
        ..pins = [serverNode(key)]
        ..holdGet = Completer();
      final r = await rig(fake: fake, marked: true, owner: 'u1');
      r.store.update((v) => v.appended(node(otherKey, 'Ridge')));
      expect(fake.puts, isEmpty);
      fake.holdGet!.complete();
      await r.store.idle;
      expect(fake.puts.length, 1);
      final body = jsonDecode(fake.puts.single.body);
      expect(body['baseRevision'], 2);
      expect(
        [for (final p in body['pins'] as List) p['name']],
        ['Hill', 'Ridge'],
      );
      expect(fake.revision, 3);
    });

    test('a held change goes on top of the first sign-in merge', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [serverNode(key)]
        ..holdGet = Completer();
      final r = await rig(fake: fake, local: [node(otherKey, 'Local')]);
      r.store.update((v) => v.appended(node(keyN(9), 'Mine')));
      fake.holdGet!.complete();
      await r.store.idle;
      expect(fake.puts.length, 1);
      expect(
        [
          for (final p in (jsonDecode(fake.puts.single.body)['pins'] as List))
            p['name'],
        ],
        ['Hill', 'Local', 'Mine'],
      );
      expect(r.prefs.atlasSyncedFor(server, 'u1'), true);
    });

    test('a held change is not lost when the first load fails', () async {
      final fake = FakeServer()..offline = true;
      final r = await rig(fake: fake, marked: true, owner: 'u1', local: []);
      r.store.update((v) => v.appended(node(otherKey, 'Ridge')));
      await r.store.idle;
      expect(r.store.notice?.kind, AtlasNoticeKind.failed);
      fake.offline = false;
      fake.revision = 3;
      r.store.update((v) => v.copyWith(range: AtlasRange.threeDays));
      await r.store.idle;
      expect(fake.puts.length, 1);
      expect(
        [
          for (final p in (jsonDecode(fake.puts.single.body)['pins'] as List))
            p['name'],
        ],
        ['Ridge'],
      );
      expect(fake.range, '3d');
    });
  });

  group('another account on the same device', () {
    Future<Rig> aSynced(FakeServer fake) async {
      fake
        ..revision = 1
        ..pins = [serverNode(key, 'A pin')];
      final r = await rig(fake: fake);
      await r.store.idle;
      return r;
    }

    test('a new user gets the server copy, never the previous one', () async {
      final fake = FakeServer();
      final r = await aSynced(fake);
      expect(r.prefs.atlasOwnerFor(server), 'u1');
      r.account.adopt(null);
      fake
        ..revision = 7
        ..pins = [serverNode(otherKey, 'B pin')];
      final before = fake.requests.length;
      r.account.adopt({'id': 'u2', 'username': 'valley'});
      await r.store.idle;
      expect([for (final p in r.store.saved.pins) p.name], ['B pin']);
      expect(fake.puts, isEmpty);
      expect(
        [for (final q in fake.requests.skip(before)) q.body].join(),
        isNot(contains(key)),
      );
      expect(fake.revision, 7);
      expect(r.prefs.atlasOwnerFor(server), 'u2');
      expect(r.prefs.atlasSyncedFor(server, 'u2'), true);
    });

    test('a new user with an empty server copy uploads nothing', () async {
      final fake = FakeServer();
      final r = await aSynced(fake);
      r.account.adopt(null);
      fake
        ..revision = 0
        ..pins = [];
      r.account.adopt({'id': 'u2'});
      await r.store.idle;
      expect(r.store.saved.pins, isEmpty);
      expect(fake.puts, isEmpty);
    });

    test('the first user signing back in still works', () async {
      final fake = FakeServer();
      final r = await aSynced(fake);
      r.account.adopt(null);
      fake.pins = [serverNode(otherKey, 'B pin')];
      r.account.adopt({'id': 'u2'});
      await r.store.idle;
      r.account.adopt(null);
      fake.pins = [serverNode(key, 'A pin')];
      r.account.adopt({'id': 'u1'});
      await r.store.idle;
      expect([for (final p in r.store.saved.pins) p.name], ['A pin']);
      expect(fake.puts, isEmpty);
      expect(r.prefs.atlasOwnerFor(server), 'u1');
    });

    test('signed-out edits keep the owner', () async {
      final r = await aSynced(FakeServer());
      r.account.adopt(null);
      r.store.update((v) => v.appended(node(otherKey, 'Local')));
      expect(r.prefs.atlasOwnerFor(server), 'u1');
    });

    test('a held change by the new user goes on the server copy', () async {
      final fake = FakeServer();
      final r = await aSynced(fake);
      r.account.adopt(null);
      fake
        ..revision = 7
        ..pins = [serverNode(otherKey, 'B pin')]
        ..holdGet = Completer();
      r.account.adopt({'id': 'u2'});
      r.store.update((v) => v.appended(node(keyN(9), 'Mine')));
      fake.holdGet!.complete();
      await r.store.idle;
      expect(
        [
          for (final p in (jsonDecode(fake.puts.single.body)['pins'] as List))
            p['name'],
        ],
        ['B pin', 'Mine'],
      );
    });

    test('a never-synced local Atlas still merges', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [serverNode(key)];
      final r = await rig(fake: fake, local: [node(otherKey, 'Local')]);
      await r.store.idle;
      expect(fake.puts.length, 1);
      expect(r.store.saved.pins.length, 2);
      expect(r.prefs.atlasOwnerFor(server), 'u1');
    });

    test('a local copy owned by the same user still merges', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [serverNode(key)];
      final r = await rig(
        fake: fake,
        local: [node(otherKey, 'Local')],
        owner: 'u1',
      );
      await r.store.idle;
      expect(fake.puts.length, 1);
      expect(r.store.saved.pins.length, 2);
    });
  });

  group('conflict answer', () {
    test('without the document the store refetches it', () async {
      final fake = FakeServer()
        ..revision = 4
        ..pins = [serverNode(key)];
      final r = await rig(fake: fake, marked: true, owner: 'u1');
      await r.store.idle;
      fake
        ..bareConflict = true
        ..revision = 5
        ..pins = [serverNode(key), serverNode(otherKey, 'Elsewhere')];
      final gets = fake.requests.where((q) => q.method == 'GET').length;
      r.store.update((v) => v.appended(node(keyN(9), 'Mine')));
      await r.store.idle;
      expect(
        [for (final p in r.store.saved.pins) p.name],
        ['Hill', 'Elsewhere'],
      );
      expect(fake.requests.where((q) => q.method == 'GET').length, gets + 1);
      expect(r.store.notice?.kind, AtlasNoticeKind.conflict);
    });
  });

  group('a failed write followed by a reload', () {
    test(
      'keeps the base revision of the edit, so the server answers 409',
      () async {
        final fake = FakeServer()
          ..revision = 4
          ..pins = [serverNode(key)];
        final r = await rig(fake: fake, marked: true, owner: 'u1');
        await r.store.idle;
        fake.offline = true;
        r.store.update((v) => v.appended(node(otherKey, 'Mine')));
        await r.store.idle;
        fake.offline = false;
        // Another device adds a pin at revision 5.
        fake
          ..revision = 5
          ..pins = [serverNode(key), serverNode(keyN(7), 'Elsewhere')];
        await r.store.sync();
        await r.store.idle;
        final bases = [
          for (final q in fake.puts)
            (jsonDecode(q.body) as Map)['baseRevision'],
        ];
        expect(bases, isNot(contains(5)));
        expect(fake.pins.length, 2);
        expect(
          [for (final p in r.store.saved.pins) p.name],
          ['Hill', 'Elsewhere'],
        );
        expect(r.store.notice?.kind, AtlasNoticeKind.conflict);
      },
    );
  });

  group('automatic rewrites', () {
    test('a relink changes the view only: no write, no request', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [serverNode(key)];
      final r = await rig(fake: fake, marked: true);
      await r.store.idle;
      final before = r.prefs.atlasFor(server);
      final requests = fake.requests.length;
      var notified = 0;
      r.store.addListener(() => notified++);
      r.store.relink(
        (v) => v.copyWith(pins: [v.pins.single.relinked(obsId, null)]),
      );
      await r.store.idle;
      expect(r.store.saved.pins.single.id, obsId);
      expect(notified, 1);
      expect(r.prefs.atlasFor(server), before);
      expect(fake.requests.length, requests);
    });

    test('a write adopts the stored resolution of the pins', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [serverNode(key)];
      final r = await rig(fake: fake, marked: true);
      await r.store.idle;
      r.store.relink(
        (v) => v.copyWith(pins: [v.pins.single.relinked(obsId, null)]),
      );
      r.store.update((v) => v.copyWith(range: AtlasRange.threeDays));
      await r.store.idle;
      expect(r.store.saved.pins.single.id, nodeId);
    });
  });

  group('sign out', () {
    test('keeps the collection and the marker, and stops sending', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [serverNode(key)];
      final r = await rig(fake: fake);
      await r.store.idle;
      r.account.adopt(null);
      expect(r.store.signedIn, false);
      expect(r.store.saved.pins.length, 1);
      expect(r.prefs.atlasSyncedFor(server, 'u1'), true);
      final count = fake.requests.length;
      r.store.update((v) => v.appended(node(otherKey, 'Local')));
      await r.store.idle;
      expect(fake.requests.length, count);
      expect(cachedPins(r.prefs).length, 2);
      // Signing back in does not merge again: the server wins.
      r.account.adopt({'id': 'u1'});
      await r.store.idle;
      expect(r.store.saved.pins.length, 1);
      expect(fake.puts, isEmpty);
    });
  });

  group('radios named by an alert', () {
    // Push data carries a public key, but the detail routes take ids.
    test('a node is found by key and answers its id', () async {
      final fake = FakeServer()
        ..revision = 1
        ..pins = [serverNode(key)];
      final r = await rig(fake: fake);
      await r.store.idle;
      expect(r.store.idForRadio('node', key.toUpperCase()), nodeId);
      expect(r.store.idForRadio('node', otherKey), isNull);
    });

    test(
      'an observer is found by key once the server Atlas has loaded',
      () async {
        final fake = FakeServer()
          ..revision = 1
          ..pins = [
            {
              'kind': 'observer',
              'observerPublicKey': obsKey,
              'observerId': obsId,
              'name': 'Roof',
            },
            {
              'kind': 'observer',
              'observerPublicKey': otherKey,
              'observerId': null,
              'name': 'Gone',
            },
          ];
        final r = await rig(fake: fake);
        expect(r.store.idForRadio('observer', obsKey), isNull);
        await r.store.idle;
        expect(r.store.idForRadio('observer', obsKey), obsId);
        // An observer the server could not resolve has nothing to open.
        expect(r.store.idForRadio('observer', otherKey), isNull);
      },
    );
  });
}
