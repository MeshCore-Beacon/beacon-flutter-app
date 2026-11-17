import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/account.dart';
import '../../core/api.dart';
import '../../core/auth_api.dart';
import '../../core/json.dart';
import '../../core/preferences.dart';
import 'atlas.dart';
import 'atlas_sync.dart';

enum AtlasNoticeKind { conflict, overflow, failed, overLimit }

/// The one inline line above the cards.
class AtlasNotice {
  const AtlasNotice(this.kind, [this.count = 0, this.limit = 0]);
  final AtlasNoticeKind kind;

  /// Local cards that did not fit, for [AtlasNoticeKind.overflow], or cards to
  /// remove, for [AtlasNoticeKind.overLimit].
  final int count;

  /// The server's cap, for [AtlasNoticeKind.overLimit].
  final int limit;
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

  /// The account generation. An action that awaits notes it first and drops
  /// its result when [sameAccount] says it moved.
  int get epoch => account?.epoch ?? 0;
  bool sameAccount(int noted) => epoch == noted;

  /// True while [user]'s session, as noted at [epoch], is still the live one.
  bool _live(String user, int epoch) =>
      _currentUser == user && account?.epoch == epoch;

  String? get _currentUser {
    final id = account?.user?['id'];
    return id == null ? null : '$id';
  }

  // Memory only: the stored JSON keeps the shape older builds and the web read.
  int? _revision;
  Map<String, String> _observerKeys = {};
  String? _user;
  bool _dirty = false, _wantLoad = false, _markAfterWrite = false;
  // Whether the server stores Telemetry tiles and views; otherwise they live
  // only in the local copy.
  bool _telemetrySync = false;
  bool _disposed = false;
  int _changes = 0;
  Future<void>? _job;

  // User changes made before the first load finishes, replayed on top of it.
  List<SavedAtlas Function(SavedAtlas)> _held = [];
  SavedAtlas? _heldBase;

  /// The id the detail screens take for the radio an alert names; they do not
  /// take public keys. Null when this Atlas has no such pin, or the observer's
  /// row is gone.
  String? idForRadio(String kind, String publicKey) {
    final key = publicKey.toLowerCase();
    if (kind == 'node') {
      return saved.pins
          .where((p) => p.isNode && p.publicKey?.toLowerCase() == key)
          .firstOrNull
          ?.id;
    }
    for (final MapEntry(key: id, value: observerKey) in _observerKeys.entries) {
      if (observerKey == key && id != placeholderObserverId(key)) return id;
    }
    return null;
  }

  /// Completes when no load or write is running or waiting.
  Future<void> get idle async {
    while (_job != null) {
      await _job;
    }
  }

  void update(SavedAtlas Function(SavedAtlas value) change) {
    notice = null;
    if (signedIn && _revision == null) {
      _heldBase ??= saved;
      _held.add(change);
    }
    saved = change(saved);
    _changes++;
    _notify();
    _cache();
    if (signedIn && _revision == null) {
      _start();
    } else if (signedIn) {
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
      final epoch = account!.epoch;
      if (_wantLoad || _revision == null) {
        _wantLoad = false;
        if (!await _load(user, epoch)) break;
      } else if (_dirty) {
        if (!await _write(user, epoch)) break;
      } else {
        return;
      }
    }
    if ((_dirty || _held.isNotEmpty) && signedIn && notice == null) {
      notice = const AtlasNotice(AtlasNoticeKind.failed);
      _notify();
    }
  }

  void _adopt(ServerAtlas server) {
    _revision = server.revision;
    _observerKeys = {..._observerKeys, ...server.observerKeys};
    saved = _telemetrySync ? server.atlas : carryTelemetry(server.atlas, saved);
    _changes++;
    _notify();
    _cache();
  }

  /// Records that the local copy now belongs to [user]'s account.
  void _own(String user) {
    if (preferences.atlasOwnerFor(url) != user) {
      unawaited(preferences.setAtlasOwner(url, user));
    }
  }

  /// Puts the changes made before the first load on top of the loaded copy.
  void _applyHeld(List<SavedAtlas Function(SavedAtlas)> held) {
    if (held.isEmpty) return;
    for (final change in held) {
      saved = change(saved);
    }
    _changes++;
    _dirty = true;
    _notify();
    _cache();
  }

  /// False when the server could not be reached.
  Future<bool> _load(String user, int epoch) async {
    ServerAtlas? server;
    try {
      server = parseServerAtlas(await account!.api.atlas());
      _telemetrySync = await account!.api.atlasTelemetry();
    } catch (_) {
      return !_live(user, epoch);
    }
    if (!_live(user, epoch)) return true;
    if (server == null) return false;
    // The local copy as it was before any held change.
    final local = _heldBase ?? saved, held = _held;
    _held = [];
    _heldBase = null;
    final edited = _revision;
    _revision = server.revision;
    _observerKeys = {..._observerKeys, ...server.observerKeys};
    final owner = preferences.atlasOwnerFor(url);
    if (!preferences.atlasSyncedFor(url, user)) {
      // A copy another account synced is never merged into this one.
      final merged = owner != null && owner != user
          ? AtlasMerge(server.atlas, upload: false)
          : mergeFirstSignIn(server, local);
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
    } else if (_dirty) {
      // Local changes the server has not seen keep the revision they were made
      // on, so a newer server copy answers 409 instead of being overwritten.
      saved = local;
      _revision = edited ?? server.revision;
    } else {
      _adopt(server);
    }
    _own(user);
    _applyHeld(held);
    return true;
  }

  /// False when the write failed, so the loop stops until the next change.
  Future<bool> _write(String user, int epoch) async {
    final snapshot = saved, changes = _changes;
    _dirty = false;
    Json doc;
    try {
      _telemetrySync = await account!.api.atlasTelemetry();
      if (!_live(user, epoch)) return true;
      doc = await account!.api.putAtlas(
        _revision!,
        snapshot.range.id,
        (atlasPutBody(
                  snapshot,
                  _observerKeys,
                  _revision!,
                  telemetry: _telemetrySync,
                )['pins']
                as List)
            .cast<Json>(),
      );
    } on AtlasConflict catch (conflict) {
      if (!_live(user, epoch)) return true;
      var doc = conflict.current;
      if (doc == null) {
        // The answer did not carry the document: fetch it.
        try {
          doc = await account!.api.atlas();
        } catch (_) {
          if (_live(user, epoch)) _dirty = true;
          return false;
        }
        if (!_live(user, epoch)) return true;
      }
      final current = parseServerAtlas(doc);
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
    } on ApiException catch (e) {
      if (!_live(user, epoch)) return true;
      // A save over the server's cap is refused as "at most N pins".
      final cap = e.status == 422
          ? RegExp(r'^at most (\d+) pins$').firstMatch(e.message)?.group(1)
          : null;
      final over = cap == null ? 0 : saved.pins.length - int.parse(cap);
      if (over > 0) {
        _dirty = false;
        notice = AtlasNotice(AtlasNoticeKind.overLimit, over, int.parse(cap!));
        _notify();
        return true;
      }
      _dirty = true;
      return false;
    } catch (_) {
      if (_live(user, epoch)) _dirty = true;
      return false;
    }
    if (!_live(user, epoch)) return true;
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
    final stored = _telemetrySync
        ? written.atlas
        : carryTelemetry(written.atlas, saved);
    if (!_dirty && _changes == changes && stored.encode() != saved.encode()) {
      saved = stored;
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
    _held = [];
    _heldBase = null;
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
