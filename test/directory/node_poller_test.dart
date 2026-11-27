import 'package:beacon/core/json.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/directory/node_chips.dart';
import 'package:beacon/features/directory/node_poller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const minute = 60000;
final now = DateTime.now().millisecondsSinceEpoch;

Json target({
  String? nodeId = 'n-1',
  String publicKey =
      '5be1c07a00000000000000000000000000000000000000000000000000000000',
  String? name = 'Carp Ridge',
  bool requested = false,
  String role = 'poller',
  int? rank,
  String state = 'ok',
  int misses = 0,
  int? lastOk,
  double? claimedSnr,
  double? evidenceSnr,
  int evidenceCount = 0,
  int? latestReadingAt,
}) => {
  'nodeId': nodeId,
  'publicKey': publicKey,
  'name': name,
  'requested': requested,
  'role': role,
  'rank': rank,
  'state': state,
  'misses': misses,
  'lastAttempt': lastOk,
  'lastOk': lastOk,
  'claimedSnr': claimedSnr,
  'evidenceSnr': evidenceSnr,
  'evidenceCount': evidenceCount,
  'latestReadingAt': latestReadingAt,
};

Json answer({
  List<Json> targets = const [],
  bool live = true,
  bool accepts = true,
  int max = 8,
  int own = 3,
  int requested = 2,
  int free = 3,
  int? receivedAt,
}) => {
  'claim': {
    'receivedAt': receivedAt ?? now - 12 * minute,
    'live': live,
    'acceptsRequests': accepts,
    'slots': {
      'max': max,
      'used': own + requested,
      'own': own,
      'requested': requested,
      'free': free,
    },
  },
  'readings24h': 212,
  'targets': targets,
};

void main() {
  setUpAll(BeaconTheme.load);

  Future<List<String>> pump(
    WidgetTester tester,
    Json data, {
    double width = 375,
  }) async {
    final opened = <String>[];
    tester.view.physicalSize = Size(width, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [NodePollerSection(data: data, onOpenNode: opened.add)],
          ),
        ),
      ),
    );
    await tester.pump();
    return opened;
  }

  List<PollerSeatKind> meter(WidgetTester tester) => tester
      .widgetList<PollerSeat>(
        find.descendant(
          of: find.byKey(const ValueKey('poller-meter')),
          matching: find.byType(PollerSeat),
        ),
      )
      .map((s) => s.kind)
      .toList();

  Color colorOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style!.color!;

  BeaconColors colors(WidgetTester tester) =>
      BeaconColors.of(tester.element(find.byType(NodePollerSection)));

  test('seats run own, requested, free, then not offered', () {
    expect(pollerSeats({'max': 4, 'own': 1, 'requested': 1, 'free': 1}), [
      PollerSeatKind.own,
      PollerSeatKind.requested,
      PollerSeatKind.free,
      PollerSeatKind.notOffered,
    ]);
    // Never more seats than the radio has.
    expect(pollerSeats({'max': 2, 'own': 3, 'requested': 1, 'free': 0}), [
      PollerSeatKind.own,
      PollerSeatKind.own,
    ]);
    expect(pollerSeats({}), isEmpty);
  });

  testWidgets('the slots section shows the count, meter and legend', (
    tester,
  ) async {
    await pump(tester, answer());
    expect(find.text('SLOTS'), findsOneWidget);
    expect(find.text('5 / 8', findRichText: true), findsOneWidget);
    expect(find.text('slots used'), findsOneWidget);
    expect(meter(tester), [
      ...List.filled(3, PollerSeatKind.own),
      ...List.filled(2, PollerSeatKind.requested),
      ...List.filled(3, PollerSeatKind.free),
    ]);
    expect(find.bySemanticsLabel('5 of 8 slots used'), findsOneWidget);
    expect(find.text('3 own'), findsOneWidget);
    expect(find.text('2 requested'), findsOneWidget);
    expect(find.text('3 free'), findsOneWidget);
    expect(find.textContaining('not offered'), findsNothing);
    expect(find.text('Last claim 12m ago', findRichText: true), findsOneWidget);
    expect(find.text('Requests accepting', findRichText: true), findsOneWidget);
    expect(
      find.text('Readings in 24 h 212', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('slots the radio holds back are drawn as not offered', (
    tester,
  ) async {
    await pump(tester, answer(free: 1, accepts: false));
    expect(meter(tester), [
      ...List.filled(3, PollerSeatKind.own),
      ...List.filled(2, PollerSeatKind.requested),
      PollerSeatKind.free,
      ...List.filled(2, PollerSeatKind.notOffered),
    ]);
    expect(find.text('1 free'), findsOneWidget);
    expect(find.text('2 not offered'), findsOneWidget);
    expect(
      find.text('Requests not accepting', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a stale claim warns and dims the meter and the cards', (
    tester,
  ) async {
    await pump(
      tester,
      answer(live: false, receivedAt: now - 180 * minute, targets: [target()]),
    );
    const line = 'Not currently polling. Last claim 3h ago.';
    expect(colorOf(tester, line), colors(tester).warning);
    expect(
      find.textContaining('Last claim', findRichText: true),
      findsOneWidget,
    );
    double opacity(Finder of) => tester
        .widget<Opacity>(
          find.ancestor(of: of, matching: find.byType(Opacity)).first,
        )
        .opacity;
    expect(opacity(find.byKey(const ValueKey('poller-meter'))), lessThan(1));
    expect(opacity(find.text('Carp Ridge')), lessThan(1));

    await pump(tester, answer(targets: [target()]));
    expect(opacity(find.byKey(const ValueKey('poller-meter'))), 1);
    expect(opacity(find.text('Carp Ridge')), 1);
  });

  testWidgets('a card names the repeater and tags its origin and role', (
    tester,
  ) async {
    await pump(
      tester,
      answer(
        targets: [
          target(name: 'Own Poller', publicKey: 'a1'),
          target(
            name: 'Asked Standby',
            publicKey: 'a2',
            requested: true,
            role: 'standby',
            rank: 2,
          ),
          target(name: null, publicKey: 'c4470b19ffff', role: 'unassigned'),
        ],
      ),
    );
    expect(find.text('REPEATERS IT POLLS'), findsOneWidget);
    final c = colors(tester);
    expect(colorOf(tester, 'Own Poller'), c.primary);
    expect(find.text('OWN'), findsNWidgets(2));
    expect(colorOf(tester, 'REQUESTED'), c.primary);
    expect(colorOf(tester, 'POLLER'), pollerColor);
    expect(find.text('STANDBY 2'), findsOneWidget);
    expect(find.text('NOT ASSIGNED'), findsOneWidget);
    final unnamed = tester.widget<Text>(find.text('c4470b19'));
    expect(unnamed.style!.fontStyle, FontStyle.italic);
    expect(unnamed.style!.color, c.dim);
  });

  testWidgets('each poll state has its own line', (tester) async {
    final states = {
      'ok': 'Answering',
      'pending': 'Waiting for the first poll',
      'no_reply': 'No reply, 3 in a row',
      'not_direct': 'Not in direct range',
      'login_failed': 'Login failed',
      'admin_stop': 'Stopped: repeater gave admin access',
      'brand_new': 'brand_new',
    };
    await pump(
      tester,
      answer(
        targets: [
          for (final state in states.keys)
            target(name: 'r-$state', publicKey: state, state: state, misses: 3),
          target(name: 'quiet', publicKey: 'quiet', state: ''),
        ],
      ),
    );
    final c = colors(tester);
    expect(
      {for (final text in states.values) text: colorOf(tester, text)},
      {
        'Answering': c.success,
        'Waiting for the first poll': c.muted,
        'No reply, 3 in a row': c.warning,
        'Not in direct range': c.danger,
        'Login failed': c.danger,
        'Stopped: repeater gave admin access': c.danger,
        'brand_new': c.muted,
      },
    );
    // An empty state draws no line: the card holds only its other texts.
    final quiet = find.descendant(
      of: find.byKey(const ValueKey('poller-target-quiet')),
      matching: find.byType(Text),
    );
    final answering = find.descendant(
      of: find.byKey(const ValueKey('poller-target-ok')),
      matching: find.byType(Text),
    );
    expect(quiet.evaluate().length, answering.evaluate().length - 1);
  });

  testWidgets('the stats and evidence lines fill in or say never', (
    tester,
  ) async {
    await pump(
      tester,
      answer(
        targets: [
          target(
            publicKey: 'full',
            lastOk: now - 14 * minute,
            latestReadingAt: now - 21 * minute,
            claimedSnr: 11.25,
            evidenceSnr: 10.4,
            evidenceCount: 22,
          ),
        ],
      ),
    );
    final c = colors(tester);
    expect(find.text('LAST REPLY'), findsOneWidget);
    expect(find.text('SNR'), findsOneWidget);
    expect(find.text('READING'), findsOneWidget);
    expect(find.text('14m ago'), findsOneWidget);
    expect(find.text('21m ago'), findsOneWidget);
    expect(colorOf(tester, '11.25'), c.success);
    expect(find.text('22 adverts heard, 10.40 dB'), findsOneWidget);

    await pump(
      tester,
      answer(targets: [target(evidenceSnr: 3, evidenceCount: 1)]),
    );
    expect(find.text('1 advert heard, 3.00 dB'), findsOneWidget);

    await pump(tester, answer(targets: [target(claimedSnr: 7.5)]));
    expect(colorOf(tester, '7.50'), c.warning);
    expect(find.text('never'), findsNWidgets(2));
    expect(find.text('No adverts heard from it'), findsOneWidget);

    await pump(tester, answer(targets: [target(claimedSnr: -4.5)]));
    expect(colorOf(tester, '-4.50'), c.danger);

    await pump(tester, answer(targets: [target()]));
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('empty states', (tester) async {
    await pump(tester, {'claim': null, 'readings24h': 0, 'targets': []});
    expect(find.text('This radio has no polling claim.'), findsOneWidget);
    expect(find.byType(PollerSeat), findsNothing);
    expect(find.text('REPEATERS IT POLLS'), findsNothing);

    await pump(tester, answer(own: 0, requested: 0, free: 8));
    expect(find.text('It polls no repeaters yet.'), findsOneWidget);
    expect(find.text('0 / 8', findRichText: true), findsOneWidget);
  });

  testWidgets('only a card with a node opens it', (tester) async {
    final opened = await pump(
      tester,
      answer(
        targets: [
          target(name: 'Known', publicKey: 'k1', nodeId: 'node-9'),
          target(name: 'Unknown', publicKey: 'k2', nodeId: null),
        ],
      ),
    );
    await tester.tap(find.text('Unknown'));
    expect(opened, isEmpty);
    await tester.tap(find.text('Known'));
    expect(opened, ['node-9']);
  });

  testWidgets('long names fit an iPhone-width screen', (tester) async {
    for (final width in [320.0, 375.0]) {
      await pump(
        tester,
        answer(
          max: 16,
          free: 4,
          targets: [
            target(
              name: 'A very long repeater name that keeps going ' * 3,
              requested: true,
              role: 'unassigned',
              state: 'admin_stop',
              lastOk: now - 400 * 24 * 60 * minute,
              latestReadingAt: now - 400 * 24 * 60 * minute,
              claimedSnr: -12.75,
              evidenceSnr: -10.25,
              evidenceCount: 123456,
            ),
          ],
        ),
        width: width,
      );
      expect(tester.takeException(), isNull);
    }
  });
}
