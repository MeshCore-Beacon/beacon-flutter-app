import '../../core/strings.dart';

typedef DirectoryRow = Map<String, dynamic>;
List<DirectoryRow> directoryRows(dynamic value) {
  final items = value is Map ? value['items'] : value;
  return items is List
      ? items.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : [];
}

Map<String, dynamic> nextDirectoryCursor(
  String kind,
  dynamic response,
  int limit,
) {
  final items = directoryRows(response);
  if (items.isEmpty || (response is Map && response['hasMore'] == false)) {
    return {};
  }
  if (response is Map) {
    if (response['nextPageCursor'] case final String cursor
        when cursor.isNotEmpty) {
      return {'pageCursor': cursor};
    }
    if (response['nextCursor'] != null) {
      return {'cursor': response['nextCursor']};
    }
  }
  if (items.length < limit) return {};
  final last = items.last;
  if (kind == 'routes') {
    return {'cursor': last['lastSeen'], 'cursorId': last['id']};
  }
  if (kind == 'traces') {
    return {'cursor': last['lastHeardAt'], 'cursorTag': last['traceTag']};
  }
  if (kind == 'messages') return {'cursor': last['id']};
  return {};
}

String directoryRowKey(DirectoryRow row, String kind) {
  if (kind == 'routes') return '${row['iata']}:${row['pathKey'] ?? row['id']}';
  return '${row[kind == 'traces' ? 'traceTag' : 'id'] ?? row['packetHash']}';
}

List<DirectoryRow> mergeDirectoryRows(
  List<DirectoryRow> old,
  List<DirectoryRow> incoming,
  String kind,
) {
  final keyed = <String, DirectoryRow>{};
  for (final row in [...old, ...incoming]) {
    keyed[directoryRowKey(row, kind)] = row;
  }
  return keyed.values.toList();
}

String channelName(DirectoryRow row) {
  final name = row['name'];
  if (name == null || name == '') {
    return '${row['channelHash'] ?? tr('Unknown channel')}';
  }
  return row['isHashtag'] == true || name == 'Public' ? '$name' : '#$name';
}
