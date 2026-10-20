import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/preferences.dart';
import 'core/strings.dart';
import 'core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([BeaconTheme.load(), loadStrings()]);
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'MeshMapper',
    ], await rootBundle.loadString('docs/licenses/meshmapper-MIT.txt'));
    for (final family in ['Inter', 'JetBrainsMono']) {
      yield LicenseEntryWithLineBreaks([
        family,
      ], await rootBundle.loadString('assets/fonts/$family-LICENSE.txt'));
    }
  });
  final preferences = await Preferences.load();
  runApp(BeaconApp(preferences: preferences));
}
