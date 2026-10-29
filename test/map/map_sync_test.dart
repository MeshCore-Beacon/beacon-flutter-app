import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:beacon/core/api.dart';
import 'package:beacon/core/page_pacer.dart';
import 'package:beacon/features/map/map_repository.dart';
import 'package:beacon/features/map/map_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> node(
  String id, {
  String type = 'repeater',
  List<String> neighbors = const [],
  double lat = 45.4,
}) => {
  'id': id,
  'name': id,
  'nodeTypeName': type,
  'lat': lat,
  'lng': -75.7,
  'neighborIds': neighbors,
};

void main() {
  group('MapLayers', () {
    final nodes = [
      node('a', neighbors: ['b']),
      node('b', type: 'companion', neighbors: ['a'], lat: 45.5),
    ];
    const none = <Map<String, dynamic>>[];
    MapLayerData build(
      MapLayers layers, {
      List<Map<String, dynamic>>? of,
      String type = '',
      bool flow = false,
      String mode = 'on',
      String? selected,
      List<Map<String, dynamic>> neighbors = none,
      List<Map<String, dynamic>> borders = none,
    }) {
      final list = of ?? nodes;
      return layers.build(
        nodes: list,
        type: type,
        flow: flow,
        mode: mode,
        selected: selected,
        selectedNode: list.where((n) => n['id'] == selected).firstOrNull,
        neighbors: neighbors,
        borders: borders,
      );
    }

    test('a rebuild with the same inputs hands back the same data', () {
      final layers = MapLayers();
      final first = build(layers), again = build(layers);
      expect(first.points['features'], hasLength(2));
      expect(first.lines['features'], hasLength(1));
      expect(again.points, same(first.points));
      expect(again.lines, same(first.lines));
      expect(again.borders, same(first.borders));
      expect(again.live, isNull);
    });

    test('a new node list rebuilds the nodes and lines only', () {
      final layers = MapLayers();
      final first = build(layers), next = build(layers, of: [...nodes]);
      expect(next.points, isNot(same(first.points)));
      expect(next.lines, isNot(same(first.lines)));
      expect(next.borders, same(first.borders));
    });

    test('turning borders on rebuilds only the borders', () {
      final layers = MapLayers();
      final first = build(layers);
      final next = build(
        layers,
        borders: [
          {'type': 'Feature'},
        ],
      );
      expect(next.borders['features'], hasLength(1));
      expect(next.borders, isNot(same(first.borders)));
      expect(next.points, same(first.points));
      expect(next.lines, same(first.lines));
    });

    test('a selection redraws the lines and keeps the node data', () {
      final layers = MapLayers();
      final first = build(layers), next = build(layers, selected: 'a');
      expect(next.points, same(first.points));
      expect(next.lines, isNot(same(first.lines)));
      expect(
        (next.lines['features'] as List).single['properties']['selected'],
        isTrue,
      );
    });

    test('a type filter rebuilds the nodes and keeps the lines', () {
      final layers = MapLayers();
      final first = build(layers), next = build(layers, type: 'repeater');
      expect(next.points['features'], hasLength(1));
      expect(next.points, isNot(same(first.points)));
      expect(next.lines, same(first.lines));
    });

    test('live keeps a selected node of another type, built once', () {
      final layers = MapLayers();
      final first = build(layers, flow: true, type: 'repeater', selected: 'b');
      final again = build(layers, flow: true, type: 'repeater', selected: 'b');
      expect((first.points['features'] as List).map((f) => f['id']), [
        'a',
        'b',
      ]);
      expect(first.live!['features'], hasLength(2));
      expect(again.points, same(first.points));
      expect(again.live, same(first.live));
    });

    test('focused lines are built once per neighbour list', () {
      final layers = MapLayers();
      final neighbors = [node('c', lat: 45.6)];
      final first = build(
        layers,
        mode: 'selected',
        selected: 'a',
        neighbors: neighbors,
      );
      final again = build(
        layers,
        mode: 'selected',
        selected: 'a',
        neighbors: neighbors,
      );
      expect(first.lines['features'], hasLength(1));
      expect(again.lines, same(first.lines));
    });
  });

  group('MapSync', () {
    MapWrite write(String id, Object? key, List<String> log) =>
        (id: id, key: key, send: () async => log.add('$id=$key'));

    test('sends only what the native map does not already hold', () async {
      final sent = <String>[];
      var links = 'l1';
      final sync = MapSync(
        () => [write('nodes', 'n1', sent), write('links', links, sent)],
        onError: (e) => fail('$e'),
      );
      await sync.sync();
      expect(sent, ['nodes=n1', 'links=l1']);
      // a camera-only rebuild changes nothing
      await sync.sync();
      expect(sent, hasLength(2));
      links = 'l2';
      await sync.sync();
      expect(sent, ['nodes=n1', 'links=l1', 'links=l2']);
    });

    test('a write the map never had is sent even with a null key', () async {
      final sent = <String>[];
      final sync = MapSync(
        () => [write('selected', null, sent)],
        onError: (e) => fail('$e'),
      );
      await sync.sync();
      await sync.sync();
      expect(sent, ['selected=null']);
    });

    test('calls during a send collapse into one send of the latest', () async {
      final sent = <int>[];
      final gate = Completer<void>();
      var version = 1, running = 0, most = 0;
      final sync = MapSync(() {
        final v = version;
        return [
          (
            id: 'nodes',
            key: v,
            send: () async {
              most = math.max(most, ++running);
              sent.add(v);
              await gate.future;
              running--;
            },
          ),
        ];
      }, onError: (e) => fail('$e'));
      final first = sync.sync();
      await pumpEventQueue();
      for (final v in [2, 3, 4]) {
        version = v;
        await sync.sync();
      }
      expect(sent, [1]);
      gate.complete();
      await first;
      expect(sent, [1, 4]);
      expect(most, 1);
    });

    test('a failed write is reported and sent again next time', () async {
      final errors = <Object>[];
      var attempts = 0;
      final sync = MapSync(
        () => [
          (
            id: 'nodes',
            key: 'n1',
            send: () async {
              if (++attempts == 1) throw StateError('channel');
            },
          ),
        ],
        onError: errors.add,
      );
      await sync.sync();
      expect(errors, [isStateError]);
      await sync.sync();
      expect(attempts, 2);
      await sync.sync();
      expect(attempts, 2);
    });

    test('newer data asked for during a failed send still goes out', () async {
      final errors = <Object>[], sent = <int>[];
      final gate = Completer<void>();
      var version = 1;
      final sync = MapSync(() {
        final v = version;
        return [
          (
            id: 'nodes',
            key: v,
            send: () async {
              if (v == 1) {
                await gate.future;
                throw StateError('channel');
              }
              sent.add(v);
            },
          ),
        ];
      }, onError: errors.add);
      final first = sync.sync();
      await pumpEventQueue();
      version = 2;
      await sync.sync();
      gate.complete();
      await first;
      expect(errors, hasLength(1));
      expect(sent, [2]);
    });

    test('close stops a batch before its next write', () async {
      final sent = <String>[];
      final gate = Completer<void>();
      final sync = MapSync(
        () => [
          (
            id: 'nodes',
            key: 'n1',
            send: () async {
              sent.add('nodes');
              await gate.future;
            },
          ),
          write('links', 'l1', sent),
        ],
        onError: (e) => fail('$e'),
      );
      final first = sync.sync();
      await pumpEventQueue();
      sync.close();
      gate.complete();
      await first;
      await sync.sync();
      expect(sent, ['nodes']);
    });
  });

  group('throttleLatest', () {
    const second = Duration(seconds: 1);

    testWidgets(
      'shows the first event at once, then the latest once a second',
      (tester) async {
        final source = StreamController<int>();
        final seen = <int>[];
        final sub = throttleLatest(source.stream, second).listen(seen.add);
        source.add(1);
        await tester.pump();
        expect(seen, [1]);
        source
          ..add(2)
          ..add(3);
        await tester.pump(const Duration(milliseconds: 500));
        expect(seen, [1]);
        await tester.pump(const Duration(milliseconds: 500));
        expect(seen, [1, 3]);
        source.add(4);
        await tester.pump(const Duration(milliseconds: 999));
        expect(seen, [1, 3]);
        await tester.pump(const Duration(milliseconds: 1));
        expect(seen, [1, 3, 4]);
        // a second with nothing held ends the hold
        await tester.pump(second);
        source.add(5);
        await tester.pump();
        expect(seen, [1, 3, 4, 5]);
        // awaiting these resumes outside the test's fake clock
        unawaited(sub.cancel());
        unawaited(source.close());
      },
    );

    testWidgets('the last event shows as soon as the source ends', (
      tester,
    ) async {
      final source = StreamController<int>();
      final seen = <int>[];
      var done = false;
      throttleLatest(
        source.stream,
        second,
      ).listen(seen.add, onDone: () => done = true);
      source
        ..add(1)
        ..add(2)
        ..add(3);
      unawaited(source.close());
      await tester.pump();
      expect(seen, [1, 3]);
      expect(done, isTrue);
    });

    testWidgets('a held event shows before the error after it', (tester) async {
      final source = StreamController<int>();
      final log = <Object>[];
      throttleLatest(
        source.stream,
        second,
      ).listen(log.add, onError: (Object e) => log.add('error $e'));
      source
        ..add(1)
        ..add(2)
        ..addError('incomplete');
      await tester.pump();
      expect(log, [1, 2, 'error incomplete']);
      unawaited(source.close());
    });

    testWidgets('cancelling stops the source and drops the hold', (
      tester,
    ) async {
      var cancelled = false;
      final source = StreamController<int>(onCancel: () => cancelled = true);
      final seen = <int>[];
      final sub = throttleLatest(source.stream, second).listen(seen.add);
      source
        ..add(1)
        ..add(2);
      await tester.pump();
      unawaited(sub.cancel());
      await tester.pump();
      expect(cancelled, isTrue);
      await tester.pump(const Duration(seconds: 2));
      expect(seen, [1]);
      unawaited(source.close());
    });

    testWidgets('a held-back map load still ends with every node', (
      tester,
    ) async {
      // past the page burst, so pages keep landing while updates are held
      var requests = 0;
      final api = ApiClient(
        Uri.parse('https://example.org'),
        client: MockClient((r) async {
          final n = ++requests;
          return http.Response(
            jsonEncode({
              'items': [
                {'id': 'n$n'},
              ],
              'hasMore': n < 45,
              'nextCursor': 'c$n',
            }),
            200,
          );
        }),
      );
      final shown = <int>[];
      final done = throttleLatest(
        loadMapNodes(api, {}, pacer: PagePacer(now: tester.binding.clock.now)),
        second,
      ).forEach((nodes) => shown.add(nodes.length));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await done;
      expect(requests, 45);
      expect(shown, [1, 44, 45]);
      api.close();
    });
  });
}
