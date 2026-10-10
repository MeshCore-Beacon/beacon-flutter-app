import 'package:beacon/core/preferences.dart';
import 'package:beacon/features/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('versionLabel tells releases from beta builds', () {
    expect(versionLabel('0.2.0'), 'Version 0.2.0');
    expect(versionLabel('1791597587'), 'Beta build 1791597587');
    expect(versionLabel(null), '');
  });

  Future<String> aboutSubtitle(
    WidgetTester tester,
    Future<String?> Function() appVersion,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await Preferences.load();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(preferences: prefs, appVersion: appVersion),
      ),
    );
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('about-version'));
    await tester.scrollUntilVisible(tile, 200);
    final subtitle = tester.widget<ListTile>(tile).subtitle! as Text;
    return subtitle.data!;
  }

  testWidgets('About shows the release version', (tester) async {
    expect(
      await aboutSubtitle(tester, () async => '0.2.0'),
      'Version 0.2.0\nNative MeshCore packet analyzer',
    );
  });

  testWidgets('About shows a beta build number', (tester) async {
    expect(
      await aboutSubtitle(tester, () async => '1791597587'),
      'Beta build 1791597587\nNative MeshCore packet analyzer',
    );
  });

  testWidgets('About falls back to the description alone', (tester) async {
    expect(
      await aboutSubtitle(tester, () async => throw StateError('no info')),
      'Native MeshCore packet analyzer',
    );
  });
}
