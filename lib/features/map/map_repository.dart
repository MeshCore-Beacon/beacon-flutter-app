import 'dart:convert';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/page_pacer.dart';

// A million nodes even at an older server's 200 per page: only a never-ending server gets here.
const mapNodePageCap = 5000;

Stream<List<Map<String, dynamic>>> loadMapNodes(
  ApiClient api,
  Map<String, dynamic> region, {
  bool Function()? isCurrent,
  PagePacer? pacer,
}) async* {
  final iatas = region['iatas'];
  if (iatas is List && iatas.isEmpty || iatas == '') {
    yield [];
    return;
  }
  final collected = <String, Map<String, dynamic>>{};
  final seen = <String>{};
  Map<String, Object> next = {};
  var pages = 0;
  do {
    // later pages share the app-wide page budget, so a big region can't trip the rate limit
    if (pages > 0) await (pacer ?? pagePacer).wait();
    if (isCurrent?.call() == false) return;
    // Keeps the same cursors and visible nodes during a server cooldown.
    final response = await withPageCursorFallback(
      // older servers clamp this to 200 and keep paging, so asking for more is always safe
      {...region, 'neighbors': true, 'limit': 2000, ...next},
      (p) => api.getCached('/nodes', p, isCurrent),
      isCurrent: isCurrent,
    );
    if (response == null || isCurrent?.call() == false) return;
    for (final n in rows(response)) {
      collected[textOf(n['id'])] = n;
    }
    yield collected.values.toList();
    final page = object(response);
    if (page['hasMore'] != true) break;
    // Stopping here drops nodes, so the screen must show an error, not a smaller map.
    if (++pages >= mapNodePageCap) {
      throw StateError(
        'The server sent more than $mapNodePageCap map pages; the map is incomplete.',
      );
    }
    next = nextPageParams(page);
    if (next.isEmpty || !seen.add(jsonEncode(next))) {
      throw StateError('The server returned an invalid map page cursor.');
    }
  } while (true);
}
