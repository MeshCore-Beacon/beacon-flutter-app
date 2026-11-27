import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app.dart';
import 'core/account.dart';
import 'core/auth_api.dart';
import 'core/preferences.dart';
import 'core/push.dart';
import 'core/push_apns.dart';
import 'core/push_firebase.dart';
import 'core/push_relay.dart';
import 'core/push_store.dart';
import 'core/strings.dart';
import 'core/theme.dart';
import 'core/token_store.dart';
import 'features/account/sign_in.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([BeaconTheme.load(), loadStrings()]);
  LicenseRegistry.addLicense(() async* {
    for (final family in ['Inter', 'JetBrainsMono']) {
      yield LicenseEntryWithLineBreaks([
        family,
      ], await rootBundle.loadString('assets/fonts/$family-LICENSE.txt'));
    }
  });
  final tokens = SecureTokenStore();
  final preferences = await Preferences.load(tokens: tokens);
  final accounts = AccountRegistry();
  final pushStore = SecurePushStore();
  runApp(
    BeaconApp(
      preferences: preferences,
      tokens: tokens,
      accounts: accounts,
      signInFlow: SignInFlow(
        apiFor: (url) => AuthApi(url, tokens),
        launch: (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
        now: DateTime.now,
        accountFor: (url) => accounts[url],
      ),
      linkSource: AppLinksSource(),
      push: PushHub(
        // A platform constant, so release iOS builds drop the Firebase client.
        client: Platform.isIOS
            ? ApnsPushClient()
            : FirebasePushClient(store: pushStore),
        store: pushStore,
        relay: PushRelay(),
      ),
    ),
  );
}
