import 'dart:convert';

import 'package:beacon/features/atlas/atlas.dart';
import 'package:beacon/features/atlas/atlas_sync.dart';
import 'package:flutter_test/flutter_test.dart';

const nodeId = '11111111-1111-4111-8111-111111111111';
const obsId = '44444444-4444-4444-8444-444444444444';
final key = 'ab' * 32, otherKey = 'cd' * 32, obsKey = 'ef' * 32;

Map<String, dynamic> serverNode(
  String publicKey, {
  String? id,
  String? observerId,
  List<String>? tiles,
  String? view,
  String name = 'Hill',
}) => {
  'kind': 'node',
  'publicKey': publicKey,
  'id': id,
  'name': name,
  'observerId': observerId,
  'tiles': ?tiles,
  'view': ?view,
};

Map<String, dynamic> serverObserver(
  String publicKey, {
  String? observerId,
  String name = 'Roof',
}) => {
  'kind': 'observer',
  'observerPublicKey': publicKey,
  'observerId': observerId,
  'name': name,
};

Map<String, dynamic> doc(
  List<Map<String, dynamic>> pins, {
  int revision = 3,
  String range = '24h',
}) => {'revision': revision, 'range': range, 'limit': 12, 'pins': pins};

AtlasPin node(String publicKey, {String name = 'N', String? observerId}) =>
    AtlasPin.node(
      id: nodeId,
      publicKey: publicKey,
      name: name,
      observerId: observerId,
    );

String keyN(int i) => i.toRadixString(16).padLeft(2, '0') * 32;

void main() {
  group('server document to SavedAtlas', () {
    test('keeps order, range, tiles and view', () {
      final tiles = ['airtime', 'battery', 'uptime', 'noise'];
      final server = parseServerAtlas(
        doc([
          serverNode(key, id: nodeId, observerId: obsId, view: 'heard'),
          serverObserver(obsKey, observerId: obsId, name: 'Ridge')
            ..['tiles'] = tiles,
        ], range: '3d'),
      )!;
      expect(server.revision, 3);
      expect(server.atlas.range, AtlasRange.threeDays);
      final pins = server.atlas.pins;
      expect(pins[0].isNode, true);
      expect(pins[0].id, nodeId);
      expect(pins[0].observerId, obsId);
      expect(pins[0].view, AtlasView.heard);
      expect(pins[1].isNode, false);
      expect(pins[1].observerId, obsId);
      expect(pins[1].tiles, tiles);
      expect(server.observerKeys, {obsId: obsKey});
    });

    test('a node pin with no id becomes a pin the card cannot find', () {
      final server = parseServerAtlas(doc([serverNode(key)]))!;
      expect(server.atlas.pins.single.id, nilId);
      expect(server.atlas.pins.single.publicKey, key);
    });

    test('an observer pin with no id gets a distinct stand-in id', () {
      final server = parseServerAtlas(
        doc([serverObserver(obsKey), serverObserver(keyN(1))]),
      )!;
      final ids = [for (final pin in server.atlas.pins) pin.observerId];
      expect(ids.toSet().length, 2);
      expect(ids.first, placeholderObserverId(obsKey));
      expect(server.observerKeys[ids.first], obsKey);
    });

    test('the stored JSON keeps the shape older builds read', () {
      final server = parseServerAtlas(
        doc([serverNode(key, id: nodeId, view: 'observer', observerId: obsId)]),
      )!;
      final stored = jsonDecode(server.atlas.encode()) as Map;
      expect(stored.keys, ['version', 'range', 'pins']);
      expect((stored['pins'] as List).single, {
        'kind': 'node',
        'id': nodeId,
        'publicKey': key,
        'name': 'Hill',
        'observerId': obsId,
        'view': 'observer',
      });
    });

    test('malformed documents are refused', () {
      expect(parseServerAtlas({}), isNull);
      expect(parseServerAtlas({'revision': 'x', 'pins': []}), isNull);
      expect(parseServerAtlas({'revision': 1, 'pins': 'x'}), isNull);
    });

    test('an empty document reads as an empty Atlas', () {
      final server = parseServerAtlas({'revision': 0, 'pins': []})!;
      expect(server.atlas.pins, isEmpty);
      expect(server.atlas.range, AtlasRange.day);
    });
  });

  group('SavedAtlas to PUT body', () {
    test('local pins go out by id, node pins by key', () {
      final saved = SavedAtlas(
        range: AtlasRange.threeDays,
        pins: [
          AtlasPin.node(
            id: nodeId,
            publicKey: key,
            name: 'Hill',
            observerId: obsId,
            tiles: const ['airtime', 'battery', 'uptime', 'noise'],
            view: AtlasView.heard,
          ),
          const AtlasPin.observer(observerId: obsId, name: 'Roof'),
        ],
      );
      expect(atlasPutBody(saved, const {}, 7), {
        'baseRevision': 7,
        'range': '3d',
        'pins': [
          {
            'kind': 'node',
            'publicKey': key,
            'name': 'Hill',
            'tiles': ['airtime', 'battery', 'uptime', 'noise'],
            'view': 'heard',
          },
          {'kind': 'observer', 'observerId': obsId, 'name': 'Roof'},
        ],
      });
    });

    test('a stand-in observer goes out by its public key', () {
      final server = parseServerAtlas(doc([serverObserver(obsKey)]))!;
      final body = atlasPutBody(server.atlas, server.observerKeys, 1);
      expect((body['pins'] as List).single, {
        'kind': 'observer',
        'observerPublicKey': obsKey,
        'name': 'Roof',
      });
    });

    test('a real observer id is sent as the id even when the key is known', () {
      const saved = SavedAtlas(
        pins: [AtlasPin.observer(observerId: obsId, name: 'Roof')],
      );
      final body = atlasPutBody(saved, {obsId: obsKey}, 0);
      expect((body['pins'] as List).single['observerId'], obsId);
      expect(
        (body['pins'] as List).single.containsKey('observerPublicKey'),
        false,
      );
    });
  });

  group('first sign-in merge', () {
    ServerAtlas server(List<AtlasPin> pins, {AtlasRange? range}) => ServerAtlas(
      revision: 4,
      atlas: SavedAtlas(range: range ?? AtlasRange.day, pins: pins),
      observerKeys: const {},
    );

    test('an empty server takes the local Atlas', () {
      final local = SavedAtlas(range: AtlasRange.threeDays, pins: [node(key)]);
      final merged = mergeFirstSignIn(server([]), local);
      expect(merged.upload, true);
      expect(merged.atlas.range, AtlasRange.threeDays);
      expect(merged.atlas.pins.single.publicKey, key);
      expect(merged.dropped, 0);
    });

    test('nothing on either side uploads nothing', () {
      final merged = mergeFirstSignIn(server([]), const SavedAtlas());
      expect(merged.upload, false);
      expect(merged.atlas.pins, isEmpty);
    });

    test('only the server has pins: use them, upload nothing', () {
      final merged = mergeFirstSignIn(
        server([node(key)], range: AtlasRange.threeDays),
        const SavedAtlas(),
      );
      expect(merged.upload, false);
      expect(merged.atlas.range, AtlasRange.threeDays);
      expect(merged.atlas.pins.single.publicKey, key);
    });

    test('server pins first, then local pins not already present', () {
      final merged = mergeFirstSignIn(
        server([node(key, name: 'S1'), node(otherKey, name: 'S2')]),
        SavedAtlas(
          range: AtlasRange.threeDays,
          pins: [
            node(otherKey, name: 'L1'),
            node(keyN(7), name: 'L2'),
          ],
        ),
      );
      expect(
        [for (final pin in merged.atlas.pins) pin.name],
        ['S1', 'S2', 'L2'],
      );
      expect(merged.atlas.range, AtlasRange.day);
      expect(merged.upload, true);
      expect(merged.dropped, 0);
    });

    test('local pins already on the server mean nothing to upload', () {
      final merged = mergeFirstSignIn(
        server([node(key)]),
        SavedAtlas(pins: [node(key, name: 'again')]),
      );
      expect(merged.upload, false);
      expect(merged.atlas.pins.single.name, 'N');
    });

    test('a local observer pin matches a server node pin linked to it', () {
      final merged = mergeFirstSignIn(
        server([node(key, observerId: obsId)]),
        const SavedAtlas(
          pins: [AtlasPin.observer(observerId: obsId, name: 'Roof')],
        ),
      );
      expect(merged.atlas.pins.length, 1);
      expect(merged.upload, false);
    });

    test('a local node pin matches a server observer pin on its key', () {
      final merged = mergeFirstSignIn(
        ServerAtlas(
          revision: 1,
          atlas: const SavedAtlas(
            pins: [AtlasPin.observer(observerId: obsId, name: 'Roof')],
          ),
          observerKeys: {obsId: obsKey},
        ),
        SavedAtlas(pins: [node(obsKey)]),
      );
      expect(merged.atlas.pins.length, 1);
    });

    test('counts the local cards that did not fit in twelve', () {
      final merged = mergeFirstSignIn(
        server([for (var i = 0; i < 10; i++) node(keyN(i))]),
        SavedAtlas(pins: [for (var i = 20; i < 25; i++) node(keyN(i))]),
      );
      expect(merged.atlas.pins.length, 12);
      expect(merged.dropped, 3);
      expect(merged.upload, true);
      expect(merged.atlas.pins[10].publicKey, keyN(20));
    });
  });
}
