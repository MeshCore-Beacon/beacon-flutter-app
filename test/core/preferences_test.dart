import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
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
}
