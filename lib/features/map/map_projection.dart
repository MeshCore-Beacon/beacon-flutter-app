import 'dart:ui';

import 'package:flutter/foundation.dart';

/// MapLibre Android queries use physical screen pixels; its iOS API uses
/// logical UIKit points. Native tap coordinates already follow that convention.
Rect nativeViewport(Size size, TargetPlatform platform, double pixelRatio) {
  final scale = platform == TargetPlatform.android ? pixelRatio : 1.0;
  return Rect.fromLTWH(0, 0, size.width * scale, size.height * scale);
}
