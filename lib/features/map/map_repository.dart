import 'dart:convert';

import '../../core/api.dart';
import '../../core/json.dart';

// 50k nodes at 200 per page; bounds a server that never stops paging.
const mapNodePageCap = 250;

Stream<List<Map<String, dynamic>>> loadMapNodes(
  ApiClient api,
  Map<String, dynamic> region, {
  bool Function()? isCurrent,
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
    if (isCurrent?.call() == false) return;
    // Keeps the same cursors and visible nodes during a server cooldown.
    final response = await withPageCursorFallback(
      {...region, 'neighbors': true, 'limit': 200, ...next},
      (p) => retryTransient(
        () => api.getCached('/nodes', p),
        isCurrent: isCurrent,
      ),
    );
    if (response == null || isCurrent?.call() == false) return;
    for (final n in rows(response)) {
      collected[textOf(n['id'])] = n;
    }
    yield collected.values.toList();
    final page = object(response);
    if (page['hasMore'] != true || ++pages >= mapNodePageCap) break;
    next = nextPageParams(page);
    if (next.isEmpty || !seen.add(jsonEncode(next))) {
      throw StateError('The server returned an invalid map page cursor.');
    }
  } while (true);
}
