import 'dart:convert';

import '../../core/json.dart';
import 'atlas.dart';

/// Id for a node pin the server could not resolve. A card with it shows the
/// not-found state, and the stored JSON keeps the shape older builds read.
const nilId = '00000000-0000-0000-0000-000000000000';

final _hexKey = RegExp(r'^[\da-f]{64}$');

/// Stand-in observer id for an observer pin the server could not resolve,
/// unique per key so two such cards never share a grid key.
String placeholderObserverId(String key) =>
    '${key.substring(0, 8)}-${key.substring(8, 12)}-${key.substring(12, 16)}-'
    '${key.substring(16, 20)}-${key.substring(20, 32)}';

class ServerAtlas {
  const ServerAtlas({
    required this.revision,
    required this.atlas,
    required this.observerKeys,
  });
  final int revision;
  final SavedAtlas atlas;

  /// Observer id to public key. A local observer pin holds only the id, and the
  /// server needs the key when that id is a stand-in.
  final Map<String, String> observerKeys;
}

/// Null when the document is not an Atlas.
ServerAtlas? parseServerAtlas(Json doc) {
  final revision = doc['revision'];
  final pins = doc['pins'];
  if (revision is! int || pins is! List) return null;
  final keys = <String, String>{};
  final local = <Json>[];
  for (final raw in pins) {
    if (raw is! Map) continue;
    final pin = object(raw);
    if (pin['kind'] == 'observer') {
      final key = pin['observerPublicKey'];
      if (key is! String || !_hexKey.hasMatch(key.toLowerCase())) continue;
      final id = pin['observerId'] is String
          ? pin['observerId'] as String
          : placeholderObserverId(key.toLowerCase());
      keys[id] = key.toLowerCase();
      local.add({
        'kind': 'observer',
        'observerId': id,
        'name': pin['name'],
        'tiles': pin['tiles'],
      });
    } else {
      local.add({
        'kind': 'node',
        'id': pin['id'] is String ? pin['id'] : nilId,
        'publicKey': pin['publicKey'],
        'name': pin['name'],
        'observerId': pin['observerId'],
        'tiles': pin['tiles'],
        'telemetryTiles': pin['telemetryTiles'],
        'view': pin['view'],
      });
    }
  }
  // The local parser applies the same checks, dedupe and cap as a restore.
  final atlas = parseAtlas(
    jsonEncode({'version': 2, 'range': doc['range'], 'pins': local}),
  );
  return ServerAtlas(revision: revision, atlas: atlas, observerKeys: keys);
}

/// The PUT body for [saved]. A stand-in observer goes out by key; any other
/// observer by id, as a local pin only has that. An older server rejects the
/// Telemetry fields, so without [telemetry] they stay out.
Json atlasPutBody(
  SavedAtlas saved,
  Map<String, String> keys,
  int revision, {
  bool telemetry = true,
}) => {
  'baseRevision': revision,
  'range': saved.range.id,
  'pins': [
    for (final pin in saved.pins)
      if (pin.isNode)
        {
          'kind': 'node',
          'publicKey': pin.publicKey,
          'name': pin.name,
          'tiles': ?pin.tiles,
          if (telemetry) 'telemetryTiles': ?pin.telemetryTiles,
          'view': ?(pin.view == AtlasView.telemetry && !telemetry
              ? null
              : pin.view?.name),
        }
      else
        {
          'kind': 'observer',
          if (keys[pin.observerId] case final key?
              when placeholderObserverId(key) == pin.observerId)
            'observerPublicKey': key
          else
            'observerId': pin.observerId,
          'name': pin.name,
          'tiles': ?pin.tiles,
        },
  ],
};

class AtlasMerge {
  const AtlasMerge(this.atlas, {required this.upload, this.dropped = 0});
  final SavedAtlas atlas;

  /// The result differs from the server copy and has to be sent.
  final bool upload;

  /// Local cards that did not fit within the limit.
  final int dropped;
}

/// Every way a pin can be recognised: by node key or by observer id.
Set<String> _identities(AtlasPin pin, Map<String, String> keys) => {
  if (pin.isNode) 'n:${pin.publicKey}',
  if (pin.observerId != null) 'o:${pin.observerId}',
  if (!pin.isNode && keys[pin.observerId] != null) 'n:${keys[pin.observerId]}',
};

/// First sign-in on a device: server pins first in their order, then local pins
/// not already there, up to the limit.
AtlasMerge mergeFirstSignIn(ServerAtlas server, SavedAtlas local) {
  if (local.pins.isEmpty) return AtlasMerge(server.atlas, upload: false);
  if (server.atlas.pins.isEmpty) return AtlasMerge(local, upload: true);
  final pins = [...server.atlas.pins];
  final seen = <String>{
    for (final pin in pins) ..._identities(pin, server.observerKeys),
  };
  var added = 0, dropped = 0;
  for (final pin in local.pins) {
    final ids = _identities(pin, const {});
    if (ids.any(seen.contains)) continue;
    if (pins.length >= atlasLimit) {
      dropped++;
      continue;
    }
    pins.add(pin);
    seen.addAll(ids);
    added++;
  }
  return AtlasMerge(
    server.atlas.copyWith(pins: pins),
    upload: added > 0,
    dropped: dropped,
  );
}

/// Against a server that does not store the Telemetry fields, the local copy
/// keeps them: a card's tiles and pinned view are put back on the server's pins.
SavedAtlas carryTelemetry(SavedAtlas server, SavedAtlas local) {
  final mine = {for (final pin in local.pins) pin.key: pin};
  return server.copyWith(
    pins: [
      for (final pin in server.pins)
        if (pin.isNode && mine[pin.key]?.isNode == true)
          AtlasPin.node(
            id: pin.id!,
            publicKey: pin.publicKey!,
            name: pin.name,
            observerId: pin.observerId,
            tiles: pin.tiles,
            telemetryTiles: pin.telemetryTiles ?? mine[pin.key]!.telemetryTiles,
            view: pin.view == null && mine[pin.key]!.view == AtlasView.telemetry
                ? AtlasView.telemetry
                : pin.view,
          )
        else
          pin,
    ],
  );
}
