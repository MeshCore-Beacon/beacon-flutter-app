import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';

String observerUptime(num seconds) {
  final minutes = seconds ~/ 60;
  final days = minutes ~/ 1440;
  final hours = minutes ~/ 60 % 24;
  return [
    if (days > 0) '${days}d',
    if (days > 0 || hours > 0) '${hours}h',
    '${minutes % 60}m',
  ].join(' ');
}

class ObserverInfo extends StatelessWidget {
  const ObserverInfo({super.key, required this.data});
  final Json data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final beacon = BeaconColors.of(context);
    final key = textOf(data['publicKey']);
    final firmware = textOf(data['firmwareVersion']);
    final software = textOf(data['softwareVersion']);
    final radio = [
      if (number(data['radioFreqMhz']) case final num value when value > 0)
        '$value MHz',
      if (number(data['radioSf']) case final num value when value > 0)
        'SF${value.toInt()}',
      if (number(data['radioBwKhz']) case final num value when value > 0)
        '$value kHz',
      if (number(data['radioCr']) case final num value when value > 0)
        'CR 4/${value.toInt()}',
    ].join(' · ');
    final device = <String, String>{
      'Hardware': textOf(data['hardwareModel']),
      'Firmware': firmware,
      if (software != firmware &&
          (firmware.isEmpty || !software.contains(firmware)))
        'Software': software,
      if (!firmware.contains(textOf(data['firmwareBuild'])))
        'Build': textOf(data['firmwareBuild']),
      'Radio': radio,
      if (textOf(data['observerType']) != software)
        'Type': textOf(data['observerType']),
    }..removeWhere((_, value) => value.isEmpty);
    String absolute(dynamic value) =>
        epoch(value)?.toLocal().toString() ?? tr('Unknown');
    final brokers = rows(data['brokers'])
      ..sort((a, b) => textOf(a['name']).compareTo(textOf(b['name'])));
    Widget badge(String value, {String? hint}) => Tooltip(
      message: hint ?? value,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: beacon.raised.withValues(alpha: .45),
          border: Border.all(color: beacon.borderSubtle),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          value,
          style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11),
        ),
      ),
    );
    Widget row(String label, Widget value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              tr(label),
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ),
          Expanded(child: value),
        ],
      ),
    );
    Widget time(dynamic value) => Tooltip(
      message: epoch(value)?.toLocal().toString() ?? tr('Unknown'),
      child: Text(
        age(value),
        style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11),
      ),
    );
    final status = textOf(data['status'], 'Unknown');
    final statusColor = status == 'online' ? beacon.success : beacon.muted;
    final metrics = <(String, String)>[
      if (data['observationCount'] != null)
        ('Observations', '${data['observationCount']}'),
      ('Last seen', age(data['lastSeen'])),
      if (number(data['batteryLevel']) case final num value)
        ('Battery', '${value.toStringAsFixed(2)} V'),
      if (number(data['uptimeSeconds']) case final num value)
        ('Uptime', observerUptime(value)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: .10),
                      border: Border.all(
                        color: statusColor.withValues(alpha: .32),
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 7, color: statusColor),
                        const SizedBox(width: 5),
                        Text(
                          tr(switch (status) {
                            'online' => 'Online',
                            'offline' => 'Offline',
                            _ => status,
                          }).toUpperCase(),
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: statusColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (textOf(data['iata']).isNotEmpty)
                    badge(textOf(data['iata']), hint: tr('Observer region')),
                ],
              ),
              const SizedBox(height: 6),
              if (device.isNotEmpty)
                row(
                  'Device',
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      for (final item in device.entries)
                        badge(item.value, hint: tr(item.key)),
                    ],
                  ),
                ),
              if (key.isNotEmpty)
                row(
                  'Public key',
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(tr('Public key')),
                              content: SingleChildScrollView(
                                child: SelectableText(key),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: Text(tr('Close')),
                                ),
                              ],
                            ),
                          ),
                          child: Text(
                            key.length > 18
                                ? '${key.substring(0, 8)}…${key.substring(key.length - 7)}'
                                : key,
                            style: TextStyle(
                              fontFamily: 'JetBrainsMono',
                              fontSize: 11,
                              color: colors.primary,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: tr('Copy public key'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.copy, size: 15),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: key));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(tr('Copied'))),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
              if (brokers.isNotEmpty)
                row(
                  'Brokers',
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      for (final broker in brokers)
                        Tooltip(
                          message:
                              '${tr('Last seen')}: ${absolute(broker['lastSeenAt'])}\n${tr('Last packet')}: ${absolute(broker['lastPacketAt'])}',
                          child: Text(
                            '${broker['name']}  ${age(broker['lastSeenAt'])}',
                            style: const TextStyle(
                              fontFamily: 'JetBrainsMono',
                              fontSize: 11,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (data['firstSeen'] != null)
                row('First seen', time(data['firstSeen'])),
              if (data['scopes'] is List && (data['scopes'] as List).isNotEmpty)
                row(
                  'Scopes',
                  Wrap(
                    spacing: 5,
                    runSpacing: 4,
                    children: [
                      for (final scope in data['scopes'] as List)
                        badge('$scope'),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final (label, value) in metrics)
                Container(
                  width: (constraints.maxWidth - 10) / 2,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: beacon.raised.withValues(alpha: .25),
                    border: Border.all(color: beacon.borderSubtle),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Column(
                    children: [
                      Text(
                        tr(label).toUpperCase(),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 10,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        value,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
