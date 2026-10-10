import 'dart:async';

import 'package:beacon/core/strings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every test sees the real catalogs, as the app does after startup.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadStrings();
  await testMain();
}
