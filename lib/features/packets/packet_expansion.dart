import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../map/map_data.dart' show packetPaths;
import '../map/packet_path_screen.dart';
import 'path_hop.dart';

/// Inline mobile investigation below a packet card. The observation identifier
/// is kept in the navigation argument so the analyzer selects exactly that report.
class PacketExpansion extends StatefulWidget {
  const PacketExpansion({
    super.key,
    required this.api,
    required this.packet,
    required this.onOpen,
  });
  final ApiClient api;
  final Json packet;
  final void Function(String kind, String id) onOpen;
  @override
  State<PacketExpansion> createState() => _PacketExpansionState();
}

class _PacketExpansionState extends State<PacketExpansion>
    with WidgetsBindingObserver {
  Json? detail;
  Object? error;
  bool loading = true;
  int generation = 0;
  dynamic selected;
  String get hash => textOf(widget.packet['packetHash']);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void didUpdateWidget(covariant PacketExpansion old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api || old.packet['packetHash'] != hash) {
      detail = null;
      selected = null;
      load();
    } else if (old.packet['observationCount'] !=
            widget.packet['observationCount'] ||
        old.packet['lastHeardAt'] != widget.packet['lastHeardAt']) {
      load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    final g = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = object(
        await widget.api.get('/packets/${Uri.encodeComponent(hash)}'),
      );
      if (mounted && g == generation) {
        setState(() {
          detail = result;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted && g == generation) {
        setState(() {
          error = e;
          loading = false;
        });
      }
    }
  }

  String propagation(dynamic milliseconds) {
    final ms = number(milliseconds);
    return ms == null ? tr('Unknown') : '${(ms / 1000).toStringAsFixed(3)}s';
  }

  Widget mono(String value, {Color? color, double size = 11}) => Text(
    value,
    style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: size, color: color),
  );
  Color signal(dynamic value) {
    final snr = number(value);
    return snr == null
        ? Theme.of(context).colorScheme.primary
        : snr >= 10
        ? BeaconColors.of(context).success
        : snr >= 5
        ? BeaconColors.of(context).warning
        : BeaconColors.of(context).danger;
  }

  Widget metric(String name, String value, {Color? color}) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr(name).toUpperCase(),
          style: TextStyle(
            fontSize: 10,
            color: BeaconColors.of(context).muted,
            letterSpacing: .6,
          ),
        ),
        const SizedBox(height: 2),
        mono(value, color: color, size: 12),
      ],
    ),
  );
  void select(Json observation) {
    setState(() => selected = observation['id']);
    widget.onOpen(
      'packet',
      observation['id'] == null ? hash : '$hash:${observation['id']}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final first = number(widget.packet['firstHeardAt']),
        last = number(widget.packet['lastHeardAt']);
    final observations = rows(detail?['observations']);
    final empty =
        widget.packet['observationCount'] == 0 ||
        (!loading && error == null && observations.isEmpty);
    final hasPath = detail != null && packetPaths(detail!).isNotEmpty;
    return Container(
      key: const ValueKey('packet-expansion'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          left: BorderSide(color: Theme.of(context).colorScheme.primary),
          right: BorderSide(color: Theme.of(context).colorScheme.primary),
          bottom: BorderSide(color: Theme.of(context).colorScheme.primary),
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              mono(
                '${tr('First')} ${age(widget.packet['firstHeardAt'])}',
                color: BeaconColors.of(context).muted,
              ),
              mono(
                '${tr('Last')} ${age(widget.packet['lastHeardAt'])}',
                color: BeaconColors.of(context).muted,
              ),
              mono(
                '${tr('Spread')} ${propagation(first == null || last == null ? null : last - first)}',
                color: BeaconColors.of(context).muted,
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: !loading && error == null && hasPath
                ? () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PacketPathScreen(
                        detail: detail!,
                        onOpen: widget.onOpen,
                      ),
                    ),
                  )
                : null,
            child: Text(
              tr('View all paths'),
              style: const TextStyle(fontSize: 11),
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${tr('Could not load observations')}: ${tr('$error')}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  OutlinedButton(onPressed: load, child: Text(tr('Retry'))),
                ],
              ),
            )
          else if (empty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                tr('No observations'),
                style: TextStyle(
                  fontSize: 11,
                  color: BeaconColors.of(context).muted,
                ),
              ),
            )
          else if (loading && detail == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: LinearProgressIndicator(minHeight: 2),
            )
          else
            ...observations.map(observationCard),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => widget.onOpen('packet', hash),
              child: Text(
                tr('Open analyzer'),
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget observationCard(Json observation) {
    final path = object(observation['pathLength']);
    final radio = object(observation['radio']);
    final selectedHere = selected != null && selected == observation['id'];
    final color = selectedHere
        ? Theme.of(context).colorScheme.primary
        : signal(observation['snr']);
    final radioParts = [
      if (radio['freqMhz'] != null) '${radio['freqMhz']} MHz',
      if (radio['spreadFactor'] != null) 'SF${radio['spreadFactor']}',
      if (radio['bandwidthKhz'] != null) '${radio['bandwidthKhz']} kHz',
      if (radio['codingRate'] != null) 'CR 4/${radio['codingRate']}',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        borderRadius: BorderRadius.circular(3),
        clipBehavior: Clip.antiAlias,
        color: selectedHere
            ? color.withValues(alpha: .06)
            : Theme.of(context).scaffoldBackgroundColor,
        child: InkWell(
          onTap: () => select(observation),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: color, width: 2),
                right: BorderSide(color: Theme.of(context).dividerColor),
                top: BorderSide(color: Theme.of(context).dividerColor),
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        textOf(
                          observation['observerName'],
                          shortKey(observation['observerId']),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (observation['iata'] != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: mono(textOf(observation['iata']), size: 10),
                      ),
                    const SizedBox(width: 8),
                    mono(
                      age(observation['heardAt']),
                      color: BeaconColors.of(context).muted,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    metric(
                      'SNR',
                      number(observation['snr'])?.toStringAsFixed(2) ??
                          tr('Unknown'),
                      color: signal(observation['snr']),
                    ),
                    metric(
                      'RSSI',
                      textOf(observation['rssi'], tr('Unknown')),
                      color: signal(observation['snr']),
                    ),
                    metric(
                      'Prop',
                      propagation(observation['propagationTimeMs']),
                    ),
                    metric('Hops', textOf(path['hopCount'], tr('Unknown'))),
                  ],
                ),
                if (radioParts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: mono(
                      '${tr('Radio')}  ${radioParts.join(' · ')}',
                      color: BeaconColors.of(context).muted,
                    ),
                  ),
                if (textOf(observation['pathBytes']).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Divider(
                          height: 1,
                          color: Theme.of(context).dividerColor,
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            mono(
                              tr('Path').toUpperCase(),
                              color: BeaconColors.of(context).muted,
                              size: 10,
                            ),
                            ...pathHops(observation),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> pathHops(Json observation) {
    final bytes = textOf(observation['pathBytes']);
    final rawWidth =
        (number(object(observation['pathLength'])['hashSize']) ?? 1).toInt();
    final width = rawWidth.clamp(1, 8) * 2;
    final resolved = rows(observation['resolvedPath']);
    final payload = object(detail?['parsedPayload']);
    final snrs = payload['snrValues'] is List
        ? payload['snrValues'] as List
        : [];
    final isTrace = number(object(detail?['header'])['payloadType']) == 9;
    return [
      for (
        var offset = 0, index = 0;
        offset < bytes.length;
        offset += width, index++
      ) ...[
        if (index > 0) mono('→', color: BeaconColors.of(context).muted),
        Builder(
          builder: (context) {
            final hash = bytes
                .substring(offset, (offset + width).clamp(0, bytes.length))
                .toUpperCase();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PathHopChip(
                  hash: hash,
                  hop: index < resolved.length ? resolved[index] : const {},
                  onOpen: widget.onOpen,
                ),
                if (isTrace && index < snrs.length)
                  mono(
                    '${snrs[index]} dB',
                    color: signal(snrs[index]),
                    size: 10,
                  ),
              ],
            );
          },
        ),
      ],
    ];
  }
}
