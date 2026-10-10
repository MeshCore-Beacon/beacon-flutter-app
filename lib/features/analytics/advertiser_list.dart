import 'package:flutter/material.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'charts.dart';

class AdvertiserList extends StatelessWidget {
  const AdvertiserList({
    super.key,
    required this.nodes,
    required this.days,
    required this.onOpen,
  });
  final List<Json> nodes;
  final double days;
  final void Function(String, String) onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = BeaconColors.of(context);
    if (nodes.isEmpty) return const AnalyticsEmptyState();
    Widget chip(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        border: Border.all(color: color.withValues(alpha: .25)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 10,
          color: color,
        ),
      ),
    );
    Widget stat(String label, dynamic value, Color color) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                tr(label),
                style: TextStyle(fontSize: 10, color: colors.muted),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  countLabel(number(value)),
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 14,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            days > 0 && number(value) != null
                ? '${(number(value)! / days).toStringAsFixed(1)} / ${tr('day')}'
                : '—',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              color: colors.dim,
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < nodes.length; i++) ...[
          if (i > 0) Divider(height: 1, color: colors.borderSubtle),
          InkWell(
            onTap: textOf(nodes[i]['nodeId']).isEmpty
                ? null
                : () => onOpen('node', textOf(nodes[i]['nodeId'])),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          textOf(
                            nodes[i]['nodeName'],
                            shortKey(nodes[i]['publicKey']),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.primary,
                          ),
                        ),
                      ),
                      if (textOf(nodes[i]['nodeId']).isNotEmpty)
                        Icon(
                          Icons.chevron_right,
                          size: 17,
                          color: colors.muted,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (textOf(nodes[i]['nodeTypeName']).isNotEmpty)
                        chip(
                          textOf(nodes[i]['nodeTypeName']).replaceAll('_', ' '),
                          analyticsNodeColor(
                            textOf(nodes[i]['nodeTypeName']),
                            context,
                          ),
                        ),
                      if (textOf(nodes[i]['iata']).isNotEmpty)
                        chip(textOf(nodes[i]['iata']), colors.primary),
                    ],
                  ),
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      stat(
                        'Flood',
                        nodes[i]['floodAdvertCount'],
                        colors.secondary,
                      ),
                      stat(
                        'Direct',
                        nodes[i]['directAdvertCount'],
                        colors.primary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
