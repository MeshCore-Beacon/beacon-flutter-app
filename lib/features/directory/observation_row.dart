import 'package:flutter/material.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../packets/packet_model.dart';
import '../packets/packet_screen.dart' show PacketBadge;

class ObservationRow extends StatelessWidget {
  const ObservationRow({
    super.key,
    required this.observation,
    required this.timestamp,
    required this.onOpen,
  });
  final Json observation;
  final String timestamp;
  final void Function(String, String) onOpen;

  @override
  Widget build(BuildContext context) {
    final o = observation;
    final c = BeaconColors.of(context);
    final name = textOf(o['payloadTypeName']).toUpperCase();
    final type =
        number(o['payloadType'])?.toInt() ??
        switch (name) {
          'ADVERT' => 4,
          'GROUP_TEXT' || 'GRP_TXT' => 5,
          'GROUP_DATA' || 'GRP_DATA' => 6,
          'TRACE' => 9,
          _ => 0,
        };
    final snr = number(o['snr']);
    final signal = snr == null
        ? c.muted
        : snr >= 10
        ? c.success
        : snr >= 5
        ? c.warning
        : c.danger;
    final hash = textOf(o['packetHash']);
    final nodeName = textOf(o['nodeName']);
    Widget metric(String label, dynamic value, String unit, Color color) =>
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(label),
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 9,
                  color: c.muted,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value == null ? '-' : '$value$unit',
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  color: color,
                ),
              ),
            ],
          ),
        );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: hash.isEmpty
                ? null
                : () => onOpen(
                    'packet',
                    '$hash${o['id'] == null ? '' : ':${o['id']}'}',
                  ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 5,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            PacketBadge(
                              label: name.isEmpty
                                  ? payloadName(o['payloadType'])
                                  : name,
                              type: type,
                            ),
                            if (textOf(o['iata']).isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: c.primary.withValues(alpha: .08),
                                  border: Border.all(
                                    color: c.primary.withValues(alpha: .25),
                                  ),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  textOf(o['iata']),
                                  style: TextStyle(
                                    fontFamily: 'JetBrainsMono',
                                    fontSize: 10,
                                    color: c.primary,
                                  ),
                                ),
                              ),
                            Tooltip(
                              message: timestamp,
                              child: Text(
                                age(o['heardAt']),
                                style: TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 10,
                                  color: c.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (hash.isNotEmpty)
                        Icon(Icons.chevron_right, size: 17, color: c.primary),
                    ],
                  ),
                  if (nodeName.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Text(
                        nodeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 12,
                          color: c.primary,
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      metric('RSSI', o['rssi'], ' dBm', c.normal),
                      metric('SNR', o['snr'], ' dB', signal),
                      metric('Hops', o['hopCount'], '', c.normal),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (textOf(o['observerId']).isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => onOpen('observer', textOf(o['observerId'])),
                icon: const Icon(Icons.sensors, size: 14),
                label: Text(
                  textOf(o['observerName'], shortKey(o['observerId'])),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
