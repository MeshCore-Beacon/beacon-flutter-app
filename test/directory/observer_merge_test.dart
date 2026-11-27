import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/json.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const observerId = 'obs-1';

void main() {
  late List<Uri> seen;
  late bool observerHasNode;

  ApiClient api() => ApiClient(
    Uri.parse('https://test.invalid'),
    transientRetries: 0,
    client: MockClient((request) async {
      seen.add(request.url);
      final path = request.url.path.replaceFirst('/api/v1', '');
      final dynamic body = switch (path) {
        '/nodes' => {
          'items': [
            if (observerHasNode && request.url.queryParameters['pubkey'] == 'k')
              {'id': 'node-1', 'publicKey': 'k'},
          ],
          'hasMore': false,
        },
        '/nodes/node-1' => {
          'id': 'node-1',
          'name': 'Node One',
          'publicKey': 'k',
          'nodeTypeName': 'repeater',
          'observerId': observerId,
        },
        '/nodes/node-1/neighbors' => [],
        '/observers/$observerId' => {
          'id': observerId,
          'displayName': 'Observer One',
          'publicKey': 'K',
          'status': 'online',
          'firmwareVersion': 'v1.2.3',
        },
        '/observers/$observerId/adverts' => {
          'items': [
            {'id': 7, 'nodeName': 'Heard Node', 'heardAt': 1000},
          ],
          'hasMore': false,
        },
        _ => {'items': [], 'hasMore': false, 'points': []},
      };
      return http.Response(jsonEncode(body), 200);
    }),
  );

  Future<void> pump(
    WidgetTester tester, {
    String kind = 'node',
    String id = 'node-1',
    Stream<Json>? events,
    void Function(String, String)? onOpen,
  }) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: EntityDetailScreen(
          kind: kind,
          id: id,
          api: api(),
          region: const {},
          onOpen: onOpen ?? (_, _) {},
          events: events,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool asked(String path) => seen.any((u) => u.path == '/api/v1$path');

  setUp(() {
    seen = [];
    observerHasNode = true;
  });

  testWidgets('a node that is an observer switches to its observer view', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Observer details'), findsNothing);
    expect(find.text(trKey('observerMerge.node')), findsOneWidget);
    // The observer loads only once its view is shown.
    expect(asked('/observers/$observerId'), isFalse);

    await tester.tap(find.text(trKey('observerMerge.observer')));
    await tester.pumpAndSettle();
    expect(asked('/observers/$observerId'), isTrue);
    expect(asked('/observers/$observerId/activity'), isTrue);
    expect(find.text('v1.2.3'), findsOneWidget);
    expect(find.text('Compare observers'), findsOneWidget);
    expect(find.text('Heard Node'), findsOneWidget);
    expect(find.text('Node One'), findsOneWidget);

    await tester.tap(find.text(trKey('observerMerge.node')));
    await tester.pumpAndSettle();
    expect(find.text('Compare observers'), findsNothing);
    expect(find.text('TELEMETRY'), findsNothing);
  });

  testWidgets(
    'an observer with a node opens as the node on its observer view',
    (tester) async {
      await pump(tester, kind: 'observer', id: observerId);
      expect(
        seen.where((u) => u.path == '/api/v1/nodes').single.queryParameters,
        {'pubkey': 'k', 'limit': '2'},
      );
      expect(find.text('Node One'), findsOneWidget);
      expect(find.text(trKey('observerMerge.node')), findsOneWidget);
      expect(find.text('Compare observers'), findsOneWidget);
      expect(find.text('Heard Node'), findsOneWidget);
      // Fetched while resolving, not again for the view.
      expect(
        seen.where((u) => u.path == '/api/v1/observers/$observerId').length,
        1,
      );
    },
  );

  testWidgets('an observer with no node keeps the observer screen', (
    tester,
  ) async {
    observerHasNode = false;
    await pump(tester, kind: 'observer', id: observerId);
    expect(find.text('Observer One'), findsOneWidget);
    expect(find.text(trKey('observerMerge.node')), findsNothing);
    expect(find.text('Compare observers'), findsOneWidget);
    expect(asked('/nodes/node-1'), isFalse);
  });

  testWidgets('the observer view copies a link to it', (tester) async {
    String? copied;
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
    await pump(tester, kind: 'observer', id: observerId);
    await tester.tap(find.byTooltip('Copy link'));
    await tester.pumpAndSettle();
    expect(Uri.parse(copied!).queryParameters, {
      'tab': 'Nodes',
      'node': 'node-1',
      'view': 'observer',
    });
  });

  testWidgets('an observer status refreshes the observer view', (tester) async {
    final events = StreamController<Json>.broadcast();
    addTearDown(events.close);
    await pump(tester, events: events.stream);
    await tester.tap(find.text(trKey('observerMerge.observer')));
    await tester.pumpAndSettle();
    final before = seen
        .where((u) => u.path == '/api/v1/observers/$observerId')
        .length;

    events.add({
      'type': 'event',
      'event': 'observerStatus',
      'data': {'observerId': observerId},
    });
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(
      seen.where((u) => u.path == '/api/v1/observers/$observerId').length,
      before + 1,
    );
  });
}
