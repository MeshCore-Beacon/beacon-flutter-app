import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/account.dart';
import '../../core/auth_api.dart';
import '../../core/json.dart';
import '../../core/preferences.dart';
import 'atlas.dart';
import 'atlas_sync.dart';

enum AtlasNoticeKind { conflict, overflow, failed }

/// The one inline line above the cards.
class AtlasNotice {
  const AtlasNotice(this.kind, [this.count = 0]);
  final AtlasNoticeKind kind;

  /// Local cards that did not fit, for [AtlasNoticeKind.overflow].
  final int count;
}

/// One server's saved Atlas. Each saved server keeps its own cards, as each
/// web origin does. Signed in, the account's copy on the server is the truth
/// and this storage is its cache.
class AtlasStore extends ChangeNotifier {
  AtlasStore(this.preferences, this.url, {this.account})
    : saved = parseAtlas(preferences.atlasFor(url)) {
    preferences.atlasRevision.addListener(_reload);
    account?.addListener(_accountChanged);
    _user = _currentUser;
    if (_user != null) unawaited(sync());
  }
  final Preferences preferences;
  final String url;
  final AccountState? account;
  SavedAtlas saved;

  /// The last write was refused; changes last only for this session.
  bool storageFailed = false;
  AtlasNotice? notice;

  bool get signedIn => _currentUser != null;

  String? get _currentUser {
    final id = account?.user?['id'];
    return id == null ? null : '$id';
  }

  // Memory only: the stored JSON keeps the shape older builds and the web read.
  int? _revision;
  Map<String, String> _observerKeys = {};
  String? _user;
  bool _dirty = false, _wantLoad = false, _markAfterWrite = false;
  bool _disposed = false;
  int _changes = 0;
  Future<void>? _job;

  /// Completes when no load or write is running or waiting.
  Future<void> get idle async {
    while (_job != null) {
      await _job;
    }
  }

  void update(SavedAtlas Function(SavedAtlas value) change) {
    notice = null;
    saved = change(saved);
    _changes++;
    _notify();
    _cache();
    if (signedIn) {
      _dirty = true;
      _start();
    }
  }

  /// A card re-found under a new id, or an observer that turned out to be a
  /// node. Signed in, the next read from the server already reflects it, so it
  /// is neither stored nor sent.
  void relink(SavedAtlas Function(SavedAtlas value) change) {
    if (!signedIn) return update(change);
    saved = change(saved);
    _notify();
  }

  /// Fetches the account copy again, as when the screen opens.
  Future<void> sync() {
    if (signedIn) {
      _wantLoad = true;
      _start();
    }
    return idle;
  }

  void _cache() => preferences.saveAtlas(url, saved.encode()).then((ok) {
    if (storageFailed == ok) {
      storageFailed = !ok;
      _notify();
    }
  });

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _start() => _job ??= _run().whenComplete(() => _job = null);

  /// One worker, so writes never overlap and each carries the latest revision.
  Future<void> _run() async {
    while (true) {
      final user = _currentUser;
      if (user == null) return;
      if (_wantLoad || _revision == null) {
        _wantLoad = false;
        if (!await _load(user)) break;
      } else if (_dirty) {
        if (!await _write(user)) break;
      } else {
        return;
      }
    }
    if (_dirty && signedIn && notice == null) {
      notice = const AtlasNotice(AtlasNoticeKind.failed);
      _notify();
    }
  }

  void _adopt(ServerAtlas server) {
    _revision = server.revision;
    _observerKeys = {..._observerKeys, ...server.observerKeys};
    saved = server.atlas;
    _changes++;
    _notify();
    _cache();
  }

  /// False when the server could not be reached.
  Future<bool> _load(String user) async {
    final started = _changes;
    ServerAtlas? server;
    try {
      server = parseServerAtlas(await account!.api.atlas());
    } catch (_) {
      return false;
    }
    if (_currentUser != user) return true;
    if (server == null) return false;
    if (!preferences.atlasSyncedFor(url, user)) {
      final merged = mergeFirstSignIn(server, saved);
      _revision = server.revision;
      _observerKeys = {..._observerKeys, ...server.observerKeys};
      if (merged.upload) {
        saved = merged.atlas;
        _changes++;
        _dirty = true;
        _markAfterWrite = true;
        if (merged.dropped > 0) {
          notice = AtlasNotice(AtlasNoticeKind.overflow, merged.dropped);
        }
        _notify();
        _cache();
      } else {
        _adopt(server);
        await preferences.markAtlasSynced(url, user);
      }
    } else if (_dirty || _changes != started) {
      // Local changes the server has not seen: push them over its revision.
      _revision = server.revision;
      _observerKeys = {..._observerKeys, ...server.observerKeys};
      _dirty = true;
    } else {
      _adopt(server);
    }
    return true;
  }

  /// False when the write failed, so the loop stops until the next change.
  Future<bool> _write(String user) async {
    final snapshot = saved, changes = _changes;
    _dirty = false;
    Json doc;
    try {
      doc = await account!.api.putAtlas(
        _revision!,
        snapshot.range.id,
        (atlasPutBody(snapshot, _observerKeys, _revision!)['pins'] as List)
            .cast<Json>(),
      );
    } on AtlasConflict catch (conflict) {
      if (_currentUser != user) return true;
      final current = parseServerAtlas(conflict.current);
      if (current == null) {
        _dirty = true;
        return false;
      }
      // The server copy wins; no retry of the dropped change.
      _markAfterWrite = false;
      _dirty = false;
      _adopt(current);
      notice = const AtlasNotice(AtlasNoticeKind.conflict);
      _notify();
      return true;
    } catch (_) {
      if (_currentUser == user) _dirty = true;
      return false;
    }
    if (_currentUser != user) return true;
    final written = parseServerAtlas(doc);
    if (written == null) {
      _dirty = true;
      return false;
    }
    _revision = written.revision;
    _observerKeys = {..._observerKeys, ...written.observerKeys};
    if (_markAfterWrite) {
      _markAfterWrite = false;
      await preferences.markAtlasSynced(url, user);
    }
    // The stored copy is the truth, but only when nothing newer is waiting.
    if (!_dirty &&
        _changes == changes &&
        written.atlas.encode() != saved.encode()) {
      saved = written.atlas;
      _changes++;
      _notify();
      _cache();
    }
    return true;
  }

  void _accountChanged() {
    final next = _currentUser;
    if (next == _user) return;
    _user = next;
    // Whatever was in flight belonged to the previous user.
    _revision = null;
    _observerKeys = {};
    _dirty = false;
    _markAfterWrite = false;
    notice = null;
    _notify();
    if (next != null) unawaited(sync());
  }

  // Another screen (Settings import) saved this server's Atlas.
  void _reload() {
    final raw = preferences.atlasFor(url);
    if (raw == null || raw == saved.encode()) return;
    saved = parseAtlas(raw);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    preferences.atlasRevision.removeListener(_reload);
    account?.removeListener(_accountChanged);
    super.dispose();
  }
}
