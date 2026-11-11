import 'dart:convert';

import '../../core/api.dart';
import '../../core/json.dart';

const atlasLimit = 12;

enum AtlasRange {
  day('24h', 24, '24h'),
  threeDays('3d', 72, '72h');

  const AtlasRange(this.id, this.hours, this.duration);
  final String id;
  final int hours;

  /// Go duration string the activity and telemetry endpoints expect.
  final String duration;
}

enum AtlasView { analytics, heard, observer }

/// The metrics an Observer view tile can show. A pin stores its four only when
/// they differ from the default.
const observerTiles = [
  'airtime',
  'battery',
  'uptime',
  'types',
  'packets',
  'snr',
  'rssi',
  'noise',
  'queue',
  'errors',
];
const defaultTiles = ['airtime', 'battery', 'types', 'noise'];

final _uuid = RegExp(
  r'^[\da-f]{8}(-[\da-f]{4}){3}-[\da-f]{12}$',
  caseSensitive: false,
);
final _publicKey = RegExp(r'^[\da-f]{64}$', caseSensitive: false);
bool _isUuid(dynamic value) => value is String && _uuid.hasMatch(value);

class AtlasPin {
  const AtlasPin.node({
    required String this.id,
    required String this.publicKey,
    required this.name,
    this.observerId,
    this.tiles,
    this.view,
  }) : isNode = true;
  const AtlasPin.observer({
    required String this.observerId,
    required this.name,
    this.tiles,
  }) : isNode = false,
       id = null,
       publicKey = null,
       view = null;

  final bool isNode;
  final String? id, publicKey, observerId;
  final String name;

  /// Four tile ids in slot order; null for the default layout.
  final List<String>? tiles;

  /// The tab a node card opens on; null for Analytics.
  final AtlasView? view;

  String get key => isNode ? publicKey! : observerId!;

  /// Field order matches the web export so files diff cleanly.
  Json toJson() => isNode
      ? {
          'kind': 'node',
          'id': id,
          'publicKey': publicKey,
          'name': name,
          'observerId': ?observerId,
          'tiles': ?tiles,
          'view': ?view?.name,
        }
      : {
          'kind': 'observer',
          'observerId': observerId,
          'name': name,
          'tiles': ?tiles,
        };

  AtlasPin withTiles(List<String> next) {
    final kept = _tiles(next);
    return isNode
        ? AtlasPin.node(
            id: id!,
            publicKey: publicKey!,
            name: name,
            observerId: observerId,
            tiles: kept,
            view: view,
          )
        : AtlasPin.observer(observerId: observerId!, name: name, tiles: kept);
  }

  AtlasPin withView(AtlasView next) => AtlasPin.node(
    id: id!,
    publicKey: publicKey!,
    name: name,
    observerId: observerId,
    tiles: tiles,
    view: next == AtlasView.analytics ? null : next,
  );

  /// A node pin under a new server id or observer link.
  AtlasPin relinked(String nodeId, String? observer) => AtlasPin.node(
    id: nodeId,
    publicKey: publicKey!,
    name: name,
    observerId: observer,
    tiles: tiles,
    view: view,
  );

  /// The tab the card opens on. A pinned Observer view waits for the observer
  /// link without being forgotten.
  AtlasView get homeView {
    if (!isNode) return AtlasView.observer;
    if (view == AtlasView.observer && observerId == null) {
      return AtlasView.analytics;
    }
    return view ?? AtlasView.analytics;
  }
}

class SavedAtlas {
  const SavedAtlas({this.range = AtlasRange.day, this.pins = const []});
  final AtlasRange range;
  final List<AtlasPin> pins;
  Json toJson() => {
    'version': 2,
    'range': range.id,
    'pins': [for (final pin in pins) pin.toJson()],
  };
  String encode() => jsonEncode(toJson());
  SavedAtlas copyWith({AtlasRange? range, List<AtlasPin>? pins}) =>
      SavedAtlas(range: range ?? this.range, pins: pins ?? this.pins);

  /// Re-parsed so an add goes through the same checks, dedupe and cap as a restore.
  SavedAtlas appended(AtlasPin pin) =>
      parseAtlas(copyWith(pins: [...pins, pin]).encode());
}

/// Four distinct known ids in slot order; null for anything else and for the default layout.
List<String>? _tiles(dynamic raw) {
  if (raw is! List || raw.length != defaultTiles.length) return null;
  if (raw.toSet().length != raw.length) return null;
  if (!raw.every(observerTiles.contains)) return null;
  for (var i = 0; i < raw.length; i++) {
    if (raw[i] != defaultTiles[i]) return List<String>.from(raw);
  }
  return null;
}

AtlasPin? _pin(dynamic raw) {
  if (raw is! Map) return null;
  final rawName = raw['name'];
  final name = rawName is String
      ? (rawName.length > 160 ? rawName.substring(0, 160) : rawName)
      : '';
  final tiles = _tiles(raw['tiles']);
  final observerId = raw['observerId'];
  if (raw['kind'] == 'observer') {
    return _isUuid(observerId)
        ? AtlasPin.observer(
            observerId: observerId as String,
            name: name,
            tiles: tiles,
          )
        : null;
  }
  final id = raw['id'], key = raw['publicKey'];
  if (raw['kind'] != 'node' ||
      !_isUuid(id) ||
      key is! String ||
      !_publicKey.hasMatch(key)) {
    return null;
  }
  return AtlasPin.node(
    id: id as String,
    publicKey: key.toLowerCase(),
    name: name,
    observerId: _isUuid(observerId) ? observerId as String : null,
    tiles: tiles,
    view: switch (raw['view']) {
      'heard' => AtlasView.heard,
      'observer' => AtlasView.observer,
      _ => null,
    },
  );
}

/// Only a version 2 payload loads; anything else is empty.
SavedAtlas parseAtlas(String? raw) {
  try {
    if (raw == null || raw.isEmpty || raw.length > 32000) {
      return const SavedAtlas();
    }
    final value = jsonDecode(raw);
    if (value is! Map || value['version'] != 2 || value['pins'] is! List) {
      return const SavedAtlas();
    }
    final pins = <AtlasPin>[];
    for (final entry in value['pins'] as List) {
      final pin = _pin(entry);
      if (pin == null || pins.any((other) => other.key == pin.key)) continue;
      pins.add(pin);
      if (pins.length == atlasLimit) break;
    }
    return SavedAtlas(
      range: value['range'] == '3d' ? AtlasRange.threeDays : AtlasRange.day,
      pins: pins,
    );
  } catch (_) {
    return const SavedAtlas();
  }
}

/// The export file is the saved Atlas plus a format tag. Web and app read and
/// write the same file.
const atlasFileFormat = 'beacon-atlas';
const atlasFileMaxBytes = 256000;

String atlasFile(SavedAtlas saved, {DateTime? now}) =>
    const JsonEncoder.withIndent('  ').convert({
      'format': atlasFileFormat,
      'version': 2,
      'exportedAt': (now ?? DateTime.now()).millisecondsSinceEpoch,
      'range': saved.range.id,
      'pins': [for (final pin in saved.pins) pin.toJson()],
    });

String atlasFileName([DateTime? now]) =>
    'beacon-atlas-${(now ?? DateTime.now()).toUtc().toIso8601String().substring(0, 10)}.json';

class AtlasImport {
  const AtlasImport(this.atlas, this.skipped);
  final SavedAtlas atlas;
  final int skipped;
}

/// Null when the text is not an Atlas export. Pins go through the same checks,
/// dedupe and cap as a restore.
AtlasImport? readAtlasFile(String text) {
  if (text.length > atlasFileMaxBytes) return null;
  dynamic value;
  try {
    value = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (value is! Map ||
      value['format'] != atlasFileFormat ||
      value['pins'] is! List) {
    return null;
  }
  final atlas = parseAtlas(jsonEncode(value));
  return AtlasImport(atlas, (value['pins'] as List).length - atlas.pins.length);
}

bool isNotFound(Object? error) => error is ApiException && error.status == 404;

Future<Json?> _nodeByKey(ApiClient api, String key) async {
  final page = await api.getCached('/nodes', {'pubkey': key, 'limit': 2});
  for (final row in rows(page)) {
    if (textOf(row['publicKey']).toLowerCase() == key) return row;
  }
  return null;
}

/// The same radio can be a node and an observer; when it advertises, the node is the pin.
Future<Json?> resolveObserverNode(ApiClient api, Json observer) async {
  final key = textOf(observer['publicKey']).toLowerCase();
  return key.isEmpty ? null : _nodeByKey(api, key);
}

/// Resolve by full identity after a server database reset; never adopt a
/// different node at an old id.
Future<Json> loadAtlasNode(ApiClient api, AtlasPin pin) async {
  final key = pin.publicKey!;
  Json? node;
  try {
    node = object(await api.getCached('/nodes/${pin.id}'));
  } catch (error) {
    if (!isNotFound(error)) rethrow;
  }
  if (textOf(node?['publicKey']).toLowerCase() != key) {
    final match = await _nodeByKey(api, key);
    if (match == null) {
      throw const ApiException('Atlas identity unavailable', status: 404);
    }
    node = object(await api.getCached('/nodes/${textOf(match['id'])}'));
  }
  if (textOf(node?['publicKey']).toLowerCase() != key) {
    throw const ApiException('Atlas identity changed');
  }
  return node!;
}

const hourMs = 3600000;

/// Slots count back from the tick, newest last. The tick can trail the clock by
/// a minute, so a bucket up to an hour past it lands in the newest slot;
/// anything later is a bad clock and is dropped.
class HourSlots {
  const HourSlots(this.range, this.now);
  final AtlasRange range;
  final int now;
  int get hours => range.hours;
  int _age(num t) {
    final age = ((now - t) / hourMs).floor();
    return age < 0 ? 0 : age;
  }

  int bin(num t) => hours - 1 - _age(t);
  bool inWindow(num? t) =>
      t != null && t.isFinite && t < now + hourMs && _age(t) < hours;

  /// Zero for an hour the server read, null for one it has not: no reply yet,
  /// or between the rollups and the raw tail.
  List<double?> counts(Json? read) {
    final rawFrom = finite(read?['rawFrom']);
    final rolledUntil = finite(read?['rolledUntil']);
    return List<double?>.generate(hours, (i) {
      if (read == null) return null;
      final hour = ((now - (hours - 1 - i) * hourMs) / hourMs).floor() * hourMs;
      return rawFrom != null &&
              hour < rawFrom &&
              (rolledUntil == null || hour >= rolledUntil)
          ? null
          : 0;
    });
  }
}

class AtlasSample {
  const AtlasSample({
    required this.total,
    required this.partial,
    required this.counts,
    required this.present,
    required this.snrHourly,
    required this.rssiHourly,
    required this.snr,
    required this.rssi,
    required this.hops,
    required this.latestHash,
    required this.latestHeardAt,
  });
  final double? total, snr, rssi, hops;
  final bool partial;
  final List<double?> counts, snrHourly, rssiHourly;
  final List<bool> present;
  final String? latestHash;
  final int? latestHeardAt;
}

/// Totals and means are the server's (sum over samples); averaging the hourly
/// means here would skew them.
AtlasSample summarizeActivity(Json? activity, AtlasRange range, int now) {
  final slots = HourSlots(range, now);
  final counts = slots.counts(activity);
  final snrHourly = List<double?>.filled(slots.hours, null);
  final rssiHourly = List<double?>.filled(slots.hours, null);
  for (final p in rows(activity?['points'])) {
    final t = finite(p['t']);
    if (!slots.inWindow(t)) continue;
    final i = slots.bin(t!);
    final observations = finite(p['observations']);
    if (observations == null) {
      counts[i] = null;
      continue;
    }
    counts[i] = (counts[i] ?? 0) + observations;
    snrHourly[i] = finite(p['snrAvg']) ?? snrHourly[i];
    rssiHourly[i] = finite(p['rssiAvg']) ?? rssiHourly[i];
  }
  final summary = object(activity?['summary']);
  final latest = object(activity?['latest']);
  final hash = textOf(latest['packetHash']);
  return AtlasSample(
    total: finite(summary['observations']),
    partial: activity != null && counts.contains(null),
    counts: counts,
    present: [for (final count in counts) (count ?? 0) > 0],
    snrHourly: snrHourly,
    rssiHourly: rssiHourly,
    snr: finite(summary['snrAvg']),
    rssi: finite(summary['rssiAvg']),
    hops: finite(summary['hopAvg']),
    latestHash: hash.isEmpty ? null : hash,
    latestHeardAt: hash.isEmpty ? null : finite(latest['heardAt'])?.toInt(),
  );
}

/// A JSON number only; the web ignores numeric strings too.
double? finite(dynamic value) =>
    value is num && value.isFinite ? value.toDouble() : null;
