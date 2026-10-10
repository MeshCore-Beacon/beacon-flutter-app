import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final kind in ['nodes']) {
    testWidgets('$kind uses name order when activity counts are tied', (
      tester,
    ) async {
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient((r) async {
          return http.Response(
            jsonEncode(
              r.url.path.endsWith('/$kind')
                  ? {
                      'items': [
                        {'id': 'z', 'name': 'Zulu', 'lastSeen': 9000},
                        {'id': 'a', 'name': 'alpha', 'lastSeen': 1000},
                        {
                          'id': 'b',
                          if (kind == 'observers')
                            'displayName': 'Bravo'
                          else
                            'name': 'Bravo',
                          'lastSeen': 5000,
                        },
                      ],
                      'hasMore': false,
                    }
                  : [],
            ),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DirectoryScreen(
              kind: kind,
              api: api,
              region: const {},
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('alpha')).dy,
        lessThan(tester.getTopLeft(find.text('Bravo')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Bravo')).dy,
        lessThan(tester.getTopLeft(find.text('Zulu')).dy),
      );
    });
  }

  testWidgets('observers default to most traffic and allow name sorting', (
    tester,
  ) async {
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        if (!r.url.path.endsWith('/directory')) return http.Response('[]', 200);
        final entries = [
          {
            'id': 'z',
            'displayName': 'Zulu',
            'status': 'online',
            'observationCount': 100,
          },
          {
            'id': 'a',
            'displayName': 'Alpha',
            'status': 'online',
            'observationCount': 25,
          },
          {
            'id': 'b',
            'displayName': 'Bravo',
            'status': 'offline',
            'observationCount': 0,
          },
        ];
        if (r.url.queryParameters['sort'] == 'name') {
          entries.sort(
            (a, b) => '${a['displayName']}'.compareTo('${b['displayName']}'),
          );
        }
        return http.Response(
          jsonEncode({
            'items': entries,
            'windowStart': 1767225600000,
            'windowEnd': 1767830400000,
            'effectiveSort': 'traffic',
            'hasMore': false,
            'coverage': {'status': 'complete'},
            'maxObservationCount': 100,
            'observerTypes': [],
          }),
          200,
        );
      }),
    );
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryScreen(
            kind: 'observers',
            api: api,
            region: const {},
            onOpen: (kind, id) => opened = '$kind/$id',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Zulu')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Alpha')).dy,
      lessThan(tester.getTopLeft(find.text('Bravo')).dy),
    );
    expect(find.text('100'), findsOneWidget);
    await tester.tap(find.text('Zulu'));
    expect(opened, 'observer/z');
    await tester.tap(find.byTooltip('Sort observers'));
    await tester.pumpAndSettle();
    expect(find.text('Most traffic'), findsOneWidget);
    await tester.tap(find.text('Name').last);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Alpha')).dy,
      lessThan(tester.getTopLeft(find.text('Zulu')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'observer status updates preserve snapshot rows and scroll position',
    (tester) async {
      final events = StreamController<Map<String, dynamic>>.broadcast();
      final update = Completer<http.Response>();
      var calls = 0;
      Map<String, dynamic> observer(int i, {String status = 'online'}) => {
        'id': '$i',
        'name': 'Observer ${i.toString().padLeft(2, '0')}',
        'status': status,
      };
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient((r) async {
          if (!r.url.path.endsWith('/directory')) {
            return http.Response('[]', 200);
          }
          calls++;
          if (calls > 1) return update.future;
          return http.Response(
            jsonEncode({
              'items': List.generate(30, (i) => observer(i)),
              'hasMore': false,
              'windowStart': 1767225600000,
              'windowEnd': 1767830400000,
              'effectiveSort': 'traffic',
              'coverage': {'status': 'complete'},
              'maxObservationCount': 0,
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DirectoryScreen(
              kind: 'observers',
              api: api,
              region: const {},
              events: events.stream,
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      scroll.position.jumpTo(350);
      await tester.pumpAndSettle();
      final row = find.text('Observer 08');
      final position = tester.getTopLeft(row);
      final offset = scroll.position.pixels;
      events.add({
        'event': 'observerStatus',
        'data': {'observerId': '8', 'online': false},
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 801));
      expect(calls, 1);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.getTopLeft(row), position);
      update.complete(
        http.Response(
          jsonEncode({
            'items': List.generate(
              30,
              (i) => observer(29 - i, status: 'offline'),
            ),
            'hasMore': false,
            'windowStart': 1767225600000,
            'windowEnd': 1767830400000,
            'effectiveSort': 'traffic',
            'coverage': {'status': 'complete'},
            'maxObservationCount': 0,
          }),
          200,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(row), position);
      expect(scroll.position.pixels, offset);
      expect(find.byTooltip('Offline'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets(
    'channel pins scope filter and prepends older pages without moving the reader',
    (tester) async {
      final older = Completer<http.Response>();
      var olderCalls = 0;
      Map<String, dynamic> message(int id) => {
        'id': id,
        'sentAt': id * 1000,
        'senderName': 'Alice',
        'content': 'Message $id',
        'packetHash': 'packet$id',
      };
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient((r) async {
          if (r.url.path.endsWith('/scopes')) {
            return http.Response('["#at"]', 200);
          }
          if (!r.url.path.endsWith('/messages')) {
            return http.Response('{"id":1,"name":"Public"}', 200);
          }
          if (r.url.queryParameters.containsKey('cursor')) {
            olderCalls++;
            return older.future;
          }
          return http.Response(
            jsonEncode({
              'items': List.generate(50, (i) => message(i + 51)),
              'hasMore': true,
              'nextCursor': 51,
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EntityDetailScreen(
            kind: 'channel',
            id: '1',
            api: api,
            region: const {},
            onOpen: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final filter = find.byType(DropdownButtonFormField<String>);
      final filterPosition = tester.getTopLeft(filter);
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('channel-message-list')),
      );
      list.controller!.jumpTo(list.controller!.position.maxScrollExtent - 100);
      await tester.pump();
      expect(olderCalls, 1);
      expect(tester.getTopLeft(filter), filterPosition);
      final anchor = find.text('Message 55');
      final anchorPosition = tester.getTopLeft(anchor);
      older.complete(
        http.Response(
          jsonEncode({
            'items': List.generate(50, (i) => message(i + 1)),
            'hasMore': false,
          }),
          200,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(anchor).dy, closeTo(anchorPosition.dy, 1));
      expect(tester.getTopLeft(filter), filterPosition);
      expect(find.text('Load older'), findsNothing);
      list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(olderCalls, 1);
      expect(find.text('Message 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nodes filter transmits canonical lowercase type name', (
    tester,
  ) async {
    final requests = <Uri>[];
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        requests.add(r.url);
        return http.Response(
          jsonEncode(
            r.url.path.endsWith('/scopes')
                ? []
                : {'items': [], 'hasMore': false},
          ),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryScreen(
            kind: 'nodes',
            api: api,
            region: const {},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Any').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repeater').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['typeName'], 'repeater');
  });
  testWidgets('empty region issues no unbounded directory request', (
    tester,
  ) async {
    final requests = <Uri>[];
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        requests.add(r.url);
        return http.Response('[]', 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryScreen(
            kind: 'nodes',
            api: api,
            region: const {'iatas': ''},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('No nodes found'), findsOneWidget);
  });
  testWidgets(
    'channel message preserves zero signal content and packet navigation',
    (tester) async {
      String? selected;
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient((r) async {
          final path = r.url.path;
          return http.Response(
            jsonEncode(
              path.endsWith('/scopes')
                  ? []
                  : path.endsWith('/messages')
                  ? {
                      'items': [
                        {
                          'id': 1,
                          'senderName': 'Alice',
                          'content': 'Mesh message',
                          'packetHash': 'abc',
                          'sentAt': 1000,
                          'observationCount': 2,
                        },
                      ],
                      'hasMore': false,
                    }
                  : {'id': 4, 'name': 'Public', 'keyKnown': true},
            ),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EntityDetailScreen(
            kind: 'channel',
            id: '4',
            api: api,
            region: const {},
            onOpen: (k, id) => selected = '$k/$id',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mesh message'), findsOneWidget);
      await tester.tap(find.text('2 observations'));
      expect(selected, 'packet/abc');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('routes request every selected IATA', (tester) async {
    final requested = <String>[];
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/routes')) {
          requested.add(r.url.queryParameters['iata']!);
        }
        return http.Response('[]', 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryScreen(
            kind: 'routes',
            api: api,
            region: const {'iatas': 'YVR,YYJ'},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requested, ['YVR', 'YYJ']);
  });
  testWidgets('old instance response cannot replace new directory', (
    tester,
  ) async {
    final delayed = Completer<http.Response>();
    final oldApi = ApiClient(
      Uri.parse('https://old.invalid'),
      client: MockClient(
        (r) async => r.url.path.endsWith('/nodes')
            ? delayed.future
            : http.Response('[]', 200),
      ),
    );
    final newApi = ApiClient(
      Uri.parse('https://new.invalid'),
      client: MockClient(
        (r) async => http.Response(
          r.url.path.endsWith('/nodes')
              ? ' {"items":[{"id":"new","name":"New instance node"}],"hasMore":false}'
              : '[]',
          200,
        ),
      ),
    );
    Widget screen(ApiClient api) => MaterialApp(
      home: Scaffold(
        body: DirectoryScreen(
          kind: 'nodes',
          api: api,
          region: const {},
          onOpen: (_, _) {},
        ),
      ),
    );
    await tester.pumpWidget(screen(oldApi));
    await tester.pump();
    await tester.pumpWidget(screen(newApi));
    await tester.pumpAndSettle();
    delayed.complete(
      http.Response(
        '{"items":[{"id":"old","name":"Old instance node"}],"hasMore":false}',
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New instance node'), findsOneWidget);
    expect(find.text('Old instance node'), findsNothing);
  });

  testWidgets('trace detail reloads when socket reconnect emits refresh', (
    tester,
  ) async {
    var requests = 0;
    final events = StreamController<Map<String, dynamic>>.broadcast();
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        requests++;
        return http.Response('{"traceTag":"ABCD","packets":[]}', 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EntityDetailScreen(
          kind: 'trace',
          id: 'ABCD',
          api: api,
          region: const {},
          events: events.stream,
          onOpen: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, 1);
    events.add({'type': 'refresh'});
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(requests, 2);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
  testWidgets('node mobile card is compact and truncates long names', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient(
        (r) async => http.Response(
          r.url.path.endsWith('/nodes')
              ? jsonEncode({
                  'items': [
                    {
                      'id': 'one',
                      'name': 'A very long repeater name that should remain on one line',
                      'nodeTypeName': 'repeater',
                      'lat': 48.64,
                      'lng': -123.4,
                      'radio': '915,250,11',
                      'knownNeighborCount': 9,
                      'iatas': [
                        {'iata': 'YVR', 'lastHeard': 1},
                      ],
                    },
                    {
                      'id': 'two',
                      'name': 'Second repeater',
                      'nodeTypeName': 'repeater',
                      'iatas': [],
                    },
                  ],
                  'hasMore': false,
                })
              : '[]',
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryScreen(
            kind: 'nodes',
            api: api,
            region: const {},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(
      find.text('A very long repeater name that should remain on one line'),
    );
    final second = tester.getTopLeft(find.text('Second repeater'));
    expect(second.dy - first.dy, lessThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'channel renders messages chronologically despite descending API ids',
    (tester) async {
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient(
          (r) async => http.Response(
            jsonEncode(
              r.url.path.endsWith('/messages')
                  ? {
                      'items': [
                        {
                          'id': 2,
                          'senderName': 'New sender',
                          'content': 'New message',
                          'packetHash': 'new',
                          'sentAt': 2000,
                        },
                        {
                          'id': 1,
                          'senderName': 'Old sender',
                          'content': 'Old message',
                          'packetHash': 'old',
                          'sentAt': 1000,
                        },
                      ],
                      'hasMore': false,
                    }
                  : r.url.path.endsWith('/scopes')
                  ? []
                  : {'id': 1, 'name': 'Public'},
            ),
            200,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EntityDetailScreen(
            kind: 'channel',
            id: '1',
            api: api,
            region: const {},
            onOpen: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Old message')).dy,
        lessThan(tester.getTopLeft(find.text('New message')).dy),
      );
    },
  );

  testWidgets('legacy empty region slug never issues all-region routes', (
    tester,
  ) async {
    final calls = <Uri>[];
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        calls.add(r.url);
        return http.Response('[]', 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryScreen(
            kind: 'routes',
            api: api,
            region: const {'region': 'empty'},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
  });
  testWidgets(
    'legacy empty region prevents channel history and scope requests',
    (tester) async {
      final calls = <Uri>[];
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient((r) async {
          calls.add(r.url);
          return http.Response('{"id":1,"name":"Public"}', 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EntityDetailScreen(
            kind: 'channel',
            id: '1',
            api: api,
            region: const {'region': 'empty'},
            onOpen: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.map((e) => e.path), ['/api/v1/channels/1']);
    },
  );

  testWidgets('channel queues new-message refresh during older history fetch', (
    tester,
  ) async {
    final events = StreamController<Map<String, dynamic>>.broadcast();
    final older = Completer<http.Response>();
    var firstPageCalls = 0;
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/scopes')) return http.Response('[]', 200);
        if (!r.url.path.endsWith('/messages')) {
          return http.Response('{"id":1,"name":"Public"}', 200);
        }
        if (r.url.queryParameters.containsKey('cursor')) return older.future;
        firstPageCalls++;
        return http.Response(
          jsonEncode({
            'items': [
              {
                'id': firstPageCalls == 1 ? 2 : 3,
                'sentAt': firstPageCalls == 1 ? 2000 : 3000,
                'senderName': 'Alice',
                'content': firstPageCalls == 1 ? 'Existing' : 'Latest',
                'packetHash': 'abc',
              },
            ],
            'hasMore': true,
            'nextCursor': 2,
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EntityDetailScreen(
          kind: 'channel',
          id: '1',
          api: api,
          region: const {},
          events: events.stream,
          onOpen: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('channel-message-list')),
      const Offset(0, 350),
    );
    await tester.pump();
    events.add({
      'type': 'event',
      'event': 'channelMessage',
      'data': {'channelId': 1},
    });
    await tester.pump();
    older.complete(
      http.Response(
        '{"items":[{"id":1,"sentAt":1000,"senderName":"Alice","content":"Older"}],"hasMore":false}',
        200,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(firstPageCalls, 2);
    expect(find.text('Latest'), findsOneWidget);
    expect(find.text('Older'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
  testWidgets('directory queues refresh received during initial snapshot', (
    tester,
  ) async {
    final events = StreamController<Map<String, dynamic>>.broadcast();
    final first = Completer<http.Response>();
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/scopes')) return http.Response('[]', 200);
        calls++;
        return calls == 1
            ? first.future
            : http.Response(
                '{"items":[{"id":"new","name":"Latest node"}],"hasMore":false}',
                200,
              );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryScreen(
            kind: 'nodes',
            api: api,
            region: const {},
            events: events.stream,
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pump();
    events.add({'type': 'refresh'});
    await tester.pump();
    first.complete(http.Response('{"items":[],"hasMore":false}', 200));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Latest node'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets(
    'channels default to name order with Public pinned and others opt in',
    (tester) async {
      final filters = <String?>[];
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient((r) async {
          if (r.url.path.endsWith('/scopes')) return http.Response('[]', 200);
          filters.add(r.url.queryParameters['keyKnown']);
          return http.Response(
            jsonEncode({
              'items': r.url.queryParameters['keyKnown'] == 'false'
                  ? [
                      {'id': 3, 'channelHash': 'dd', 'keyKnown': false},
                    ]
                  : [
                      {
                        'id': 1,
                        'name': 'Music',
                        'keyKnown': true,
                        'lastSeen': 3000,
                      },
                      {
                        'id': 2,
                        'name': 'Public',
                        'keyKnown': true,
                        'lastSeen': 1000,
                      },
                      {
                        'id': 4,
                        'name': 'alpha',
                        'keyKnown': true,
                        'lastSeen': 100,
                      },
                    ],
              'hasMore': false,
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DirectoryScreen(
              kind: 'channels',
              api: api,
              region: const {},
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(filters, ['true']);
      expect(
        tester.getTopLeft(find.text('Public')).dy,
        lessThan(tester.getTopLeft(find.text('#Music')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Public')).dy,
        lessThan(tester.getTopLeft(find.text('#alpha')).dy),
      );
      expect(
        tester.getTopLeft(find.text('#alpha')).dy,
        lessThan(tester.getTopLeft(find.text('#Music')).dy),
      );
      await tester.tap(find.byTooltip('Sort loaded rows'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Public')).dy,
        lessThan(tester.getTopLeft(find.text('#alpha')).dy),
      );
      await tester.tap(find.text('Load other channels'));
      await tester.pumpAndSettle();
      expect(filters.contains('false'), isTrue);
      expect(find.text('dd'), findsOneWidget);
      expect(find.text('Public'), findsOneWidget);
    },
  );
}
