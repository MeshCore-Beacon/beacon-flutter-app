import 'dart:ui' as ui;

import 'package:beacon/features/map/map_markers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native density assets retain intended logical marker size', () async {
    final bytes = await markerImage('cluster-0', scale: 3);
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 264);
    expect(frame.image.height, 264);
    frame.image.dispose();
    codec.dispose();
  });
  test(
    'web node and cluster artwork rasterizes into native style images',
    () async {
      for (final key in markerSvgs.keys) {
        final bytes = await markerImage(key);
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 88, reason: key);
        expect(frame.image.height, 88, reason: key);
        frame.image.dispose();
        codec.dispose();
      }
    },
  );
  test(
    'lit icons are solid type discs with a white glyph and orange ring',
    () async {
      Future<List<int>> rgba(String key, int x, int y) async {
        final codec = await ui.instantiateImageCodec(await markerImage(key));
        final image = (await codec.getNextFrame()).image;
        final data = (await image.toByteData())!;
        final i = (y * image.width + x) * 4;
        final pixel = [for (var c = 0; c < 4; c++) data.getUint8(i + c)];
        image.dispose();
        codec.dispose();
        return pixel;
      }

      Matcher near(List<int> rgba) => pairwiseCompare<int, int>(
        rgba,
        (a, b) => (a - b).abs() <= 12,
        'within 12 of',
      );
      // Image pixel = SVG unit + 12 (viewBox -12 -12 88 88, scale 1).
      expect(await rgba('live-repeater', 22, 44), near([167, 139, 250, 255]));
      expect(await rgba('live-repeater', 44, 47), near([255, 255, 255, 255]));
      expect(await rgba('live-repeater', 83, 44), near([255, 107, 53, 255]));
      expect(await rgba('live-companion', 22, 44), near([59, 130, 246, 255]));
      for (final type in nodeColors.keys) {
        expect(
          liveMarkerSvg(type),
          isNot(contains('${nodeColors[type]}" stroke-width="3"')),
          reason: '$type glyph recoloured',
        );
        expect(liveMarkerSvg(type), contains('stroke-width="3"'));
      }
    },
  );
}
