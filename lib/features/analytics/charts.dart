import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'transforms.dart';

List<Color> analyticsChartColors(BuildContext context) {
  final c = BeaconColors.of(context);
  Color blend(Color a, Color b) => Color.lerp(a, b, .5)!;
  return [
    c.primary,
    c.success,
    c.secondary,
    c.warning,
    c.danger,
    c.primary.withValues(alpha: .68),
    blend(c.primary, c.secondary),
    blend(c.success, c.warning),
  ];
}

Color analyticsNodeColor(String type, BuildContext context) {
  final c = BeaconColors.of(context);
  return switch (type.toLowerCase().replaceAll(' ', '_')) {
    'companion' => c.primary,
    'repeater' => c.success,
    'room_server' => c.secondary,
    'sensor' => c.warning,
    _ => c.primary.withValues(alpha: .4),
  };
}

Color _seriesColor(BuildContext context, int index) {
  final colors = analyticsChartColors(context);
  return colors[index % colors.length];
}

String countLabel(num? n) => n == null
    ? 'Unavailable'
    : n.abs() >= 1000000
    ? '${(n / 1000000).toStringAsFixed(1)}m'
    : n.abs() >= 1000
    ? '${(n / 1000).toStringAsFixed(1)}k'
    : n == n.roundToDouble()
    ? '${n.toInt()}'
    : n.toStringAsFixed(1);

class AnalyticsEmptyState extends StatelessWidget {
  const AnalyticsEmptyState({
    super.key,
    this.label = 'No observations in this window.',
  });
  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      tr(label),
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 11,
        color: BeaconColors.of(context).dim,
      ),
    ),
  );
}

class AnalyticsCard extends StatelessWidget {
  const AnalyticsCard({super.key, required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: BeaconColors.of(context).surface,
      border: Border.all(color: BeaconColors.of(context).border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr(title).toUpperCase(),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontWeight: FontWeight.w600,
              fontSize: 11,
              letterSpacing: .6,
              color: BeaconColors.of(context).muted,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

class StatsQuery extends StatefulWidget {
  const StatsQuery({
    super.key,
    required this.api,
    required this.path,
    this.params = const {},
    required this.builder,
    this.pollInterval,
    this.fallback,
  });
  final ApiClient api;
  final String path;
  final Map<String, dynamic> params;
  final Widget Function(dynamic) builder;
  final Duration? pollInterval;

  /// Shown instead of the spinner and error, for content that stays useful
  /// without this query.
  final WidgetBuilder? fallback;
  @override
  State<StatsQuery> createState() => _StatsQueryState();
}

class _StatsQueryState extends State<StatsQuery> {
  late Future<dynamic> future;
  Timer? timer;
  int generation = 0;
  int? lastStatus;
  @override
  void initState() {
    super.initState();
    load();
    if (widget.pollInterval != null) {
      timer = Timer.periodic(widget.pollInterval!, (_) {
        if (mounted &&
            lastStatus != 404 &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
          setState(() => load(fresh: true));
        }
      });
    }
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    super.dispose();
  }

  void load({bool fresh = false}) {
    final token = ++generation;
    future =
        (fresh ? widget.api.get : widget.api.getCached)(
          widget.path,
          widget.params,
          () => mounted && token == generation,
        ).then(
          (value) {
            if (token == generation) lastStatus = null;
            return value;
          },
          onError: (Object error) {
            if (token == generation) {
              lastStatus = error is ApiException ? error.status : null;
            }
            throw error;
          },
        );
  }

  @override
  void didUpdateWidget(covariant StatsQuery old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api ||
        old.path != widget.path ||
        old.params.toString() != widget.params.toString()) {
      load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<dynamic>(
    future: future,
    builder: (context, s) {
      if (s.connectionState != ConnectionState.done) {
        final cached = widget.api.peekCache(widget.path, widget.params);
        if (cached != null) return widget.builder(cached);
        if (widget.fallback case final fallback?) return fallback(context);
        return const Padding(
          padding: EdgeInsets.all(30),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      }
      if (s.hasError) {
        if (widget.fallback case final fallback?) return fallback(context);
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(
                'Data unavailable: ${s.error}',
                style: TextStyle(color: BeaconColors.of(context).danger),
              ),
              TextButton.icon(
                onPressed: () => setState(load),
                icon: const Icon(Icons.refresh),
                label: Text(tr('Retry')),
              ),
            ],
          ),
        );
      }
      return widget.builder(s.data);
    },
  );
}

class TimeChart extends StatefulWidget {
  const TimeChart({
    super.key,
    required this.series,
    this.unit = '',
    this.timeAxis = true,
    this.stacked = false,
    this.showSingleSeriesToggle = true,
  });
  final Map<String, List<ChartPoint>> series;
  final String unit;
  final bool timeAxis;
  final bool stacked;
  final bool showSingleSeriesToggle;
  @override
  State<TimeChart> createState() => _TimeChartState();
}

class _TimeChartState extends State<TimeChart> {
  final hidden = <String>{};
  @override
  Widget build(BuildContext context) {
    final entries = widget.series.entries.toList();
    final all = entries
        .expand((e) => e.value)
        .where((p) => p.y != null)
        .toList();
    if (all.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: AnalyticsEmptyState(),
      );
    }
    final active = entries.where((e) => !hidden.contains(e.key)).toList();
    final xValues = all.map((point) => point.x).toList();
    final xSpan = xValues.isEmpty
        ? 0.0
        : xValues.reduce((a, b) => a > b ? a : b) -
              xValues.reduce((a, b) => a < b ? a : b);
    const tickSteps = [
      1000.0,
      5000.0,
      15000.0,
      30000.0,
      60000.0,
      300000.0,
      900000.0,
      1800000.0,
      3600000.0,
      7200000.0,
      10800000.0,
      14400000.0,
      21600000.0,
      43200000.0,
      86400000.0,
      172800000.0,
      259200000.0,
      432000000.0,
      604800000.0,
      1209600000.0,
      2592000000.0,
      7776000000.0,
      31536000000.0,
    ];
    final timeTickInterval = tickSteps.firstWhere(
      (step) => step >= xSpan / 4,
      // A fixed yearly step would mean millions of ticks for a hostile span.
      orElse: () => xSpan / 4,
    );
    final cumulative = <double, double>{};
    final plotted = [
      for (final entry in active)
        [
          for (final point in entry.value)
            if (point.y == null)
              FlSpot.nullSpot
            else
              FlSpot(
                point.x,
                widget.stacked
                    ? (cumulative[point.x] =
                          (cumulative[point.x] ?? 0) + point.y!)
                    : point.y!,
              ),
        ],
    ];
    return Column(
      children: [
        if (entries.length > 1 || widget.showSingleSeriesToggle)
          Wrap(
            spacing: 8,
            children: [
              for (var i = 0; i < entries.length; i++)
                FilterChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    tr(entries[i].key),
                    style: TextStyle(
                      fontSize: 10,
                      color: _seriesColor(context, i),
                    ),
                  ),
                  selected: !hidden.contains(entries[i].key),
                  onSelected: (v) => setState(
                    () => v
                        ? hidden.remove(entries[i].key)
                        : hidden.add(entries[i].key),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: LineChart(
            LineChartData(
              lineBarsData: [
                for (var i = 0; i < active.length; i++)
                  LineChartBarData(
                    spots: plotted[i],
                    color: _seriesColor(context, entries.indexOf(active[i])),
                    barWidth: 1.7,
                    isCurved: false,
                    dotData: FlDotData(show: all.length <= 2),
                    belowBarData: BarAreaData(
                      show: active.length == 1 || (widget.stacked && i == 0),
                      color: _seriesColor(
                        context,
                        entries.indexOf(active[i]),
                      ).withValues(alpha: widget.stacked ? .4 : .13),
                    ),
                  ),
              ],
              betweenBarsData: widget.stacked
                  ? [
                      for (var i = 1; i < active.length; i++)
                        BetweenBarsData(
                          fromIndex: i - 1,
                          toIndex: i,
                          color: _seriesColor(
                            context,
                            entries.indexOf(active[i]),
                          ).withValues(alpha: .4),
                        ),
                    ]
                  : [],
              borderData: FlBorderData(show: false),
              gridData: FlGridData(
                drawVerticalLine: false,
                getDrawingHorizontalLine: (v) => FlLine(
                  color: BeaconColors.of(context).borderSubtle,
                  strokeWidth: .5,
                ),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 42,
                    minIncluded: false,
                    maxIncluded: false,
                    getTitlesWidget: (v, m) => Text(
                      countLabel(v),
                      style: TextStyle(
                        fontSize: 9,
                        color: BeaconColors.of(context).dim,
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 30,
                    interval: widget.timeAxis ? timeTickInterval : null,
                    minIncluded: !widget.timeAxis,
                    maxIncluded: !widget.timeAxis,
                    getTitlesWidget: (v, m) {
                      final d = epoch(v, isUtc: true);
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          widget.timeAxis && d == null
                              ? ''
                              : d != null && widget.timeAxis
                              ? xSpan < 120000
                                    ? '${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}'
                                    : xSpan <= 2 * 3600000
                                    ? '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'
                                    : xSpan <= 36 * 3600000
                                    ? '${d.hour.toString().padLeft(2, '0')}h'
                                    : '${d.month}/${d.day}'
                              : countLabel(v),
                          style: TextStyle(
                            fontSize: 8,
                            color: BeaconColors.of(context).dim,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => spots.map((s) {
                    final d = epoch(s.x, isUtc: true);
                    return LineTooltipItem(
                      '${widget.timeAxis && d != null ? '${d.toIso8601String().substring(5, 16)} UTC\n' : ''}${tr(active[s.barIndex].key)}: ${countLabel(widget.stacked ? active[s.barIndex].value.firstWhere((p) => p.x == s.x).y : s.y)}${widget.unit}',
                      TextStyle(
                        fontSize: 11,
                        color: BeaconColors.of(context).bright,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class RankedBars extends StatefulWidget {
  const RankedBars({
    super.key,
    required this.labels,
    required this.values,
    this.onTap,
    this.unit = '',
    this.pageSize,
  });
  final List<String> labels;
  final List<double?> values;
  final void Function(int)? onTap;
  final String unit;

  /// When set, shows this many rows at first and reveals the same number
  /// more each time "Show more" is tapped.
  final int? pageSize;
  @override
  State<RankedBars> createState() => _RankedBarsState();
}

class _RankedBarsState extends State<RankedBars> {
  late int shown = widget.pageSize ?? widget.labels.length;
  @override
  Widget build(BuildContext context) {
    final labels = widget.labels, values = widget.values, onTap = widget.onTap;
    final count = widget.pageSize == null
        ? labels.length
        : shown.clamp(0, labels.length);
    if (labels.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: AnalyticsEmptyState(),
      );
    }
    final max = values.whereType<double>().fold<double>(
      0,
      (a, b) => a > b.abs() ? a : b.abs(),
    );
    return Column(
      children: [
        for (var i = 0; i < count; i++)
          InkWell(
            onTap: onTap == null ? null : () => onTap(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          labels[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${countLabel(values[i])}${widget.unit}',
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 11,
                        ),
                      ),
                      if (onTap != null)
                        const Icon(Icons.chevron_right, size: 15),
                    ],
                  ),
                  const SizedBox(height: 5),
                  LinearProgressIndicator(
                    value: values[i] == null
                        ? 0
                        : max == 0
                        ? 0
                        : values[i]!.abs() / max,
                    minHeight: 5,
                    color: _seriesColor(context, i),
                    backgroundColor: BeaconColors.of(context).raised,
                  ),
                ],
              ),
            ),
          ),
        if (count < labels.length)
          TextButton(
            onPressed: () => setState(() => shown = count + widget.pageSize!),
            child: Text(
              '${tr('Show more')} (${labels.length - count})',
              style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11),
            ),
          ),
      ],
    );
  }
}

class DonutChart extends StatefulWidget {
  const DonutChart({
    super.key,
    required this.labels,
    required this.values,
    this.center = '',
    this.colors,
  });
  final List<String> labels;
  final List<double?> values;
  final String center;
  final List<Color>? colors;
  @override
  State<DonutChart> createState() => _DonutChartState();
}

class _DonutChartState extends State<DonutChart> {
  int? selected;
  @override
  Widget build(BuildContext context) {
    final total = widget.values.fold<double>(0, (sum, v) => sum + (v ?? 0));
    if (total <= 0) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: AnalyticsEmptyState(),
      );
    }
    return Column(
      children: [
        SizedBox(
          height: 205,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(
                PieChartData(
                  centerSpaceRadius: 61,
                  sectionsSpace: 2,
                  pieTouchData: PieTouchData(
                    touchCallback: (event, response) {
                      if (!event.isInterestedForInteractions) return;
                      setState(
                        () => selected =
                            response?.touchedSection?.touchedSectionIndex,
                      );
                    },
                  ),
                  sections: [
                    for (var i = 0; i < widget.labels.length; i++)
                      PieChartSectionData(
                        value: widget.values[i] ?? 0,
                        color: widget.colors?[i] ?? _seriesColor(context, i),
                        radius: selected == i ? 36 : 28,
                        showTitle: selected == i,
                        title:
                            '${((widget.values[i] ?? 0) / total * 100).toStringAsFixed(1)}%',
                        titleStyle: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    countLabel(
                      selected != null &&
                              selected! >= 0 &&
                              selected! < widget.values.length
                          ? widget.values[selected!]
                          : total,
                    ),
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 22,
                    ),
                  ),
                  Text(tr(widget.center), style: const TextStyle(fontSize: 9)),
                ],
              ),
            ],
          ),
        ),
        for (var i = 0; i < widget.labels.length; i++)
          InkWell(
            onTap: () => setState(() => selected = selected == i ? null : i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    color: widget.colors?[i] ?? _seriesColor(context, i),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.labels[i],
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  Text(
                    '${countLabel(widget.values[i])} · ${((widget.values[i] ?? 0) / total * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class DistributionChart extends StatelessWidget {
  const DistributionChart({
    super.key,
    required this.labels,
    required this.values,
    this.unit = '',
  });
  final List<String> labels;
  final List<double?> values;
  final String unit;
  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty || !values.any((v) => v != null && v > 0)) {
      return const AnalyticsEmptyState();
    }
    return SizedBox(
      height: 245,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          barGroups: [
            for (var i = 0; i < labels.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: values[i] ?? 0,
                    color: _seriesColor(context, i),
                    width: (260 / labels.length).clamp(3, 22),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(2),
                    ),
                  ),
                ],
              ),
          ],
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (v) => FlLine(
              color: BeaconColors.of(context).borderSubtle,
              strokeWidth: .5,
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 37,
                getTitlesWidget: (v, m) =>
                    Text(countLabel(v), style: const TextStyle(fontSize: 9)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 60,
                getTitlesWidget: (v, m) {
                  final i = v.toInt();
                  if (i < 0 ||
                      i >= labels.length ||
                      labels.length > 20 && i % 3 != 0) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: RotatedBox(
                      quarterTurns: 1,
                      child: Text(
                        labels[i],
                        style: const TextStyle(fontSize: 8),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                  BarTooltipItem(
                    '${labels[group.x]}$unit\n${countLabel(rod.toY)}',
                    TextStyle(
                      color: BeaconColors.of(context).bright,
                      fontSize: 11,
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

class StackedRows extends StatelessWidget {
  const StackedRows({super.key, required this.labels, required this.series});
  final List<String> labels;
  final Map<String, List<double?>> series;
  @override
  Widget build(BuildContext context) {
    final totals = List.generate(
      labels.length,
      (i) => series.values.fold<double>(
        0,
        (sum, v) => sum + (i < v.length ? v[i] ?? 0 : 0),
      ),
    );
    final max = totals.fold<double>(0, (a, b) => a > b ? a : b);
    if (labels.isEmpty) return const AnalyticsEmptyState();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          children: [
            for (var i = 0; i < series.length; i++)
              Text(
                tr(series.keys.elementAt(i)),
                style: TextStyle(fontSize: 10, color: _seriesColor(context, i)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < labels.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  labels[i],
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 5),
                LayoutBuilder(
                  builder: (context, c) => Row(
                    children: [
                      for (var j = 0; j < series.length; j++)
                        Tooltip(
                          triggerMode: TooltipTriggerMode.tap,
                          message:
                              '${tr(series.keys.elementAt(j))}: ${countLabel(series.values.elementAt(j)[i])}',
                          child: Container(
                            width: max == 0
                                ? 0
                                : c.maxWidth *
                                      (series.values.elementAt(j)[i] ?? 0) /
                                      max,
                            height: 13,
                            color: _seriesColor(context, j),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  series.entries
                      .map((e) => '${tr(e.key)} ${countLabel(e.value[i])}')
                      .join(' · '),
                  style: const TextStyle(fontSize: 9),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class MetricGrid extends StatelessWidget {
  const MetricGrid({
    super.key,
    required this.values,
    this.sparks = const {},
    this.presence = const {},
  });
  final Map<String, dynamic> values;
  final Map<String, List<ChartPoint>> sparks;
  final Map<String, List<bool>> presence;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var i = 0; i < values.length; i++)
          Container(
            width: (c.maxWidth - 10) / 2,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: BeaconColors.of(context).surface,
              border: Border.all(color: BeaconColors.of(context).borderSubtle),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(values.keys.elementAt(i)),
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  values.values.elementAt(i) is String
                      ? textOf(values.values.elementAt(i))
                      : countLabel(metric(values.values.elementAt(i))),
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 22,
                    color: _seriesColor(context, i),
                  ),
                ),
                if (presence[values.keys.elementAt(i)]?.isNotEmpty ?? false)
                  SizedBox(
                    height: 28,
                    child: Center(
                      child: SizedBox(
                        height: 12,
                        child: Row(
                          children: [
                            for (final reported
                                in presence[values.keys.elementAt(i)]!)
                              Expanded(
                                child: Container(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: .3,
                                  ),
                                  color: reported
                                      ? _seriesColor(context, i)
                                      : BeaconColors.of(context).raised,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (sparks[values.keys.elementAt(i)]?.any((p) => p.y != null) ??
                    false)
                  SizedBox(
                    height: 28,
                    child: LineChart(
                      LineChartData(
                        titlesData: const FlTitlesData(show: false),
                        borderData: FlBorderData(show: false),
                        gridData: const FlGridData(show: false),
                        lineTouchData: const LineTouchData(enabled: false),
                        lineBarsData: [
                          LineChartBarData(
                            spots: sparks[values.keys.elementAt(i)]!
                                .map(
                                  (p) => p.y == null
                                      ? FlSpot.nullSpot
                                      : FlSpot(p.x, p.y!),
                                )
                                .toList(),
                            barWidth: 1,
                            color: _seriesColor(context, i),
                            dotData: const FlDotData(show: false),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class ActivityHeatmap extends StatelessWidget {
  const ActivityHeatmap({super.key, required this.points});
  final List<ChartPoint> points;
  @override
  Widget build(BuildContext context) {
    final days = <String, List<ChartPoint>>{};
    final max = points.fold<double>(1, (v, p) => (p.y ?? 0) > v ? p.y! : v);
    for (final point in points) {
      final date = epoch(point.x, isUtc: true);
      if (date == null) continue;
      final day = date.toIso8601String().substring(0, 10);
      days.putIfAbsent(day, () => []).add(point);
    }
    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: 41),
            for (var i = 0; i < 24; i += 3)
              Expanded(
                child: Text(
                  '${i.toString().padLeft(2, '0')}h',
                  maxLines: 1,
                  style: const TextStyle(fontSize: 7),
                ),
              ),
          ],
        ),
        const SizedBox(height: 5),
        for (final day in days.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              children: [
                SizedBox(
                  width: 41,
                  child: Text(
                    day.key.substring(5),
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 8,
                    ),
                  ),
                ),
                for (var hour = 0; hour < 24; hour++)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final point = day.value
                            .where((p) => epoch(p.x, isUtc: true)?.hour == hour)
                            .firstOrNull;
                        return Tooltip(
                          triggerMode: TooltipTriggerMode.tap,
                          message:
                              '${day.key} ${hour.toString().padLeft(2, '0')}:00 UTC\n${point?.y == null ? tr('No sample') : countLabel(point!.y)}',
                          child: Container(
                            height: 13,
                            margin: const EdgeInsets.only(right: 1),
                            color: point?.y == null
                                ? BeaconColors.of(context).raised
                                : Color.lerp(
                                    _seriesColor(
                                      context,
                                      0,
                                    ).withValues(alpha: .2),
                                    _seriesColor(context, 1),
                                    point!.y! / max,
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(tr('Fewer'), style: const TextStyle(fontSize: 8)),
            const SizedBox(width: 5),
            for (var i = 0; i < 20; i++)
              Container(
                width: 5,
                height: 8,
                color: Color.lerp(
                  _seriesColor(context, 0).withValues(alpha: .2),
                  _seriesColor(context, 1),
                  i / 19,
                ),
              ),
            const SizedBox(width: 5),
            Text(tr('More'), style: const TextStyle(fontSize: 8)),
          ],
        ),
      ],
    );
  }
}
