import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import 'charts.dart';
import 'transforms.dart';

/// Query for `/observers/{id}/activity`; the detail tiles reuse the charts'
/// params so both share one request.
Map<String, dynamic> observerActivityParams(String range) {
  final hours = rangeHours[range] ?? 24;
  return {
    'range': '${hours}h',
    'interval': hours == 24
        ? '15m'
        : hours == 168
        ? '1h'
        : '6h',
  };
}

class ObserverCharts extends StatelessWidget {
  const ObserverCharts({
    super.key,
    required this.api,
    required this.observerId,
    this.range = '24h',
  });
  final ApiClient api;
  final String observerId, range;

  @override
  Widget build(BuildContext context) {
    final params = observerActivityParams(range);
    final hours = rangeHours[range] ?? 24,
        intervalMs = hours == 24
            ? 900000
            : hours == 168
            ? 3600000
            : 21600000;
    final telemetryInterval = hours == 24
        ? '1h'
        : hours == 168
        ? '6h'
        : '24h';
    final id = Uri.encodeComponent(observerId);
    return StatsQuery(
      api: api,
      path: '/observers/$id/activity',
      pollInterval: const Duration(minutes: 1),
      params: params,
      builder: (d) {
        final o = object(d),
            end =
                number(o['windowEnd'])?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
            start = number(o['windowStart'])?.toInt() ?? end - hours * 3600000;
        final rawPoints = rows(o['points']);
        final costed = rawPoints.any((r) => number(r['airtimeMs']) != null);
        final activity = fillActivity(
          rawPoints,
          intervalMs,
          start,
          end,
          rolledUntil: number(o['rolledUntil'])?.toInt(),
          rawFrom: number(o['rawFrom'])?.toInt(),
        );
        List<ChartPoint> activitySeries(String key) => activity
            .map((r) => ChartPoint(number(r['t']) ?? 0, number(r[key])))
            .toList();

        Widget busyChart() {
          final points = activity
              .map(
                (r) => ChartPoint(
                  number(r['t']) ?? 0,
                  number(r['airtimeMs']) == null
                      ? null
                      : number(r['airtimeMs'])! * 100 / intervalMs,
                ),
              )
              .toList();
          return AnalyticsCard(
            title: 'Channel busy',
            child: TimeChart(
              unit: '%',
              showSingleSeriesToggle: false,
              series: {'Busy': points},
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnalyticsCard(
              title: tr('Packets heard per {{interval}}')
                  .replaceAll('{{interval}}', '${params['interval']}'),
              child: TimeChart(
                showSingleSeriesToggle: false,
                series: {'Receptions': activitySeries('observations')},
              ),
            ),
            AnalyticsCard(
              title: 'Packet-type mix',
              child: RankedBars(
                labels: rows(o['payloadTypes'])
                    .map((p) => textOf(p['payloadTypeName']))
                    .toList(),
                values: rows(o['payloadTypes'])
                    .map((p) => number(p['count']))
                    .toList(),
              ),
            ),
            AnalyticsCard(
              title: 'Signal · dB',
              child: TimeChart(
                showSingleSeriesToggle: false,
                series: {
                  'SNR average': activitySeries('snrAvg'),
                  'SNR minimum': activitySeries('snrMin'),
                },
              ),
            ),
            StatsQuery(
              api: api,
              path: '/observers/$id/telemetry',
              params: {'range': '${hours}h', 'interval': telemetryInterval},
              builder: (telemetry) {
                final points = rows(object(telemetry)['points']);
                final meaningful = points.any(
                  (r) => [
                    'batteryMv',
                    'airtimeTxSecs',
                    'airtimeRxSecs',
                    'noiseFloorDb',
                    'uptimeSeconds',
                    'queueLength',
                    'receiveErrors',
                  ].any((key) => number(r[key]) != null && number(r[key]) != 0),
                );
                if (!meaningful) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AnalyticsCard(
                        title: 'Telemetry',
                        child: Text(
                          tr(
                            'This observer sent no device telemetry for this period.',
                          ),
                        ),
                      ),
                      if (costed) busyChart(),
                    ],
                  );
                }
                List<ChartPoint> telemetrySeries(
                  String key, {
                  double scale = 1,
                }) => points
                    .map(
                      (r) => ChartPoint(
                        number(r['t']) ?? 0,
                        number(r[key]) == null ? null : number(r[key])! * scale,
                      ),
                    )
                    .toList();
                bool hasValues(String key) =>
                    points.any((r) => number(r[key]) != null);
                final bucketMs = telemetryInterval == '1h'
                    ? null
                    : hours == 168
                    ? 21600000
                    : 86400000;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (hasValues('airtimeTxSecs') ||
                        hasValues('airtimeRxSecs'))
                      AnalyticsCard(
                        title: 'Airtime TX / RX',
                        child: TimeChart(
                          unit: '%',
                          showSingleSeriesToggle: false,
                          series: {
                            'RX': airtimePercent(
                              points,
                              'airtimeRxSecs',
                              bucketMs: bucketMs,
                            ),
                            'TX': airtimePercent(
                              points,
                              'airtimeTxSecs',
                              bucketMs: bucketMs,
                            ),
                          },
                        ),
                      ),
                    if (hasValues('batteryMv'))
                      AnalyticsCard(
                        title: 'Battery V',
                        child: TimeChart(
                          unit: ' V',
                          showSingleSeriesToggle: false,
                          series: {
                            'Battery': telemetrySeries(
                              'batteryMv',
                              scale: .001,
                            ),
                          },
                        ),
                      ),
                    if (hasValues('noiseFloorDb'))
                      AnalyticsCard(
                        title: 'Noise floor',
                        child: TimeChart(
                          unit: ' dB',
                          showSingleSeriesToggle: false,
                          series: {
                            'Noise floor': telemetrySeries('noiseFloorDb'),
                          },
                        ),
                      ),
                    if (hasValues('queueLength'))
                      AnalyticsCard(
                        title: 'Queue',
                        child: TimeChart(
                          showSingleSeriesToggle: false,
                          series: {'Queue': telemetrySeries('queueLength')},
                        ),
                      ),
                    if (hasValues('receiveErrors'))
                      AnalyticsCard(
                        title: 'Receive errors',
                        child: TimeChart(
                          showSingleSeriesToggle: false,
                          series: {
                            'Receive errors': telemetrySeries('receiveErrors'),
                          },
                        ),
                      ),
                    if (costed) busyChart(),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }
}
