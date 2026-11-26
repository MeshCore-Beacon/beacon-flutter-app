import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/filter_sheet.dart';
import 'package:beacon/features/packets/packet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('payload filters refetch from server and reset cursor', (
    tester,
  ) async {
    final requests = <Uri>[];
    final api = ApiClient(
      Uri.parse('https://test'),
      client: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode(
            request.url.path.endsWith('/scopes')
                ? ['#bc']
                : {'items': [], 'hasMore': true, 'nextCursor': 7},
          ),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketScreen(api: api, region: {}, onOpen: (_, _) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-Payload type')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('search-Payload type')),
      'adv',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'ADVERT'));
    await tester.pumpAndSettle();
    final request = requests.lastWhere((r) => r.path.endsWith('/packets'));
    expect(request.queryParameters['payloadTypes'], '4');
    expect(request.queryParameters.containsKey('cursor'), false);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('the sheet matches the directory sheet and Clear all resets', (
    tester,
  ) async {
    final requests = <Uri>[];
    final api = ApiClient(
      Uri.parse('https://test'),
      client: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode(
            request.url.path.endsWith('/scopes')
                ? ['#bc']
                : {'items': [], 'hasMore': false},
          ),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketScreen(api: api, region: {}, onOpen: (_, _) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    // Floating labels live inside the field's decorator, not above it.
    for (final label in ['Payload type', 'Route type', 'Observers', 'Scope']) {
      final field = find.byKey(ValueKey('filter-$label'));
      expect(
        find.descendant(of: field, matching: find.byType(InputDecorator)),
        findsOneWidget,
        reason: label,
      );
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Any'), findsNWidgets(4));
    // One Clear all, in the footer beside the primary button, not the header.
    expect(find.text('Clear all'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Clear all'),
        matching: find.byType(FilterSheetFooter),
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('filter-Payload type')));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('search-Payload type'));
    await tester.enterText(search, 'adv');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'ADVERT'));
    await tester.pumpAndSettle();
    await tester.enterText(search, 'grp_t');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'GRP_TXT'));
    await tester.pumpAndSettle();
    expect(
      requests
          .lastWhere((r) => r.path.endsWith('/packets'))
          .queryParameters['payloadTypes'],
      '4,5',
    );
    await tester.tap(find.byKey(const ValueKey('filter-Payload type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();
    expect(
      requests
          .lastWhere((r) => r.path.endsWith('/packets'))
          .queryParameters
          .containsKey('payloadTypes'),
      false,
    );
    expect(find.text('Any'), findsNWidgets(4));
    await tester.pumpWidget(const SizedBox());
  });
}
