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
}
