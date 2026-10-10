import 'package:beacon/app.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:beacon/features/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Probe extends StatelessWidget {
  const _Probe();
  @override
  Widget build(BuildContext context) => const Scaffold(
    appBar: _Bar(),
    body: Center(child: DirectoryText('Retry')),
  );
}

class _Bar extends StatelessWidget implements PreferredSizeWidget {
  const _Bar();
  @override
  Size get preferredSize => const Size.fromHeight(56);
  @override
  Widget build(BuildContext context) => AppBar(leading: const BackButton());
}

Future<Preferences> _prefs(String code) async {
  SharedPreferences.setMockInitialValues({'beacon.language': code});
  return Preferences.load();
}

void main() {
  // Outside fake async: the theme asset is decoded on an isolate.
  setUpAll(BeaconTheme.load);
  tearDown(() => language = 'en');

  testWidgets('const labels and Material strings follow a language switch', (
    tester,
  ) async {
    final prefs = await _prefs('en');
    await tester.pumpWidget(BeaconApp(preferences: prefs, connectLive: false));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(builder: (_) => const _Probe()));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);

    await prefs.setLanguage('fr');
    await tester.pumpAndSettle();
    expect(find.text('Réessayer'), findsOneWidget);
    expect(find.byTooltip('Retour'), findsOneWidget);

    await prefs.setLanguage('sv');
    await tester.pumpAndSettle();
    expect(find.text('Försök igen'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('welcome and settings render in French', (tester) async {
    final prefs = await _prefs('fr');
    await tester.pumpWidget(BeaconApp(preferences: prefs, connectLive: false));
    await tester.pumpAndSettle();
    expect(find.text('Connectez-vous à votre maillage'), findsOneWidget);
    expect(find.text('Ajouter un serveur'), findsOneWidget);

    await tester.tap(find.byTooltip('Réglages'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Licences'), findsOneWidget);
    expect(find.text('APPARENCE'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('directory section titles are translated', (tester) async {
    language = 'sv';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: section('Capabilities', const [Text('x')])),
      ),
    );
    expect(find.text('FUNKTIONER'), findsOneWidget);
  });
}
