import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/account.dart';
import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/sheet.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../analytics/charts.dart';
import '../analytics/observer_charts.dart';
import '../atlas/atlas.dart' show resolveObserverNode;
import '../atlas/atlas_widgets.dart' show AtlasSegmented;
import 'directory_widgets.dart';
import 'meshmapper_section.dart';
import 'node_telemetry.dart';
import 'observation_row.dart';
import 'observer_info.dart';
import 'paging.dart';

class EntityDetailScreen extends StatefulWidget {
  const EntityDetailScreen({
    super.key,
    required this.kind,
    required this.id,
    required this.api,
    required this.region,
    required this.onOpen,
    this.events,
    this.account,
  });
  final String kind, id;
  final ApiClient api;
  final Json region;
  final void Function(String, String) onOpen;
  final Stream<Json>? events;

  /// The signed-in user on this server, for "Request telemetry".
  final AccountState? account;
  @override
  State<EntityDetailScreen> createState() => _EntityDetailScreenState();
}

class _EntityDetailScreenState extends State<EntityDetailScreen>
    with WidgetsBindingObserver {
  Json? detail;
  List<Json> history = [], neighbors = [];
  Json cursor = {};
  Json evidenceWindow = {};
  Json customWindow = {};
  final historyScroll = ScrollController();
  Object? error, historyError, neighborsError;
  bool loading = true, loadingHistory = false;
  bool refreshPending = false, detailInFlight = false;
  int generation = 0;
  int historyGeneration = 0;
  String range = '24h', scope = '';
  List<String> scopes = [];
  StreamSubscription<Json>? subscription;
  Timer? refreshTimer, observerTimer;

  /// Set when an observer opened here turned out to be a node's radio.
  String? nodeId;
  String get entityKind => nodeId != null ? 'node' : widget.kind;
  String get entityId => nodeId ?? widget.id;

  /// The observer a node screen shows in its Observer view.
  String? get linkedObserverId {
    if (entityKind != 'node') return null;
    final id = textOf(detail?['observerId']);
    return id.isEmpty ? null : id;
  }

  String view = 'node';
  Json? observer;
  List<Json> adverts = [];
  Json advertsCursor = {};
  Object? observerError, advertsError;
  bool observerStarted = false, observerLoading = false, loadingAdverts = false;
  int observerGeneration = 0, advertsGeneration = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    bind();
  }

  void bind() {
    subscription?.cancel();
    subscription = widget.events?.listen((event) {
      final relevant = {
        'node': 'nodeUpdate',
        'observer': 'observerStatus',
        'channel': 'channelMessage',
      }[entityKind];
      final data = object(event['data']);
      final linked = linkedObserverId;
      if (linked != null && event['event'] == 'observerStatus') {
        if (textOf(data['observerId'] ?? data['id']) == linked) {
          refreshObserver();
        }
        return;
      }
      if (event['type'] == 'refresh') refreshObserver();
      if (event['type'] != 'refresh' && event['event'] != relevant) return;
      final id =
          data['channelId'] ??
          data['observerId'] ??
          data['nodeId'] ??
          data['id'];
      if (id != null && textOf(id) != entityId) return;
      refreshPending = true;
      flushRefresh();
    });
  }

  void refreshObserver() {
    if (!observerStarted) return;
    observerTimer?.cancel();
    observerTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) loadObserver(fresh: true, live: true);
    });
  }

  void flushRefresh() {
    if (!mounted ||
        !refreshPending ||
        loading ||
        loadingHistory ||
        detailInFlight ||
        refreshTimer?.isActive == true) {
      return;
    }
    refreshTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted || loading || loadingHistory || detailInFlight) return;
      refreshPending = false;
      entityKind == 'channel'
          ? loadHistory(live: true)
          : load(live: true, fresh: true);
    });
  }

  @override
  void didUpdateWidget(covariant EntityDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api ||
        old.id != widget.id ||
        old.kind != widget.kind ||
        jsonEncode(old.region) != jsonEncode(widget.region)) {
      generation++;
      refreshPending = false;
      refreshTimer?.cancel();
      resetObserver();
      nodeId = null;
      history = [];
      neighbors = [];
      neighborsError = null;
      detail = null;
      load();
    }
    if (old.events != widget.events) bind();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      load(preserveHistory: true);
      refreshObserver();
    }
  }

  void resetObserver() {
    observerGeneration++;
    advertsGeneration++;
    observerTimer?.cancel();
    view = 'node';
    observer = null;
    adverts = [];
    advertsCursor = {};
    observerError = advertsError = null;
    observerStarted = observerLoading = loadingAdverts = false;
  }

  @override
  void dispose() {
    generation++;
    subscription?.cancel();
    refreshTimer?.cancel();
    observerTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    historyScroll.dispose();
    super.dispose();
  }

  Future<void> load({
    bool fresh = false,
    bool preserveHistory = false,
    bool live = false,
  }) async {
    final g = ++generation;
    detailInFlight = true;
    setState(() {
      loading = detail == null || !live;
      error = null;
    });
    try {
      final get = retryingGet(
        widget.api,
        fresh: fresh,
        isCurrent: () => mounted && g == generation,
      );
      Json value;
      if (entityKind == 'route') {
        value = object(jsonDecode(entityId));
      } else if (widget.kind == 'observer' && nodeId == null && !live) {
        value = await loadObserverOrNode(get, g);
      } else {
        value = object(
          await get('/${entityKind}s/${Uri.encodeComponent(entityId)}'),
        );
      }
      if (!mounted || g != generation) return;
      setState(() {
        detail = value;
        loading = false;
      });
      if (view == 'observer' && !observerStarted) unawaited(loadObserver());
      if (entityKind == 'node') await loadNeighbors(g, fresh: fresh);
      if (entityKind == 'channel' && !emptyDirectoryRegion(widget.region)) {
        try {
          final s = await widget.api.get('/scopes', widget.region);
          if (mounted && g == generation) {
            setState(
              () => scopes = (s is List ? s : []).map((e) => '$e').toList(),
            );
          }
        } catch (_) {}
      }
      if (mounted &&
          g == generation &&
          !(preserveHistory && history.isNotEmpty)) {
        await loadHistory(fresh: fresh);
      }
    } catch (e) {
      if (mounted && g == generation) {
        setState(() {
          error = e;
          loading = false;
        });
      }
    } finally {
      if (mounted && g == generation) {
        detailInFlight = false;
        flushRefresh();
      }
    }
  }

  /// An observer whose radio is also a node opens as that node, on its
  /// Observer view; one with no node keeps the observer screen.
  Future<Json> loadObserverOrNode(
    Future<dynamic> Function(String, [Json]) get,
    int g,
  ) async {
    final obs = object(
      await get('/observers/${Uri.encodeComponent(widget.id)}'),
    );
    Json? node;
    try {
      node = await resolveObserverNode(widget.api, obs);
    } catch (_) {}
    final id = textOf(node?['id']);
    if (id.isEmpty || !mounted || g != generation) return obs;
    try {
      final value = object(await get('/nodes/${Uri.encodeComponent(id)}'));
      if (textOf(value['observerId']).isEmpty) value['observerId'] = widget.id;
      nodeId = id;
      observer = obs;
      view = 'observer';
      return value;
    } catch (_) {
      return obs;
    }
  }

  Future<void> loadObserver({bool fresh = false, bool live = false}) async {
    final id = linkedObserverId;
    if (id == null) return;
    observerStarted = true;
    final og = ++observerGeneration;
    bool current() => mounted && og == observerGeneration;
    setState(() {
      observerLoading = observer == null;
      observerError = null;
    });
    try {
      if (observer == null || fresh) {
        final value = object(
          await retryingGet(widget.api, fresh: fresh, isCurrent: current)(
            '/observers/${Uri.encodeComponent(id)}',
          ),
        );
        if (!current()) return;
        setState(() => observer = value);
      }
      if (!current()) return;
      setState(() => observerLoading = false);
      await loadAdverts(fresh: fresh, live: live);
    } catch (e) {
      if (current()) {
        setState(() {
          observerError = e;
          observerLoading = false;
        });
      }
    }
  }

  Future<void> loadAdverts({
    bool more = false,
    bool live = false,
    bool fresh = false,
  }) async {
    final id = linkedObserverId;
    if (id == null) return;
    final ag = ++advertsGeneration;
    if (emptyDirectoryRegion(widget.region)) {
      setState(() {
        adverts = [];
        advertsCursor = {};
        loadingAdverts = false;
      });
      return;
    }
    bool current() => mounted && ag == advertsGeneration;
    setState(() {
      loadingAdverts = true;
      advertsError = null;
    });
    try {
      final response =
          await retryingGet(
            widget.api,
            fresh: more || live || fresh,
            isCurrent: current,
          )('/observers/${Uri.encodeComponent(id)}/adverts', {
            'limit': 50,
            if (more) ...advertsCursor,
          });
      if (!current()) return;
      setState(() {
        adverts = more || live
            ? mergeDirectoryRows(adverts, rows(response), 'messages')
            : rows(response);
        if (!live) {
          advertsCursor = nextDirectoryCursor('observer', response, 50);
        }
        loadingAdverts = false;
      });
    } catch (e) {
      if (current()) {
        setState(() {
          advertsError = e;
          loadingAdverts = false;
        });
      }
    }
  }

  void setView(String next) {
    if (next == view) return;
    setState(() => view = next);
    if (next == 'observer' && !observerStarted) loadObserver();
  }

  Future<void> loadNeighbors(int g, {bool fresh = false}) async {
    try {
      final n = await retryingGet(
        widget.api,
        fresh: fresh,
        isCurrent: () => mounted && g == generation,
      )('/nodes/${Uri.encodeComponent(entityId)}/neighbors');
      if (mounted && g == generation) {
        setState(() {
          neighbors = rows(n);
          neighborsError = null;
        });
      }
    } catch (e) {
      // Kept apart from historyError, which loadHistory() clears.
      if (mounted && g == generation) setState(() => neighborsError = e);
    }
  }

  Future<void> loadHistory({
    bool more = false,
    bool live = false,
    bool fresh = false,
  }) async {
    if (entityKind == 'trace') return;
    if (emptyDirectoryRegion(widget.region)) {
      setState(() {
        history = [];
        cursor = {};
        loadingHistory = false;
      });
      return;
    }
    final g = generation;
    final hg = ++historyGeneration;
    final oldOffset = historyScroll.hasClients ? historyScroll.offset : 0.0;
    final initial = history.isEmpty;
    final wasAtBottom = oldOffset < 80;
    setState(() {
      loadingHistory = true;
      historyError = null;
    });
    try {
      final d = detail ?? {};
      String path;
      Json params = {'limit': 50, if (more) ...cursor};
      switch (entityKind) {
        case 'node':
          path = '/nodes/${Uri.encodeComponent(entityId)}/observations';
        case 'observer':
          path = '/observers/${Uri.encodeComponent(entityId)}/adverts';
        case 'channel':
          path = '/channels/${Uri.encodeComponent(entityId)}/messages';
          params = {
            ...params,
            ...widget.region,
            if (scope.isNotEmpty) 'scope': scope,
          };
        case 'route':
          if (d['pathKey'] == null) {
            setState(() => loadingHistory = false);
            return;
          }
          path =
              '/routes/${Uri.encodeComponent(textOf(d['iata']))}/${Uri.encodeComponent(textOf(d['pathKey']))}/observations';
          params = {
            ...params,
            if (more && evidenceWindow.isNotEmpty)
              ...evidenceWindow
            else if (customWindow.isNotEmpty)
              ...customWindow
            else
              'range': range,
          };
        default:
          return;
      }
      final response =
          entityKind == 'channel' && emptyDirectoryRegion(widget.region)
          ? []
          : await retryingGet(
              widget.api,
              fresh: more || live || fresh,
              isCurrent: () =>
                  mounted && g == generation && hg == historyGeneration,
            )(path, params);
      if (!mounted || g != generation || hg != historyGeneration) return;
      setState(() {
        history = more || live
            ? mergeDirectoryRows(history, rows(response), 'messages')
            : rows(response);
        if (entityKind == 'channel') {
          // Server receipt order is stable even when a sender's clock is wrong.
          history.sort(
            (a, b) => (number(a['id']) ?? 0).compareTo(number(b['id']) ?? 0),
          );
        }
        if (entityKind == 'route') {
          final responseMap = object(response);
          evidenceWindow = {
            'since': responseMap['windowStart'],
            'until': responseMap['windowEnd'],
          };
        }
        if (!live) {
          cursor = nextDirectoryCursor(
            entityKind == 'channel' ? 'messages' : entityKind,
            response,
            50,
          );
        }
        loadingHistory = false;
      });
      if (entityKind == 'channel') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !historyScroll.hasClients) return;
          // A reversed list anchors existing messages when older rows are added.
          if (!more && (initial || wasAtBottom)) {
            historyScroll.jumpTo(0);
          }
        });
      }
    } catch (e) {
      if (mounted && g == generation && hg == historyGeneration) {
        setState(() {
          historyError = e;
          loadingHistory = false;
        });
      }
    } finally {
      if (mounted && g == generation && hg == historyGeneration) flushRefresh();
    }
  }

  Widget link(String title, String kind, dynamic id, {String? subtitle}) =>
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(tr(title), style: const TextStyle(fontSize: 12)),
        subtitle: subtitle == null ? null : mono(subtitle),
        trailing: const Icon(Icons.chevron_right, size: 16),
        onTap: id == null ? null : () => widget.onOpen(kind, '$id'),
      );
  Widget hop(Json h, int index) {
    final colors = BeaconColors.of(context);
    final node = object(h['node']);
    final candidates = rows(h['nodes']);
    if (node.isNotEmpty) candidates.insert(0, node);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          mono('${tr('Hop')} ${index + 1}', color: colors.muted),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              nodeBadge(
                textOf(h['hashBytes'] ?? h['hash']).toUpperCase(),
                colors.primary,
              ),
              if (number(h['snr']) != null)
                nodeBadge(
                  '${h['snr']} dB',
                  number(h['snr'])! >= 0 ? colors.success : colors.warning,
                ),
            ],
          ),
          if (candidates.isEmpty) const SizedBox(height: 6),
          if (candidates.isEmpty)
            Text(
              h['nodeId'] == null
                  ? tr('Unresolved hop')
                  : '${tr('Node')} ${h['nodeId']}',
              style: TextStyle(
                fontSize: 11,
                color: BeaconColors.of(context).muted,
              ),
            ),
          ...candidates.map(
            (n) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                label(n),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.bright),
              ),
              subtitle: textOf(n['publicKey']).isEmpty
                  ? null
                  : Tooltip(
                      message: textOf(n['publicKey']),
                      child: Text(
                        textOf(n['publicKey']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 10,
                          color: colors.muted,
                        ),
                      ),
                    ),
              trailing: Icon(
                Icons.chevron_right,
                size: 16,
                color: colors.primary,
              ),
              onTap: n['id'] == null
                  ? null
                  : () => widget.onOpen('node', textOf(n['id'])),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> copyLink() async {
    final uri = widget.api.base;
    final params = entityKind == 'route'
        ? {
            'tab': 'Routes',
            'route': textOf(detail?['pathKey']),
            'routeIata': textOf(detail?['iata']),
          }
        : {
            'tab': '${entityKind[0].toUpperCase()}${entityKind.substring(1)}s',
            entityKind: entityId,
            if (linkedObserverId != null && view == 'observer')
              'view': 'observer',
          };
    await Clipboard.setData(
      ClipboardData(text: uri.replace(queryParameters: params).toString()),
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: DirectoryText('Link copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = detail;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          d == null
              ? tr('$entityKind detail')
              : entityKind == 'channel'
              ? channelName(d)
              : entityKind == 'trace'
              ? '${d['traceTag']}'
              : entityKind == 'route'
              ? '${trKey('routeDetail.route')} · ${d['iata']}'
              : label(d),
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          IconButton(
            onPressed: copyLink,
            tooltip: tr('Copy link'),
            icon: const Icon(Icons.link),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? failure(error!, () => load(fresh: true))
          : d == null
          ? const Center(child: DirectoryText('Not found'))
          : entityKind == 'channel'
          ? channelBody(d)
          : RefreshIndicator(
              onRefresh: () => Future.wait([
                load(fresh: true),
                if (observerStarted) loadObserver(fresh: true),
              ]),
              child: ListView(
                controller: historyScroll,
                padding: const EdgeInsets.all(16),
                children: [
                  ...switch (entityKind) {
                    'node' => nodeContent(d),
                    'observer' => observerContent(d, entityId, history),
                    'trace' => traceContent(d),
                    'route' => routeContent(d),
                    _ => [],
                  },
                  if (showingObserver)
                    ...observerViewFooter()
                  else ...[
                    if (historyError != null)
                      failure(historyError!, () => loadHistory(fresh: true)),
                    if (loadingHistory)
                      const LinearProgressIndicator(minHeight: 2),
                    if (cursor.isNotEmpty && entityKind != 'channel')
                      OutlinedButton(
                        onPressed: loadingHistory
                            ? null
                            : () => loadHistory(more: true),
                        child: const DirectoryText('Load older'),
                      ),
                  ],
                ],
              ),
            ),
    );
  }

  bool get showingObserver => linkedObserverId != null && view == 'observer';

  List<Widget> observerViewFooter() => [
    if (advertsError != null)
      failure(advertsError!, () => loadAdverts(fresh: true)),
    if (loadingAdverts) const LinearProgressIndicator(minHeight: 2),
    if (advertsCursor.isNotEmpty)
      OutlinedButton(
        onPressed: loadingAdverts ? null : () => loadAdverts(more: true),
        child: const DirectoryText('Load older'),
      ),
  ];

  Widget viewSwitch() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: AtlasSegmented<String>(
      stretch: true,
      label: trKey('observerMerge.view'),
      value: view,
      onChanged: setView,
      options: {
        'node': trKey('observerMerge.node'),
        'observer': trKey('observerMerge.observer'),
      },
    ),
  );

  List<Widget> linkedObserverContent(String id) {
    final o = observer;
    if (observerError != null) {
      return [failure(observerError!, () => loadObserver(fresh: true))];
    }
    if (o == null || observerLoading) {
      return [
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    return observerContent(o, id, adverts);
  }

  Widget nodeBadge(String value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      border: Border.all(color: color.withValues(alpha: .3)),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      value,
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    ),
  );

  Widget nodeTime(String title, dynamic value) =>
      Tooltip(message: stamp(value), child: fact(title, age(value)));

  List<Widget> nodeContent(Json d) {
    final colors = BeaconColors.of(context);
    final publicKey = textOf(d['publicKey']);
    final meshMapper = object(d['meshmapper']);
    Widget capability(String title, dynamic value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              tr(title),
              style: TextStyle(fontSize: 11, color: colors.muted),
            ),
          ),
          nodeBadge(
            tr(
              value == true
                  ? 'Yes'
                  : value == false
                  ? 'No'
                  : 'Unknown',
            ),
            value == true ? colors.success : colors.muted,
          ),
        ],
      ),
    );
    final observerId = linkedObserverId;
    final identity = section('Identity', [
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          nodeBadge(
            textOf(d['nodeTypeName'], tr('Unknown')).toUpperCase(),
            switch (textOf(d['nodeTypeName']).toLowerCase()) {
              'repeater' => colors.success,
              'room server' || 'room_server' => colors.secondary,
              'companion' => colors.primary,
              'sensor' => colors.warning,
              _ => colors.muted,
            },
          ),
          if (textOf(d['defaultScope']).isNotEmpty)
            nodeBadge(textOf(d['defaultScope']), colors.secondary),
          if (d['possiblyForeign'] == true)
            nodeBadge(tr('Possibly foreign'), colors.warning),
          if (meshMapper['carpeater'] == true)
            Tooltip(
              message: trKey('meshMapper.carpeaterHint'),
              child: nodeBadge(trKey('meshMapper.carpeater'), colors.warning),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: publicKey.isEmpty
                  ? null
                  : () => showValueSheet(
                      context,
                      title: tr('Public key'),
                      value: publicKey,
                    ),
              child: Text(
                publicKey.isEmpty ? tr('Unknown') : publicKey,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 12,
                  color: colors.primary,
                ),
              ),
            ),
          ),
          if (publicKey.isNotEmpty)
            IconButton(
              tooltip: tr('Copy public key'),
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: publicKey));
                if (mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(tr('Copied'))));
                }
              },
            ),
        ],
      ),
      nodeTime('Last seen', d['lastSeen']),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          if (d['lat'] != null)
            OutlinedButton.icon(
              onPressed: () => widget.onOpen('map', entityId),
              icon: const Icon(Icons.map_outlined, size: 16),
              label: Text(tr('Show on map')),
            ),
        ],
      ),
    ]);
    if (observerId != null && view == 'observer') {
      return [identity, viewSwitch(), ...linkedObserverContent(observerId)];
    }
    return [
      identity,
      if (observerId != null) viewSwitch(),
      section(trKey('nodePanel.details'), [
        if (d['lat'] != null && d['lng'] != null)
          fact('Coordinates', '${d['lat']}, ${d['lng']}'),
        nodeTime('First seen', d['firstSeen']),
        if (d['lastAdvertAt'] != null)
          nodeTime('Last advert', d['lastAdvertAt']),
        if (textOf(d['radio']).isNotEmpty) fact('Radio', d['radio']),
        capability('Multibyte paths', d['supportsMultibytePaths']),
        capability('Multibyte traces', d['supportsMultibyteTraces']),
        if (d['minFirmwareVersion'] != null)
          fact('Minimum firmware', d['minFirmwareVersion']),
        if (d['clockDriftSeconds'] != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  tr('Clock drift'),
                  style: TextStyle(fontSize: 11, color: colors.muted),
                ),
                nodeBadge(
                  '${d['clockDriftSeconds']} s${d['clockOutOfSync'] == true ? ' · ${tr('Out of sync')}' : ''}',
                  d['clockOutOfSync'] == true ? colors.warning : colors.success,
                ),
              ],
            ),
          ),
        if (rows(d['iatas']).isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            tr('Heard in regions'),
            style: TextStyle(fontSize: 11, color: colors.muted),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final region in rows(d['iatas']))
                Tooltip(
                  message: '${tr('Last seen')}: ${stamp(region['lastHeard'])}',
                  child: nodeBadge(textOf(region['iata']), colors.primary),
                ),
            ],
          ),
        ],
      ]),
      if (MeshMapperSection.hasContent(meshMapper))
        MeshMapperSection(data: meshMapper),
      // Observers report their own readings, shown in the Observer view.
      if (isPolledNodeType(textOf(d['nodeTypeName'])) && observerId == null)
        NodeTelemetrySection(
          key: ValueKey('telemetry:$entityId'),
          api: widget.api,
          nodeId: entityId,
          publicKey: publicKey,
          account: widget.account,
          onOpen: widget.onOpen,
        ),
      FoldSection(
        id: 'node-neighbors',
        title: trKey('nodeDetail.neighborsCount')
            .replaceAll('{{count}}', '${neighbors.length}'),
        children: [
          if (neighborsError != null)
            failure(
              neighborsError!,
              () => loadNeighbors(generation, fresh: true),
            )
          else if (neighbors.isEmpty)
            Text(
              tr('No known neighbors'),
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
          for (final n in neighbors)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                label(n),
                style: TextStyle(fontSize: 12, color: colors.primary),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (textOf(n['iata']).isNotEmpty)
                      nodeBadge(textOf(n['iata']), colors.primary),
                    if (n['observationCount'] != null)
                      mono(
                        trKey(
                          'investigation.observations',
                          count: (number(n['observationCount']) ?? 0).toInt(),
                        ),
                        color: colors.muted,
                      ),
                    Tooltip(
                      message: stamp(n['lastSeen']),
                      child: mono(age(n['lastSeen']), color: colors.muted),
                    ),
                  ],
                ),
              ),
              trailing: const Icon(Icons.chevron_right, size: 16),
              onTap: n['id'] == null
                  ? null
                  : () => widget.onOpen('node', textOf(n['id'])),
            ),
        ],
      ),
      FoldSection(
        id: 'node-packets',
        title: trKey('nodePanel.packetsSent'),
        info: [
          trKey('nodePanel.packetsSentInfo'),
          trKey('nodePanel.packetsSentExpire'),
        ],
        summary: history.isEmpty ? '' : age(history.first['heardAt']),
        children: history.isEmpty
            ? [
                Text(
                  trKey('nodePanel.noPacketsSent'),
                  style: TextStyle(fontSize: 12, color: colors.muted),
                ),
              ]
            : history.map(observation).toList(),
      ),
    ];
  }

  List<Widget> observerContent(Json d, String id, List<Json> heard) => [
    StatsQuery(
      api: widget.api,
      path: '/observers/${Uri.encodeComponent(id)}/activity',
      params: observerActivityParams(range),
      pollInterval: const Duration(minutes: 1),
      builder: (activity) =>
          ObserverInfo(data: d, summary: object(object(activity)['summary'])),
      fallback: (_) => ObserverInfo(data: d),
    ),
    link('Compare observers', 'analytics', 'compare:$id'),
    section('Activity & telemetry', [
      Text(tr('Window'), style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: range,
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        items: const [
          DropdownMenuItem(value: '24h', child: DirectoryText('24 hours')),
          DropdownMenuItem(value: '7d', child: DirectoryText('7 days')),
          DropdownMenuItem(value: '30d', child: DirectoryText('30 days')),
        ],
        onChanged: (v) => setState(() => range = v ?? '24h'),
      ),
      const SizedBox(height: 12),
      ObserverCharts(
        key: ValueKey('$id:$range'),
        api: widget.api,
        observerId: id,
        range: range,
      ),
    ]),
    section('Heard adverts', heard.map(observation).toList()),
  ];
  Widget channelBody(Json d) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: channelHeader(d),
        ),
      ),
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            final scrollingUp =
                notification is ScrollUpdateNotification &&
                (notification.scrollDelta ?? 0) > 0;
            final overscrollingUp =
                notification is OverscrollNotification &&
                notification.overscroll > 0;
            if (notification.depth == 0 &&
                (scrollingUp || overscrollingUp) &&
                notification.metrics.extentAfter < 200 &&
                cursor.isNotEmpty &&
                !loadingHistory &&
                historyError == null) {
              loadHistory(more: true);
            }
            return false;
          },
          child: ListView(
            key: const ValueKey('channel-message-list'),
            reverse: true,
            controller: historyScroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              ...channelMessages().reversed,
              // Keep this slot a fixed height so loading does not shift messages.
              SizedBox(
                height: 2,
                child: loadingHistory ? const LinearProgressIndicator() : null,
              ),
              if (historyError != null)
                failure(
                  historyError!,
                  () => loadHistory(more: cursor.isNotEmpty),
                ),
            ],
          ),
        ),
      ),
    ],
  );

  List<Widget> channelHeader(Json d) => [
    Wrap(
      spacing: 12,
      children: [
        mono(textOf(d['channelHash'])),
        mono(
          tr(d['keyKnown'] == true ? 'key known' : 'Encrypted').toUpperCase(),
        ),
        mono(
          trKey(
            'channelMessages.count',
            count: (number(d['messageCount']) ?? history.length).toInt(),
          ),
        ),
      ],
    ),
    if (scopes.isNotEmpty)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: DropdownButtonFormField<String>(
          initialValue: scope,
          decoration: InputDecoration(labelText: tr('Transport scope')),
          items: [
            const DropdownMenuItem(
              value: '',
              child: DirectoryText('All scopes'),
            ),
            ...scopes.map((s) => DropdownMenuItem(value: s, child: Text(s))),
          ],
          onChanged: (v) {
            setState(() {
              scope = v ?? '';
              history = [];
              cursor = {};
            });
            loadHistory();
          },
        ),
      ),
  ];

  List<Widget> channelMessages() => [
    // A failed load is not an empty scope; the failure row says so.
    if (history.isEmpty && !loadingHistory && historyError == null)
      const Padding(
        padding: EdgeInsets.all(20),
        child: DirectoryText('No messages in this scope.'),
      ),
    ...history.map(
      (m) => InkWell(
        onTap: () => widget.onOpen('packet', textOf(m['packetHash'])),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).dividerColor.withValues(alpha: .4),
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    textOf(m['senderName'], tr('Unknown sender')),
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: senderColor(textOf(m['senderName'])),
                    ),
                  ),
                  mono(age(m['sentAt']), color: BeaconColors.of(context).muted),
                  if ((number(m['observationCount']) ?? 0) > 0)
                    GestureDetector(
                      onTap: () =>
                          widget.onOpen('packet', textOf(m['packetHash'])),
                      child: Text(
                        trKey(
                          'investigation.observations',
                          count: number(m['observationCount'])!.toInt(),
                        ),
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 10,
                          color: BeaconColors.of(context).primary,
                        ),
                      ),
                    ),
                  if (textOf(m['scope']).trim().isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: BeaconColors.of(context).secondary
                            .withValues(alpha: .1),
                        border: Border.all(
                          color: BeaconColors.of(context).secondary
                              .withValues(alpha: .3),
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Text(
                        textOf(m['scope']).trim(),
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: .5,
                          color: BeaconColors.of(context).secondary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              SelectableText(
                textOf(m['content']),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  ];

  Widget observation(Json o) => ObservationRow(
    observation: o,
    timestamp: stamp(o['heardAt']),
    onOpen: widget.onOpen,
  );
  List<Widget> routeContent(Json d) => [
    section('Known path', [
      fact('IATA', d['iata']),
      fact('Hops', d['hopCount']),
      if (d['observationCount'] != null)
        fact('Observations', d['observationCount']),
      if (d['firstSeen'] != null) fact('First seen', stamp(d['firstSeen'])),
      fact('Last seen', stamp(d['lastSeen'])),
      ...rows(d['hops']).indexed.map((e) => hop(e.$2, e.$1)),
    ]),
    section('Retained evidence', [
      TextButton.icon(
        onPressed: () async {
          final now = DateTime.now();
          final picked = await showDateRangePicker(
            context: context,
            firstDate: now.subtract(const Duration(days: 365)),
            lastDate: now,
          );
          if (picked != null && mounted) {
            if (picked.duration.inDays >= 30) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: DirectoryText('Choose a window of 30 days or less.'),
                ),
              );
              return;
            }
            customWindow = {
              'since': picked.start.millisecondsSinceEpoch,
              'until': picked.end
                  .add(const Duration(days: 1))
                  .millisecondsSinceEpoch,
            };
            unawaited(loadHistory());
          }
        },
        icon: const Icon(Icons.date_range, size: 16),
        label: Text(
          customWindow.isEmpty
              ? tr('Custom date window')
              : tr('{{since}} to {{until}}')
                    .replaceAll('{{since}}', stamp(customWindow['since']))
                    .replaceAll('{{until}}', stamp(customWindow['until'])),
        ),
      ),
      DropdownButtonFormField<String>(
        initialValue: range,
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        items: const [
          DropdownMenuItem(value: '24h', child: DirectoryText('24 hours')),
          DropdownMenuItem(value: '168h', child: DirectoryText('7 days')),
          DropdownMenuItem(value: '720h', child: DirectoryText('30 days')),
        ],
        onChanged: (v) {
          range = v ?? '24h';
          customWindow = {};
          loadHistory();
        },
      ),
      const SizedBox(height: 10),
      if (d['pathKey'] == null)
        const DirectoryText(
          'This server does not provide retained evidence for this route.',
        ),
      if (d['pathKey'] != null && history.isEmpty && !loadingHistory)
        const DirectoryText(
          'No retained matching observations in this window.',
        ),
      ...history.map(observation),
    ]),
  ];
  List<Widget> traceContent(Json d) => [
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          nodeBadge(
            textOf(d['traceTag']).toUpperCase(),
            BeaconColors.of(context).primary,
          ),
          nodeBadge(
            trKey('traces.packetCount', count: rows(d['packets']).length),
            BeaconColors.of(context).muted,
          ),
        ],
      ),
    ),
    ...rows(d['packets']).map((p) {
      final raw = rows(p['rawPath']), resolved = rows(p['resolvedRoute']);
      return section(textOf(p['routeTypeName'], 'Trace packet'), [
        link(
          textOf(p['packetHash']),
          'packet',
          p['packetHash'],
          subtitle: age(p['lastHeardAt']),
        ),
        if (textOf(p['scope']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: nodeBadge(
              textOf(p['scope']),
              BeaconColors.of(context).secondary,
            ),
          ),
        ...List.generate(
          raw.length > resolved.length ? raw.length : resolved.length,
          (i) => hop({
            if (i < raw.length) ...raw[i],
            if (i < resolved.length) ...resolved[i],
          }, i),
        ),
      ]);
    }),
  ];
}
