import 'package:beacon/core/api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/features/account/account_errors.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUp(loadAssets);
  tearDown(() => language = 'en');

  ApiException err(String code, int status) =>
      ApiException('raw server text', status: status, code: code);

  test('portal_managed has its own line in every language', () {
    for (final lang in supportedLanguages) {
      language = lang;
      final text = accountError(err('portal_managed', 404));
      expect(text, isNot(trKey('account.errors.generic')), reason: lang);
      expect(text, isNot('raw server text'));
      expect(text, isNot(startsWith('account.')));
    }
    language = 'en';
    expect(
      accountError(err('portal_managed', 404)),
      'Your sign-in is managed at the MeshMapper portal. Use it there.',
    );
  });

  test('a wrong username on delete says so, in every language', () {
    final expected = {
      'en': 'That is not your username.',
      'fr': 'Ce n’est pas votre nom d’utilisateur.',
      'sv': 'Det är inte ditt användarnamn.',
    };
    for (final lang in supportedLanguages) {
      language = lang;
      expect(
        deleteError(err('invalid_input', 422), portal: true),
        expected[lang],
        reason: lang,
      );
    }
    language = 'en';
    // A local account never sends a username, so there it stays the shared line.
    expect(
      deleteError(err('invalid_input', 422), portal: false),
      accountError(err('invalid_input', 422)),
    );
    expect(
      deleteError(err('invalid_credentials', 401), portal: false),
      'That password is not right.',
    );
  });
}
