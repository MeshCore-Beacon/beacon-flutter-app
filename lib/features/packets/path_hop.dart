import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';

class PathHopChip extends StatelessWidget {
  const PathHopChip({
    super.key,
    required this.hash,
    required this.hop,
    required this.onOpen,
  });
  final String hash;
  final Json hop;
  final void Function(String, String) onOpen;
  @override
  Widget build(BuildContext context) {
    final nodes = rows(hop['nodes']);
    final label = hash.isNotEmpty
        ? hash.startsWith('0x')
              ? '0x${hash.substring(2).toUpperCase()}'
              : hash.toUpperCase()
        : nodes.length == 1
        ? textOf(nodes.first['name'], shortKey(nodes.first['publicKey']))
        : tr(nodes.isEmpty ? 'Unresolved hop' : 'Resolved nodes');
    final color = switch (hop['confidence']) {
      'high' => BeaconColors.of(context).success,
      'ambiguous' => BeaconColors.of(context).warning,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return ActionChip(
      backgroundColor: color.withValues(alpha: .08),
      label: Text(
        label,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 11,
          color: color,
        ),
      ),
      avatar: nodes.length > 1
          ? const Icon(Icons.people_outline, size: 14)
          : null,
      onPressed: () async {
        final id = await showModalBottomSheet<String>(
          context: context,
          useSafeArea: true,
          showDragHandle: false,
          isScrollControlled: true,
          builder: (context) => _ResolvedNodesSheet(
            label: label,
            nodes: nodes,
            hop: hop,
            color: color,
          ),
        );
        if (id != null && context.mounted) onOpen('node', id);
      },
    );
  }
}

class _ResolvedNodesSheet extends StatelessWidget {
  const _ResolvedNodesSheet({
    required this.label,
    required this.nodes,
    required this.hop,
    required this.color,
  });
  final String label;
  final List<Json> nodes;
  final Json hop;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = BeaconColors.of(context);
    final status = nodes.isEmpty
        ? tr('Unresolved hop')
        : nodes.length > 1
        ? tr('Multiple matches')
        : tr('Resolved node');
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .65,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 32,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 2),
                decoration: BoxDecoration(
                  color: palette.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 12,
                            color: palette.muted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(
                              nodes.isEmpty
                                  ? Icons.help_outline
                                  : nodes.length > 1
                                  ? Icons.people_outline
                                  : Icons.check_circle_outline,
                              size: 14,
                              color: color,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                status,
                                style: TextStyle(fontSize: 12, color: color),
                              ),
                            ),
                          ],
                        ),
                        if (hop['snr'] != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'SNR ${hop['snr']} dB',
                              style: TextStyle(
                                fontSize: 11,
                                color: palette.muted,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Close'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                children: [
                  if (nodes.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        tr('No resolved nodes for this hop.'),
                        style: TextStyle(color: palette.muted),
                      ),
                    ),
                  for (final node in nodes)
                    Container(
                      width: double.infinity,

                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: palette.borderSubtle),
                        ),
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: ListTile(
                          dense: true,
                          minVerticalPadding: 0,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            textOf(node['name'], shortKey(node['publicKey'])),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: palette.bright,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (textOf(node['publicKey']).isNotEmpty)
                                IconButton(
                                  tooltip: tr('Copy public key'),
                                  icon: const Icon(
                                    Icons.copy_outlined,
                                    size: 18,
                                  ),
                                  onPressed: () async {
                                    await Clipboard.setData(
                                      ClipboardData(
                                        text: textOf(node['publicKey']),
                                      ),
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(content: Text(tr('Copied'))),
                                      );
                                    }
                                  },
                                ),
                              if (node['id'] != null)
                                Icon(
                                  Icons.chevron_right,
                                  color: palette.primary,
                                  size: 20,
                                ),
                            ],
                          ),
                          onTap: node['id'] == null
                              ? null
                              : () =>
                                    Navigator.pop(context, textOf(node['id'])),
                          subtitle: textOf(node['publicKey']).isEmpty
                              ? null
                              : Row(
                                  children: [
                                    Expanded(
                                      child: InkWell(
                                        onTap: () => showDialog<void>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: Text(tr('Public key')),
                                            content: SelectableText(
                                              textOf(node['publicKey']),
                                              style: const TextStyle(
                                                fontFamily: 'JetBrainsMono',
                                                fontSize: 12,
                                              ),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(context),
                                                child: Text(tr('Close')),
                                              ),
                                            ],
                                          ),
                                        ),
                                        child: Text(
                                          _keyPreview(
                                            textOf(node['publicKey']),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'JetBrainsMono',
                                            fontSize: 11,
                                            color: palette.muted,
                                          ),
                                        ),
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
          ],
        ),
      ),
    );
  }

  String _keyPreview(String key) => key.length > 24
      ? '${key.substring(0, 12)}…${key.substring(key.length - 8)}'
      : key;
}

/// Observation hashes live in pathBytes; resolvedPath carries only candidate data.
class PacketPathHops extends StatelessWidget {
  const PacketPathHops({
    super.key,
    required this.observation,
    required this.onOpen,
  });
  final Json observation;
  final void Function(String, String) onOpen;

  @override
  Widget build(BuildContext context) {
    final raw = textOf(observation['pathBytes']);
    final width =
        (number(object(observation['pathLength'])['hashSize'])?.toInt() ?? 1)
            .clamp(1, 3) *
        2;
    final resolved = rows(observation['resolvedPath']);
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (var offset = 0; offset < raw.length; offset += width)
          PathHopChip(
            hash: raw.substring(offset, (offset + width).clamp(0, raw.length)),
            hop: offset ~/ width < resolved.length
                ? resolved[offset ~/ width]
                : const {},
            onOpen: onOpen,
          ),
      ],
    );
  }
}
