import 'package:beacon/core/region_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const members = {
    'golm': ['YYZ', 'YHM'],
    'ottawa': ['YOW'],
    'empty': <String>[],
  };

  test('regions stay regions and flatten to codes for queries', () {
    const s = RegionSelection(regions: {'golm'}, areas: {'YOW', 'YHM'});
    expect(s.toParams(members), {'iatas': 'YHM,YOW,YYZ'});
  });

  test('nothing selected means all regions', () {
    expect(RegionSelection.all.toParams(members), <String, dynamic>{});
    expect(RegionSelection.restore(null, {}).isAll, isTrue);
  });

  test('a region with no member codes asks for the region itself', () {
    const s = RegionSelection(regions: {'empty'});
    expect(s.toParams(members), {'region': 'empty', 'iatas': ''});
  });

  test('saved selections round trip', () {
    const s = RegionSelection(regions: {'golm'}, areas: {'YOW'});
    final back = RegionSelection.restore(s.toJson(), s.toParams(members));
    expect(back.regions, {'golm'});
    expect(back.areas, {'YOW'});
  });

  test('older saved selections read their codes as areas', () {
    final legacy = RegionSelection.restore(null, {'iatas': 'YYZ,YHM'});
    expect(legacy.regions, isEmpty);
    expect(legacy.areas, {'YYZ', 'YHM'});
    final emptyRegion = RegionSelection.restore(null, {
      'region': 'empty',
      'iatas': '',
    });
    expect(emptyRegion.regions, {'empty'});
    expect(emptyRegion.areas, isEmpty);
  });

  test('header label matches the web wording', () {
    expect(RegionSelection.all.label, 'ALL');
    expect(const RegionSelection(areas: {'YYJ', 'YVR'}).label, 'YVR, YYJ');
    expect(const RegionSelection(areas: {'A', 'B', 'C'}).label, '3 areas');
    expect(const RegionSelection(regions: {'golm'}).label, '1 region');
    expect(
      const RegionSelection(regions: {'a', 'b'}, areas: {'X', 'Y', 'Z'}).label,
      '2 regions · 3 areas',
    );
  });
}
