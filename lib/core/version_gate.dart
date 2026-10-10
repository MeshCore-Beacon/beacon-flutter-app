import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'api.dart';
import 'instance.dart';
import 'json.dart';

/// Where "Update BEACON" sends the user, by platform and by how the app was
/// installed (package_info_plus `installerStore`). Change links here only.
class StoreLinks {
  static const appleId = '6818921013';
  static final appStore = Uri.parse('https://apps.apple.com/app/id$appleId');
  static final testFlight = Uri.parse(
    'itms-beta://beta.itunes.apple.com/v1/app/$appleId',
  );
  static final play = Uri.parse(
    'https://play.google.com/store/apps/details?id=meshcorebeacon.app',
  );
  static final githubReleases = Uri.parse(
    'https://github.com/MeshCore-Beacon/beacon-flutter-app/releases/latest',
  );

  /// Play reports itself as com.android.vending (older devices:
  /// com.google.android.feedback). Anything else on Android, including no
  /// installer at all, is a sideloaded APK from the GitHub releases.
  static UpdateTarget resolve(TargetPlatform platform, String? installerStore) {
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
      return installerStore == 'com.apple.testflight'
          ? UpdateTarget(testFlight, 'Update in TestFlight')
          : UpdateTarget(appStore, 'Update BEACON');
    }
    const play = {'com.android.vending', 'com.google.android.feedback'};
    return play.contains(installerStore)
        ? UpdateTarget(StoreLinks.play, 'Update BEACON')
        : UpdateTarget(githubReleases, 'Download latest version');
  }
}

/// The update button's destination and its (untranslated) label.
class UpdateTarget {
  const UpdateTarget(this.uri, this.label);
  final Uri uri;
  final String label;
}

/// Parses plain "X.Y.Z" into numeric components, or null for anything else
/// (prefixes, suffixes, other lengths). Matches beacon-web's `isBelowVersion`.
List<int>? parseVersion(String? input) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(input ?? '');
  if (match == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
}

/// Numeric per-component comparison (0.10.0 > 0.9.0). Returns null when
/// either side is not plain X.Y.Z.
int? compareVersions(String a, String b) {
  final left = parseVersion(a), right = parseVersion(b);
  if (left == null || right == null) return null;
  for (var i = 0; i < 3; i++) {
    if (left[i] != right[i]) return left[i] < right[i] ? -1 : 1;
  }
  return 0;
}

/// The app's own version: Build.sh's APP_VERSION define without its `APP-`
/// prefix (`0.1.0` for prod, the epoch for dev/beta builds), else the
/// installed version for plain `flutter run`.
String? appVersionFrom(String define, String? installed) {
  if (define.isEmpty) return installed;
  return define.startsWith('APP-') ? define.substring(4) : define;
}

void _log(String message) {
  if (kDebugMode) debugPrint(message);
}

enum GateStatus { checking, allowed, blocked }

class GateResult {
  const GateResult(
    this.status, {
    this.minAppVersion,
    this.currentVersion,
    this.installerStore,
    this.checkedAt,
  });
  final GateStatus status;
  final String? minAppVersion, currentVersion;

  /// How the app was installed; only read for blocked results, where it picks
  /// the update button's destination.
  final String? installerStore;
  final DateTime? checkedAt;
}

/// Reads `GET /api/v1/info` for a server. Returns the decoded body, or null
/// when the server does not have the endpoint (404). Throws on network error.
typedef InfoFetcher = Future<Json?> Function(Uri base);

/// Holds the in-memory "does this server accept this app version" state per
/// server URL. Nothing is persisted; every check recomputes it.
class VersionGate extends ChangeNotifier {
  VersionGate({
    InfoFetcher? fetchInfo,
    Future<String?> Function()? appVersion,
    Future<String?> Function()? installerStore,
    this.timeout = const Duration(seconds: 6),
  }) : _fetchInfo = fetchInfo ?? apiFetcher(null),
       _appVersion = appVersion ?? platformVersion,
       _installerStore = installerStore ?? platformInstallerStore;

  final InfoFetcher _fetchInfo;
  final Future<String?> Function() _appVersion;
  final Future<String?> Function() _installerStore;
  final Duration timeout;
  final _results = <String, GateResult>{};
  final _inflight = <String, Future<GateResult>>{};
  Future<String?>? _version;

  static InfoFetcher apiFetcher(ApiClient Function(Uri)? factory) =>
      (base) async {
        final api = factory?.call(base) ?? ApiClient(base);
        try {
          return object(await api.get('/info'));
        } on ApiException catch (e) {
          if (e.status == 404) return null;
          rethrow;
        } finally {
          api.close();
        }
      };

  /// See [appVersionFrom]. The installed versionName is X.Y.Z even on betas,
  /// so the define is what tells a beta apart.
  static Future<String?> platformVersion() async {
    const define = String.fromEnvironment('APP_VERSION');
    if (define.isNotEmpty) return appVersionFrom(define, null);
    return (await PackageInfo.fromPlatform()).version;
  }

  /// e.g. com.apple.testflight, com.apple, com.android.vending, or null.
  static Future<String?> platformInstallerStore() async =>
      (await PackageInfo.fromPlatform()).installerStore;

  GateResult resultFor(String url) =>
      _results[url] ?? const GateResult(GateStatus.checking);

  /// Re-checks [server]. With [keepCurrent] the last known state stays visible
  /// while the request is in flight (used on resume so an allowed server keeps
  /// its screens). A result younger than [reuseWithin] is returned as is.
  Future<GateResult> check(
    BeaconInstance server, {
    bool keepCurrent = false,
    Duration reuseWithin = Duration.zero,
  }) async {
    final url = server.url;
    final previous = _results[url];
    if (previous?.checkedAt != null &&
        DateTime.now().difference(previous!.checkedAt!) < reuseWithin) {
      return previous;
    }
    if (!keepCurrent || previous == null) {
      _set(url, const GateResult(GateStatus.checking));
    }
    // Callers that arrive while a check is running share it.
    return _inflight[url] ??= _run(server).whenComplete(() {
      _inflight.remove(url);
    });
  }

  Future<GateResult> _run(BeaconInstance server) async {
    final result = await _evaluate(server.base);
    _set(server.url, result);
    return result;
  }

  void _set(String url, GateResult result) {
    final old = _results[url];
    _results[url] = result;
    if (old?.status != result.status ||
        old?.minAppVersion != result.minAppVersion ||
        old?.currentVersion != result.currentVersion) {
      notifyListeners();
    }
  }

  Future<GateResult> _evaluate(Uri base) async {
    GateResult allowed() =>
        GateResult(GateStatus.allowed, checkedAt: DateTime.now());
    Json? info;
    try {
      info = await _fetchInfo(base).timeout(timeout);
    } catch (e) {
      // Fail open: the normal screens surface connection errors themselves.
      _log('Version check for $base failed: $e');
      return allowed();
    }
    final minimum = info?['minAppVersion'];
    if (minimum == null) return allowed();
    if (minimum is! String || parseVersion(minimum) == null) {
      _log('Ignoring malformed minAppVersion from $base: $minimum');
      return allowed();
    }
    String? current;
    try {
      current = await (_version ??= _appVersion());
    } catch (e) {
      _version = null;
      _log('Could not read the app version: $e');
    }
    if (current == null) {
      _log('Unknown app version; not enforcing $minimum.');
      return allowed();
    }
    // Betas (epoch versions) are deliberately never blocked, as on the web.
    if (parseVersion(current) == null) {
      _log('Beta build "$current"; not enforcing $minimum.');
      return allowed();
    }
    final order = compareVersions(current, minimum)!;
    String? installer;
    if (order < 0) {
      try {
        installer = await _installerStore();
      } catch (e) {
        _log('Could not read the install source: $e');
      }
    }
    return GateResult(
      order < 0 ? GateStatus.blocked : GateStatus.allowed,
      minAppVersion: minimum,
      currentVersion: current,
      installerStore: installer,
      checkedAt: DateTime.now(),
    );
  }
}

/// Makes the app's [VersionGate] reachable from routes such as the server
/// editor sheet.
class VersionGateScope extends InheritedNotifier<VersionGate> {
  const VersionGateScope({
    super.key,
    required VersionGate gate,
    required super.child,
  }) : super(notifier: gate);
  static VersionGate? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<VersionGateScope>()?.notifier;
}
