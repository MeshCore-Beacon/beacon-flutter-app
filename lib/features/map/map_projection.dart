import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// MapLibre Android queries use physical screen pixels; its iOS API uses
/// logical UIKit points. Native tap coordinates already follow that convention.
Rect nativeViewport(Size size, TargetPlatform platform, double pixelRatio) {
  final scale = _scale(platform, pixelRatio);
  return Rect.fromLTWH(0, 0, size.width * scale, size.height * scale);
}

// Live dots are 3 px; a fingertip needs a wider target than the dot itself.
Rect nativeTapRect(
  math.Point<double> point,
  TargetPlatform platform,
  double pixelRatio, {
  double radius = 14,
}) => Rect.fromCircle(
  center: Offset(point.x, point.y),
  radius: radius * _scale(platform, pixelRatio),
);

double _scale(TargetPlatform platform, double pixelRatio) =>
    platform == TargetPlatform.android ? pixelRatio : 1.0;
