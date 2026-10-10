import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'charts.dart';
import 'network_canvas.dart';
import 'transforms.dart';

class NeighbourGraph extends StatefulWidget {
  const NeighbourGraph({
    super.key,
    required this.api,
    required this.region,
    required this.onOpen,
  });
  final ApiClient api;
  final Map<String, dynamic> region;
  final void Function(String, String) onOpen;
  @override
  State<NeighbourGraph> createState() => _NeighbourGraphState();
}

class _NeighbourGraphState extends State<NeighbourGraph>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>>? nodes;
  Object? error;
  int generation = 0;
  int totalNodes = 0;
  String search = '';
  Map<String, dynamic>? selected;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) load();
  }

  @override
  void didUpdateWidget(covariant NeighbourGraph old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api ||
        old.region.toString() != widget.region.toString()) {
      selected = null;
      load();
    }
  }

  Future<void> load() async {
    final token = ++generation;
    if (mounted && (nodes != null || error != null)) {
      setState(() {
        nodes = null;
        error = null;
      });
    } else {
      nodes = null;
      error = null;
    }
    if (widget.region.isEmpty || widget.region.containsKey('region')) {
      setState(() => nodes = []);
      return;
    }
    try {
      final found = <String, Map<String, dynamic>>{};
      dynamic cursor;
      final cursors = <String>{};
      do {
        final response = await widget.api.getCached('/nodes', {
          ...widget.region,
          'neighbors': 'true',
          'limit': 500,
          'cursor': ?cursor,
        });
        if (!mounted || token != generation) return;
        for (final n in rows(response)) {
          found[textOf(n['id'])] = n;
        }
        final o = object(response);
        if (o['hasMore'] == false) break;
        cursor = o['nextCursor'];
        if (cursor == null || !cursors.add('$cursor')) break;
      } while (true);
      final ranked = found.values.toList()
        ..sort((a, b) {
          final c = (number(b['knownNeighborCount']) ?? 0).compareTo(
            number(a['knownNeighborCount']) ?? 0,
          );
          return c == 0 ? textOf(a['id']).compareTo(textOf(b['id'])) : c;
        });
      if (mounted && token == generation) {
        setState(() {
          nodes = ranked.take(1000).toList();
          totalNodes = ranked.length;
        });
      }
    } catch (e) {
      if (mounted && token == generation) setState(() => error = e);
    }
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget graph(List<Map<String, dynamic>> data) => NetworkCanvas(
    nodes: data,
    search: search,
    ego: selected != null,
    onSelect: (node) => setState(() => selected = node),
    onClear: () => setState(() => selected = null),
  );
  @override
  Widget build(BuildContext context) {
    if (widget.region.isEmpty || widget.region.containsKey('region')) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(tr('Choose a region to view the neighbour graph.')),
        ),
      );
    }
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr('Unable to load graph: {{error}}')
                  .replaceAll('{{error}}', tr('$error')),
              style: TextStyle(color: BeaconColors.of(context).danger),
            ),
            TextButton(
              onPressed: () {
                setState(() {});
                load();
              },
              child: Text(tr('Retry')),
            ),
          ],
        ),
      );
    }
    if (nodes == null) return const Center(child: CircularProgressIndicator());
    if (nodes!.isEmpty) {
      return Center(child: Text(tr('No nodes in this region.')));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text(
                nodes!.length < totalNodes
                    ? '${nodes!.length} / $totalNodes ${tr('Nodes')}'
                    : '${nodes!.length} ${tr('Nodes')}',
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  color: BeaconColors.of(context).muted,
                ),
              ),
              IconButton(
                tooltip: tr('Refresh graph'),
                onPressed: () {
                  widget.api.invalidateCache(prefix: '/nodes');
                  load();
                },
                icon: const Icon(Icons.refresh, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: tr('Find node'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                  ),
                  onChanged: (s) => setState(() => search = s),
                ),
              ),
            ],
          ),
        ),
        if (selected != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                IconButton(
                  tooltip: tr('Full mesh'),
                  onPressed: () => setState(() => selected = null),
                  icon: const Icon(Icons.close),
                ),
                Expanded(
                  child: Text(
                    textOf(selected!['name'], textOf(selected!['id'])),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      widget.onOpen('node', textOf(selected!['id'])),
                  child: Text(tr('Details')),
                ),
              ],
            ),
          ),
        Expanded(
          child: selected == null
              ? graph(nodes!)
              : StatsQuery(
                  api: widget.api,
                  path:
                      '/nodes/${Uri.encodeComponent(textOf(selected!['id']))}/neighbors',
                  builder: (d) {
                    final folded = foldNeighbours(
                      textOf(selected!['id']),
                      rows(d),
                    );
                    final neighbours = {
                      for (final n in folded) textOf(n['id']): n,
                    };
                    return graph([
                      {...selected!, 'neighborIds': neighbours.keys.toList()},
                      ...neighbours.values,
                    ]);
                  },
                ),
        ),
      ],
    );
  }
}
