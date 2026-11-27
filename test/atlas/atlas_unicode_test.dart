import 'package:beacon/features/atlas/atlas.dart';
import 'package:beacon/features/atlas/atlas_sync.dart';
import 'package:flutter_test/flutter_test.dart';

const nodeId = '11111111-1111-4111-8111-111111111111';
const observerId = '44444444-4444-4444-8444-444444444444';
final nodeKey = 'ab' * 32, observerKey = 'cd' * 32;

SavedAtlas collection(String name) => SavedAtlas(
  range: AtlasRange.threeDays,
  pins: [
    AtlasPin.node(
      id: nodeId,
      publicKey: nodeKey,
      name: name,
      tiles: const ['snr', 'rssi', 'queue', 'errors'],
      telemetryTiles: const ['temperature', 'packets', 'signal', 'errors'],
      view: AtlasView.telemetry,
    ),
    AtlasPin.observer(
      observerId: observerId,
      name: name,
      tiles: const ['snr', 'battery', 'queue', 'errors'],
    ),
  ],
);

void main() {
  const face = '\u{1f600}';
  final names = <String, (String, String)>{
    '160 supplementary characters': (face * 160, face * 160),
    '159 ASCII plus one supplementary': (
      '${'a' * 159}$face',
      '${'a' * 159}$face',
    ),
    '161 supplementary characters': (face * 161, face * 160),
    '159 ASCII plus two supplementary': (
      '${'a' * 159}$face$face',
      '${'a' * 159}$face',
    ),
    'ASCII': ('a' * 161, 'a' * 160),
    'BMP': ('\u00e9' * 161, '\u00e9' * 160),
    'escaped controls': ('\n' * 161, '\n' * 160),
    'combining code points without normalization': (
      'e\u0301' * 81,
      'e\u0301' * 80,
    ),
  };

  for (final entry in names.entries) {
    final (raw, normalized) = entry.value;
    test('node and observer local roundtrips: ${entry.key}', () {
      final original = collection(raw);
      final expected = collection(normalized).toJson();
      expect(parseAtlas(original.encode()).toJson(), expected);

      var appended = const SavedAtlas(range: AtlasRange.threeDays);
      for (final pin in original.pins) {
        appended = appended.appended(pin);
      }
      expect(appended.toJson(), expected);

      final imported = readAtlasFile(atlasFile(original), limit: 2)!;
      expect(imported.skipped, 0);
      expect(imported.atlas.toJson(), expected);
      expect(
        readAtlasFile(atlasFile(imported.atlas), limit: 2)!.atlas.toJson(),
        expected,
      );
      expect(
        readAtlasFile(atlasFile(original), limit: 1)!.atlas.pins,
        hasLength(1),
      );
    });

    test('node and observer account conversions: ${entry.key}', () {
      final original = collection(raw);
      final server = parseServerAtlas({
        'revision': 7,
        'range': '3d',
        'limit': 20,
        'pins': [
          original.pins.first.toJson(),
          {...original.pins.last.toJson(), 'observerPublicKey': observerKey},
        ],
      })!;
      expect(server.atlas.toJson(), collection(normalized).toJson());
      final put = atlasPutBody(
        server.atlas,
        server.observerKeys,
        server.revision,
      );
      expect(put['baseRevision'], 7);
      expect(put['range'], '3d');
      expect(
        [for (final pin in put['pins'] as List) pin['name']],
        [normalized, normalized],
      );
    });
  }
}
