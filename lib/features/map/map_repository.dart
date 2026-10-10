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
  dynamic cursor;
  var pages = 0;
  do {
    dynamic response;
    var retries = 0;
    while (true) {
      if (isCurrent?.call() == false) return;
      try {
        response = await api.getCached('/nodes', {
          ...region,
          'neighbors': true,
          'limit': 200,
          'cursor': ?cursor,
        });
        break;
      } on ApiException catch (e) {
        if (e.status != 429 || retries++ >= 3) rethrow;
        // Keep the current cursor and visible nodes during the server cooldown.
        await Future<void>.delayed(e.retryAfter ?? const Duration(seconds: 10));
      }
    }
    if (isCurrent?.call() == false) return;
    for (final n in rows(response)) {
      collected[textOf(n['id'])] = n;
    }
    yield collected.values.toList();
    final page = object(response);
    cursor = page['nextCursor'];
    if (page['hasMore'] != true || ++pages >= mapNodePageCap) break;
    if (cursor == null || !seen.add(jsonEncode(cursor))) {
      throw StateError('The server returned an invalid map page cursor.');
    }
  } while (true);
}
