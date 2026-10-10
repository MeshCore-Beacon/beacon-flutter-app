import 'package:beacon/core/instance.dart';
import 'package:beacon/core/version_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('compareVersions', () {
    test('equal versions compare as zero', () {
      expect(compareVersions('0.1.1', '0.1.1'), 0);
    });
    test('older and newer', () {
      expect(compareVersions('0.1.0', '0.1.1'), -1);
      expect(compareVersions('0.2.0', '0.1.9'), 1);
      expect(compareVersions('1.0.0', '0.9.9'), 1);
    });
    test('components compare numerically, not as text', () {
      expect(compareVersions('0.10.0', '0.9.0'), 1);
      expect(compareVersions('0.9.10', '0.9.9'), 1);
      expect(compareVersions('2.0.0', '10.0.0'), -1);
    });
    test('anything but plain X.Y.Z returns null, like the web gate', () {
      for (final v in [
        'APP-1759700000',
        '1760054400',
        '1.0',
        '1.0.0.0',
        'v0.1.0',
        '0.1.1+42',
        '0.1.1-beta',
        ' 0.1.0',
        'latest',
        '',
        '0.1.x',
      ]) {
        expect(parseVersion(v), isNull, reason: v);
        expect(compareVersions(v, '0.1.0'), isNull, reason: v);
        expect(compareVersions('0.1.0', v), isNull, reason: v);
      }
    });
  });

  group('appVersionFrom', () {
    test('prefers the APP_VERSION define without its APP- prefix', () {
      expect(appVersionFrom('APP-0.2.0', '0.1.0'), '0.2.0');
      expect(appVersionFrom('APP-1791597587', '0.1.0'), '1791597587');
    });
    test('falls back to the installed version without a define', () {
      expect(appVersionFrom('', '0.1.0'), '0.1.0');
      expect(appVersionFrom('', null), isNull);
    });
  });

  group('VersionGate', () {
    final server = BeaconInstance.create('Test', 'https://gate.test');
    VersionGate gate(Object? info, {String version = '0.1.0'}) => VersionGate(
      appVersion: () async => version,
      fetchInfo: (_) async {
        if (info is Exception) throw info;
        return info as Map<String, dynamic>?;
      },
    );

    test('blocks an older app and reports both versions', () async {
      final result = await gate({'minAppVersion': '0.1.1'}).check(server);
      expect(result.status, GateStatus.blocked);
      expect(result.minAppVersion, '0.1.1');
      expect(result.currentVersion, '0.1.0');
    });
    test('allows an equal or newer app', () async {
      expect(
        (await gate({'minAppVersion': '0.1.0'}).check(server)).status,
        GateStatus.allowed,
      );
      expect(
        (await gate({
          'minAppVersion': '0.9.0',
        }, version: '0.10.0').check(server)).status,
        GateStatus.allowed,
      );
    });
    test('no requirement, 404 and network errors fail open', () async {
      for (final info in [
        {'minAppVersion': null, 'serverVersion': '1.2.3'},
        null,
        http.ClientException('offline'),
      ]) {
        expect((await gate(info).check(server)).status, GateStatus.allowed);
      }
    });
    test('malformed minAppVersion or app version does not block', () async {
      expect(
        (await gate({'minAppVersion': 'soon'}).check(server)).status,
        GateStatus.allowed,
      );
      expect(
        (await gate({'minAppVersion': 3}).check(server)).status,
        GateStatus.allowed,
      );
      expect(
        (await gate({
          'minAppVersion': '0.1.1',
        }, version: 'APP-1759700000').check(server)).status,
        GateStatus.allowed,
      );
    });
    test('epoch beta builds are never blocked', () async {
      final result = await gate({
        'minAppVersion': '99.0.0',
      }, version: '1791597587').check(server);
      expect(result.status, GateStatus.allowed);
    });
    test('state starts as checking and is recomputed per check', () async {
      Object? info = {'minAppVersion': '0.2.0'};
      final gate = VersionGate(
        appVersion: () async => '0.1.0',
        fetchInfo: (_) async => info as Map<String, dynamic>?,
      );
      expect(gate.resultFor(server.url).status, GateStatus.checking);
      await gate.check(server);
      expect(gate.resultFor(server.url).status, GateStatus.blocked);
      info = {'minAppVersion': null};
      await gate.check(server);
      expect(gate.resultFor(server.url).status, GateStatus.allowed);
    });
  });

  group('StoreLinks.resolve', () {
    test('iOS TestFlight installs open TestFlight', () {
      final t = StoreLinks.resolve(TargetPlatform.iOS, 'com.apple.testflight');
      expect(t.uri, StoreLinks.testFlight);
      expect(t.label, 'Update in TestFlight');
    });
    test('iOS App Store, simulator and unknown open the App Store', () {
      for (final store in ['com.apple', 'com.apple.simulator', null]) {
        final t = StoreLinks.resolve(TargetPlatform.iOS, store);
        expect(t.uri, StoreLinks.appStore, reason: '$store');
        expect(t.label, 'Update BEACON');
      }
    });
    test('Android Play installs open the Play listing', () {
      for (final store in [
        'com.android.vending',
        'com.google.android.feedback',
      ]) {
        final t = StoreLinks.resolve(TargetPlatform.android, store);
        expect(t.uri, StoreLinks.play, reason: store);
        expect(t.label, 'Update BEACON');
      }
    });
    test('sideloaded Android APKs open the GitHub release', () {
      for (final store in [null, 'com.google.android.packageinstaller']) {
        final t = StoreLinks.resolve(TargetPlatform.android, store);
        expect(t.uri, StoreLinks.githubReleases, reason: '$store');
        expect(t.label, 'Download latest version');
      }
    });
  });

  group('install source', () {
    final server = BeaconInstance.create('Test', 'https://gate.test');
    VersionGate gate(String minimum, {required void Function() onRead}) =>
        VersionGate(
          appVersion: () async => '0.1.0',
          installerStore: () async {
            onRead();
            return 'com.apple.testflight';
          },
          fetchInfo: (_) async => {'minAppVersion': minimum},
        );

    test('is carried on blocked results', () async {
      var reads = 0;
      final result = await gate('0.2.0', onRead: () => reads++).check(server);
      expect(result.installerStore, 'com.apple.testflight');
      expect(reads, 1);
    });
    test('is not read when the server is allowed', () async {
      var reads = 0;
      final result = await gate('0.1.0', onRead: () => reads++).check(server);
      expect(result.status, GateStatus.allowed);
      expect(reads, 0);
    });
  });
}
