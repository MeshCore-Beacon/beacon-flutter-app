import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'map_data.dart';
import 'map_markers.dart';
import 'map_projection.dart';
import 'map_repository.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.api,
    required this.region,
    required this.onOpen,
    this.selectedNodeId,
    this.events,
  });
  final Stream<Json>? events;
  final ApiClient api;
  final Map<String, dynamic> region;
  final void Function(String kind, String id) onOpen;
  final String? selectedNodeId;
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  StreamSubscription<Json>? _events;
  Timer? _flowTimer;
  bool _flow = false;
  final _flows = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _nodes = [],
      _neighbors = [],
      _airports = [],
      _borders = [];
  String _style = 'dark', _type = '', _mode = 'selected';
  String? _selected, _error, _mapError;
  int? _visibleCount;
  bool _loading = true,
      _settings = false,
      _cluster = true,
      _showBorders = false;
  int _generation = 0;
  final _canvas = GlobalKey<_NativeMapState>();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listen();
    _selected = widget.selectedNodeId;
    _restore();
    _load();
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _settings = p.getBool('beacon-map-settings-open') ?? false;
      _style = p.getString('beacon-map-style') ?? 'dark';
      _type = p.getString('beacon-map-node-type') ?? '';
      _cluster = p.getBool('beacon-map-clustering') ?? true;
      _mode = p.getString('beacon-map-neighbors') ?? 'selected';
      _showBorders = p.getBool('beacon-map-borders') ?? false;
    });
    if (_showBorders) unawaited(_loadBorders());
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('beacon-map-settings-open', _settings);
    await p.setString('beacon-map-style', _style);
    await p.setString('beacon-map-node-type', _type);
    await p.setBool('beacon-map-clustering', _cluster);
    await p.setString('beacon-map-neighbors', _mode);
    await p.setBool('beacon-map-borders', _showBorders);
  }

  @override
  void didUpdateWidget(covariant MapScreen old) {
    super.didUpdateWidget(old);
    if (old.events != widget.events) _listen();
    if (old.api != widget.api ||
        jsonEncode(old.region) != jsonEncode(widget.region)) {
      _selected = widget.selectedNodeId;
      _load(replace: true);
    } else if (old.selectedNodeId != widget.selectedNodeId) {
      _select(widget.selectedNodeId);
    }
  }

  void _listen() {
    _events?.cancel();
    _events = widget.events?.listen((event) {
      if (!mounted) return;
      if (_codes?.isEmpty == true) return;
      if (event['type'] == 'refresh') {
        _load();
        return;
      }
      final d = object(event['data']);
      if (event['event'] == 'nodeUpdate') {
        final id = textOf(d['nodeId']);
        final index = _nodes.indexWhere((n) => n['id'] == id);
        setState(() {
          if (index >= 0) {
            _nodes[index] = {..._nodes[index], ...d, 'id': id};
          } else {
            _nodes.add({...d, 'id': id});
          }
        });
      }
      if (_flow && event['event'] == 'packetObservation') {
        final ns = flowNodes(object(d['observation']));
        if (ns.length < 2) return;
        while (_flows.length >= 120) {
          _flows.removeAt(0);
        }
        _flows.add({
          'nodes': ns,
          'start': DateTime.now().millisecondsSinceEpoch,
        });
        _flowTimer ??= Timer.periodic(
          const Duration(milliseconds: 50),
          (_) => _tick(),
        );
      }
    });
  }

  void _tick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _flows.removeWhere(
      (f) =>
          now - (number(f['start']) ?? 0) >
          (rows(f['nodes']).length - 1) * 480 + 1000,
    );
    _canvas.currentState?.flow(flowFrame(_flows, now));
    if (_flows.isEmpty) {
      _flowTimer?.cancel();
      _flowTimer = null;
    }
  }

  void _clearFlow() {
    _flows.clear();
    _flowTimer?.cancel();
    _flowTimer = null;
    _canvas.currentState?.flow(flowFrame([], 0));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
    } else {
      _clearFlow();
    }
  }

  bool _current(int gen) => mounted && gen == _generation;
  Future<void> _load({bool replace = false}) async {
    if (_loading && _generation > 0 && !replace) return;
    final gen = ++_generation;
    _flows.clear();
    _flowTimer?.cancel();
    _flowTimer = null;
    setState(() {
      if (replace) {
        _nodes = [];
        _neighbors = [];
        _borders = [];
        _airports = [];
      }
      _loading = true;
      _error = null;
    });
    // An explicitly empty region must not silently broaden to every region.
    final iatas = widget.region['iatas'];
    if (iatas is List && iatas.isEmpty || iatas == '') {
      setState(() => _loading = false);
      return;
    }
    try {
      List<Map<String, dynamic>>? latest;
      await for (final nodes in loadMapNodes(
        widget.api,
        widget.region,
        isCurrent: () => _current(gen),
      )) {
        if (!_current(gen)) return;
        if (_nodes.length <= nodes.length) setState(() => _nodes = nodes);
        latest = nodes;
      }
      if (!_current(gen)) return;
      if (latest != null) setState(() => _nodes = latest!);
      final airports = await widget.api.get('/iatas');
      if (!_current(gen)) return;
      setState(() => _airports = rows(airports));
      _frame();
      if (_selected != null) unawaited(_select(_selected));
      if (_showBorders) unawaited(_loadBorders());
    } catch (e) {
      if (_current(gen)) setState(() => _error = e.toString());
    } finally {
      if (_current(gen)) setState(() => _loading = false);
    }
  }

  List<String>? get _codes {
    final raw = widget.region['iatas'];
    if (raw == null) return null;
    if (raw is List) return raw.map((e) => '$e').toList();
    return '$raw'.split(',').where((s) => s.isNotEmpty).toList();
  }

  Future<void> _loadBorders() async {
    final gen = _generation;
    try {
      final codes = _codes ?? _airports.map((a) => textOf(a['iata'])).toList();
      final output = <Map<String, dynamic>>[];
      for (final code in codes) {
        final b = object(
          await widget.api.get('/iatas/${Uri.encodeComponent(code)}/border'),
        );
        if (!_current(gen)) return;
        if (b['type'] == 'Feature') output.add(b);
      }
      if (_current(gen)) setState(() => _borders = output);
    } catch (e) {
      if (_current(gen)) setState(() => _error = '${tr('Area borders')}: $e');
    }
  }

  Future<void> _select(String? id) async {
    setState(() {
      _selected = id;
      _neighbors = [];
    });
    if (id == null) return;
    final gen = _generation;
    try {
      final ns = rows(
        await widget.api.get('/nodes/${Uri.encodeComponent(id)}/neighbors'),
      );
      if (_current(gen) && _selected == id) setState(() => _neighbors = ns);
    } catch (e) {
      if (_current(gen) && _selected == id) {
        setState(() => _error = '${tr('Neighbor links')}: $e');
      }
    }
  }

  Map<String, dynamic>? get _selectedNode {
    for (final n in _nodes) {
      if (n['id'] == _selected) return n;
    }
    return null;
  }

  void _frame() {
    final selected = _selectedNode;
    if (hasLocation(selected)) {
      _canvas.currentState?.fit([selected!]);
      return;
    }
    final codes = _codes;
    final airports = _airports
        .where((a) => codes == null || codes.contains(a['iata']))
        .map((a) => {...a, 'lng': a['lon']})
        .where(hasLocation)
        .toList();
    _canvas.currentState?.fit(airports.isEmpty ? _nodes : airports);
  }

  Future<void> _copyLink() async {
    final camera =
        _canvas.currentState?._camera ??
        const CameraPosition(target: LatLng(20, 0), zoom: 1.5);
    final link = mapShareUri(
      widget.api.base,
      widget.region,
      lat: camera.target.latitude,
      lng: camera.target.longitude,
      zoom: camera.zoom,
      style: _style,
      nodeType: _type,
      cluster: _cluster,
      neighbors: _mode,
      borders: _showBorders,
      flow: _flow,
    );
    await Clipboard.setData(ClipboardData(text: link.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('Copied!'))));
    }
  }

  Widget _choices(
    String label,
    Map<String, String> options,
    String current,
    void Function(String) changed,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr(label),
          style: TextStyle(
            fontSize: 10,
            color: BeaconColors.of(context).normal,
          ),
        ),
        const SizedBox(height: 3),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: options.entries
              .map(
                (e) => ChoiceChip(
                  label: Text(
                    tr(e.value),
                    style: const TextStyle(fontSize: 11),
                  ),
                  selected: e.key == current,
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                  onSelected: (_) {
                    setState(() => changed(e.key));
                    _save();
                  },
                ),
              )
              .toList(),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final selected = _selectedNode;
    final edges =
        _mode == 'selected' && selected != null && _neighbors.isNotEmpty
        ? focusedFeatures(selected, _neighbors)
        : neighborFeatures(_nodes, _mode, _selected);
    return Stack(
      children: [
        Positioned.fill(
          child: NativeMap(
            key: _canvas,
            style: _style,
            cluster: _cluster,
            liveFlow: _flow,
            points: nodeFeatures(_nodes, type: _type),
            lines: edges,
            borders: collection(_showBorders ? _borders : []),
            onNode: _select,
            onReady: _frame,
            onVisibleCount: (count) {
              if (mounted && _visibleCount != count) {
                setState(() => _visibleCount = count);
              }
            },
            onError: (e) {
              if (mounted) setState(() => _mapError = e);
            },
            selected: _selected,
          ),
        ),
        Positioned(
          top: 12,
          left: 12,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.min(260, MediaQuery.sizeOf(context).width - 72),
            ),
            child: Material(
              color: BeaconColors.of(context).raised,
              shape: RoundedRectangleBorder(
                side: BorderSide(color: BeaconColors.of(context).border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: () {
                      setState(() => _settings = !_settings);
                      _save();
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        children: [
                          const Icon(Icons.tune, size: 15),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              tr('Map Settings'),
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Icon(
                            _settings ? Icons.expand_less : Icons.expand_more,
                            size: 16,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_settings)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * .5,
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _choices(
                              'Map Tiles',
                              {
                                'dark': 'Dark',
                                'liberty': 'Liberty',
                                'positron': 'Light',
                              },
                              _style,
                              (v) => _style = v,
                            ),
                            _choices(
                              'Node Type',
                              {
                                '': 'All',
                                'companion': 'Companion',
                                'repeater': 'Repeater',
                                'room_server': 'Room',
                                'sensor': 'Sensor',
                              },
                              _type,
                              (v) => _type = v,
                            ),
                            _choices(
                              'Clustering',
                              {'on': 'On', 'off': 'Off'},
                              _cluster ? 'on' : 'off',
                              (v) => _cluster = v == 'on',
                            ),
                            _choices(
                              'Neighbor Lines',
                              {
                                'on': 'On',
                                'selected': 'Selected',
                                'off': 'Off',
                              },
                              _mode,
                              (v) => _mode = v,
                            ),
                            if (_mode == 'selected')
                              Text(
                                '${tr('Observations')}: 1 · 20 · 150+\n${tr('fainter = heard longer ago')}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: BeaconColors.of(context).normal,
                                ),
                              ),
                            _choices(
                              'Area Borders',
                              {'on': 'On', 'off': 'Off'},
                              _showBorders ? 'on' : 'off',
                              (v) {
                                _showBorders = v == 'on';
                                if (_showBorders) _loadBorders();
                              },
                            ),
                            TextButton.icon(
                              onPressed: _copyLink,
                              icon: const Icon(Icons.link, size: 16),
                              label: Text(tr('Copy map link')),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: 12,
          right: 10,
          child: Column(
            children: [
              const SizedBox(height: 6),
              _mapButton(Icons.center_focus_strong, 'Fit region', _frame),
              const SizedBox(height: 6),
              _mapButton(
                _flow ? Icons.pause_circle : Icons.bolt,
                _flow
                    ? 'Stop live map packet flow'
                    : 'Play live map packet flow',
                () {
                  setState(() => _flow = !_flow);
                  if (!_flow) _clearFlow();
                },
              ),
            ],
          ),
        ),
        Positioned(
          bottom: selected == null ? 12 : 100,
          left: 12,
          right: 56,
          child: Material(
            color: BeaconColors.of(context).surface.withValues(alpha: .94),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Text(
                [
                  tr('{{located}} located / {{total}} nodes')
                      .replaceAll(
                        '{{located}}',
                        '${_nodes.where(hasLocation).length}',
                      )
                      .replaceAll('{{total}}', '${_nodes.length}'),
                  if (_visibleCount != null)
                    tr('{{count}} visible')
                        .replaceAll('{{count}}', '$_visibleCount'),
                  if (_loading) tr('Loading…'),
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
            ),
          ),
        ),
        if (!_loading && _nodes.isEmpty && _error == null)
          Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(tr('No nodes in this region')),
              ),
            ),
          ),
        if (_error != null || _mapError != null)
          Positioned(
            bottom: 12,
            left: 12,
            right: 12,
            child: Material(
              color: BeaconColors.of(context).danger.withValues(alpha: .12),
              child: ListTile(
                dense: true,
                title: Text(
                  tr(_error ?? _mapError!),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: () {
                    setState(() => _mapError = null);
                    _canvas.currentState?.reload();
                    widget.api.invalidateCache(prefix: '/nodes');
                    _load();
                  },
                  child: Text(tr('Retry')),
                ),
              ),
            ),
          ),
        if (selected != null)
          Positioned(
            bottom: 12,
            left: 12,
            right: 12,
            child: Material(
              color: BeaconColors.of(context).raised,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: BorderSide(color: BeaconColors.of(context).primary),
              ),
              child: ListTile(
                dense: true,
                title: Text(
                  textOf(selected['name'], textOf(selected['id'])),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${textOf(selected['nodeTypeName'])} · ${textOf(selected['lat'])}, ${textOf(selected['lng'])}',
                  style: const TextStyle(
                    fontSize: 10,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
                onTap: () => widget.onOpen('node', textOf(selected['id'])),
                trailing: IconButton(
                  tooltip: tr('Clear selection'),
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _select(null),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _mapButton(IconData icon, String tip, VoidCallback action) => Material(
    color: BeaconColors.of(context).raised,
    borderRadius: BorderRadius.circular(5),
    child: IconButton(
      tooltip: tr(tip),
      onPressed: action,
      icon: Icon(icon, size: 19),
    ),
  );
  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _events?.cancel();
    _flowTimer?.cancel();
    super.dispose();
  }
}

/// Shared native map canvas. Style changes recreate the platform view so stale
/// async layer writes cannot target a replacement style.
// The plugin sends null defaults when updating typed properties. Omit them so
// changing opacity does not clear marker images, label text or sizing.
class _PaintUpdate implements LayerProperties {
  const _PaintUpdate(this.properties);
  final LayerProperties properties;
  @override
  Map<String, dynamic> toJson({bool skipNulls = true}) =>
      properties.toJson(skipNulls: true);
}

Future<void> _setPaint(
  MapLibreMapController controller,
  String layer,
  LayerProperties properties,
) => controller.setLayerProperties(layer, _PaintUpdate(properties));

class NativeMap extends StatefulWidget {
  const NativeMap({
    super.key,
    required this.points,
    required this.lines,
    required this.borders,
    required this.onNode,
    this.style = 'dark',
    this.cluster = false,
    this.liveFlow = false,
    this.selected,
    this.onReady,
    this.onError,
    this.fitPoints = false,
    this.onVisibleCount,
  });
  final Map<String, dynamic> points, lines, borders;
  final void Function(int)? onVisibleCount;
  final bool fitPoints;
  final String style;
  final bool cluster;
  final bool liveFlow;
  final String? selected;
  final void Function(String) onNode;
  final VoidCallback? onReady;
  final void Function(String)? onError;
  @override
  State<NativeMap> createState() => _NativeMapState();
}

class _NativeMapState extends State<NativeMap> {
  MapLibreMapController? _controller;
  bool _ready = false;
  int _epoch = 0;
  Future<void> _writes = Future.value();
  int _reload = 0;
  bool _firstReady = true;
  CameraPosition _camera = const CameraPosition(
    target: LatLng(20, 0),
    zoom: 1.5,
  );
  String get _identity => '${widget.style}-${widget.cluster}-$_reload';
  void reload() {
    setState(() {
      _epoch++;
      _ready = false;
      _controller = null;
      _reload++;
    });
  }

  @override
  void didUpdateWidget(covariant NativeMap old) {
    super.didUpdateWidget(old);
    if (old.style != widget.style || old.cluster != widget.cluster) {
      _epoch++;
      _ready = false;
      _controller = null;
    } else {
      _update();
      if (widget.fitPoints) fit(_locations());
    }
  }

  void _update() {
    final epoch = _epoch;
    _writes = _writes.catchError((Object _) {}).then((_) async {
      final c = _controller;
      if (!_ready || c == null || !mounted || epoch != _epoch) return;
      try {
        await c.setGeoJsonSource('beacon-nodes', widget.points);
        if (!mounted || epoch != _epoch) return;
        await c.setGeoJsonSource('beacon-links', widget.lines);
        if (!mounted || epoch != _epoch) return;
        await c.setGeoJsonSource('beacon-borders', widget.borders);
        if (!mounted || epoch != _epoch) return;
        await _applyFlowStyle(c);
        if (!mounted || epoch != _epoch) return;
        await c.setFilter('beacon-selected', [
          '==',
          ['get', 'id'],
          widget.selected ?? '',
        ]);
      } catch (e) {
        if (mounted && epoch == _epoch) widget.onError?.call('Map layers: $e');
      }
    });
  }

  Future<void> _applyFlowStyle(MapLibreMapController c) async {
    await _applyNodeGlow(c);
    await _setPaint(
      c,
      'beacon-clusters',
      SymbolLayerProperties(iconOpacity: widget.liveFlow ? 0.07 : 1.0),
    );
    await _setPaint(
      c,
      'beacon-cluster-count',
      SymbolLayerProperties(textOpacity: widget.liveFlow ? 0.0 : 1.0),
    );
    await _setPaint(
      c,
      'beacon-labels',
      SymbolLayerProperties(textOpacity: widget.liveFlow ? 0.0 : 1.0),
    );
  }

  Future<void> _applyNodeGlow(MapLibreMapController c) async {
    final opacity = liveMarkerOpacity(widget.liveFlow, _nodeGlow);
    await _setPaint(
      c,
      'beacon-points',
      SymbolLayerProperties(iconOpacity: opacity),
    );
    await _setPaint(
      c,
      'beacon-path-points',
      CircleLayerProperties(
        circleOpacity: opacity,
        circleStrokeOpacity: opacity,
      ),
    );
  }

  Future<void> _styleLoaded() async {
    final c = _controller;
    final epoch = _epoch;
    if (c == null || !mounted) return;
    final imageScale = MediaQuery.devicePixelRatioOf(context);
    try {
      // MapLibre Native supports raster DEM hillshading, but not 3D terrain.
      await c.addSource(
        'beacon-elevation',
        const RasterDemSourceProperties(
          tiles: [
            'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png',
          ],
          tileSize: 256,
          encoding: 'terrarium',
          maxzoom: 15,
          attribution: '<a href="https://github.com/tilezen/joerd/blob/master/docs/attribution.md">Tilezen Joerd</a>',
        ),
      );
      await c.addHillshadeLayer(
        'beacon-elevation',
        'beacon-hillshade',
        HillshadeLayerProperties(
          hillshadeExaggeration: 0.3,
          hillshadeShadowColor: widget.style == 'dark' ? '#09090b' : '#566477',
          hillshadeHighlightColor: widget.style == 'dark'
              ? '#424250'
              : '#ffffff',
        ),
      );
      await c.addGeoJsonSource('beacon-borders', widget.borders);
      await c.addFillLayer(
        'beacon-borders',
        'beacon-border-fill',
        const FillLayerProperties(fillColor: '#a78bfa', fillOpacity: 0.06),
        enableInteraction: false,
      );
      await c.addLineLayer(
        'beacon-borders',
        'beacon-border-line',
        const LineLayerProperties(
          lineColor: '#a78bfa',
          lineWidth: 1.5,
          lineOpacity: 0.65,
        ),
        enableInteraction: false,
      );
      await c.addGeoJsonSource('beacon-links', widget.lines);
      await c.addLineLayer(
        'beacon-links',
        'beacon-links',
        const LineLayerProperties(
          lineColor: [
            'case',
            ['has', 'color'],
            ['get', 'color'],
            ['has', 'obs'],
            [
              'interpolate',
              ['linear'],
              [
                'log10',
                [
                  'max',
                  1,
                  ['get', 'obs'],
                ],
              ],
              0,
              '#ef4444',
              1.301,
              '#eab308',
              2.176,
              '#22c55e',
            ],
            '#3b82f6',
          ],
          lineWidth: [
            'case',
            [
              '==',
              ['get', 'selected'],
              true,
            ],
            2,
            1.5,
          ],
          lineOpacity: [
            'case',
            ['has', 'ageDays'],
            [
              'interpolate',
              ['linear'],
              ['get', 'ageDays'],
              0,
              0.9,
              28,
              0.15,
            ],
            0.65,
          ],
        ),
        enableInteraction: false,
      );
      await c.addSource(
        'beacon-nodes',
        GeojsonSourceProperties(
          data: widget.points,
          cluster: widget.cluster,
          clusterRadius: 40,
          clusterMaxZoom: 20,
          maxzoom: 22,
        ),
      );
      for (var i = 0; i < 6; i++) {
        await c.addImage(
          'cluster-$i',
          await markerImage('cluster-$i', scale: imageScale),
        );
        if (!mounted || epoch != _epoch) return;
      }
      await c.addSymbolLayer(
        'beacon-nodes',
        'beacon-clusters',
        const SymbolLayerProperties(
          iconImage: [
            'step',
            ['get', 'point_count'],
            'cluster-0',
            5,
            'cluster-1',
            15,
            'cluster-2',
            25,
            'cluster-3',
            50,
            'cluster-4',
            100,
            'cluster-5',
          ],
          iconSize: 0.48,
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
        filter: ['has', 'point_count'],
      );
      await c.addSymbolLayer(
        'beacon-nodes',
        'beacon-cluster-count',
        const SymbolLayerProperties(
          textFont: ['Noto Sans Regular'],
          textField: [
            'to-string',
            ['get', 'point_count'],
          ],
          textSize: 11,
          textColor: '#fafafa',
          textAllowOverlap: true,
        ),
        filter: ['has', 'point_count'],
        enableInteraction: false,
      );
      await c.addCircleLayer(
        'beacon-nodes',
        'beacon-selected',
        const CircleLayerProperties(
          circleRadius: 12,
          circleColor: '#3b82f6',
          circleOpacity: 0.2,
          circleStrokeColor: '#3b82f6',
          circleStrokeWidth: 2,
        ),
        filter: [
          '==',
          ['get', 'id'],
          widget.selected ?? '',
        ],
        enableInteraction: false,
      );
      final markerStyle = widget.style == 'dark' ? 'glitch' : 'wireframe';
      for (final type in ['companion', 'repeater', 'room_server', 'sensor']) {
        for (final suffix in ['', '-observer']) {
          final key = '$markerStyle-$type$suffix';
          await c.addImage(
            'node-$type$suffix',
            await markerImage(key, scale: imageScale),
          );
          if (!mounted || epoch != _epoch) return;
        }
      }
      await c.addCircleLayer(
        'beacon-nodes',
        'beacon-path-points',
        const CircleLayerProperties(
          circleRadius: 5,
          circleColor: [
            'coalesce',
            ['get', 'color'],
            '#a1a1aa',
          ],
          circleStrokeColor: '#fafafa',
          circleStrokeWidth: 1,
        ),
        filter: [
          'all',
          [
            '!',
            ['has', 'point_count'],
          ],
          [
            '!',
            [
              'in',
              ['get', 'nodeTypeName'],
              [
                'literal',
                ['companion', 'repeater', 'room_server', 'sensor'],
              ],
            ],
          ],
        ],
      );
      await c.addSymbolLayer(
        'beacon-nodes',
        'beacon-points',
        const SymbolLayerProperties(
          iconImage: [
            'concat',
            'node-',
            ['get', 'nodeTypeName'],
            [
              'case',
              [
                '==',
                ['get', 'isObserver'],
                true,
              ],
              '-observer',
              '',
            ],
          ],
          iconSize: 0.41,
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
        filter: [
          'all',
          [
            '!',
            ['has', 'point_count'],
          ],
          [
            'in',
            ['get', 'nodeTypeName'],
            [
              'literal',
              ['companion', 'repeater', 'room_server', 'sensor'],
            ],
          ],
        ],
      );
      await c.addSymbolLayer(
        'beacon-nodes',
        'beacon-labels',
        const SymbolLayerProperties(
          textField: ['get', 'name'],
          textFont: ['Noto Sans Regular'],
          textSize: 11,
          textColor: '#fafafa',
          textHaloColor: '#09090b',
          textHaloWidth: 1.5,
          textOffset: [0, 1.4],
          textAnchor: 'top',
        ),
        minzoom: 12,
        filter: [
          '!',
          ['has', 'point_count'],
        ],
        enableInteraction: false,
      );
      await c.addGeoJsonSource('beacon-flow-trails', collection([]));
      await c.addLineLayer(
        'beacon-flow-trails',
        'beacon-flow-trails',
        const LineLayerProperties(
          lineColor: '#ff6b35',
          lineWidth: 2.5,
          lineDasharray: [2, 2],
          lineOpacity: ['get', 'a'],
        ),
        enableInteraction: false,
      );
      await c.addGeoJsonSource('beacon-flow-dots', collection([]));
      await c.addCircleLayer(
        'beacon-flow-dots',
        'beacon-flow-dots',
        const CircleLayerProperties(
          circleColor: '#ff6b35',
          circleRadius: 5,
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 1.1,
        ),
        enableInteraction: false,
      );
      if (!mounted || epoch != _epoch) return;
      _nodeGlow.clear();
      _ready = true;
      _update();
      if (_firstReady) {
        _firstReady = false;
        widget.onReady?.call();
      }
      if (widget.fitPoints) unawaited(fit(_locations()));
    } catch (e) {
      if (mounted && epoch == _epoch) {
        widget.onError?.call('Map initialization: $e');
      }
    }
  }

  List<Map<String, dynamic>> _locations() =>
      rows(widget.points['features']).expand((f) {
        final coords = object(f['geometry'])['coordinates'];
        return coords is List && coords.length >= 2
            ? [
                {'lng': coords[0], 'lat': coords[1]},
              ]
            : const <Map<String, dynamic>>[];
      }).toList();
  final _nodeGlow = <String, dynamic>{};
  bool _flowWriting = false;
  Map<String, dynamic>? _pendingFlow;
  Future<void> flow(Map<String, dynamic> data) async {
    final c = _controller;
    final epoch = _epoch;
    if (!_ready || c == null) return;
    if (_flowWriting) {
      _pendingFlow = data;
      return;
    }
    _flowWriting = true;
    try {
      final glow = widget.liveFlow ? object(data['glow']) : <String, dynamic>{};
      _nodeGlow
        ..clear()
        ..addAll(glow);
      await _applyNodeGlow(c);
      if (!mounted || epoch != _epoch) return;
      await c.setGeoJsonSource('beacon-flow-trails', object(data['trails']));
      if (!mounted || epoch != _epoch) return;
      await c.setGeoJsonSource('beacon-flow-dots', object(data['dots']));
    } catch (e) {
      if (mounted && epoch == _epoch) widget.onError?.call('Packet flow: $e');
    } finally {
      _flowWriting = false;
      final pending = _pendingFlow;
      _pendingFlow = null;
      if (pending != null && mounted && epoch == _epoch) {
        await flow(pending);
      }
    }
  }

  Future<void> fit(List<Map<String, dynamic>> items) async {
    final c = _controller;
    if (!_ready || c == null) return;
    final ns = items.where(hasLocation).toList();
    if (ns.isEmpty) return;
    try {
      if (ns.length == 1) {
        await c.animateCamera(
          CameraUpdate.newLatLngZoom(
            LatLng(number(ns.first['lat'])!, number(ns.first['lng'])!),
            9,
          ),
        );
        return;
      }
      final lats = ns.map((n) => number(n['lat'])!).toList(),
          lngs = ns.map((n) => number(n['lng'])!).toList();
      await c.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(lats.reduce(math.min), lngs.reduce(math.min)),
            northeast: LatLng(lats.reduce(math.max), lngs.reduce(math.max)),
          ),
          left: 48,
          right: 48,
          top: 90,
          bottom: 70,
        ),
      );
    } catch (e) {
      if (mounted) widget.onError?.call('Map camera: $e');
    }
  }

  Future<void> _tap(math.Point<double> point, LatLng location) async {
    final c = _controller;
    final epoch = _epoch;
    if (c == null || !_ready) return;
    try {
      final hits = await c.queryRenderedFeatures(point, [
        'beacon-points',
        'beacon-path-points',
        'beacon-clusters',
      ], null);
      if (!mounted || epoch != _epoch || hits.isEmpty) return;
      final props = object(object(hits.first)['properties']);
      if (props['cluster_id'] is num) {
        final id = (props['cluster_id'] as num).toInt();
        final zoom = await c.getClusterExpansionZoom('beacon-nodes', id);
        if (!mounted || epoch != _epoch) return;
        if (zoom >= 19) {
          final leaves = await c.getClusterLeaves(
            'beacon-nodes',
            id,
            limit: (number(props['point_count']) ?? 100).toInt(),
            offset: 0,
          );
          if (!mounted || epoch != _epoch) return;
          await showModalBottomSheet<void>(
            context: context,
            builder: (context) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: leaves.map((f) {
                  final p = object(f['properties']);
                  return ListTile(
                    title: Text(textOf(p['name'], textOf(p['id']))),
                    onTap: () {
                      Navigator.pop(context);
                      widget.onNode(textOf(p['id']));
                    },
                  );
                }).toList(),
              ),
            ),
          );
        } else {
          await c.animateCamera(
            CameraUpdate.newLatLngZoom(location, zoom.toDouble() + 0.5),
          );
        }
      } else if (props['id'] != null) {
        widget.onNode(textOf(props['id']));
      }
    } catch (e) {
      if (mounted && epoch == _epoch) widget.onError?.call('Map selection: $e');
    }
  }

  Future<void> _idle() async {
    final c = _controller;
    final epoch = _epoch;
    if (!_ready || c == null || !mounted) return;
    try {
      final size = context.size;
      if (size == null) return;
      final hits = await c.queryRenderedFeaturesInRect(
        nativeViewport(
          size,
          Theme.of(context).platform,
          MediaQuery.devicePixelRatioOf(context),
        ),
        ['beacon-points', 'beacon-path-points', 'beacon-clusters'],
        null,
      );
      if (!mounted || epoch != _epoch) return;
      var count = 0;
      for (final h in hits) {
        final p = object(object(h)['properties']);
        count += (number(p['point_count']) ?? 1).toInt();
      }
      widget.onVisibleCount?.call(count);
    } catch (e) {
      if (mounted && epoch == _epoch) widget.onError?.call('Map rendering: $e');
    }
  }

  @override
  Widget build(BuildContext context) => MapLibreMap(
    key: ValueKey(_identity),
    styleString:
        'https://tiles.openfreemap.org/styles/${['dark', 'liberty', 'positron'].contains(widget.style) ? widget.style : 'dark'}',
    initialCameraPosition: _camera,
    onCameraMove: (camera) => _camera = camera,
    onMapCreated: (c) => _controller = c,
    onStyleLoadedCallback: _styleLoaded,
    onMapClick: _tap,
    onMapIdle: _idle,
    onCameraIdle: _idle,
    featureTapsTriggersMapClick: true,
    compassEnabled: true,
    trackCameraPosition: true,
    attributionButtonPosition: AttributionButtonPosition.bottomRight,
  );
  @override
  void dispose() {
    _epoch++;
    _ready = false;
    _controller = null;
    super.dispose();
  }
}
