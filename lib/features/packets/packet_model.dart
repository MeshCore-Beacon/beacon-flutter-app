import '../../core/json.dart';

const payloadNames = <int, String>{
  0: 'REQ',
  1: 'RESPONSE',
  2: 'TXT_MSG',
  3: 'ACK',
  4: 'ADVERT',
  5: 'GRP_TXT',
  6: 'GRP_DATA',
  7: 'ANON_REQ',
  8: 'PATH',
  9: 'TRACE',
  10: 'MULTIPART',
  11: 'CONTROL',
  15: 'RAW_CUSTOM',
};
String payloadName(dynamic value) =>
    payloadNames[number(value)?.toInt()] ?? 'UNKNOWN';
List<Json> mergePacketPages(List<Json> current, List<Json> incoming) {
  final all = <String, Json>{
    for (final row in current) textOf(row['packetHash']): row,
  };
  for (final row in incoming) {
    final key = textOf(row['packetHash']);
    final old = all[key];
    if (old == null ||
        (number(row['lastHeardAt']) ?? 0) >=
            (number(old['lastHeardAt']) ?? 0)) {
      all[key] = row;
    }
  }
  return all.values.toList();
}

List<Json> mergePacketEvent(List<Json> current, Json data) {
  final packet = object(data['packet']);
  if (packet['isRepeat'] == true) return current;
  final observation = object(data['observation']);
  final hash = textOf(data['packetHash']);
  if (hash.isEmpty) return current;
  final existing =
      current.where((e) => e['packetHash'] == hash).firstOrNull ??
      <String, dynamic>{};
  final incoming = <String, dynamic>{
    ...existing,
    ...packet,
    'packetHash': hash,
    'firstHeardAt': existing['firstHeardAt'] ?? observation['heardAt'],
    'lastHeardAt': observation['heardAt'],
    'latestObserver': {
      ...observation,
      'id': observation['observerId'],
      'displayName': observation['observerName'],
    },
  };
  return existing.isEmpty
      ? [incoming, ...current]
      : mergePacketPages(current, [incoming]);
}

String observationFrame(Json detail, Json? observation) {
  String byte(dynamic value) => textOf(value, '00').padLeft(2, '0');
  String code(dynamic value) {
    final n = (number(value) ?? 0).toInt();
    return '${(n & 255).toRadixString(16).padLeft(2, '0')}${((n >> 8) & 255).toRadixString(16).padLeft(2, '0')}';
  }

  final transport = object(detail['transportCodes']);
  return '${byte(object(detail['header'])['raw'])}${transport.isEmpty ? '' : code(transport['regionCode']) + code(transport['subRegionCode'])}${observation == null ? '' : byte(object(observation['pathLength'])['raw']) + textOf(observation['pathBytes'])}${textOf(detail['rawPayload'])}';
}

class PacketBuffer {
  List<Json> _history = [];
  List<Json> _live = [];
  List<Json> get packets => mergePacketPages(_live, _history);
  void addHistory(List<Json> rows) {
    _history = mergePacketPages(_history, rows)
      ..sort(
        (a, b) => (number(b['lastHeardAt']) ?? 0).compareTo(
          number(a['lastHeardAt']) ?? 0,
        ),
      );
  }

  void addEvent(Json event) {
    _live = mergePacketEvent(_live, event).take(500).toList();
  }

  void reveal(List<Json> pending) {
    _live = mergePacketPages(pending, _live).take(500).toList();
  }

  void clearHistory() {
    _history = [];
  }

  void clear() {
    _history = [];
    _live = [];
  }
}

class PathSearch {
  const PathSearch(this.hashSize, this.bytes);
  final int hashSize;
  final String bytes;
}

PathSearch? parsePathSearch(String query) {
  final text = query.trim().toLowerCase();
  if (text.isEmpty) return const PathSearch(0, '');
  if (text.length > 1024) return null;
  final hops = text.split(RegExp(r'[\s,→]+'));
  final width = hops.first.length;
  if (!hops.every(
    (hop) =>
        hop.length == width && RegExp(r'^(?:[0-9a-f]{2}){1,4}$').hasMatch(hop),
  )) {
    return null;
  }
  return PathSearch(width ~/ 2, hops.join());
}

bool matchesPathSearch(Json packet, PathSearch? search) {
  if (search == null) return false;
  if (search.bytes.isEmpty) return true;
  final observer = object(packet['latestObserver']),
      length = object(object(packet['latestObserver'])['pathLength']);
  final bytes = textOf(observer['pathBytes']);
  final count = number(length['hopCount']);
  if (number(packet['payloadType']) == 9 ||
      length['hashSize'] != search.hashSize ||
      count == null ||
      count != count.truncateToDouble() ||
      count <= 0 ||
      bytes.length != count * search.hashSize * 2 ||
      search.bytes.length > bytes.length ||
      !RegExp(r'^[0-9a-f]+$', caseSensitive: false).hasMatch(bytes)) {
    return false;
  }
  final path = bytes.toLowerCase();
  for (
    var offset = 0;
    offset <= path.length - search.bytes.length;
    offset += search.hashSize * 2
  ) {
    if (path.startsWith(search.bytes, offset)) return true;
  }
  return false;
}

bool matchesPacketFilters(
  Json packet, {
  Set<int> payloadTypes = const {},
  Set<int> routeTypes = const {},
  Set<String> observers = const {},
  Set<String> scopes = const {},
  String search = '',
  String searchField = 'Hash',
  Map<String, Set<String>> observersByHash = const {},
}) {
  if (payloadTypes.isNotEmpty &&
      !payloadTypes.contains(number(packet['payloadType'])?.toInt())) {
    return false;
  }
  if (routeTypes.isNotEmpty &&
      !routeTypes.contains(number(packet['routeType'])?.toInt())) {
    return false;
  }
  if (observers.isNotEmpty) {
    final known = observersByHash[textOf(packet['packetHash'])];
    if (known != null
        ? !observers.any(known.contains)
        : !observers.contains(textOf(object(packet['latestObserver'])['id']))) {
      return false;
    }
  }
  if (scopes.isNotEmpty && !scopes.contains(textOf(packet['scope']))) {
    return false;
  }
  if (searchField == 'Path') {
    return matchesPathSearch(packet, parsePathSearch(search));
  }
  final hash = search.trim().toLowerCase();
  return hash.isEmpty ||
      textOf(packet['packetHash']).toLowerCase().contains(hash);
}
