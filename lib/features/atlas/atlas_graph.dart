import 'package:flutter/material.dart';

import '../../core/sheet.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../analytics/charts.dart';
import '../analytics/transforms.dart';
import 'atlas.dart';
import 'atlas_widgets.dart';

/// An hourly series against the time each slot starts; an unread hour stays a gap.
List<ChartPoint> slotPoints(List<double?> values, HourSlots slots) => [
  for (final (i, value) in values.indexed)
    ChartPoint(slots.start(i).toDouble(), value),
];

/// Readings against their own times. Two more than a bucket and a half apart
/// get a gap between them, so the line does not bridge an outage.
List<ChartPoint> readingPoints(
  List<int> times,
  List<double> values,
  int bucketMs,
) => [
  for (final (i, t) in times.indexed) ...[
    ChartPoint(t.toDouble(), values[i]),
    if (i + 1 < times.length && times[i + 1] - t > bucketMs * 1.5)
      ChartPoint((t + bucketMs).toDouble(), null),
  ],
];

/// What a tile hands its graph: the points and how the tile writes a value.
class AtlasGraph {
  const AtlasGraph(this.points, this.format);
  final List<ChartPoint> points;
  final String Function(double value) format;
  bool get isEmpty => !points.any((p) => p.y != null);
}

/// One tile's metric drawn large, over the Atlas range ending at [now].
Future<void> showAtlasGraph(
  BuildContext context, {
  required String name,
  required String metric,
  required AtlasRange range,
  required int now,
  required AtlasGraph graph,
  required Color color,
}) => showBeaconSheet<void>(
  context,
  builder: (context) {
    final c = BeaconColors.of(context);
    return BeaconSheet(
      maxHeight: .85,
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$name · $metric',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: c.bright,
            ),
          ),
          Text(
            '${atlasRangeLabel(range)} · ${trKey('atlasGraph.hint')}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: atlasMono(10, c.muted),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, box) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, BeaconSheet.gutter, 12),
          child: TimeChart(
            key: const ValueKey('atlas-graph'),
            series: {metric: graph.points},
            // What is left under the header, less the chart's own top gap.
            height: (box.maxHeight - 24).clamp(80, 340),
            colors: [color],
            format: graph.format,
            minX: (now - range.hours * hourMs).toDouble(),
            maxX: now.toDouble(),
            showSingleSeriesToggle: false,
            showDots: true,
            zoom: true,
          ),
        ),
      ),
    );
  },
);
