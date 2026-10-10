import 'package:beacon/features/map/map_projection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native viewport query uses Android physical pixels and iOS points', () {
    expect(
      nativeViewport(const Size(400, 800), TargetPlatform.android, 3),
      const Rect.fromLTWH(0, 0, 1200, 2400),
    );
    expect(
      nativeViewport(const Size(400, 800), TargetPlatform.iOS, 3),
      const Rect.fromLTWH(0, 0, 400, 800),
    );
  });
}
