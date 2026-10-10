import 'dart:convert';
import 'dart:io';

import 'package:beacon/core/strings.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> catalog(String code) {
  final out = <String, String>{};
  void walk(Map<String, dynamic> node, String prefix) {
    for (final MapEntry(:key, :value) in node.entries) {
      final path = prefix.isEmpty ? key : '$prefix.$key';
      if (value is Map<String, dynamic>) {
        walk(value, path);
      } else {
        out[path] = '$value';
      }
    }
  }

  final json = jsonDecode(File('assets/locales/$code.json').readAsStringSync());
  walk(json['translation'] as Map<String, dynamic>, '');
  return out;
}

/// Single-quoted literals passed straight to [pattern], skipping
/// interpolated ones.
Map<String, String> literals(RegExp pattern) {
  final found = <String, String>{};
  for (final file in Directory('lib').listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.dart')) continue;
    final source = file.readAsStringSync();
    for (final match in pattern.allMatches(source)) {
      final text = match.group(1)!.replaceAll(r"\'", "'");
      if (text.contains(r'$')) continue;
      final line = '\n'.allMatches(source.substring(0, match.start)).length;
      found[text] = '${file.path}:${line + 1}';
    }
  }
  return found;
}

void main() {
  final en = catalog('en'), fr = catalog('fr'), sv = catalog('sv');

  test('every tr() and DirectoryText literal is in en.json', () {
    final values = en.values.toSet();
    final missing = {
      for (final MapEntry(:key, :value) in literals(
        RegExp(r"\b(?:tr|DirectoryText)\(\s*'((?:[^'\\\n]|\\.)*)'"),
      ).entries)
        if (!values.contains(key)) key: value,
    };
    expect(missing, isEmpty);
  });

  test('every trKey() literal is a catalog key', () {
    final missing = {
      for (final MapEntry(:key, :value) in literals(
        RegExp(r"\btrKey\(\s*'((?:[^'\\\n]|\\.)*)'"),
      ).entries)
        if (!en.containsKey(key) && !en.containsKey('${key}_other')) key: value,
    };
    expect(missing, isEmpty);
  });

  test('interpolated directory strings exist for every kind', () {
    final values = en.values.toSet();
    for (final kind in ['nodes', 'channels', 'observers', 'routes', 'traces']) {
      expect(values, contains('Search $kind'));
      expect(values, contains('No $kind found'));
      expect(en, contains('directory.count.${kind}_other'));
    }
    for (final kind in ['node', 'observer', 'channel', 'route', 'trace']) {
      expect(values, contains('$kind detail'));
    }
  });

  test('locales share one key set; only French adds _many', () {
    final frBase = {
      for (final key in fr.keys)
        if (!key.endsWith('_many')) key,
    };
    expect(frBase.difference(en.keys.toSet()), isEmpty);
    expect(en.keys.toSet().difference(frBase), isEmpty);
    expect(sv.keys.toSet(), en.keys.toSet());
    for (final key in fr.keys.where((k) => k.endsWith('_many'))) {
      final base = key.substring(0, key.length - 5);
      expect(en, contains('${base}_other'), reason: key);
    }
  });

  test('translations keep their placeholders', () {
    final placeholder = RegExp(r'\{\{\w+\}\}');
    Set<String> names(String text) =>
        placeholder.allMatches(text).map((m) => m[0]!).toSet();
    for (final MapEntry(:key, :value) in en.entries) {
      final base = key.replaceFirst(RegExp(r'_(one|other)$'), '');
      // A singular may spell out its count ("Heard once").
      if (key.endsWith('_one')) continue;
      expect(names(fr[key]!), names(value), reason: 'fr $base');
      expect(names(sv[key]!), names(value), reason: 'sv $base');
    }
  });

  group('lookup', () {
    tearDown(() => language = 'en');

    test('tr resolves shared English text deterministically', () {
      language = 'fr';
      expect(tr('All'), fr['common.all']);
      expect(tr('Unknown'), fr['packetRow.unknown']);
      expect(tr('not in the catalog'), 'not in the catalog');
    });

    test('trKey picks a variant and plural form', () {
      language = 'fr';
      expect(trKey('channels.keyUnknownOption'), 'Inconnue');
      expect(trKey('investigation.observations', count: 0), '0 observation');
      expect(trKey('investigation.observations', count: 2), '2 observations');
      language = 'sv';
      expect(trKey('routes.hops', count: 1), '1 hopp');
      language = 'en';
      expect(trKey('routes.hops', count: 1), '1 hop');
      expect(trKey('routes.hops', count: 3), '3 hops');
      expect(trKey('timestamp.unit.m', count: 5), '5m');
      expect(trKey('no.such.key'), 'no.such.key');
    });

    test('French many category', () {
      expect(pluralCategory('fr', 1000000), 'many');
      expect(pluralCategory('fr', 1), 'one');
      expect(pluralCategory('fr', 0), 'one');
      expect(pluralCategory('sv', 0), 'other');
      expect(pluralCategory('en', 1), 'one');
    });
  });
}
