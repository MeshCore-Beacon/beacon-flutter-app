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
    String? initialView,
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
          initialView: initialView,
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
  const refreshNote = ValueKey('poller-refresh-failed');
  int pollerAsks() =>
      seen.where((u) => u.path == '/api/v1/nodes/node-1/poller').length;
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
    // The route is asked at once: its answer is what offers the view.
    expect(asked('/nodes/node-1/poller'), isTrue);
    expect(pollerTab, findsOneWidget);
    expect(nodeDetails, findsOneWidget);

    await tester.tap(pollerTab);
    await tester.pumpAndSettle();
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

  testWidgets('a node asked for on its Poller view opens there', (
    tester,
  ) async {
    isPoller = true;
    await pump(tester, initialView: 'poller');
    expect(asked('/nodes/node-1/poller'), isTrue);
    expect(find.text('Polled One'), findsOneWidget);
    expect(nodeDetails, findsNothing);

    await tester.tap(find.text(trKey('observerMerge.node')));
    await tester.pumpAndSettle();
    expect(nodeDetails, findsOneWidget);
  });

  testWidgets('a node that offers no Poller view opens on Node instead', (
    tester,
  ) async {
    await pump(tester, initialView: 'poller');
    expect(pollerTab, findsNothing);
    expect(nodeDetails, findsOneWidget);
    expect(asked('/nodes/node-1/poller'), isFalse);

    isPoller = true;
    pollingOn = false;
    await pump(tester, id: 'node-2', initialView: 'poller');
    expect(pollerTab, findsNothing);
    expect(nodeDetails, findsOneWidget);
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
    // Never offered, so there is no tab to tap and lose.
    expect(asked('/nodes/node-1/poller'), isTrue);
    expect(pollerTab, findsNothing);
    expect(find.text(trKey('observerMerge.observer')), findsOneWidget);
    expect(nodeDetails, findsOneWidget);

    // Nor is it asked again.
    final before = pollerAsks();
    await tester.pump(pollerRefresh);
    await tester.pumpAndSettle();
    expect(pollerAsks(), before);

    await pump(tester, id: 'node-2', initialView: 'poller');
    expect(pollerTab, findsNothing);
    expect(nodeDetails, findsOneWidget);
  });

  testWidgets('the Poller view waits for a read that failed', (tester) async {
    isPoller = true;
    pollerStatus = 500;
    await pump(tester);
    expect(pollerTab, findsNothing);
    expect(nodeDetails, findsOneWidget);

    // The next minute's read answers, and the view is offered.
    pollerStatus = 200;
    await tester.pump(pollerRefresh);
    await tester.pumpAndSettle();
    expect(pollerTab, findsOneWidget);
  });

  testWidgets('a node opened on its Poller view shows a failed load there', (
    tester,
  ) async {
    isPoller = true;
    pollerStatus = 500;
    await pump(tester, initialView: 'poller');
    expect(pollerTab, findsOneWidget);
    expect(nodeDetails, findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byKey(refreshNote), findsNothing);

    pollerStatus = 200;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Polled One'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a failed refresh keeps the loaded view and offers a retry', (
    tester,
  ) async {
    isPoller = true;
    await pump(tester);
    await tester.tap(pollerTab);
    await tester.pumpAndSettle();
    expect(find.text('Polled One'), findsOneWidget);
    expect(find.byKey(refreshNote), findsNothing);

    pollerStatus = 500;
    unawaited(
      tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Polled One'), findsOneWidget);
    expect(find.text('1 / 8', findRichText: true), findsOneWidget);
    expect(find.byKey(refreshNote), findsOneWidget);
    expect(find.text(trKey('atlasNotes.refreshFailed')), findsOneWidget);

    pollerStatus = 200;
    await tester.tap(
      find.descendant(
        of: find.byKey(refreshNote),
        matching: find.text('Retry'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Polled One'), findsOneWidget);
    expect(find.byKey(refreshNote), findsNothing);
  });

  testWidgets('the poller refreshes every minute while the screen shows', (
    tester,
  ) async {
    isPoller = true;
    await pump(tester);
    expect(pollerAsks(), 1);
    await tester.pump(pollerRefresh);
    await tester.pumpAndSettle();
    expect(pollerAsks(), 2);

    Future<void> lifecycle(List<AppLifecycleState> states) async {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
    }

    // Nothing is read in the background; one read is owed on return.
    await lifecycle(const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    await tester.pump(pollerRefresh * 5);
    expect(pollerAsks(), 2);
    await lifecycle(const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await tester.pumpAndSettle();
    expect(pollerAsks(), 3);

    // Nor under another screen.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold())),
    );
    await tester.pumpAndSettle();
    await tester.pump(pollerRefresh * 3);
    expect(pollerAsks(), 3);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(pollerAsks(), 4);
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
  });

  testWidgets('pull to refresh reloads the poller view', (tester) async {
    isPoller = true;
    await pump(tester);
    await tester.tap(pollerTab);
    await tester.pumpAndSettle();
    int asks() => pollerAsks();
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
