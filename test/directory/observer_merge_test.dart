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
  late bool observerHasNode, isPoller, pollingOn, linked;
  late int pollerStatus;

  ApiClient api() => ApiClient(
    Uri.parse('https://test.invalid'),
    transientRetries: 0,
    client: MockClient((request) async {
      seen.add(request.url);
      final path = request.url.path.replaceFirst('/api/v1', '');
      if (path.endsWith('/poller') && pollerStatus != 200) {
        return http.Response('{}', pollerStatus);
      }
      final dynamic body = switch (path) {
        '/info' => {
          'features': {'polling': pollingOn},
        },
        '/nodes/node-1/poller' => {
          'claim': {
            'receivedAt': DateTime.now().millisecondsSinceEpoch,
            'live': true,
            'acceptsRequests': true,
            'slots': {'max': 8, 'used': 1, 'own': 1, 'requested': 0, 'free': 7},
          },
          'readings24h': 4,
          'targets': [
            {
              'nodeId': 'node-9',
              'publicKey': 'ab' * 32,
              'name': 'Polled One',
              'requested': false,
              'role': 'poller',
              'rank': null,
              'state': 'ok',
              'misses': 0,
              'evidenceCount': 0,
            },
          ],
        },
        '/nodes/node-2' => {
          'id': 'node-2',
          'name': 'Node Two',
          'publicKey': 'k2',
          'nodeTypeName': 'repeater',
          'observerId': 'obs-2',
          'isPoller': true,
        },
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
          if (linked) 'observerId': observerId,
          'isPoller': isPoller,
        },
        '/nodes/node-1/neighbors' || '/nodes/node-2/neighbors' => [],
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
    isPoller = false;
    pollingOn = true;
    linked = true;
    pollerStatus = 200;
  });

  final pollerTab = find.text(trKey('nodePoller.tab'));
  final nodeDetails = find.text(trKey('nodePanel.details').toUpperCase());

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

  testWidgets('the Poller view is offered to a poller when polling is on', (
    tester,
  ) async {
    String? opened;
    isPoller = true;
    await pump(tester, onOpen: (kind, id) => opened = '$kind:$id');
    expect(pollerTab, findsOneWidget);
    // The poller loads only once its view is shown.
    expect(asked('/nodes/node-1/poller'), isFalse);

    await tester.tap(pollerTab);
    await tester.pumpAndSettle();
    expect(asked('/nodes/node-1/poller'), isTrue);
    expect(find.text('1 / 8', findRichText: true), findsOneWidget);
    expect(find.text('Polled One'), findsOneWidget);
    expect(nodeDetails, findsNothing);
    expect(find.text('Node One'), findsOneWidget);

    await tester.tap(find.text('Polled One'));
    expect(opened, 'node:node-9');

    await tester.tap(find.text(trKey('observerMerge.node')));
    await tester.pumpAndSettle();
    expect(nodeDetails, findsOneWidget);
    expect(find.text('Polled One'), findsNothing);
  });

  testWidgets('the Poller view is not offered without all three conditions', (
    tester,
  ) async {
    await pump(tester);
    expect(pollerTab, findsNothing);
    expect(asked('/info'), isFalse);

    isPoller = true;
    pollingOn = false;
    await pump(tester);
    expect(find.text(trKey('observerMerge.observer')), findsOneWidget);
    expect(pollerTab, findsNothing);

    pollingOn = true;
    linked = false;
    await pump(tester);
    expect(find.text(trKey('observerMerge.node')), findsNothing);
    expect(pollerTab, findsNothing);
    expect(asked('/nodes/node-1/poller'), isFalse);
  });

  testWidgets('a server without the poller route drops the option', (
    tester,
  ) async {
    isPoller = true;
    pollerStatus = 404;
    await pump(tester);
    await tester.tap(pollerTab);
    await tester.pumpAndSettle();
    expect(asked('/nodes/node-1/poller'), isTrue);
    expect(pollerTab, findsNothing);
    expect(find.text(trKey('observerMerge.observer')), findsOneWidget);
    expect(nodeDetails, findsOneWidget);
  });

  testWidgets('a failed poller load can be retried', (tester) async {
    isPoller = true;
    pollerStatus = 500;
    await pump(tester);
    await tester.tap(pollerTab);
    await tester.pumpAndSettle();
    expect(pollerTab, findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    pollerStatus = 200;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Polled One'), findsOneWidget);
  });

  testWidgets('another node opens on its node view', (tester) async {
    isPoller = true;
    await pump(tester);
    await tester.tap(pollerTab);
    await tester.pumpAndSettle();
    expect(find.text('Polled One'), findsOneWidget);

    await pump(tester, id: 'node-2');
    expect(find.text('Node Two'), findsOneWidget);
    expect(nodeDetails, findsOneWidget);
    expect(pollerTab, findsOneWidget);
    expect(find.text('Polled One'), findsNothing);
    expect(asked('/nodes/node-2/poller'), isFalse);
  });

  testWidgets('pull to refresh reloads the poller view', (tester) async {
    isPoller = true;
    await pump(tester);
    await tester.tap(pollerTab);
    await tester.pumpAndSettle();
    int asks() =>
        seen.where((u) => u.path == '/api/v1/nodes/node-1/poller').length;
    expect(asks(), 1);
    unawaited(
      tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show(),
    );
    await tester.pumpAndSettle();
    expect(asks(), 2);
    expect(find.text('Polled One'), findsOneWidget);
  });

  testWidgets('the poller view copies a link to it', (tester) async {
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
    isPoller = true;
    await pump(tester);
    await tester.tap(pollerTab);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy link'));
    await tester.pumpAndSettle();
    expect(Uri.parse(copied!).queryParameters, {
      'tab': 'Nodes',
      'node': 'node-1',
      'view': 'poller',
    });
  });
}
