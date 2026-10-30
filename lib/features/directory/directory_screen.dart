import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../analytics/charts.dart' show countLabel;
import 'directory_widgets.dart';
import 'paging.dart';

/// Display text for a filter option value.
String optionLabel(String value) => switch (value) {
  'true' => tr('Yes'),
  'false' => tr('No'),
  'online' => tr('Online'),
  'offline' => tr('Offline'),
  'companion' ||
  'repeater' ||
  'room_server' ||
  'sensor' => trKey('nodeTypes.$value'),
  _ => value,
};

/// "1 route" / "3 routes" for a plural directory kind such as `routes`.
String pluralCount(int count, String plural) {
  final key = 'directory.count.$plural';
  final text = trKey(key, count: count);
  if (text != key) return text;
  return count == 1 && plural.endsWith('s')
      ? '1 ${plural.substring(0, plural.length - 1)}'
      : '$count $plural';
}

/// A /routes/cross result as a route row. The segments already end and start
/// at the boundary pair, so crossHop.fromNode/toNode are not inserted again.
Json crossRouteRow(Json item) {
  final bridge = object(item['crossHop']);
  return {
    ...item,
    'id': jsonEncode(item),
    'iata': '${bridge['fromIata']} → ${bridge['toIata']}',
    'hopCount': item['totalHops'],
    'lastSeen': bridge['lastSeen'],
    'hops': [...rows(item['sourceSegment']), ...rows(item['targetSegment'])],
  };
}

/// Fewest hops first, then most recently seen.
int compareRouteResults(Json a, Json b) {
  final hops = (number(a['hopCount']) ?? 0).compareTo(
    number(b['hopCount']) ?? 0,
  );
  return hops != 0
      ? hops
      : (number(b['lastSeen']) ?? 0).compareTo(number(a['lastSeen']) ?? 0);
}

/// Newest first, as /routes pages them: lastSeen, then id.
int compareRouteRecency(Json a, Json b) {
  final seen = (number(b['lastSeen']) ?? 0).compareTo(
    number(a['lastSeen']) ?? 0,
  );
  return seen != 0
      ? seen
      : (number(b['id']) ?? 0).compareTo(number(a['id']) ?? 0);
}

class DirectoryScreen extends StatefulWidget {
  const DirectoryScreen({
    super.key,
    required this.kind,
    required this.api,
    required this.region,
    required this.onOpen,
    this.events,
  });
  final String kind;
  final ApiClient api;
  final Json region;
  final void Function(String, String) onOpen;
  final Stream<Json>? events;
  @override
  State<DirectoryScreen> createState() => _DirectoryScreenState();
}

class _DirectoryScreenState extends State<DirectoryScreen>
    with WidgetsBindingObserver {
  List<Json> items = [];
  Json cursor = {};
  Json routeCursors = {};
  bool routesIgnoreIatas = false;
  final filters = <String, String>{};
  final search = TextEditingController();
  final from = TextEditingController(), to = TextEditingController();
  List<String> scopes = [], brokers = [], types = [];
  Map<String, double> activityCounts = {};
  final observerScroll = ScrollController();
  Json observerQuery = {};
  String? observerEffectiveSort;
  int observerSortRestarts = 0;
  double? observerMaximum;
  bool observerUnavailable = false;
  bool observerMoreError = false;
  final observerCursors = <String>{};
  String searchField = 'name';
  String sortBy = 'recent';
  bool descending = true;
  bool nodesServerSorted = false;
  bool nodesCarryLastSeen = false;
  Object? error;
  bool loading = false;
  bool backgroundRefresh = false;
  bool refreshPending = false;
  bool showOtherChannels = false;
  int generation = 0;
  int optionsGeneration = 0;
  Timer? debounce;
  DateTime? lastUncertainRefresh;
  StreamSubscription<Json>? subscription;
  @override
  void initState() {
    super.initState();
    resetSort();
    observerScroll.addListener(maybeLoadObservers);
    WidgetsBinding.instance.addObserver(this);
    bind();
    load();
    options();
  }

  void resetSort() {
    sortBy = switch (widget.kind) {
      'nodes' || 'channels' => 'name',
      _ => 'recent',
    };
    descending = sortBy == 'recent';
  }

  void bind() {
    subscription?.cancel();
    subscription = widget.events?.listen((event) {
      final relevant = {
        'nodes': 'nodeUpdate',
        'observers': 'observerStatus',
        'channels': 'channelMessage',
        'traces': 'packetObservation',
        'routes': 'packetObservation',
      }[widget.kind];
      if (event['type'] != 'refresh' && event['event'] != relevant) return;
      if (widget.kind == 'observers') {
        if (event['event'] == 'observerStatus') _patchDirectoryEvent(event);
        return;
      }
      if (event['type'] != 'refresh' &&
          {'nodes', 'observers'}.contains(widget.kind) &&
          _patchDirectoryEvent(event)) {
        return;
      }
      refreshPending = true;
      flushRefresh();
    });
  }

  bool _patchDirectoryEvent(Json event) {
    final data = object(event['data']);
    final id = textOf(data[widget.kind == 'nodes' ? 'nodeId' : 'observerId']);
    if (id.isEmpty) return false;
    final index = items.indexWhere((row) => textOf(row['id']) == id);
    if (index < 0) return false;
    final current = items[index];
    final updated = Map<String, dynamic>.from(current);
    if (widget.kind == 'nodes') {
      final membershipMayChange =
          (data.containsKey('iatas') &&
              jsonEncode(current['iatas']) != jsonEncode(data['iatas'])) ||
          (search.text.trim().isNotEmpty &&
              data.containsKey('name') &&
              data['name'] != current['name']) ||
          (textOf(filters['scope']).isNotEmpty &&
              data.containsKey('defaultScope') &&
              data['defaultScope'] != filters['scope']) ||
          filters.keys.any(
            (key) => data.containsKey(key) && data[key] != current[key],
          );
      for (final key in [
        'name',
        'lat',
        'lng',
        'possiblyForeign',
        'defaultScope',
        'radio',
        'iatas',
        'isObserver',
      ]) {
        if (data.containsKey(key)) {
          if (data[key] == null &&
              !['lat', 'lng', 'possiblyForeign'].contains(key)) {
            continue;
          }
          updated[key] = data[key];
        }
      }
      // A changed server-side region or search value can alter membership. Keep the
      // visible row current, then let the throttled refresh reconcile the filter.
      setState(() => items[index] = updated);
      if (membershipMayChange) {
        refreshPending = true;
        flushRefresh();
      }
      return true;
    }
    if (data['online'] is bool) {
      updated['status'] = data['online'] == true ? 'online' : 'offline';
    }
    setState(() => items[index] = updated);
    return true;
  }

  void flushRefresh() {
    if (!mounted || !refreshPending || loading || debounce?.isActive == true) {
      return;
    }
    final now = DateTime.now();
    final last = lastUncertainRefresh;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      final remaining = const Duration(seconds: 30) - now.difference(last);
      debounce = Timer(remaining, () {
        debounce = null;
        flushRefresh();
      });
      return;
    }
    debounce = Timer(const Duration(milliseconds: 800), () {
      if (!mounted || loading) return;
      refreshPending = false;
      lastUncertainRefresh = DateTime.now();
      load(live: true);
    });
  }

  @override
  void didUpdateWidget(covariant DirectoryScreen old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api ||
        old.kind != widget.kind ||
        jsonEncode(old.region) != jsonEncode(widget.region)) {
      if (old.kind != widget.kind) {
        resetSort();
      }
      if (old.api != widget.api) {
        routesIgnoreIatas = false;
        nodesCarryLastSeen = false;
      }
      generation++;
      refreshPending = false;
      debounce?.cancel();
      items = [];
      cursor = {};
      showOtherChannels = false;
      filters.clear();
      search.clear();
      load();
      options();
    }
    if (old.events != widget.events) bind();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load(preserveLoaded: true);
  }

  @override
  void dispose() {
    generation++;
    debounce?.cancel();
    subscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    observerScroll.dispose();
    search.dispose();
    from.dispose();
    to.dispose();
    super.dispose();
  }

  bool get emptyRegion => emptyDirectoryRegion(widget.region);
  Future<void> options() async {
    final g = ++optionsGeneration;
    if (emptyRegion) {
      scopes = [];
      brokers = [];
      return;
    }
    try {
      final s = await widget.api.get('/scopes', widget.region);
      if (mounted && g == optionsGeneration) {
        setState(() => scopes = (s is List ? s : []).map((e) => '$e').toList());
      }
    } catch (_) {}
    if (widget.kind == 'observers') {
      try {
        final b = await widget.api.get('/brokers');
        if (mounted && g == optionsGeneration) {
          setState(
            () =>
                brokers = directoryRows(b)
                    .map((e) => textOf(e['name']))
                    .toList(),
          );
        }
      } catch (_) {}
    }
  }

  Json query() {
    final q = <String, dynamic>{...widget.region, 'limit': 50};
    for (final e in filters.entries) {
      if (e.value.isNotEmpty && !['scope', 'hashtag'].contains(e.key)) {
        q[e.key] = e.value;
      }
    }
    if (widget.kind == 'nodes' && search.text.trim().isNotEmpty) {
      q[searchField == 'pubkey' ? 'pubkeyPrefix' : 'name'] = search.text.trim();
    }
    if (widget.kind == 'observers' && search.text.trim().isNotEmpty) {
      q['name'] = search.text.trim();
    }
    if ({'nodes', 'traces', 'observers'}.contains(widget.kind) &&
        filters['scope']?.isNotEmpty == true) {
      q['scope'] = filters['scope'];
    }
    if (widget.kind == 'nodes') q.addAll(nodeOrder());
    if (widget.kind == 'routes') {
      q.remove('iatas');
      q.remove('region');
      final iatas = textOf(widget.region['iatas']);
      if (iatas.isNotEmpty && textOf(q['iata']).isEmpty) {
        q['iata'] = iatas.split(',').first;
      }
    }
    return q;
  }

  /// Server order for the node sort choice; newest first is the server's default.
  Json nodeOrder() {
    if (sortBy == 'recent') {
      // Servers that leave lastSeen off node rows reject this sort with a 400.
      return !descending && nodesCarryLastSeen
          ? {'sort': 'lastSeen', 'order': 'asc'}
          : {};
    }
    final sort = const {
      'name': 'name',
      'nodeTypeName': 'type',
      'knownNeighborCount': 'neighbors',
    }[sortBy];
    return sort == null
        ? {}
        : {'sort': sort, 'order': descending ? 'desc' : 'asc'};
  }

  void maybeLoadObservers() {
    if (widget.kind != 'observers' ||
        !mounted ||
        loading ||
        error != null ||
        debounce?.isActive == true ||
        cursor.isEmpty ||
        !observerScroll.hasClients) {
      return;
    }
    if (observerScroll.position.extentAfter < 300) load(more: true);
  }

  Future<void> loadObservers({bool more = false}) async {
    if (more && (loading || cursor.isEmpty || debounce?.isActive == true)) {
      return;
    }
    final g = ++generation;
    final requestCursor = more ? Map<String, dynamic>.from(cursor) : null;
    setState(() {
      loading = true;
      backgroundRefresh = false;
      error = null;
      observerMoreError = more;
      if (!more) {
        items = [];
        cursor = {};
        observerQuery = {};
        observerEffectiveSort = null;
        observerCursors.clear();
        activityCounts = {};
        observerMaximum = null;
        observerUnavailable = false;
      }
    });
    if (!more && observerScroll.hasClients) observerScroll.jumpTo(0);
    try {
      if (emptyRegion) {
        setState(() {
          loading = false;
          types = [];
        });
        return;
      }
      final params = more
          ? {...observerQuery, ...requestCursor!, 'limit': 50}
          : {...query(), 'sort': sortBy == 'recent' ? 'traffic' : 'name'};
      final response = object(
        await retryingGet(
          widget.api,
          fresh: true,
          isCurrent: () => mounted && g == generation,
        )('/observers/directory', params),
      );
      if (!mounted || g != generation) return;
      if (response['items'] is! List ||
          response['windowStart'] is! num ||
          response['windowEnd'] is! num ||
          !{'traffic', 'name'}.contains(response['effectiveSort'])) {
        throw const FormatException('Invalid observer directory response.');
      }
      if (more && response['effectiveSort'] != observerEffectiveSort) {
        if (observerSortRestarts++ >= 1) {
          cursor = {};
          observerMoreError = false;
          throw const ApiException(
            'Traffic ordering changed again. Refresh to reload the list.',
          );
        }
        await loadObservers();
        return;
      }
      final batch = directoryRows(response);
      final next = response['hasMore'] == true && response['nextCursor'] != null
          ? <String, dynamic>{'cursor': response['nextCursor']}
          : <String, dynamic>{};
      if (next.isNotEmpty && !observerCursors.add(jsonEncode(next))) {
        next.clear();
      }
      setState(() {
        if (!more) {
          observerQuery = {
            ...params,
            'since': response['windowStart'],
            'until': response['windowEnd'],
          };
          observerMaximum = number(response['maxObservationCount']);
          observerEffectiveSort = textOf(response['effectiveSort']);
        }
        items = more ? mergeDirectoryRows(items, batch, 'observers') : batch;
        cursor = next;
        observerUnavailable = observerMaximum == null;
        activityCounts = {
          for (final row in items)
            textOf(row['id']): ?(observerMaximum == null
                ? null
                : number(row['observationCount'])),
        };
        types =
            (response['observerTypes'] is List
                    ? response['observerTypes'] as List
                    : const [])
                .map((v) => '$v')
                .toList();
        loading = false;
        observerMoreError = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) maybeLoadObservers();
      });
    } catch (e) {
      if (!mounted || g != generation) return;
      Object displayError = e;
      if (e is ApiException &&
          (e.status == 404 ||
              (e.status == 400 &&
                  e.message == 'failed to parse observer UUID'))) {
        displayError = const ApiException(
          'Upgrade your Beacon server to load observers with traffic pagination.',
        );
      }
      setState(() {
        error = displayError;
        loading = false;
      });
    }
  }

  Future<void> load({
    bool more = false,
    bool live = false,
    bool fresh = false,
    bool preserveLoaded = false,
  }) async {
    if (widget.kind == 'observers') {
      if (!more) observerSortRestarts = 0;
      return loadObservers(more: more);
    }
    final g = ++generation;
    bool current() => mounted && g == generation;
    final routeSearch =
        widget.kind == 'routes' &&
        from.text.trim().isNotEmpty &&
        to.text.trim().isNotEmpty;
    Object? partial;
    setState(() {
      loading = !(preserveLoaded && items.isNotEmpty);
      backgroundRefresh = live || preserveLoaded;
      error = null;
    });
    try {
      dynamic response;
      if (emptyRegion) {
        response = [];
      } else if (widget.kind == 'channels') {
        final known = <Json>[];
        if (!more) {
          Json boundary = {};
          final seen = <String>{};
          do {
            final page =
                await retryingGet(
                  widget.api,
                  fresh: more || live || fresh,
                  isCurrent: current,
                )('/channels', {
                  ...widget.region,
                  'limit': 200,
                  'keyKnown': 'true',
                  ...boundary,
                });
            if (!mounted || g != generation) return;
            final batch = rows(page);
            known.addAll(batch.where((row) => row['keyKnown'] == true));
            final next = nextDirectoryCursor('channels', page, 200);
            if (next.isEmpty ||
                batch.any((row) => row['keyKnown'] != true) ||
                !seen.add(jsonEncode(next))) {
              break;
            }
            boundary = next;
          } while (true);
        }
        final wantOthers = showOtherChannels || filters['keyKnown'] == 'false';
        final other = wantOthers
            ? await retryingGet(
                widget.api,
                fresh: more || live || fresh,
                isCurrent: current,
              )('/channels', {
                ...widget.region,
                'limit': 50,
                'keyKnown': 'false',
                if (more) ...cursor,
              })
            : {'items': [], 'hasMore': false};
        final next = nextDirectoryCursor('channels', other, 50);
        response = {
          'items': [...known, ...rows(other)],
          'hasMore': next.isNotEmpty,
          if (next['pageCursor'] != null) 'nextPageCursor': next['pageCursor'],
          if (next['cursor'] != null) 'nextCursor': next['cursor'],
        };
      } else if (routeSearch) {
        final found = await searchRoutes(more || live || fresh);
        response = {'items': found.items};
        partial = found.error;
      } else if (widget.kind == 'routes') {
        final selected = textOf(filters['iata']).isNotEmpty
            ? filters['iata']!
            : textOf(widget.region['iatas']);
        final areas = selected.isEmpty ? [''] : selected.split(',');
        final codes = {
          for (final area in areas)
            if (area.trim().isNotEmpty) area.trim().toUpperCase(),
        };
        final grouped = codes.length > 1 && codes.length <= 100;
        final group = codes.join(',');
        final get = retryingGet(
          widget.api,
          fresh: more || live || fresh,
          isCurrent: current,
        );
        final next = <String, dynamic>{};
        final combined = <Json>[];
        // Pages loaded as a group leave no per-IATA cursors, so each IATA starts over.
        final resume = more && !(grouped && routeCursors.containsKey(group));
        if (grouped && !routesIgnoreIatas) {
          // No iata, so a server before 2.1 answers with every IATA's routes.
          final page = await get('/routes', {
            ...(query()..remove('iata')),
            'iatas': group,
            if (more) ...object(routeCursors[group]),
          });
          if (!current()) return;
          final batch = rows(page);
          if (batch.every(
            (r) => codes.contains(textOf(r['iata']).toUpperCase()),
          )) {
            combined.addAll(batch);
            final c = nextDirectoryCursor('routes', page, 50);
            if (c.isNotEmpty) next[group] = c;
          } else {
            // Another IATA's route: this server ignores iatas.
            routesIgnoreIatas = true;
          }
        }
        if (!grouped || routesIgnoreIatas) {
          for (final area in areas) {
            if (resume && !routeCursors.containsKey(area)) continue;
            final page = await get('/routes', {
              ...query(),
              'iata': area,
              if (resume) ...object(routeCursors[area]),
            });
            if (!current()) return;
            combined.addAll(rows(page));
            final c = nextDirectoryCursor('routes', page, 50);
            if (c.isNotEmpty) next[area] = c;
          }
        }
        response = {'items': combined, '_routeCursors': next};
      } else {
        response = await retryingGet(
          widget.api,
          fresh: more || live || fresh,
          isCurrent: current,
        )('/${widget.kind}', {...query(), if (more) ...cursor});
      }
      if (!mounted || g != generation) return;
      final batch = directoryRows(response);
      setState(() {
        items = more || (live && {'observers', 'routes'}.contains(widget.kind))
            ? mergeDirectoryRows(items, batch, widget.kind)
            : live
            ? [
                ...batch,
                ...items.where(
                  (old) => !batch.any(
                    (fresh) =>
                        fresh[widget.kind == 'traces' ? 'traceTag' : 'id'] ==
                        old[widget.kind == 'traces' ? 'traceTag' : 'id'],
                  ),
                ),
              ]
            : batch;
        // Another IATA's older page or a live row can land anywhere in the list.
        if (widget.kind == 'routes' && !routeSearch) {
          items.sort(compareRouteRecency);
        }
        if (!live && widget.kind == 'routes') {
          routeCursors = object(object(response)['_routeCursors']);
          cursor = routeCursors.isEmpty ? {} : {'more': true};
        } else if (!live) {
          cursor = nextDirectoryCursor(widget.kind, response, 50);
          if (widget.kind == 'nodes') {
            final order = nodeOrder();
            // Older servers ignore sort and leave it off the page, so the device sorts.
            nodesServerSorted =
                order.isNotEmpty &&
                response is Map &&
                response['sort'] == order['sort'] &&
                response['order'] == order['order'];
            // A sorted list pages by pageCursor alone; a cursor with it is a 400.
            if (nodesServerSorted) cursor.remove('cursor');
            nodesCarryLastSeen =
                nodesCarryLastSeen || batch.any((r) => r['lastSeen'] != null);
          }
        }
        error = partial;
        loading = false;
        types = items
            .map((r) => textOf(r['observerType']))
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList();
      });
    } catch (e) {
      if (mounted && g == generation) {
        setState(() {
          // A failed search must not leave the previous search's routes on screen.
          if (routeSearch) items = [];
          error = e;
          loading = false;
        });
      }
    } finally {
      if (mounted && g == generation) flushRefresh();
    }
  }

  /// Route search shared with beacon-web: one /routes/search plus, unless the
  /// scope is a single IATA, one /routes/cross, never a call per area or pair.
  /// Returns the merged rows and the first failure, so one endpoint failing
  /// still shows the other's routes.
  Future<({List<Json> items, Object? error})> searchRoutes(bool fresh) async {
    final fromHash = from.text.trim().toLowerCase();
    final toHash = to.text.trim().toLowerCase();
    final hash = RegExp(r'^(?:[0-9a-f]{2}){1,4}$');
    if (!hash.hasMatch(fromHash) || !hash.hasMatch(toHash)) {
      throw const ApiException(
        'Route hashes must be 2, 4, 6 or 8 hex characters.',
      );
    }
    final selected = textOf(filters['iata']).isNotEmpty
        ? filters['iata']!
        : textOf(widget.region['iatas']);
    final iatas = {
      for (final iata in selected.split(','))
        if (iata.trim().isNotEmpty) iata.trim().toUpperCase(),
    };
    if (iatas.isNotEmpty && await coversEveryIata(iatas)) iatas.clear();
    if (iatas.length > 100) {
      throw ApiException(
        tr(
          'Route search covers at most 100 areas; this region has {{count}}. Pick areas in Filters.',
        ).replaceAll('{{count}}', '${iatas.length}'),
      );
    }
    // No iatas key at all means every area.
    final scope = {if (iatas.isNotEmpty) 'iatas': iatas.join(',')};
    Object? failure;
    final g = generation;
    final get = retryingGet(
      widget.api,
      fresh: fresh,
      isCurrent: () => mounted && g == generation,
    );
    Future<List<Json>> fetch(String path, Json params) async {
      try {
        return rows(await get(path, params));
      } catch (e) {
        failure ??= e is ApiException && e.status == 503
            ? const ApiException(
                'Route search timed out — narrow the areas or use a longer hash.',
                status: 503,
              )
            : e;
        return const [];
      }
    }

    final found = await Future.wait([
      fetch('/routes/search', {...scope, 'from': fromHash, 'to': toHash}),
      if (iatas.length != 1)
        fetch('/routes/cross', {
          ...scope,
          'fromHash': fromHash,
          'toHash': toHash,
        }).then((cross) => cross.map(crossRouteRow).toList()),
    ]);
    final hops = textOf(filters['hopCount']);
    final items = [
      for (final row in found.expand((e) => e))
        if (hops.isEmpty || '${row['hopCount']}' == hops) row,
    ]..sort(compareRouteResults);
    if (items.isEmpty && failure != null) throw failure!;
    return (items: items, error: failure);
  }

  /// Whether [iatas] lists every IATA the server knows, which route search
  /// treats as the global view. An unavailable list counts as not covered.
  Future<bool> coversEveryIata(Set<String> iatas) async {
    try {
      final known = {
        for (final e in rows(await widget.api.getCached('/iatas', {})))
          textOf(e['iata']).toUpperCase(),
      }..remove('');
      return known.isNotEmpty && iatas.containsAll(known);
    } catch (_) {
      return false;
    }
  }

  void changed() {
    if (widget.kind == 'observers') {
      generation++;
      setState(() {
        items = [];
        cursor = {};
        loading = false;
        error = null;
      });
    }
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 350), () => load());
  }

  List<Json> get visible {
    if (widget.kind == 'observers') return items;
    final result = items.where((r) {
      final scope = filters['scope'];
      if (scope?.isNotEmpty == true && widget.kind != 'traces') {
        if (widget.kind == 'observers' &&
            !(r['scopes'] is List && (r['scopes'] as List).contains(scope))) {
          return false;
        }
      }
      if (widget.kind == 'channels') {
        if (filters['keyKnown']?.isNotEmpty == true &&
            '${r['keyKnown']}' != filters['keyKnown']) {
          return false;
        }
        if (filters['hashtag']?.isNotEmpty == true &&
            '${r['isHashtag']}' != filters['hashtag']) {
          return false;
        }
        final term = search.text.toLowerCase();
        return textOf(r[searchField == 'hash' ? 'channelHash' : 'name'])
            .toLowerCase()
            .contains(term);
      }
      if (widget.kind == 'traces' && search.text.isNotEmpty) {
        return textOf(r['traceTag'])
            .toLowerCase()
            .contains(search.text.toLowerCase());
      }
      return true;
    }).toList();
    if (widget.kind == 'channels' && sortBy == 'recent') {
      result.sort((a, b) {
        final aPublic = textOf(a['name']).toLowerCase() == 'public';
        final bPublic = textOf(b['name']).toLowerCase() == 'public';
        if (aPublic != bPublic) return aPublic ? -1 : 1;
        if (textOf(a['name']).isEmpty != textOf(b['name']).isEmpty) {
          return textOf(a['name']).isEmpty ? 1 : -1;
        }
        return (number(b['lastSeen']) ?? 0).compareTo(
          number(a['lastSeen']) ?? 0,
        );
      });
    }
    if (sortBy != 'recent' && !(widget.kind == 'nodes' && nodesServerSorted)) {
      result.sort((a, b) {
        if (widget.kind == 'channels') {
          final aPublic = textOf(a['name']).toLowerCase() == 'public';
          final bPublic = textOf(b['name']).toLowerCase() == 'public';
          if (aPublic != bPublic) return aPublic ? -1 : 1;
          if (textOf(a['name']).isEmpty != textOf(b['name']).isEmpty) {
            return textOf(a['name']).isEmpty ? 1 : -1;
          }
        }
        final byName = sortBy == 'name' || sortBy == 'displayName';
        final dynamic av = byName ? label(a) : a[sortBy];
        final dynamic bv = byName ? label(b) : b[sortBy];
        final value = av is num && bv is num
            ? av.compareTo(bv)
            : textOf(av).toLowerCase().compareTo(textOf(bv).toLowerCase());
        return descending ? -value : value;
      });
    }
    return result;
  }

  Widget select(
    String key,
    String title,
    List<String> values,
    StateSetter update,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: DropdownButtonFormField<String>(
      key: ValueKey('$key:${filters[key]}'),
      initialValue: filters[key] ?? '',
      isExpanded: true,
      decoration: InputDecoration(labelText: tr(title)),
      items: [
        DropdownMenuItem(value: '', child: Text(trKey('nodeFilters.any'))),
        ...{
          ...values,
          if (textOf(filters[key]).isNotEmpty) filters[key]!,
        }.map((v) => DropdownMenuItem(value: v, child: Text(optionLabel(v)))),
      ],
      onChanged: (v) => update(() => filters[key] = v ?? ''),
    ),
  );
  Future<void> showFilters() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.tune,
                        color: Theme.of(context).colorScheme.primary,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      const DirectoryText(
                        'Filters',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (widget.kind == 'nodes') ...[
                    select('typeName', 'Node type', [
                      'companion',
                      'repeater',
                      'room_server',
                      'sensor',
                    ], update),
                    select('supportsMultibytePaths', 'Multibyte paths', [
                      'true',
                      'false',
                    ], update),
                    select('supportsMultibyteTraces', 'Multibyte traces', [
                      'true',
                      'false',
                    ], update),
                  ],
                  if (widget.kind == 'observers') ...[
                    select('status', 'Status', ['online', 'offline'], update),
                    select('type', 'Observer type', types, update),
                    select('broker', 'Broker', brokers, update),
                  ],
                  if (widget.kind == 'channels') ...[
                    select('keyKnown', 'Known key', ['true', 'false'], update),
                    select('hashtag', 'Hashtag channel', [
                      'true',
                      'false',
                    ], update),
                  ],
                  if (widget.kind == 'traces')
                    select('type', 'Type', ['TRACE', 'PING'], update),
                  if (widget.kind == 'routes') ...[
                    TextFormField(
                      key: const ValueKey('routes-iata-filter'),
                      initialValue: filters['iata'],
                      decoration: InputDecoration(labelText: tr('IATA')),
                      // IATA codes are uppercase on the server; match as typed.
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [
                        TextInputFormatter.withFunction(
                          (_, value) =>
                              value.copyWith(text: value.text.toUpperCase()),
                        ),
                      ],
                      onChanged: (v) => filters['iata'] = v.toUpperCase(),
                    ),
                    select(
                      'hopCount',
                      'Hops',
                      List.generate(16, (i) => '${i + 1}'),
                      update,
                    ),
                  ],
                  if (['nodes', 'observers', 'traces'].contains(widget.kind))
                    select('scope', trKey('nodeFilters.scope'), scopes, update),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          update(filters.clear);
                        },
                        child: const DirectoryText('Clear all'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const DirectoryText('Apply'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (mounted) unawaited(load());
  }

  @override
  Widget build(BuildContext context) {
    final shown = visible;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: search,
                  onChanged: (_) {
                    if (widget.kind == 'channels') {
                      setState(() {});
                    } else {
                      changed();
                    }
                  },
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: tr('Search ${widget.kind}'),
                  ),
                ),
              ),
              if (['nodes', 'channels'].contains(widget.kind))
                PopupMenuButton<String>(
                  initialValue: searchField,
                  tooltip: tr('Search field'),
                  onSelected: (v) {
                    setState(() => searchField = v);
                    changed();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'name',
                      child: DirectoryText('Name'),
                    ),
                    PopupMenuItem(
                      value: widget.kind == 'nodes' ? 'pubkey' : 'hash',
                      child: Text(
                        widget.kind == 'nodes'
                            ? tr('Public key')
                            : trKey('channels.fieldHash'),
                      ),
                    ),
                  ],
                ),
              PopupMenuButton<String>(
                tooltip: switch (widget.kind) {
                  'nodes' => trKey('nodeList.sort'),
                  'observers' => tr('Sort observers'),
                  _ => tr('Sort loaded rows'),
                },
                icon: const Icon(Icons.sort, size: 20),
                onSelected: (v) {
                  final order = jsonEncode(nodeOrder());
                  setState(() {
                    if (v == 'reverse') {
                      descending = !descending;
                    } else {
                      sortBy = v;
                      descending = v == 'recent';
                    }
                  });
                  if (widget.kind == 'observers' ||
                      (widget.kind == 'nodes' &&
                          jsonEncode(nodeOrder()) != order)) {
                    load();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'recent',
                    child: DirectoryText(
                      widget.kind == 'observers'
                          ? 'Most traffic'
                          : 'Newest first',
                    ),
                  ),
                  PopupMenuItem(
                    value: widget.kind == 'observers' ? 'displayName' : 'name',
                    child: const DirectoryText('Name'),
                  ),
                  if (widget.kind == 'nodes') ...const [
                    PopupMenuItem(
                      value: 'nodeTypeName',
                      child: DirectoryText('Type'),
                    ),
                    PopupMenuItem(
                      value: 'knownNeighborCount',
                      child: DirectoryText('Neighbors'),
                    ),
                  ],
                  if (widget.kind == 'routes')
                    const PopupMenuItem(
                      value: 'hopCount',
                      child: DirectoryText('Hops'),
                    ),
                  if (widget.kind == 'traces')
                    const PopupMenuItem(
                      value: 'packetCount',
                      child: DirectoryText('Packets'),
                    ),
                  if (widget.kind != 'observers')
                    const PopupMenuItem(
                      value: 'reverse',
                      child: DirectoryText('Reverse order'),
                    ),
                ],
              ),
              IconButton(
                onPressed: showFilters,
                tooltip: tr('Filters'),
                icon: Badge(
                  isLabelVisible: filters.values.any((v) => v.isNotEmpty),
                  child: const Icon(Icons.tune, size: 20),
                ),
              ),
            ],
          ),
        ),
        if (widget.kind == 'routes')
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: from,
                    decoration: InputDecoration(hintText: tr('From hash')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: to,
                    decoration: InputDecoration(hintText: tr('To hash')),
                  ),
                ),
                IconButton(
                  onPressed: () => load(fresh: true),
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
        SizedBox(
          height: 2,
          child: loading && !backgroundRefresh
              ? const LinearProgressIndicator(minHeight: 2)
              : null,
        ),
        if (widget.kind == 'observers' && observerUnavailable)
          const Padding(
            padding: EdgeInsets.all(8),
            child: DirectoryText(
              'Traffic unavailable for this period. Showing name order.',
            ),
          ),
        if (error != null)
          failure(
            error!,
            () => load(
              fresh: true,
              more: widget.kind == 'observers' && observerMoreError,
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => load(fresh: true),
            child: ListView.builder(
              controller: widget.kind == 'observers' ? observerScroll : null,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: shown.length + 1,
              itemBuilder: (context, index) {
                if (index == shown.length) {
                  if (widget.kind == 'channels' &&
                      !showOtherChannels &&
                      filters['keyKnown'] != 'false') {
                    return Padding(
                      padding: const EdgeInsets.all(12),
                      child: OutlinedButton(
                        onPressed: loading
                            ? null
                            : () {
                                showOtherChannels = true;
                                load();
                              },
                        child: const DirectoryText('Load other channels'),
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.all(20),
                    child: cursor.isNotEmpty
                        ? OutlinedButton(
                            onPressed: loading ? null : () => load(more: true),
                            child: DirectoryText(
                              widget.kind == 'observers' ||
                                      (widget.kind == 'nodes' &&
                                          nodesServerSorted)
                                  ? 'Load more'
                                  : 'Load older',
                            ),
                          )
                        : error != null && shown.isEmpty
                        ? const SizedBox.shrink()
                        : Text(
                            shown.isEmpty && !loading
                                ? tr('No ${widget.kind} found')
                                : pluralCount(shown.length, widget.kind),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: BeaconColors.of(context).muted,
                              fontSize: 12,
                            ),
                          ),
                  );
                }
                return KeyedSubtree(
                  key: ValueKey(
                    '${widget.kind}:${directoryRowKey(shown[index], widget.kind)}',
                  ),
                  child: card(shown[index]),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget badge(String title, {Color? color}) {
    final tint = color ?? BeaconColors.of(context).primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: .09),
        border: Border.all(color: tint.withValues(alpha: .28)),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        tr(title).toUpperCase(),
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: tint,
          letterSpacing: .4,
        ),
      ),
    );
  }

  Widget line(String value, {Color? color, double size = 11}) => Text(
    value,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: size, color: color),
  );
  Widget card(Json r) {
    final kind = widget.kind;
    final palette = Theme.of(context).colorScheme;
    final muted = palette.onSurfaceVariant;
    final radio = textOf(r['radio']).split(',');
    final radioLabel = radio.length == 3
        ? '${radio[0]} MHz · SF${radio[2]} · ${radio[1]} kHz'
        : textOf(r['radio'], tr('Unknown'));
    List<Widget> content;
    if (kind == 'nodes') {
      final location = number(r['lat']) != null && number(r['lng']) != null
          ? '${number(r['lat'])!.toStringAsFixed(2)}, ${number(r['lng'])!.toStringAsFixed(2)}'
          : null;
      content = [
        Row(
          children: [
            Expanded(child: line(label(r), size: 12)),
            const SizedBox(width: 8),
            if (r['isObserver'] == true)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.sensors, size: 13),
              ),
            badge(
              textOf(r['nodeTypeName']),
              color: BeaconColors.of(context).secondary,
            ),
          ],
        ),
        const SizedBox(height: 6),
        line(
          [
            radioLabel,
            ?location,
            if ((number(r['knownNeighborCount']) ?? 0) > 0)
              trKey(
                'nodes.neighbors',
                count: number(r['knownNeighborCount'])!.toInt(),
              ).replaceAll('{{formatted}}', '${r['knownNeighborCount']}'),
          ].join(' · '),
          color: muted,
        ),
        if (r['possiblyForeign'] == true)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: badge('Possibly foreign', color: Colors.orange),
          ),
        if (rows(r['iatas']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 4,
              runSpacing: 3,
              children: rows(r['iatas'])
                  .map(
                    (i) => Tooltip(
                      message: tr('Last heard {{ago}}')
                          .replaceAll('{{ago}}', age(i['lastHeard'])),
                      child: badge(textOf(i['iata'])),
                    ),
                  )
                  .toList(),
            ),
          ),
      ];
    } else if (kind == 'observers') {
      content = [
        Row(
          children: [
            Tooltip(
              message: switch (r['status']) {
                'online' => tr('Online'),
                'offline' => tr('Offline'),
                _ => textOf(r['status'], tr('Unknown')),
              },
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: r['status'] == 'online'
                      ? BeaconColors.of(context).success
                      : palette.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: line(label(r), size: 13)),
            const SizedBox(width: 8),
            line(
              activityCounts.containsKey(textOf(r['id']))
                  ? countLabel(activityCounts[textOf(r['id'])])
                  : '-',
              color: muted,
            ),
          ],
        ),
      ];
    } else if (kind == 'channels') {
      content = [
        Row(
          children: [
            Expanded(child: line(channelName(r), size: 12)),
            const SizedBox(width: 8),
            line(age(r['lastSeen']), color: muted),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          children: [
            badge(
              r['keyKnown'] == true ? 'Key' : 'No key',
              color: r['keyKnown'] == true
                  ? BeaconColors.of(context).success
                  : BeaconColors.of(context).muted,
            ),
            if (r['isHashtag'] == true)
              badge('Hashtag', color: BeaconColors.of(context).secondary),
          ],
        ),
      ];
    } else if (kind == 'traces') {
      final hashes = r['pathHashes'] is List ? r['pathHashes'] as List : [];
      final snrs = r['snrValues'] is List ? r['snrValues'] as List : [];
      content = [
        Row(
          children: [
            line(
              textOf(r['traceTag']).toUpperCase(),
              color: palette.primary,
              size: 12,
            ),
            const SizedBox(width: 10),
            badge(
              textOf(r['traceType']),
              color: r['traceType'] == 'PING'
                  ? BeaconColors.of(context).primary
                  : BeaconColors.of(context).warning,
            ),
            const Spacer(),
            line(age(r['lastHeardAt']), color: muted),
          ],
        ),
        const SizedBox(height: 4),
        line(
          '${trKey('traces.packetCount', count: (number(r['packetCount']) ?? 0).toInt())} · ${trKey('traces.iataCount', count: (number(r['iataCount']) ?? 0).toInt())}',
          color: muted,
        ),
        if (hashes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Wrap(
              spacing: 7,
              runSpacing: 5,
              children: hashes.indexed
                  .map(
                    (e) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        line('${e.$2}'.toUpperCase()),
                        line(
                          e.$1 < snrs.length
                              ? '${snrs[e.$1]} dB'
                              : tr('Unknown'),
                          color: muted,
                          size: 10,
                        ),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
      ];
    } else {
      content = [
        Row(
          children: [
            badge(textOf(r['iata'])),
            const Spacer(),
            line(
              [
                trKey(
                  'routes.hops',
                  count: (number(r['hopCount']) ?? 0).toInt(),
                ),
                if (r['observationCount'] != null)
                  trKey(
                    'routes.obs',
                    count: (number(r['observationCount']) ?? 0).toInt(),
                  ).replaceAll('{{value}}', '${r['observationCount']}'),
              ].join(' · '),
              color: muted,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 5,
          runSpacing: 3,
          children: rows(r['hops']).indexed
              .expand(
                (e) => [
                  if (e.$1 > 0) line('→', color: muted),
                  badge(
                    textOf(
                      object(e.$2['node'])['name'],
                      textOf(e.$2['hashBytes']),
                    ),
                    color: BeaconColors.of(context).primary,
                  ),
                ],
              )
              .toList(),
        ),
        const SizedBox(height: 6),
        line(
          // Cross-area routes have no firstSeen; show only what is known.
          r['firstSeen'] == null
              ? '${tr('Last')} ${age(r['lastSeen'])}'
              : '${tr('First')} ${age(r['firstSeen'])} · ${tr('Last')} ${age(r['lastSeen'])}',
          color: muted,
        ),
      ];
    }
    final maxCount = observerMaximum ?? 0;
    final body = Container(
      padding: EdgeInsets.symmetric(
        horizontal: kind == 'observers' ? 16 : 12,
        vertical: kind == 'observers' ? 12 : 10,
      ),
      decoration: BoxDecoration(
        color: kind == 'observers'
            ? Colors.transparent
            : BeaconColors.of(context).surface,
        border: kind == 'observers'
            ? Border(
                bottom: BorderSide(
                  color: BeaconColors.of(context).borderSubtle,
                ),
              )
            : Border.all(color: BeaconColors.of(context).borderSubtle),
        borderRadius: kind == 'observers' ? null : BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: content,
      ),
    );
    return InkWell(
      onTap: () => widget.onOpen(
        kind.substring(0, kind.length - 1),
        kind == 'routes'
            ? jsonEncode(r)
            : textOf(r[kind == 'traces' ? 'traceTag' : 'id']),
      ),
      child: Padding(
        padding: kind == 'observers'
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: kind == 'observers'
            ? Stack(
                children: [
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: maxCount > 0
                          ? ((activityCounts[textOf(r['id'])] ?? 0) / maxCount)
                                .clamp(0.0, 1.0)
                          : 0,
                      child: ColoredBox(
                        color: BeaconColors.of(context).secondary
                            .withValues(alpha: .08),
                      ),
                    ),
                  ),
                  body,
                ],
              )
            : body,
      ),
    );
  }
}
