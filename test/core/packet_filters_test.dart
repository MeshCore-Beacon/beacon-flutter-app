import 'dart:convert';

import 'package:beacon/core/api.dart';
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
}
