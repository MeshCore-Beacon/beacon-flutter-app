import 'dart:convert';

import 'package:beacon/core/json.dart';
import 'package:beacon/features/account/request_text.dart';
import 'package:beacon/features/atlas/atlas_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/account/harness.dart';

final _a = '0f' * 32, _b = '1e' * 32, _c = '2d' * 32;

// What GET /me/atlas marshals: a node with a view, a node the server lost, and
// an observer pin whose observer row is gone (observerId null) with its tiles.
Json get _doc => object(
  jsonDecode('''
{"revision":7,"range":"3d","limit":12,"pins":[
 {"kind":"node","name":"Hilltop","publicKey":"$_a","id":"3f2b8c1e-6a52-4d0e-9b57-0d3d2b6a1c11","observerId":null,"view":"heard"},
 {"kind":"node","name":"Gone","publicKey":"$_b","id":null,"observerId":null},
 {"kind":"observer","name":"North Ridge","observerPublicKey":"$_c","observerId":null,"tiles":["snr","rssi","noise","queue"]}
]}'''),
);

void main() {
  setUp(loadAssets);

  test('reads null ids and omitted fields', () {
    final server = parseServerAtlas(_doc)!;
    expect(server.revision, 7);
    expect(server.atlas.range.id, '3d');
    expect(server.atlas.pins, hasLength(3));
    expect(server.atlas.pins[0].publicKey, _a);
    expect(server.atlas.pins[1].publicKey, _b);
    expect(server.atlas.pins[2].tiles, ['snr', 'rssi', 'noise', 'queue']);
  });

  test('sends a body the server validator accepts', () {
    final server = parseServerAtlas(_doc)!;
    final body = atlasPutBody(server.atlas, server.observerKeys, 7);
    expect(body.keys.toSet(), {'baseRevision', 'range', 'pins'});
    final pins = (body['pins'] as List).cast<Json>();
    expect(pins.length, lessThanOrEqualTo(12));
    for (final pin in pins) {
      expect(['node', 'observer'], contains(pin['kind']));
      if (pin['kind'] == 'node') {
        expect(pin['publicKey'], matches(RegExp(r'^[0-9a-f]{64}$')));
      } else {
        expect(
          pin.containsKey('observerId') || pin.containsKey('observerPublicKey'),
          isTrue,
        );
      }
      if (pin['view'] != null) {
        expect(['heard', 'observer'], contains(pin['view']));
      }
      final tiles = pin['tiles'] as List?;
      if (tiles != null) expect(tiles.toSet(), hasLength(4));
      expect((pin['name'] as String).runes.length, lessThanOrEqualTo(160));
    }
  });

  // A telemetry request as GET /me/telemetry-requests marshals it: poller
  // carries state and stateAt on a new server, neither on an old one.
  Json request(String poller) => object(
    jsonDecode(
      '{"id":"r1","status":"active","poller":$poller,"latestReadingAt":null}',
    ),
  );

  test('reads the poller state and its time, null or absent', () {
    final p = object(
      request(
        '{"observerId":"o1","name":"HOWL","state":"not_direct","stateAt":1700000000000}',
      )['poller'],
    );
    expect(p['state'], 'not_direct');
    expect(p['stateAt'], 1700000000000);
    expect(
      requestLineText(
        request(
          '{"observerId":"o1","name":"HOWL","state":"ok","stateAt":null}',
        ),
      ),
      'Being polled by HOWL',
    );
    expect(
      object(request('{"observerId":"o1","name":"HOWL"}')['poller'])
          .containsKey('state'),
      isFalse,
    );
    expect(requestLineText(request('null')), isNotEmpty);
  });
}
