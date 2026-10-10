import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'charts.dart';
import 'transforms.dart';

// Run bounded force relaxation off the UI isolate; sample repulsion at large N.
List<List<double>> networkPositions(List<Map<String, dynamic>> nodes) {
  final n = nodes.length, edges = graphEdges(nodes);
  final p = List.generate(n, (i) {
    final a = i * 2.3999632297, r = math.sqrt(i / math.max(1, n - 1)) * 300;
    return [360 + math.cos(a) * r, 360 + math.sin(a) * r];
  });
  final stride = math.max(1, n ~/ 40);
  for (var step = 0; step < 100; step++) {
    final force = List.generate(n, (_) => [0.0, 0.0]);
    for (var i = 0; i < n; i++) {
      for (var j = step % stride; j < n; j += stride) {
        if (i == j) continue;
        final dx = p[i][0] - p[j][0],
            dy = p[i][1] - p[j][1],
            dist = math.max(16.0, dx * dx + dy * dy),
            strength = 550 * stride / dist;
        force[i][0] += dx * strength / math.sqrt(dist);
        force[i][1] += dy * strength / math.sqrt(dist);
      }
      force[i][0] += (360 - p[i][0]) * .004;
      force[i][1] += (360 - p[i][1]) * .004;
    }
    for (final edge in edges) {
      final a = edge.$1,
          b = edge.$2,
          dx = p[b][0] - p[a][0],
          dy = p[b][1] - p[a][1],
          distance = math.sqrt(dx * dx + dy * dy),
          strength = (distance - 55) * .012 / math.max(1, distance);
      force[a][0] += dx * strength;
      force[a][1] += dy * strength;
      force[b][0] -= dx * strength;
      force[b][1] -= dy * strength;
    }
    final cooling = 1 - step / 120;
    for (var i = 0; i < n; i++) {
      p[i][0] = (p[i][0] + force[i][0].clamp(-7, 7) * cooling).clamp(35, 685);
      p[i][1] = (p[i][1] + force[i][1].clamp(-7, 7) * cooling).clamp(35, 685);
    }
  }
  return p;
}

class NetworkCanvas extends StatefulWidget {
  const NetworkCanvas({
    super.key,
    required this.nodes,
    required this.search,
    required this.onSelect,
    this.ego = false,
    this.onClear,
  });
  final List<Map<String, dynamic>> nodes;
  final String search;
  final bool ego;
  final void Function(Map<String, dynamic>) onSelect;
  final VoidCallback? onClear;
  @override
  State<NetworkCanvas> createState() => _NetworkCanvasState();
}

class _NetworkCanvasState extends State<NetworkCanvas> {
  late Future<List<List<double>>> positions;
  final dragged = <String, Offset>{};
  Offset dragOrigin = Offset.zero;
  final transform = TransformationController(
    Matrix4.diagonal3Values(.5, .5, 1),
  );
  @override
  void initState() {
    super.initState();
    layout();
  }

  void layout() {
    dragged.clear();
    positions = widget.ego
        ? Future.value(
            List.generate(widget.nodes.length, (i) {
              if (i == 0) return [360.0, 360.0];
              final angle =
                  (i - 1) * math.pi * 2 / math.max(1, widget.nodes.length - 1);
              return [360 + math.cos(angle) * 240, 360 + math.sin(angle) * 240];
            }),
          )
        : compute(networkPositions, widget.nodes);
  }

  @override
  void didUpdateWidget(covariant NetworkCanvas old) {
    super.didUpdateWidget(old);
    if (old.nodes.map((e) => e['id']).join('|') !=
            widget.nodes.map((e) => e['id']).join('|') ||
        old.ego != widget.ego) {
      layout();
      transform.value = Matrix4.diagonal3Values(.5, .5, 1);
    }
  }

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<List<double>>>(
    future: positions,
    builder: (context, s) {
      if (s.connectionState != ConnectionState.done || !s.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final p = List.generate(
        s.data!.length,
        (i) =>
            dragged[textOf(widget.nodes[i]['id'])] ??
            Offset(s.data![i][0], s.data![i][1]),
      );
      final maxDegree = widget.nodes.fold<double>(
        1,
        (v, n) => math.max(v, number(n['knownNeighborCount']) ?? 0),
      );
      return Stack(
        children: [
          GraphViewport(
            controller: transform,
            child: GestureDetector(
              onTap: widget.onClear,
              child: SizedBox(
                width: 720,
                height: 720,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _NetworkEdges(
                          p,
                          graphEdges(widget.nodes),
                          widget.nodes,
                          widget.ego,
                          BeaconColors.of(context).borderSubtle,
                          BeaconColors.of(context).danger,
                          BeaconColors.of(context).warning,
                          BeaconColors.of(context).success,
                        ),
                      ),
                    ),
                    for (var i = 0; i < widget.nodes.length; i++)
                      Positioned(
                        left: p[i].dx - 10,
                        top: p[i].dy - 10,
                        child: Tooltip(
                          message:
                              '${textOf(widget.nodes[i]['name'], textOf(widget.nodes[i]['id']))}\n${textOf(widget.nodes[i]['nodeTypeName'])}${widget.ego && i > 0 ? ' · ${countLabel(number(widget.nodes[i]['observationCount']))} obs · ${age(widget.nodes[i]['lastSeen'])}' : ''}',
                          child: GestureDetector(
                            onTap: () => widget.onSelect(widget.nodes[i]),
                            onLongPressStart: (_) => dragOrigin = p[i],
                            onLongPressMoveUpdate: (details) => setState(
                              () => dragged[textOf(widget.nodes[i]['id'])] =
                                  dragOrigin + details.localOffsetFromOrigin,
                            ),
                            child: Column(
                              children: [
                                Container(
                                  width: widget.ego
                                      ? (i == 0 ? 30 : 16)
                                      : 8 +
                                            26 *
                                                math.sqrt(
                                                  (number(
                                                            widget
                                                                .nodes[i]['knownNeighborCount'],
                                                          ) ??
                                                          0) /
                                                      maxDegree,
                                                ),
                                  height: widget.ego
                                      ? (i == 0 ? 30 : 16)
                                      : 8 +
                                            26 *
                                                math.sqrt(
                                                  (number(
                                                            widget
                                                                .nodes[i]['knownNeighborCount'],
                                                          ) ??
                                                          0) /
                                                      maxDegree,
                                                ),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color:
                                        widget.search.isNotEmpty &&
                                            !textOf(widget.nodes[i]['name'])
                                                .toLowerCase()
                                                .contains(
                                                  widget.search.toLowerCase(),
                                                )
                                        ? BeaconColors.of(context).borderSubtle
                                        : analyticsNodeColor(
                                            textOf(
                                              widget.nodes[i]['nodeTypeName'],
                                            ),
                                            context,
                                          ),
                                    border: Border.all(
                                      color: BeaconColors.of(context).surface,
                                      width: 1,
                                    ),
                                  ),
                                ),
                                if (widget.ego || i < 30)
                                  Text(
                                    textOf(
                                      widget.nodes[i]['name'],
                                      textOf(widget.nodes[i]['id']).substring(
                                        0,
                                        math.min(
                                          6,
                                          textOf(widget.nodes[i]['id']).length,
                                        ),
                                      ),
                                    ),
                                    style: TextStyle(
                                      fontSize: widget.ego ? 10 : 8,
                                      fontFamily: 'JetBrainsMono',
                                      color: BeaconColors.of(context).bright,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: IconButton.filledTonal(
              tooltip: tr('Reset zoom'),
              onPressed: () =>
                  transform.value = Matrix4.diagonal3Values(.5, .5, 1),
              icon: const Icon(Icons.center_focus_strong, size: 19),
            ),
          ),
        ],
      );
    },
  );
}

/// A full-viewport gesture target, including the space outside the graph.
class GraphViewport extends StatefulWidget {
  const GraphViewport({
    super.key,
    required this.controller,
    required this.child,
  });
  final TransformationController controller;
  final Widget child;

  @override
  State<GraphViewport> createState() => _GraphViewportState();
}

class _GraphViewportState extends State<GraphViewport> {
  Matrix4 start = Matrix4.identity();
  Offset focal = Offset.zero;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onScaleStart: (details) {
      start = widget.controller.value.clone();
      focal = details.localFocalPoint;
    },
    onScaleUpdate: (details) {
      final oldScale = start.getMaxScaleOnAxis();
      final ratio = (oldScale * details.scale).clamp(.25, 5.0) / oldScale;
      widget.controller.value = Matrix4.identity()
        ..translateByDouble(
          details.localFocalPoint.dx,
          details.localFocalPoint.dy,
          0,
          1,
        )
        ..rotateZ(details.rotation)
        ..scaleByDouble(ratio, ratio, 1, 1)
        ..translateByDouble(-focal.dx, -focal.dy, 0, 1)
        ..multiply(start);
    },
    child: ClipRect(
      child: SizedBox.expand(
        child: ValueListenableBuilder<Matrix4>(
          valueListenable: widget.controller,
          builder: (context, matrix, child) => Transform(
            alignment: Alignment.topLeft,
            transform: matrix,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: 720,
              maxWidth: 720,
              minHeight: 720,
              maxHeight: 720,
              child: child,
            ),
          ),
          child: widget.child,
        ),
      ),
    ),
  );
}

class _NetworkEdges extends CustomPainter {
  _NetworkEdges(
    this.positions,
    this.edges,
    this.nodes,
    this.ego,
    this.color,
    this.danger,
    this.warning,
    this.success,
  );
  final List<Offset> positions;
  final List<(int, int)> edges;
  final List<Map<String, dynamic>> nodes;
  final bool ego;
  final Color color;
  final Color danger, warning, success;
  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in edges) {
      var c = color;
      var width = .8;
      if (ego) {
        final node = nodes[edge.$1 == 0 ? edge.$2 : edge.$1],
            obs = number(node['observationCount']) ?? 0,
            age =
                (DateTime.now().millisecondsSinceEpoch -
                    (number(node['lastSeen']) ?? 0)) /
                86400000;
        final x = math.log(math.max(1, obs)) / math.ln10;
        c = x <= 1.3
            ? Color.lerp(danger, warning, (x / 1.3).clamp(0, 1))!
            : Color.lerp(warning, success, ((x - 1.3) / .88).clamp(0, 1))!;
        c = c.withValues(alpha: .9 + (.35 - .9) * (age / 28).clamp(0, 1));
        width = 1.5;
      }
      canvas.drawLine(
        positions[edge.$1] + const Offset(3, 3),
        positions[edge.$2] + const Offset(3, 3),
        Paint()
          ..color = c
          ..strokeWidth = width,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NetworkEdges old) =>
      old.positions != positions ||
      old.color != color ||
      old.danger != danger ||
      old.warning != warning ||
      old.success != success ||
      old.nodes != nodes;
}
