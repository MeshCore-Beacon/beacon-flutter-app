import 'package:flutter/material.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'map_data.dart';
import 'map_screen.dart';

/// Native packet investigation map. Pass the complete GET /packets/{id}
/// response; onOpen receives `node` and the selected resolved node UUID.
class PacketPathScreen extends StatefulWidget {
  const PacketPathScreen({
    super.key,
    required this.detail,
    required this.onOpen,
    this.initialPathKey,
  });
  final Map<String, dynamic> detail;
  final String? initialPathKey;
  final void Function(String kind, String id) onOpen;
  @override
  State<PacketPathScreen> createState() => _PacketPathScreenState();
}

class _PacketPathScreenState extends State<PacketPathScreen> {
  String? _selected;
  @override
  void initState() {
    super.initState();
    _selected =
        packetPaths(widget.detail).any((p) => p['key'] == widget.initialPathKey)
        ? widget.initialPathKey
        : null;
  }

  String _style = 'dark';
  String? _error;
  @override
  Widget build(BuildContext context) {
    final paths = packetPaths(widget.detail),
        data = pathFeatures(paths, _selected);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Packet path'))),
      body: paths.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr(
                    'No unambiguous located path is available for this packet.',
                  ),
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: DropdownButton<String>(
                            dropdownColor: BeaconColors.of(context).surface,
                            style: TextStyle(
                              fontFamily: 'JetBrainsMono',
                              fontSize: 12,
                              color: BeaconColors.of(context).normal,
                            ),
                            isExpanded: true,
                            value: _selected ?? '',
                            items: [
                              DropdownMenuItem(
                                value: '',
                                child: Text(tr('All paths')),
                              ),
                              ...paths.map(
                                (p) => DropdownMenuItem(
                                  value: textOf(p['key']),
                                  child: Text(
                                    '${textOf(p['label'])}${p['propagationMs'] == null ? '' : ' · ${p['propagationMs']} ms'}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (v) =>
                                setState(() => _selected = v == '' ? null : v),
                          ),
                        ),
                        const SizedBox(width: 12),
                        DropdownButton<String>(
                          dropdownColor: BeaconColors.of(context).surface,
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 12,
                            color: BeaconColors.of(context).normal,
                          ),
                          value: _style,
                          items: [
                            DropdownMenuItem(
                              value: 'dark',
                              child: Text(tr('Dark')),
                            ),
                            DropdownMenuItem(
                              value: 'liberty',
                              child: Text(tr('Liberty')),
                            ),
                            DropdownMenuItem(
                              value: 'positron',
                              child: Text(tr('Light')),
                            ),
                          ],
                          onChanged: (v) => setState(() => _style = v!),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: NativeMap(
                    fitPoints: true,
                    style: _style,
                    points: object(data['points']),
                    lines: object(data['lines']),
                    borders: collection([]),
                    onNode: (id) => widget.onOpen('node', id),
                    onError: (e) {
                      if (mounted) setState(() => _error = e);
                    },
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!),
                  ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    tr('Lines break at ambiguous or unlocated hops.'),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
    );
  }
}
