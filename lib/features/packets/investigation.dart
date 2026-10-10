import 'package:flutter/material.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../map/map_data.dart';
import '../map/packet_path_screen.dart';
import 'path_hop.dart';

class ReportGroup {
  ReportGroup(this.key, this.kind, this.hashes);
  final String key, kind;
  final List<String> hashes;
  final List<Json> reports = [];
}

List<ReportGroup> groupPacketReports(List<Json> reports) {
  final sorted = [...reports]
    ..sort((a, b) {
      final time = (number(a['heardAt']) ?? 0).compareTo(
        number(b['heardAt']) ?? 0,
      );
      return time == 0
          ? (number(a['id']) ?? 0).compareTo(number(b['id']) ?? 0)
          : time;
    });
  final groups = <String, ReportGroup>{};
  for (final report in sorted) {
    final length = object(report['pathLength']);
    final width = number(length['hashSize']),
        count = number(length['hopCount']);
    final raw = textOf(report['pathBytes']).toUpperCase();
    final valid =
        [1, 2, 3].contains(width) &&
        count != null &&
        count == count.roundToDouble() &&
        count >= 0 &&
        raw.length == width! * count * 2 &&
        RegExp(r'^[0-9A-F]*$').hasMatch(raw);
    final kind = !valid
        ? 'unavailable'
        : count == 0
        ? 'empty'
        : 'path';
    final key = valid ? '$width:$count:$raw' : 'unavailable:${report['id']}';
    final hashes = <String>[];
    if (valid) {
      final step = width.toInt() * 2;
      for (var i = 0; i < raw.length; i += step) {
        hashes.add(raw.substring(i, i + step));
      }
    }
    (groups[key] ??= ReportGroup(key, kind, hashes)).reports.add(report);
  }
  return groups.values.toList();
}

class PacketInvestigation extends StatefulWidget {
  const PacketInvestigation({
    super.key,
    required this.detail,
    required this.selectedId,
    required this.onSelect,
    required this.onOpen,
    this.initiallyExpanded = false,
  });
  final Json detail;
  final String? selectedId;
  final ValueChanged<Json> onSelect;
  final void Function(String, String) onOpen;
  final bool initiallyExpanded;
  @override
  State<PacketInvestigation> createState() => _PacketInvestigationState();
}

class _PacketInvestigationState extends State<PacketInvestigation> {
  int shown = 6;
  @override
  Widget build(BuildContext context) {
    final observations = rows(widget.detail['observations']);
    final groups = groupPacketReports(observations);
    final observerCount = observations
        .map((o) => o['observerId'])
        .where((id) => id != null)
        .toSet()
        .length;
    final mapped = packetPaths(widget.detail)
        .map((p) => textOf(p['key']))
        .toSet();
    final trace = number(object(widget.detail['header'])['payloadType']) == 9;
    return ExpansionTile(
      key: const ValueKey('packet-investigation'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 14),
      controlAffinity: ListTileControlAffinity.leading,
      shape: const Border(),
      collapsedShape: const Border(),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      initiallyExpanded: widget.initiallyExpanded,
      title: Text(
        tr('Observations').toUpperCase(),
        style: const TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.1,
        ),
      ),
      subtitle: Text(
        trKey('investigation.heardBy', count: observerCount),
        style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11),
      ),
      children: [
        if (groups.isEmpty) Text(tr('No observations retained.')),
        for (final (index, group) in groups.indexed)
          if (index < shown ||
              group.reports.any((r) => textOf(r['id']) == widget.selectedId))
            ExpansionTile(
              key: ValueKey(group.key),
              tilePadding: const EdgeInsets.symmetric(horizontal: 14),
              dense: true,
              minTileHeight: 40,
              controlAffinity: ListTileControlAffinity.leading,
              shape: const Border(),
              collapsedShape: const Border(),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              initiallyExpanded: group.reports.any(
                (r) => textOf(r['id']) == widget.selectedId,
              ),
              title: RichText(
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                  ),
                  children: [
                    TextSpan(
                      text: group.kind == 'empty'
                          ? tr('No path entries')
                          : group.kind == 'unavailable'
                          ? tr('Path unavailable')
                          : '${tr('Path')} ${index + 1}',
                    ),
                    if (group.hashes.isNotEmpty)
                      TextSpan(
                        text: '  ${group.hashes.join(' → ')}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
              trailing: Text('×${group.reports.length}'),
              children: [
                for (final o in group.reports)
                  _report(
                    o,
                    mapped.contains(trace ? 'trace' : textOf(o['observerId'])),
                    trace ? 'trace' : textOf(o['observerId']),
                  ),
              ],
            ),
        if (groups.length > shown)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  textStyle: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                  ),
                ),
                onPressed: () => setState(() => shown += 6),
                child: Text(
                  tr('Load more ({{count}} left)')
                      .replaceAll('{{count}}', '${groups.length - shown}'),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _report(Json o, bool canMap, String pathKey) {
    final selected = textOf(o['id']) == widget.selectedId;
    return Container(
      key: ValueKey('report-${o['id']}'),
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).dividerColor,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: InkWell(
        onTap: () => widget.onSelect(o),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                textOf(o['observerName'], shortKey(o['observerId'])),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  Text(age(o['heardAt'])),
                  Text(textOf(o['iata'])),
                  Text('RSSI ${textOf(o['rssi'], '?')} dBm'),
                  Text('SNR ${textOf(o['snr'], '?')} dB'),
                  Text(
                    trKey(
                      'routes.hops',
                      count: (number(object(o['pathLength'])['hopCount']) ?? 0)
                          .toInt(),
                    ),
                  ),
                  if (o['propagationTimeMs'] != null)
                    Text('+${o['propagationTimeMs']} ms'),
                ],
              ),
              PacketPathHops(observation: o, onOpen: widget.onOpen),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => widget.onSelect(o),
                    child: Text(tr('Inspect')),
                  ),
                  TextButton(
                    onPressed: o['observerId'] == null
                        ? null
                        : () {
                            widget.onSelect(o);
                            widget.onOpen('observer', textOf(o['observerId']));
                          },
                    child: Text(tr('Observer')),
                  ),
                  TextButton(
                    onPressed: !canMap
                        ? null
                        : () {
                            widget.onSelect(o);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PacketPathScreen(
                                  detail: widget.detail,
                                  onOpen: widget.onOpen,
                                  initialPathKey: pathKey,
                                ),
                              ),
                            );
                          },
                    child: Text(tr('Map')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
