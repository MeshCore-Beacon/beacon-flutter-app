import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'node detail copies its public key and opens the exact observation',
    (tester) async {
      String? copied;
      String? opened;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient((request) async {
          final path = request.url.path;
          final body = path.endsWith('/observations')
              ? {
                  'items': [
                    {
                      'id': 77,
                      'packetHash': 'packet-hash',
                      'nodeName': 'Mesh node',
                      'heardAt': 1,
                    },
                  ],
                  'hasMore': false,
                }
              : path.endsWith('/neighbors')
              ? []
              : {'id': 'node-1', 'publicKey': 'public-key-value'};
          return http.Response(jsonEncode(body), 200);
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: EntityDetailScreen(
            kind: 'node',
            id: 'node-1',
            api: api,
            region: const {},
            onOpen: (kind, id) => opened = '$kind/$id',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('public-key-value'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy public key'));
      await tester.pumpAndSettle();
      expect(copied, 'public-key-value');
      await tester.pump(const Duration(seconds: 2));
      await tester.drag(find.byType(ListView).first, const Offset(0, -180));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Mesh node'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mesh node'));
      expect(opened, 'packet/packet-hash:77');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail keeps pull to refresh without a duplicate app-bar refresh',
    (tester) async {
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient(
          (_) async => http.Response('{"traceTag":"ABCD","packets":[]}', 200),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EntityDetailScreen(
            kind: 'trace',
            id: 'ABCD',
            api: api,
            region: const {},
            onOpen: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Refresh'), findsNothing);
      expect(find.byType(RefreshIndicator), findsOneWidget);
    },
  );
  testWidgets('failed neighbors fetch shows an error with retry', (
    tester,
  ) async {
    final urls = <String>[];
    var neighborCalls = 0;
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((request) async {
        urls.add(request.url.path);
        final path = request.url.path;
        if (path.endsWith('/neighbors')) {
          return ++neighborCalls == 1
              ? http.Response('{"error":{"message":"neighbors down"}}', 500)
              : http.Response(
                  jsonEncode([
                    {'id': 'n2', 'name': 'Neighbor two'},
                  ]),
                  200,
                );
        }
        final body = path.endsWith('/observations')
            ? {'items': [], 'hasMore': false}
            : {'id': 'a/b', 'publicKey': 'public-key-value'};
        return http.Response(jsonEncode(body), 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EntityDetailScreen(
          kind: 'node',
          id: 'a/b',
          api: api,
          region: const {},
          onOpen: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(urls, contains('/api/v1/nodes/a%2Fb/neighbors'));
    final message = find.text('neighbors down');
    await tester.scrollUntilVisible(
      message,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('No known neighbors'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(neighborCalls, 2);
    expect(message, findsNothing);
    expect(find.text('Neighbor two'), findsOneWidget);
  });
}
