import 'package:beacon/features/directory/paging.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'route updates preserve order and distinguish regions with the same id',
    () {
      final merged = mergeDirectoryRows(
        [
          {'id': 1, 'iata': 'YOW', 'pathKey': 'a', 'observationCount': 2},
          {'id': 1, 'iata': 'YYZ', 'pathKey': 'a', 'observationCount': 3},
        ],
        [
          {'id': 1, 'iata': 'YYZ', 'pathKey': 'a', 'observationCount': 4},
          {'id': 1, 'iata': 'YOW', 'pathKey': 'a', 'observationCount': 5},
          {'id': 2, 'iata': 'YOW', 'pathKey': 'b', 'observationCount': 1},
        ],
        'routes',
      );
      expect(merged.map((r) => directoryRowKey(r, 'routes')), [
        'YOW:a',
        'YYZ:a',
        'YOW:b',
      ]);
      expect(merged.map((r) => r['observationCount']), [5, 4, 1]);
    },
  );

  test('channel paging preserves opaque cursor before numeric cursor', () {
    expect(
      nextDirectoryCursor('channels', {
        'items': [
          {'id': 1},
        ],
        'hasMore': true,
        'nextCursor': 99,
        'nextPageCursor': 'opaque',
      }, 50),
      {'pageCursor': 'opaque'},
    );
  });
  test('route and trace cursor retains timestamp ties', () {
    expect(
      nextDirectoryCursor('routes', [
        {'id': 7, 'lastSeen': 12},
      ], 1),
      {'cursor': 12, 'cursorId': 7},
    );
    expect(
      nextDirectoryCursor('traces', [
        {'traceTag': 'abcd', 'lastHeardAt': 12},
      ], 1),
      {'cursor': 12, 'cursorTag': 'abcd'},
    );
  });
  test(
    'explicit no-more overrides full message page and dedup preserves newest',
    () {
      expect(
        nextDirectoryCursor('messages', {
          'items': [
            {'id': 2},
          ],
          'hasMore': false,
        }, 1),
        isEmpty,
      );
      expect(
        mergeDirectoryRows(
          [
            {'id': 1, 'name': 'old'},
          ],
          [
            {'id': 1, 'name': 'new'},
            {'id': 2},
          ],
          'nodes',
        ).length,
        2,
      );
      expect(
        mergeDirectoryRows(
          [
            {'id': 1, 'name': 'old'},
          ],
          [
            {'id': 1, 'name': 'new'},
          ],
          'nodes',
        ).first['name'],
        'new',
      );
    },
  );
  test('legacy messages use boundary id and incomplete pages stop', () {
    expect(
      nextDirectoryCursor('messages', {
        'items': [
          {'id': 5},
          {'id': 3},
        ],
      }, 2),
      {'cursor': 3},
    );
    expect(nextDirectoryCursor('traces', [], 50), isEmpty);
  });

  test('nodes and observers send both cursors so a server ignoring pageCursor still advances', () {
    final page = {
      'items': [
        {'id': 'a'},
      ],
      'hasMore': true,
      'nextCursor': 99,
      'nextPageCursor': 'v1:99000:00000000-0000-0000-0000-00000000000a',
    };
    for (final kind in ['nodes', 'observers']) {
      expect(nextDirectoryCursor(kind, page, 50), {
        'cursor': 99,
        'pageCursor': 'v1:99000:00000000-0000-0000-0000-00000000000a',
      });
    }
  });
  test('nodes on an older server page by cursor alone', () {
    expect(
      nextDirectoryCursor('nodes', {
        'items': [
          {'id': 'a'},
        ],
        'hasMore': true,
        'nextCursor': 99,
      }, 50),
      {'cursor': 99},
    );
  });
  test('nodes stop when hasMore is false', () {
    expect(
      nextDirectoryCursor('nodes', {
        'items': [
          {'id': 'a'},
        ],
        'hasMore': false,
        'nextCursor': 99,
        'nextPageCursor': 'x',
      }, 50),
      isEmpty,
    );
  });
}
