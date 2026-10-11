import 'package:flutter/material.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'directory_widgets.dart';

/// At most one decimal, with the active language's decimal separator.
String meshMapperNumber(num value) {
  final fixed = value.toStringAsFixed(1);
  final text = fixed.endsWith('.0')
      ? fixed.substring(0, fixed.length - 2)
      : fixed;
  return language == 'en' ? text : text.replaceAll('.', ',');
}

/// MeshMapper's view of a repeater, from the optional `meshmapper` object on
/// node detail. Every string is admin-entered free text: shown as plain text.
class MeshMapperSection extends StatelessWidget {
  const MeshMapperSection({super.key, required this.data});
  final Json data;

  /// False when there is nothing to show; carpeater alone is covered by the
  /// Identity badge.
  static bool hasContent(Json data) {
    final site = object(data['site']);
    return [
          'hardware',
          'power',
          'powerSource',
          'antenna',
          'notes',
        ].any((k) => textOf(site[k]).isNotEmpty) ||
        number(site['heightM']) != null ||
        rows(data['scopes']).isNotEmpty ||
        data['scopesCheckedAt'] != null ||
        list(data['admins']).isNotEmpty ||
        data['defaultScope'] is Map;
  }

  static List<dynamic> list(dynamic value) => value is List ? value : const [];

  @override
  Widget build(BuildContext context) {
    final colors = BeaconColors.of(context);
    final site = object(data['site']);
    final dim = TextStyle(fontSize: 11, color: colors.muted);
    String text(String key) => textOf(site[key]);
    String option(String key, String value) {
      final translated = trKey('$key.$value');
      return translated == '$key.$value' ? value : translated;
    }

    final heightM = number(site['heightM']);
    final heightAslM = number(site['heightAslM']);
    final admins = [
      for (final a in list(data['admins']))
        if (textOf(a).isNotEmpty) textOf(a),
    ];
    final defaultScope = data['defaultScope'] is Map
        ? object(data['defaultScope'])
        : null;
    String defaultScopeText(Json scope) {
      final source = textOf(scope['source']);
      final detail = [
        if (source.isNotEmpty) option('meshMapper.scopeSource', source),
        if (scope['updatedAt'] != null) age(scope['updatedAt']),
      ].join(', ');
      final name = textOf(scope['name']);
      final value = scope['state'] == 'named' && name.isNotEmpty
          ? name
          : trKey(
              scope['state'] == 'none'
                  ? 'meshMapper.scopeState.none'
                  : 'meshMapper.scopeState.unknown',
            );
      return detail.isEmpty ? value : '$value ($detail)';
    }

    final scopes = rows(data['scopes']);
    final checkedAt = data['scopesCheckedAt'];
    final iata = textOf(data['iata']);

    Widget footer(String value) => Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 11,
        color: colors.muted,
      ),
    );

    Widget scopeRow(Json s) {
      final how = [
        if (number(s['observedPackets']) case final num n)
          trKey('meshMapper.observedPackets', count: n.toInt())
        else if (s['observedAt'] != null)
          trKey('meshMapper.observed'),
        if (s['reportedAt'] != null) trKey('meshMapper.reported'),
        if (s['uploadedAt'] != null) trKey('meshMapper.uploaded'),
      ].join(' · ');
      final latest = [
        s['observedAt'],
        s['reportedAt'],
        s['uploadedAt'],
      ].map((v) => number(v) ?? 0).fold<num>(0, (a, b) => a > b ? a : b);
      return Padding(
        padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                textOf(s['scope']),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  color: colors.bright,
                ),
              ),
            ),
            if (how.isNotEmpty) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  how,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: dim,
                ),
              ),
            ],
            const Spacer(),
            if (latest > 0)
              Tooltip(
                message: stamp(latest),
                child: mono(age(latest), color: colors.muted),
              ),
          ],
        ),
      );
    }

    return section(trKey('meshMapper.title'), [
      if (text('hardware').isNotEmpty)
        fact(trKey('meshMapper.hardware'), text('hardware')),
      if (text('power').isNotEmpty)
        fact(trKey('meshMapper.power'), text('power')),
      if (text('powerSource').isNotEmpty)
        fact(
          trKey('meshMapper.powerSource'),
          option('meshMapper.powerSources', text('powerSource')),
        ),
      if (text('antenna').isNotEmpty)
        fact(trKey('meshMapper.antenna'), text('antenna')),
      if (heightM != null)
        fact(
          trKey('meshMapper.height'),
          [
            trKey('meshMapper.heightAgl')
                .replaceAll('{{value}}', meshMapperNumber(heightM)),
            if (heightAslM != null)
              trKey('meshMapper.heightAsl')
                  .replaceAll('{{value}}', meshMapperNumber(heightAslM)),
          ].join(' · '),
        ),
      if (admins.isNotEmpty)
        fact(trKey('meshMapper.admins'), admins.join(', ')),
      if (defaultScope != null)
        fact(trKey('meshMapper.defaultScope'), defaultScopeText(defaultScope)),
      if (scopes.isNotEmpty || checkedAt != null) ...[
        Padding(
          padding: const EdgeInsets.only(top: 5, bottom: 2),
          child: Text(trKey('meshMapper.confirmedScopes'), style: dim),
        ),
        if (scopes.isNotEmpty)
          ...scopes.map(scopeRow)
        else
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
            child: Row(
              children: [
                Text(trKey('meshMapper.noConfirmedScopes'), style: dim),
                const Spacer(),
                Tooltip(
                  message: stamp(checkedAt),
                  child: mono(age(checkedAt), color: colors.muted),
                ),
              ],
            ),
          ),
      ],
      if (text('notes').isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            text('notes'),
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
        ),
      const SizedBox(height: 8),
      Row(
        children: [
          Flexible(child: footer(trKey('meshMapper.fromMeshMapper'))),
          if (iata.isNotEmpty) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: .08),
                border: Border.all(color: colors.primary.withValues(alpha: .3)),
                borderRadius: BorderRadius.circular(3),
              ),
              child: mono(iata, color: colors.primary),
            ),
          ],
          const SizedBox(width: 12),
          const Spacer(),
          Flexible(
            child: Tooltip(
              message: stamp(data['fetchedAt']),
              child: footer(
                '${trKey('meshMapper.updated')} ${age(data['fetchedAt'])}',
              ),
            ),
          ),
        ],
      ),
    ]);
  }
}
