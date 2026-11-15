import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  group('Atlas first sign-in marker', () {
    const home = 'https://home.invalid', moved = 'https://moved.invalid';
    const longer = 'https://home.invalid.au';

    test('is kept per server and user', () async {
      final prefs = await Preferences.load();
      expect(prefs.atlasSyncedFor(home, 'u1'), false);
      await prefs.markAtlasSynced(home, 'u1');
      expect(prefs.atlasSyncedFor(home, 'u1'), true);
      expect(prefs.atlasSyncedFor(home, 'u2'), false);
      expect(prefs.atlasSyncedFor(moved, 'u1'), false);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          'beacon.atlas.synced.$home.u1',
        ),
        true,
      );
    });

    test(
      'moves with an edited server and leaves other servers alone',
      () async {
        SharedPreferences.setMockInitialValues({
          'beacon.atlas.synced.$home.u1': true,
          'beacon.atlas.synced.$home.u2': true,
          'beacon.atlas.synced.$longer.u1': true,
        });
        final prefs = await Preferences.load();
        await prefs.saveServer(
          BeaconInstance.create('Home', moved),
          replacing: home,
        );
        expect(prefs.atlasSyncedFor(moved, 'u1'), true);
        expect(prefs.atlasSyncedFor(moved, 'u2'), true);
        expect(prefs.atlasSyncedFor(home, 'u1'), false);
        expect(prefs.atlasSyncedFor(longer, 'u1'), true);
      },
    );

    test('is deleted with the server', () async {
      SharedPreferences.setMockInitialValues({
        'beacon.atlas.synced.$home.u1': true,
        'beacon.atlas.synced.$longer.u1': true,
      });
      final prefs = await Preferences.load();
      await prefs.removeServer(home);
      expect(prefs.atlasSyncedFor(home, 'u1'), false);
      expect(prefs.atlasSyncedFor(longer, 'u1'), true);
    });
  });

  test('persists duplicate-safe servers and active deletion', () async {
    final prefs = await Preferences.load();
    await prefs.saveServer(
      BeaconInstance.create('Dev', 'https://beacon.example.com/'),
    );
    await prefs.saveServer(
      BeaconInstance.create('Renamed', 'https://beacon.example.com'),
    );
    expect(prefs.servers.length, 1);
    await prefs.saveServer(
      BeaconInstance.create('Other', 'https://other.test'),
    );
    expect(prefs.active!.name, 'Other');
    await prefs.removeServer(prefs.active!.url);
    expect(prefs.active!.name, 'Renamed');
    await prefs.setTheme('arctic');
    await prefs.setLanguage('fr');
    final restored = await Preferences.load();
    expect(restored.active!.name, 'Renamed');
    expect(restored.themeId, 'arctic');
    expect(restored.language, 'fr');
    await restored.removeServer(restored.active!.url);
    expect(restored.active, isNull);
  });
  test('bad persisted preferences do not prevent launch', () async {
    SharedPreferences.setMockInitialValues({'beacon.servers': '{bad json'});
    expect((await Preferences.load()).servers, isEmpty);
  });
  test('removing a server drops its saved region', () async {
    final prefs = await Preferences.load();
    final server = BeaconInstance.create('Dev', 'https://beacon.example.com');
    await prefs.saveServer(server);
    await prefs.saveRegion(server.url, {'iatas': 'YOW'});
    await prefs.removeServer(server.url);
    final store = await SharedPreferences.getInstance();
    expect(store.getString('beacon.region.${server.url}'), isNull);
  });
  test('changing a server URL moves its saved region', () async {
    final prefs = await Preferences.load();
    final old = BeaconInstance.create('Dev', 'https://old.example.com');
    await prefs.saveServer(old);
    await prefs.saveRegion(old.url, {'iatas': 'YOW'});
    final renamed = BeaconInstance.create('Dev', 'https://new.example.com');
    await prefs.saveServer(renamed, replacing: old.url);
    final store = await SharedPreferences.getInstance();
    expect(store.getString('beacon.region.${old.url}'), isNull);
    expect(prefs.regionFor(renamed.url), {'iatas': 'YOW'});
  });
  test('changing a server URL moves its token, removing deletes it', () async {
    final tokens = MemoryTokenStore();
    final prefs = await Preferences.load(tokens: tokens);
    final old = BeaconInstance.create('Dev', 'https://old.example.com');
    await prefs.saveServer(old);
    await tokens.write(old.url, 'abc');
    final renamed = BeaconInstance.create('Dev', 'https://new.example.com');
    await prefs.saveServer(renamed, replacing: old.url);
    expect(await tokens.read(old.url), isNull);
    expect(await tokens.read(renamed.url), 'abc');
    await prefs.removeServer(renamed.url);
    expect(await tokens.read(renamed.url), isNull);
  });
  test('a failing token store does not block server edits', () async {
    final prefs = await Preferences.load(tokens: _ThrowingStore());
    final old = BeaconInstance.create('Dev', 'https://old.example.com');
    await prefs.saveServer(old);
    final next = BeaconInstance.create('Dev', 'https://new.example.com');
    await prefs.saveServer(next, replacing: old.url);
    await prefs.removeServer(next.url);
    expect(prefs.servers, isEmpty);
  });
}

class _ThrowingStore extends MemoryTokenStore {
  @override
  Future<void> move(String fromUrl, String toUrl) => throw StateError('x');
  @override
  Future<void> delete(String serverUrl) => throw StateError('x');
}
