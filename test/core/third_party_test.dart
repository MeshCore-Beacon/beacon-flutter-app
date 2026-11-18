import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The platform keys under flutter.plugin.platforms in a pubspec.
List<String> pluginPlatforms(String pubspec) {
  final lines = pubspec.split('\n');
  final start = lines.indexWhere((l) => l.trim() == 'platforms:');
  if (start < 0) return [];
  final indent = lines[start].indexOf('platforms:');
  final keys = <String>[];
  for (final line in lines.skip(start + 1)) {
    if (line.trim().isEmpty) continue;
    final depth = line.length - line.trimLeft().length;
    if (depth <= indent) break;
    if (depth == indent + 2) keys.add(line.trim().split(':').first);
  }
  return keys;
}

void main() {
  for (final name in ['firebase_core', 'firebase_messaging']) {
    test('vendored $name has no iOS plugin', () {
      final pubspec = File('third_party/$name/pubspec.yaml').readAsStringSync();
      final platforms = pluginPlatforms(pubspec);
      expect(platforms, contains('android'));
      expect(platforms, isNot(contains('ios')));
      expect(File('third_party/$name/LICENSE').existsSync(), isTrue);
    });
  }

  test('the app uses the vendored copies', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final name in ['firebase_core', 'firebase_messaging']) {
      expect(pubspec, contains('  $name:\n    path: third_party/$name\n'));
    }
  });

  test('an ios entry is caught', () {
    const pubspec = '''
flutter:
  plugin:
    platforms:
      android:
        pluginClass: A
      ios:
        pluginClass: B
other:
  ios: x
''';
    expect(pluginPlatforms(pubspec), ['android', 'ios']);
  });
}
