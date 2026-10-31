import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'charts.dart';
import 'transforms.dart';

class ComparisonPanel extends StatefulWidget {
  const ComparisonPanel({
    super.key,
    required this.api,
    required this.region,
    this.initialSelection,
    this.onSelection,
  });
  final ApiClient api;
  final Map<String, dynamic> region;
  final Map<String, dynamic>? initialSelection;
  final ValueChanged<Map<String, dynamic>>? onSelection;
  @override
  State<ComparisonPanel> createState() => _ComparisonPanelState();
}

class _ComparisonPanelState extends State<ComparisonPanel> {
  String a = '', b = '', aName = '', bName = '';
  String? error;
  Map<String, dynamic>? selection;
  DateTime since = DateTime.now().subtract(const Duration(days: 1)),
      until = DateTime.now();
  @override
  void initState() {
    super.initState();
    final value = widget.initialSelection;
    if (value != null) {
      a = textOf(value['observerA']);
      b = textOf(value['observerB']);
      since = DateTime.fromMillisecondsSinceEpoch(
        (number(value['since']) ?? since.millisecondsSinceEpoch).toInt(),
      );
      until = DateTime.fromMillisecondsSinceEpoch(
        (number(value['until']) ?? until.millisecondsSinceEpoch).toInt(),
      );
      if (validateComparison(
            a,
            b,
            since.millisecondsSinceEpoch,
            until.millisecondsSinceEpoch,
          ) ==
          null) {
        selection = value;
      }
    }
  }

  Future<void> pick(bool first) async {
    final initial = first ? since : until;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    setState(() {
      final d = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      if (first) {
        since = d;
      } else {
        until = d;
      }
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        tr(
          'Packets are only kept for a few days, so older windows may be incomplete.',
        ),
        style: TextStyle(color: BeaconColors.of(context).muted, fontSize: 11),
      ),
      const SizedBox(height: 12),
      AnalyticsCard(
        title: 'Selection',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final first in [true, false])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final result =
                        await showModalBottomSheet<Map<String, dynamic>>(
                          context: context,
                          isScrollControlled: true,
                          builder: (c) => Material(
                            child: _ObserverChooser(
                              api: widget.api,
                              region: widget.region,
                              exclude: first ? b : a,
                            ),
                          ),
                        );
                    if (result == null || !mounted) return;
                    setState(() {
                      if (first) {
                        a = textOf(result['id']);
                        aName = textOf(result['displayName'], a);
                      } else {
                        b = textOf(result['id']);
                        bName = textOf(result['displayName'], b);
                      }
                    });
                  },
                  icon: const Icon(Icons.search, size: 16),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${tr(first ? 'Observer A' : 'Observer B')}: ${first ? (aName.isNotEmpty
                                ? aName
                                : a.isEmpty
                                ? trKey('observerCompare.chooseObserver')
                                : shortKey(a)) : (bName.isNotEmpty
                                ? bName
                                : b.isEmpty
                                ? trKey('observerCompare.chooseObserver')
                                : shortKey(b))}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            TextButton.icon(
              onPressed: () => pick(true),
              icon: const Icon(Icons.calendar_today, size: 16),
              label: Text(
                '${tr('Start')}: ${since.toString().substring(0, 16)}',
              ),
            ),
            TextButton.icon(
              onPressed: () => pick(false),
              icon: const Icon(Icons.calendar_today, size: 16),
              label: Text('${tr('End')}: ${until.toString().substring(0, 16)}'),
            ),
            if (since.isBefore(
              DateTime.now().subtract(const Duration(days: 7)),
            ))
              Text(
                tr(
                  'Only recent packets are kept, so the start of this window may be empty.',
                ),
              ),
            if (error != null)
              Text(
                tr(error!),
                style: TextStyle(color: BeaconColors.of(context).danger),
              ),
            FilledButton(
              onPressed: () {
                final e = validateComparison(
                  a,
                  b,
                  since.millisecondsSinceEpoch,
                  until.millisecondsSinceEpoch,
                );
                setState(() {
                  error = e;
                  if (e == null) {
                    selection = {
                      'observerA': a.toLowerCase(),
                      'observerB': b.toLowerCase(),
                      'since': since.millisecondsSinceEpoch,
                      'until': until.millisecondsSinceEpoch,
                    };
                    widget.onSelection?.call(selection!);
                  }
                });
              },
              child: Text(tr('Compare')),
            ),
          ],
        ),
      ),
      if (selection != null)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              final p = selection!;
              final uri = widget.api.base.replace(
                queryParameters: {
                  'tab': 'Analytics',
                  'statsTab': 'compare',
                  ...widget.region.map((k, v) => MapEntry(k, '$v')),
                  'compareA': '${p['observerA']}',
                  'compareB': '${p['observerB']}',
                  'compareSince': '${p['since']}',
                  'compareUntil': '${p['until']}',
                },
              );
              await Clipboard.setData(ClipboardData(text: uri.toString()));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(tr('Link copied'))));
              }
            },
            icon: const Icon(Icons.link, size: 16),
            label: Text(tr('Copy link')),
          ),
        ),
      if (selection != null)
        AnalyticsCard(
          title: 'Flood packets heard',
          child: StatsQuery(
            key: ValueKey(selection.toString()),
            api: widget.api,
            path: '/stats/observer-comparison',
            params: {...widget.region, ...selection!},
            builder: (d) {
              final o = object(d), total = number(o['totalPackets']);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${countLabel(total)} distinct packets',
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 20,
                      color: BeaconColors.of(context).bright,
                    ),
                  ),
                  const SizedBox(height: 12),
                  StackedRows(
                    labels: [tr('Flood packets heard')],
                    series: {
                      'Only A': [number(o['onlyA'])],
                      'Both': [number(o['both'])],
                      'Only B': [number(o['onlyB'])],
                    },
                  ),
                ],
              );
            },
          ),
        ),
    ],
  );
}

class _ObserverChooser extends StatefulWidget {
  const _ObserverChooser({
    required this.api,
    required this.region,
    required this.exclude,
  });
  final ApiClient api;
  final Map<String, dynamic> region;
  final String exclude;
  @override
  State<_ObserverChooser> createState() => _ObserverChooserState();
}

class _ObserverChooserState extends State<_ObserverChooser> {
  String query = '';
  Timer? debounce;
  @override
  void dispose() {
    debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .6,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: trKey('observerCompare.chooseObserver'),
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (value) {
                debounce?.cancel();
                debounce = Timer(const Duration(milliseconds: 250), () {
                  if (mounted) setState(() => query = value.trim());
                });
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: widget.region.containsKey('region')
                  ? Center(child: Text(tr('No matches')))
                  : StatsQuery(
                      api: widget.api,
                      path: '/observers',
                      params: {
                        ...widget.region,
                        'limit': 50,
                        if (query.isNotEmpty) 'name': query,
                      },
                      builder: (d) {
                        final items = rows(d)
                            .where((o) => textOf(o['id']) != widget.exclude)
                            .toList();
                        if (items.isEmpty) {
                          return Center(child: Text(tr('No matches')));
                        }
                        return ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (context, i) => ListTile(
                            dense: true,
                            title: Text(
                              textOf(
                                items[i]['displayName'],
                                shortKey(items[i]['id']),
                              ),
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: 12,
                              ),
                            ),
                            trailing: Text(
                              textOf(items[i]['iata']),
                              style: TextStyle(
                                fontSize: 10,
                                color: BeaconColors.of(context).muted,
                              ),
                            ),
                            onTap: () => Navigator.pop(context, items[i]),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
