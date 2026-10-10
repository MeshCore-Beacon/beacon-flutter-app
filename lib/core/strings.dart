import 'dart:convert';

import 'package:flutter/services.dart';

import 'json.dart';

const supportedLanguages = ['en', 'fr', 'sv'];
String language = 'en';
final Map<String, Map<String, String>> _translations = {};

/// English text → catalog key, built once by [loadStrings].
final Map<String, String> _keys = {};
void _flatten(Json input, String prefix, Map<String, String> output) {
  for (final entry in input.entries) {
    final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
    final value = entry.value;
    if (value is String) {
      output[key] = value;
    } else if (value is Map) {
      _flatten(object(value), key, output);
    }
  }
}

Future<void> loadStrings() async {
  for (final code in supportedLanguages) {
    final flattened = <String, String>{};
    // loadString moves files over 50 KB to an isolate, which never finishes
    // inside widget tests' fake async.
    final bytes = await rootBundle.load('assets/locales/$code.json');
    _flatten(
      object(
        object(
          jsonDecode(
            utf8.decode(
              bytes.buffer.asUint8List(
                bytes.offsetInBytes,
                bytes.lengthInBytes,
              ),
            ),
          ),
        )['translation'],
      ),
      '',
      flattened,
    );
    _translations[code] = flattened;
  }
  _keys.clear();
  // Shared English text resolves to its first key in catalog order, except
  // that a plural `_one` key yields to a later non-`_one` key. Call sites that
  // need a particular variant (gender, plural) use [trKey].
  for (final MapEntry(:key, :value) in _translations['en']!.entries) {
    final current = _keys[value];
    if (current == null || current.endsWith('_one') && !key.endsWith('_one')) {
      _keys[value] = key;
    }
  }
}

/// Translates English UI text through the catalog key that carries it.
String tr(String english) {
  if (language == 'en') return english;
  final key = _keys[english];
  return (key == null ? null : _translations[language]?[key]) ?? english;
}

/// Translates by catalog key. With [count], picks the plural variant
/// (`_one`, `_other`, French `_many`) and fills `{{count}}`.
String trKey(String key, {int? count}) {
  String? find(String code) {
    final table = _translations[code];
    if (table == null) return null;
    if (count == null) return table[key];
    return table['${key}_${pluralCategory(code, count)}'] ??
        table['${key}_other'] ??
        table[key];
  }

  final text = find(language) ?? find('en') ?? key;
  return count == null ? text : text.replaceAll('{{count}}', '$count');
}

/// CLDR cardinal category for whole numbers.
String pluralCategory(String code, int count) => switch (code) {
  'fr' when count == 0 || count == 1 => 'one',
  'fr' when count % 1000000 == 0 => 'many',
  _ when count == 1 => 'one',
  _ => 'other',
};
