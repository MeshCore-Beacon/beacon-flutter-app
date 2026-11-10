import 'package:flutter/foundation.dart';

import '../../core/preferences.dart';
import 'atlas.dart';

/// One server's saved Atlas. Each saved server keeps its own cards, as each
/// web origin does.
class AtlasStore extends ChangeNotifier {
  AtlasStore(this.preferences, this.url)
    : saved = parseAtlas(preferences.atlasFor(url)) {
    preferences.atlasRevision.addListener(_reload);
  }
  final Preferences preferences;
  final String url;
  SavedAtlas saved;

  /// The last write was refused; changes last only for this session.
  bool storageFailed = false;

  void update(SavedAtlas Function(SavedAtlas value) change) {
    saved = change(saved);
    notifyListeners();
    preferences.saveAtlas(url, saved.encode()).then((ok) {
      if (storageFailed == ok) {
        storageFailed = !ok;
        notifyListeners();
      }
    });
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
    preferences.atlasRevision.removeListener(_reload);
    super.dispose();
  }
}
