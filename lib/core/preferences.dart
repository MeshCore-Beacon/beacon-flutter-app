import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'instance.dart';
import 'json.dart';
import 'token_store.dart';

class Preferences extends ChangeNotifier {
  Preferences._(this._store, this._tokens);
  final SharedPreferences _store;
  final TokenStore? _tokens;
  final List<BeaconInstance> servers = [];
  String? _activeUrl;
  String themeId = 'neutral-blue';
  String language = 'en';
  BeaconInstance? get active {
    for (final server in servers) {
      if (server.url == _activeUrl) return server;
    }
    return servers.isEmpty ? null : servers.first;
  }

  static Future<Preferences> load({TokenStore? tokens}) async {
    final result = Preferences._(await SharedPreferences.getInstance(), tokens);
    try {
      final values = jsonDecode(
        result._store.getString('beacon.servers') ?? '[]',
      );
      for (final item in rows(values)) {
        try {
          final server = BeaconInstance.fromJson(item);
          if (!result.servers.any((e) => e.url == server.url)) {
            result.servers.add(server);
          }
        } catch (_) {
          /* Ignore an invalid saved entry without losing the others. */
        }
      }
    } catch (_) {
      /* A damaged preference must not prevent launch. */
    }
    result._activeUrl = result._store.getString('beacon.active');
    result.themeId = result._store.getString('beacon.theme') ?? 'neutral-blue';
    result.language = result._store.getString('beacon.language') ?? 'en';
    return result;
  }

  Future<void> _persist() async {
    await _store.setString(
      'beacon.servers',
      jsonEncode(servers.map((e) => e.toJson()).toList()),
    );
    await _store.setString('beacon.active', active?.url ?? '');
    notifyListeners();
  }

  Future<void> saveServer(BeaconInstance server, {String? replacing}) async {
    if (replacing != null) {
      servers.removeWhere((e) => e.url == replacing);
      // An edited URL is usually the same server (scheme, port, path fix), so
      // keep the user's region unless the new URL already has one.
      final region = _store.getString('beacon.region.$replacing');
      if (replacing != server.url && region != null) {
        if (!_store.containsKey('beacon.region.${server.url}')) {
          await _store.setString('beacon.region.${server.url}', region);
        }
        await _store.remove('beacon.region.$replacing');
      }
      // The saved Atlas follows the server the same way.
      final atlas = _store.getString('beacon.atlas.$replacing');
      if (replacing != server.url && atlas != null) {
        if (!_store.containsKey('beacon.atlas.${server.url}')) {
          await _store.setString('beacon.atlas.${server.url}', atlas);
        }
        await _store.remove('beacon.atlas.$replacing');
      }
      if (replacing != server.url) {
        await _moveAtlasMarkers(replacing, server.url);
        final owner = _store.getString('beacon.atlas.owner.$replacing');
        if (owner != null) {
          if (!_store.containsKey('beacon.atlas.owner.${server.url}')) {
            await _store.setString('beacon.atlas.owner.${server.url}', owner);
          }
          await _store.remove('beacon.atlas.owner.$replacing');
        }
      }
      // The sign-in token follows too; a keystore failure must not block the edit.
      if (replacing != server.url) {
        final name = _store.getString('$_accountPrefix$replacing');
        if (name != null) {
          if (!_store.containsKey('$_accountPrefix${server.url}')) {
            await _store.setString('$_accountPrefix${server.url}', name);
          }
          await _store.remove('$_accountPrefix$replacing');
        }
        try {
          await _tokens?.move(replacing, server.url);
        } catch (_) {}
      }
    }
    servers.removeWhere((e) => e.url == server.url);
    servers.add(server);
    _activeUrl = server.url;
    await _persist();
  }

  static const _syncedPrefix = 'beacon.atlas.synced.';

  /// Marker keys are `<prefix><url>.<userId>`; a user id has no dot, so the
  /// last dot ends the URL and `https://a.com` never matches `https://a.com.au`.
  List<(String key, String user)> _markersOf(String url) => [
    for (final key in _store.getKeys())
      if (key.startsWith(_syncedPrefix) && key.lastIndexOf('.') > 0)
        if (key.substring(_syncedPrefix.length, key.lastIndexOf('.')) == url)
          (key, key.substring(key.lastIndexOf('.') + 1)),
  ];

  /// Carries the markers to an edited URL, or drops them when [to] is null.
  Future<void> _moveAtlasMarkers(String from, String? to) async {
    for (final (key, user) in _markersOf(from)) {
      if (to != null && !_store.containsKey('$_syncedPrefix$to.$user')) {
        await _store.setBool('$_syncedPrefix$to.$user', true);
      }
      await _store.remove(key);
    }
  }

  /// Whether this user's first sign-in merge already ran on this server.
  bool atlasSyncedFor(String url, String userId) =>
      _store.getBool('$_syncedPrefix$url.$userId') ?? false;

  Future<void> markAtlasSynced(String url, String userId) =>
      _store.setBool('$_syncedPrefix$url.$userId', true);

  /// The user the local Atlas copy was last synced to, so another account
  /// signing in on this device never uploads it.
  String? atlasOwnerFor(String url) =>
      _store.getString('beacon.atlas.owner.$url');

  Future<void> setAtlasOwner(String url, String userId) =>
      _store.setString('beacon.atlas.owner.$url', userId);

  Future<void> selectServer(String url) async {
    if (!servers.any((e) => e.url == url)) return;
    _activeUrl = url;
    await _persist();
  }

  /// Runs before a server's data and token go; a failure never blocks removal.
  Future<void> Function(String url)? beforeRemove;

  Future<void> removeServer(String url) async {
    try {
      await beforeRemove?.call(url);
    } catch (_) {}
    servers.removeWhere((e) => e.url == url);
    if (_activeUrl == url) {
      _activeUrl = servers.isEmpty ? null : servers.first.url;
    }
    await _store.remove('beacon.region.$url');
    await _store.remove('beacon.atlas.$url');
    await _moveAtlasMarkers(url, null);
    await _store.remove('beacon.atlas.owner.$url');
    await _store.remove('$_accountPrefix$url');
    try {
      await _tokens?.delete(url);
    } catch (_) {}
    await _persist();
  }

  static const _accountPrefix = 'beacon.account.';

  /// The username last signed in on [url], so Settings can name the account
  /// of a server that is not open. Only a label: the token decides sign-in.
  String? accountNameFor(String url) => _store.getString('$_accountPrefix$url');

  Future<void> setAccountName(String url, String? name) async {
    if (name == accountNameFor(url)) return;
    if (name == null || name.isEmpty) {
      await _store.remove('$_accountPrefix$url');
    } else {
      await _store.setString('$_accountPrefix$url', name);
    }
    notifyListeners();
  }

  /// The servers this phone holds a sign-in token for.
  Future<Set<String>> signedInServers() async {
    final result = <String>{};
    for (final server in servers) {
      try {
        if (await _tokens?.read(server.url) != null) result.add(server.url);
      } catch (_) {}
    }
    return result;
  }

  Future<void> setTheme(String id) async {
    themeId = id;
    await _store.setString('beacon.theme', id);
    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    language = code;
    await _store.setString('beacon.language', code);
    notifyListeners();
  }

  Map<String, dynamic> _savedRegion(String url) {
    try {
      return object(jsonDecode(_store.getString('beacon.region.$url') ?? '{}'));
    } catch (_) {
      return {};
    }
  }

  /// Query params for the server's region filter.
  Map<String, dynamic> regionFor(String url) =>
      _savedRegion(url)..remove('selection');

  /// The picker's raw selection, saved with the params; null for saves from
  /// before the picker kept regions.
  Map<String, dynamic>? regionSelectionFor(String url) {
    final saved = _savedRegion(url)['selection'];
    return saved is Map<String, dynamic> ? saved : null;
  }

  Future<void> saveRegion(
    String url,
    Map<String, dynamic> params, {
    Map<String, dynamic>? selection,
  }) async {
    await _store.setString(
      'beacon.region.$url',
      jsonEncode({...params, 'selection': ?selection}),
    );
  }

  /// Bumped on every Atlas save, so an open Atlas tab picks up an import.
  final atlasRevision = ValueNotifier<int>(0);

  /// The saved Atlas cards for one server, as stored.
  String? atlasFor(String url) => _store.getString('beacon.atlas.$url');

  /// False when the device refused the write.
  Future<bool> saveAtlas(String url, String raw) async {
    var saved = false;
    try {
      final write = _store.setString('beacon.atlas.$url', raw);
      atlasRevision.value++;
      saved = await write;
    } catch (_) {
      atlasRevision.value++;
    }
    return saved;
  }
}
