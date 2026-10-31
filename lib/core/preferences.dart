import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'instance.dart';
import 'json.dart';

class Preferences extends ChangeNotifier {
  Preferences._(this._store);
  final SharedPreferences _store;
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

  static Future<Preferences> load() async {
    final result = Preferences._(await SharedPreferences.getInstance());
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
    }
    servers.removeWhere((e) => e.url == server.url);
    servers.add(server);
    _activeUrl = server.url;
    await _persist();
  }

  Future<void> selectServer(String url) async {
    if (!servers.any((e) => e.url == url)) return;
    _activeUrl = url;
    await _persist();
  }

  Future<void> removeServer(String url) async {
    servers.removeWhere((e) => e.url == url);
    if (_activeUrl == url) {
      _activeUrl = servers.isEmpty ? null : servers.first.url;
    }
    await _store.remove('beacon.region.$url');
    await _persist();
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
}
