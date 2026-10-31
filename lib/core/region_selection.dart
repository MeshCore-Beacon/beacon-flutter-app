import 'json.dart';
import 'strings.dart';

/// The geographic filter, as the picker holds it: region slugs (each stands
/// for its member area codes) plus individually picked area codes. Matches
/// beacon-web's RegionSelection.
class RegionSelection {
  const RegionSelection({this.regions = const {}, this.areas = const {}});
  final Set<String> regions, areas;

  static const all = RegionSelection();
  bool get isAll => regions.isEmpty && areas.isEmpty;

  /// Stored form, saved next to the query params so the picker can show the
  /// selection again.
  Json toJson() => {
    'regions': regions.toList()..sort(),
    'areas': areas.toList()..sort(),
  };

  /// Reads [toJson] output. Without one (saved before the picker kept
  /// regions), falls back to the query params, whose codes come back as
  /// picked areas.
  factory RegionSelection.restore(Json? saved, Json params) {
    Set<String> list(dynamic value) =>
        value is List ? value.map((e) => '$e').toSet() : <String>{};
    if (saved != null) {
      return RegionSelection(
        regions: list(saved['regions']),
        areas: list(saved['areas']),
      );
    }
    return RegionSelection(
      regions: {
        if (textOf(params['region']).isNotEmpty) textOf(params['region']),
      },
      areas: textOf(params['iatas'])
          .split(',')
          .where((e) => e.isNotEmpty)
          .toSet(),
    );
  }

  /// The query params every screen filters on, unchanged in shape: the
  /// flattened, sorted `iatas`, plus `region` for a region with no members.
  Json toParams(Map<String, List<String>> members) {
    if (isAll) return {};
    final codes = {
      for (final slug in regions) ...?members[slug],
      ...areas,
    }.toList()..sort();
    return {
      if (codes.isEmpty && regions.isNotEmpty)
        'region': (regions.toList()..sort()).first,
      'iatas': codes.join(','),
    };
  }

  /// Compact header summary, e.g. "ALL", "YVR, YYJ", "2 regions · 3 areas".
  String get label {
    if (isAll) return tr('ALL');
    final sorted = areas.toList()..sort();
    return [
      if (regions.isNotEmpty) trKey('region.count', count: regions.length),
      if (areas.isNotEmpty)
        areas.length <= 2
            ? sorted.join(', ')
            : trKey('region.iataCount', count: areas.length),
    ].join(' · ');
  }
}
