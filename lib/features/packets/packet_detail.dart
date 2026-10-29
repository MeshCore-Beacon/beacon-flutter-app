import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../map/map_data.dart';
import '../map/packet_path_screen.dart';
import 'investigation.dart';
import 'packet_model.dart';
import 'packet_screen.dart';
import 'path_hop.dart';
import 'payload_view.dart';

class PacketDetailScreen extends StatefulWidget {
  const PacketDetailScreen({
    super.key,
    required this.api,
    required this.hash,
    required this.onOpen,
    this.initialObservationId,
  });
  final ApiClient api;
  final String hash;
  final String? initialObservationId;
  final void Function(String, String) onOpen;
  @override
  State<PacketDetailScreen> createState() => _PacketDetailScreenState();
}

class _PacketDetailScreenState extends State<PacketDetailScreen>
    with WidgetsBindingObserver {
  Json? detail;
  String? error;
  int selected = 0;
  String? retainedObservationId;
  @override
  void initState() {
    super.initState();
    retainedObservationId = widget.initialObservationId;
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load(fresh: true);
  }

  int generation = 0;
  Future<void> load({bool fresh = false}) async {
    final current = ++generation;
    setState(() => error = null);
    try {
      final response = object(
        await (fresh ? widget.api.get : widget.api.getCached)(
          '/packets/${Uri.encodeComponent(widget.hash)}',
          const {},
          () => mounted && current == generation,
        ),
      );
      if (mounted && current == generation) {
        final previous = rows(detail?['observations']);
        final selectedId = previous.isEmpty || selected < 0
            ? retainedObservationId
            : textOf(previous[selected.clamp(0, previous.length - 1)]['id']);
        final next = rows(response['observations']);
        final index = next.indexWhere((o) => textOf(o['id']) == selectedId);
        setState(() {
          detail = response;
          retainedObservationId = selectedId;
          selected = index < 0 ? (selectedId == null ? 0 : -1) : index;
        });
      }
    } catch (e) {
      if (mounted && current == generation) {
        setState(() => error = e.toString());
      }
    }
  }

  Future<void> copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Copied')),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = detail;
    final header = object(data?['header']);
    final observations = rows(data?['observations']);
    final unavailable = selected < 0;
    final obs = observations.isEmpty || unavailable
        ? null
        : observations[selected.clamp(0, observations.length - 1)];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          tr('Packet analyzer'),
          style: const TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 13,
            letterSpacing: .6,
          ),
        ),
        actions: [
          TextButton(
            child: Text(
              tr('Copy link'),
              style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11),
            ),
            onPressed: () => copy(
              widget.api.base
                  .replace(
                    queryParameters: {
                      'tab': 'Packets',
                      'hash': widget.hash,
                      'analyze': '1',
                      if (obs?['id'] != null) 'observation': '${obs!['id']}',
                    },
                  )
                  .toString(),
            ),
          ),
        ],
      ),
      body: data == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(tr(error!)),
                        ),
                        TextButton(onPressed: load, child: Text(tr('Retry'))),
                      ],
                    ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 14),
              children: _insetSections([
                _section('Summary', [
                  Row(
                    children: [
                      Tooltip(
                        message: widget.hash.toUpperCase(),
                        child: SelectableText(
                          (widget.hash.length > 8
                                  ? widget.hash.substring(0, 8)
                                  : widget.hash)
                              .toUpperCase(),
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      PacketBadge(
                        label: payloadName(header['payloadType']),
                        type: (number(header['payloadType']) ?? 0).toInt(),
                      ),
                      const Spacer(),
                      Text(
                        '×${observations.map((o) => o['observerId']).where((id) => id != null).toSet().length}',
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  DefaultTextStyle.merge(
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text('${tr('First')} ${age(data['firstHeardAt'])}'),
                        const Text('·'),
                        Text('${tr('Last')} ${age(data['lastHeardAt'])}'),
                        const Text('·'),
                        Text(
                          '${tr('Heard over')} ${((number(data['firstToLastMs']) ?? 0) / 1000).toStringAsFixed(3)}s',
                        ),
                      ],
                    ),
                  ),
                  if (data['scope'] != null) _field('Scope', data['scope']),
                ]),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    minimumSize: const Size.fromHeight(36),
                    textStyle: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                    ),
                  ),
                  icon: const Icon(Icons.map_outlined, size: 14),
                  label: Text(tr('Map all paths')),
                  onPressed: packetPaths(data).isEmpty
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PacketPathScreen(
                              detail: data,
                              onOpen: widget.onOpen,
                            ),
                          ),
                        ),
                ),
                if (unavailable)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      tr(
                        'This observation is no longer retained. Select another report to inspect it.',
                      ),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                PacketInvestigation(
                  detail: data,
                  selectedId: obs == null ? null : textOf(obs['id']),
                  initiallyExpanded: widget.initialObservationId != null,
                  onSelect: (report) => setState(
                    () => selected = observations.indexWhere(
                      (o) => o['id'] == report['id'],
                    ),
                  ),
                  onOpen: widget.onOpen,
                ),
                const SizedBox(height: 12),
                if (!unavailable)
                  _section('Raw packet', [
                    _hex(
                      observationFrame(data, obs),
                      ranges: computeFieldRanges(data, obs ?? const {}),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          textStyle: const TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 11,
                          ),
                        ),
                        onPressed: () => copy(observationFrame(data, obs)),
                        icon: const Icon(Icons.copy, size: 13),
                        label: Text(tr('Copy')),
                      ),
                    ),
                  ]),
                if (obs != null) ...[
                  if (object(obs['resolvedSource']).isNotEmpty ||
                      object(obs['resolvedDestination']).isNotEmpty)
                    _section('Endpoints', [
                      for (final key in [
                        'resolvedSource',
                        'resolvedDestination',
                      ])
                        if (object(obs[key]).isNotEmpty) ...[
                          Text(
                            tr(
                              key == 'resolvedSource'
                                  ? 'Source'
                                  : 'Destination',
                            ),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          _resolved(object(obs[key])),
                        ],
                    ]),
                  if (textOf(obs['pathBytes']).isNotEmpty)
                    _section('Path', [
                      PacketPathHops(observation: obs, onOpen: widget.onOpen),
                    ]),
                ],
                _section('Packet structure', [
                  _structureLabel('Header byte'),
                  _inlineFields([
                    '${tr('Ver')} ${header['payloadVersion'] ?? '?'}',
                    '${tr('Type')} ${payloadName(header['payloadType'])} (${header['payloadType'] ?? '?'})',
                    '${tr('Route')} ${header['routeTypeName'] ?? '?'} (${header['routeType'] ?? '?'})',
                  ]),
                  if (int.tryParse(textOf(header['raw']), radix: 16)
                      case final int byte)
                    _bits(byte),
                  if (object(data['transportCodes']).isNotEmpty) ...[
                    _structureLabel('Transport codes'),
                    _inlineFields([
                      '${tr('Region code')} ${object(data['transportCodes'])['regionCode']}',
                      '${tr('Subregion code')} ${object(data['transportCodes'])['subRegionCode']}',
                    ]),
                  ],
                  if (obs != null) ...[
                    _structureLabel('Path length'),
                    _inlineFields([
                      '${tr('Hash size')} ${object(obs['pathLength'])['hashSize'] ?? '?'}B',
                      '${tr('Hops')} ${object(obs['pathLength'])['hopCount'] ?? '?'}',
                    ]),
                    if (int.tryParse(
                          textOf(object(obs['pathLength'])['raw']),
                          radix: 16,
                        )
                        case final int byte)
                      _bits(byte, pathLength: true),
                  ],
                  if (data['originPubkey'] != null &&
                      textOf(data['originPubkey']).toUpperCase() !=
                          textOf(object(data['parsedPayload'])['publicKey'])
                              .toUpperCase())
                    _field('Origin public key', data['originPubkey']),
                ]),
                _section('Payload breakdown', [
                  PacketPayloadView(
                    detail: data,
                    observation: obs ?? const {},
                    onOpen: widget.onOpen,
                  ),
                ]),
                if (textOf(data['rawPayload']).isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Text(
                      tr('Payload data').toUpperCase(),
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 12,
                      ),
                    ),
                    subtitle: Text(
                      trKey(
                        'packetAnalyzer.bytes',
                        count: textOf(data['rawPayload']).length ~/ 2,
                      ),
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                      ),
                    ),
                    children: [_hex(textOf(data['rawPayload']))],
                  ),
              ]),
            ),
    );
  }

  List<Widget> _insetSections(List<Widget> children) => [
    for (final child in children)
      if (child is PacketInvestigation)
        child
      else
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: child,
        ),
  ];

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            tr(title).toUpperCase(),
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: .7,
            ),
          ),
        ),
        ...children,
      ],
    ),
  );
  Widget _structureLabel(String label) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 6),
    child: Text(
      tr(label).toUpperCase(),
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _inlineFields(List<String> values) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        for (final value in values)
          Text(
            value,
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
          ),
      ],
    ),
  );

  Widget _field(String label, dynamic value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr(label), style: Theme.of(context).textTheme.bodySmall),
        SelectableText(
          value == null ? tr('Unknown') : value.toString(),
          style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
        ),
      ],
    ),
  );
  Widget _resolved(Json hop) => Align(
    alignment: Alignment.centerLeft,
    child: PathHopChip(
      hash: textOf(hop['hashBytes']),
      hop: hop,
      onOpen: widget.onOpen,
    ),
  );

  Widget _bits(int byte, {bool pathLength = false}) {
    final bits = (byte & 255).toRadixString(2).padLeft(8, '0');
    final groups = pathLength
        ? [
            (
              bits.substring(0, 2),
              '${((byte >> 6) & 3) + 1} B ${tr('hash')}',
              Theme.of(context).colorScheme.secondary,
            ),
            (
              bits.substring(2),
              '${byte & 63} ${tr('hops')}',
              BeaconColors.of(context).success,
            ),
          ]
        : [
            (
              bits.substring(0, 2),
              tr('Version'),
              Theme.of(context).colorScheme.secondary,
            ),
            (
              bits.substring(2, 6),
              tr('Type'),
              BeaconColors.of(context).warning,
            ),
            (bits.substring(6), tr('Route'), BeaconColors.of(context).success),
          ];
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          Text(
            '0x${byte.toRadixString(16).padLeft(2, '0').toUpperCase()} = [',
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11),
          ),
          for (final (value, label, color) in groups)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                    color: color,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                    color: color,
                  ),
                ),
              ],
            ),
          const Text(
            ']',
            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _hex(String raw, {Map<String, PacketByteRange> ranges = const {}}) {
    final scheme = Theme.of(context).colorScheme;
    Color fieldColor(String? field) => switch (field) {
      'header' ||
      'pathData' ||
      'signature' ||
      'sourceHash' ||
      'tracePath' => scheme.secondary,
      'pathLength' ||
      'channelHash' ||
      'advertTimestamp' ||
      'destinationHash' ||
      'traceTag' => scheme.primary,
      'transport' ||
      'cipherMac' ||
      'flags' ||
      'checksum' => BeaconColors.of(context).warning,
      'publicKey' ||
      'location' ||
      'senderPublicKey' ||
      'authCode' => BeaconColors.of(context).success,
      'ciphertext' => scheme.error,
      _ => scheme.onSurface.withValues(alpha: .7),
    };
    String? fieldAt(int offset) => ranges.entries
        .where(
          (e) =>
              e.key != 'payload' &&
              offset >= e.value.start &&
              offset < e.value.end,
        )
        .firstOrNull
        ?.key;
    // MeshCore frames are at most 255 bytes; don't build a widget per byte for junk.
    const maxBytes = 512;
    final total = raw.length ~/ 2;
    final shown = total > maxBytes ? maxBytes : total;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 160),
        child: SingleChildScrollView(
          child: Wrap(
            spacing: 5,
            runSpacing: 4,
            children: [
              for (int i = 0; i < shown * 2; i += 2)
                Tooltip(
                  message:
                      '${fieldAt(i ~/ 2) ?? 'payload'} · ${tr('byte')} ${i ~/ 2}',
                  child: Text(
                    raw.substring(i, i + 2).toUpperCase(),
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                      color: fieldColor(fieldAt(i ~/ 2)),
                    ),
                  ),
                ),
              if (total > shown)
                Text(
                  tr('… {{count}} more bytes')
                      .replaceAll('{{count}}', '${total - shown}'),
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
