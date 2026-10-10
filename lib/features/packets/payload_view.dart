import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'path_hop.dart';

class PacketByteRange {
  const PacketByteRange(this.start, this.end);
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is PacketByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Byte offsets in the complete frame, matching the web analyzer's field ranges.
Map<String, PacketByteRange> computeFieldRanges(Json detail, Json observation) {
  final payload = object(detail['parsedPayload']);
  final transport = object(detail['transportCodes']);
  final rawPayload = textOf(detail['rawPayload']);
  final totalBytes =
      rawPayload.length ~/ 2 +
      1 +
      (transport.isEmpty ? 0 : 4) +
      (observation.isEmpty
          ? 0
          : 1 + textOf(observation['pathBytes']).length ~/ 2);
  final ranges = <String, PacketByteRange>{
    'header': const PacketByteRange(0, 1),
  };
  var offset = 1;
  if (transport.isNotEmpty) {
    ranges['transport'] = PacketByteRange(offset, offset + 4);
    offset += 4;
  }
  if (observation.isNotEmpty) {
    ranges['pathLength'] = PacketByteRange(offset, offset + 1);
    offset++;
    final pathBytes = textOf(observation['pathBytes']).length ~/ 2;
    if (pathBytes > 0) {
      ranges['pathData'] = PacketByteRange(offset, offset + pathBytes);
    }
    offset += pathBytes;
  }
  final payloadStart = offset;
  if (offset < totalBytes && rawPayload.isNotEmpty) {
    ranges['payload'] = PacketByteRange(offset, totalBytes);
  }
  if (rawPayload.isEmpty || payload.isEmpty) return ranges;

  void add(String name, int start, int end) {
    final a = start.clamp(0, totalBytes);
    final b = end.clamp(a, totalBytes);
    if (a < b) ranges[name] = PacketByteRange(a, b);
  }

  int byteLength(dynamic value) => value is String ? value.length ~/ 2 : 0;
  var cursor = payloadStart;
  final typeCode = number(object(detail['header'])['payloadType'])?.toInt();
  if (typeCode == 4 && payload['publicKey'] is String) {
    final keyLength = byteLength(payload['publicKey']);
    add('publicKey', cursor, cursor + keyLength);
    cursor += keyLength;
    add('advertTimestamp', cursor, cursor + 4);
    cursor += 4;
    final signatureLength = payload['signature'] is String
        ? byteLength(payload['signature'])
        : 64;
    add('signature', cursor, cursor + signatureLength);
    cursor += signatureLength;
    final flagsOffset = keyLength + 4 + signatureLength;
    final flagsHex = rawPayload.length >= (flagsOffset + 1) * 2
        ? rawPayload.substring(flagsOffset * 2, flagsOffset * 2 + 2)
        : '';
    final rawFlags = int.tryParse(flagsHex, radix: 16) ?? 0;
    add('flags', cursor, cursor + 1);
    cursor++;
    if ((rawFlags & 0x10) != 0) {
      add('location', cursor, cursor + 8);
      cursor += 8;
    }
    if ((rawFlags & 0x20) != 0) cursor += 2;
    if ((rawFlags & 0x40) != 0) cursor += 2;
    if ((rawFlags & 0x80) != 0) add('advertName', cursor, totalBytes);
  } else if (typeCode == 7 && payload['ephemeralPubKey'] is String) {
    add('destinationHash', cursor, cursor + 1);
    cursor++;
    final keyLength = byteLength(payload['ephemeralPubKey']);
    add('senderPublicKey', cursor, cursor + keyLength);
    cursor += keyLength;
    add('cipherMac', cursor, cursor + 2);
    cursor += 2;
    add('ciphertext', cursor, totalBytes);
  } else if (typeCode == 9 && payload['traceTag'] is String) {
    final tagLength = byteLength(payload['traceTag']);
    if (tagLength > 0) {
      add('traceTag', cursor, cursor + tagLength);
      cursor += tagLength;
      add('authCode', cursor, cursor + 4);
      cursor += 4;
      add('flags', cursor, cursor + 1);
      cursor++;
      add('tracePath', cursor, totalBytes);
    }
  } else {
    final keys = payload['checksum'] != null
        ? const ['checksum']
        : payload['senderPublicKey'] != null
        ? const [
            'destinationHash',
            'senderPublicKey',
            'cipherMac',
            'ciphertext',
          ]
        : payload['destinationHash'] != null || payload['sourceHash'] != null
        ? const ['destinationHash', 'sourceHash', 'cipherMac', 'ciphertext']
        : payload['channelHash'] != null
        ? const ['channelHash', 'cipherMac', 'ciphertext']
        : const <String>[];
    for (final key in keys) {
      final length = byteLength(payload[key]);
      if (length == 0) break;
      add(key, cursor, cursor + length);
      cursor += length;
    }
  }
  return ranges;
}

/// Typed packet payload details, including encrypted envelopes and endpoint links.
class PacketPayloadView extends StatelessWidget {
  const PacketPayloadView({
    super.key,
    required this.detail,
    required this.observation,
    required this.onOpen,
  });

  final Json detail;
  final Json observation;
  final void Function(String, String) onOpen;

  @override
  Widget build(BuildContext context) {
    final payload = object(detail['parsedPayload']);
    if (payload.isEmpty) return Text(tr('No decoded payload available.'));
    final type = textOf(payload['type']);
    switch (type) {
      case 'ADVERT':
        return _advert(context, payload);
      case 'TRACE':
      case 'PING':
        return _trace(payload);
      case 'GROUP_TEXT':
      case 'GROUP_DATA':
        return _group(payload);
      case 'TEXT_MESSAGE':
      case 'REQUEST':
      case 'RESPONSE':
      case 'PATH':
        return _envelope(type, payload);
      case 'ANON_REQUEST':
        return _anon(payload);
      case 'ACK':
        return _fields([_field('Checksum', payload['checksum'])]);
      default:
        return _unknown(payload);
    }
  }

  Widget _advert(BuildContext context, Json payload) {
    final app = object(payload['appData']);
    final flags = object(app['flags']);
    final location = app['latitude'] != null && app['longitude'] != null
        ? '${app['latitude']}, ${app['longitude']}'
        : null;
    final rawFlagsText = flags['raw'];
    final rawFlags = rawFlagsText is String
        ? int.tryParse(rawFlagsText, radix: 16)
        : null;
    const roles = {1: 'ChatNode', 2: 'Repeater', 3: 'RoomServer', 4: 'Sensor'};
    final roleValue = rawFlags == null ? null : rawFlags & 0x0f;
    final role = roleValue == null
        ? tr('Unknown')
        : roles[roleValue] ?? '0x${roleValue.toRadixString(16).toUpperCase()}';
    final key = payload['publicKey'];
    final signature = payload['signature'];
    final name = app['name'];
    final timestamp = payload['timestamp'];
    return _fields([
      if (key is String) _longHexField(context, tr('Public key'), key),
      if (timestamp != null) _advertTimestamp(context, timestamp),
      if (signature is String)
        _longHexField(context, tr('Signature'), signature),
      if (rawFlags != null) _advertFlags(context, rawFlags, role),
      if (location != null)
        _inlineField(
          tr('Location'),
          '${_coordinate(app['latitude'])}, ${_coordinate(app['longitude'])} (8B LE)',
        ),
      if (name is String)
        _inlineField(tr('Name'), '$name (${utf8.encode(name).length}B UTF-8)'),
      for (final feature in ['feature1', 'feature2'])
        if (app[feature] != null)
          _inlineField(_label(feature), app[feature].toString()),
    ]);
  }

  Widget _advertFlags(BuildContext context, int rawFlags, String role) {
    final colors = Theme.of(context).colorScheme;
    final appBits = [
      for (final mask in [0x10, 0x20, 0x40, 0x80]) (rawFlags & mask) != 0,
    ];
    final segments = [
      (
        (rawFlags & 0x0f).toRadixString(2).padLeft(4, '0'),
        role,
        BeaconColors.of(context).warning,
      ),
      for (var i = 0; i < appBits.length; i++)
        (
          appBits[i] ? '1' : '0',
          ['loc', 'f1', 'f2', 'name'][i],
          appBits[i]
              ? BeaconColors.of(context).success
              : colors.onSurfaceVariant,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr('App flags').toUpperCase(),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${tr('Role')} $role  ${tr('Loc')} ${tr(appBits[0] ? 'Yes' : 'No')}  F1 ${tr(appBits[1] ? 'Yes' : 'No')}  F2 ${tr(appBits[2] ? 'Yes' : 'No')}  ${tr('Name')} ${tr(appBits[3] ? 'Yes' : 'No')}',
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(
                  '0x${rawFlags.toRadixString(16).padLeft(2, '0').toUpperCase()} = [',
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                  ),
                ),
                for (final (bits, label, color) in segments)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        bits,
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
          ),
        ],
      ),
    );
  }

  Widget _advertTimestamp(BuildContext context, dynamic value) {
    final seconds = number(value);
    final stamp = _timestamp(value);
    final relative = seconds == null ? '' : _relativeTime(seconds);
    final raw = seconds == null ? null : _littleEndianTimestamp(seconds);
    return _inlineField(
      tr('Timestamp'),
      seconds == null ? textOf(value) : '$relative (4B LE)',
      context: context,
      onTap: () =>
          _showFullValue(context, tr('Timestamp'), [stamp, ?raw].join('\n')),
    );
  }

  String _relativeTime(num seconds) => age(seconds * 1000);

  String _littleEndianTimestamp(num seconds) {
    final value = seconds.toInt() & 0xffffffff;
    final bytes = List.generate(4, (i) => (value >> (i * 8)) & 0xff);
    return '${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ')} LE';
  }

  String _coordinate(dynamic value) =>
      number(value)?.toStringAsFixed(6) ?? textOf(value);

  Widget _longHexField(BuildContext context, String label, String value) {
    final compact = value.toUpperCase();
    final short = compact.length > 20
        ? '${compact.substring(0, 12)}…${compact.substring(compact.length - 8)}'
        : compact;
    return _inlineField(
      label,
      '$short (${value.length ~/ 2}B)',
      context: context,
      onTap: () => _showFullValue(context, label, compact),
    );
  }

  void _showFullValue(BuildContext context, String title, String value) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(value)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Close')),
          ),
        ],
      ),
    );
  }

  Widget _group(Json payload) {
    final decrypted = object(payload['decrypted']);
    return _fields([
      _field(tr('Channel'), payload['channelHash']),
      _field('MAC', payload['cipherMac']),
      _field(tr('Ciphertext'), _hexValue(payload['ciphertext'])),
      if (payload['ciphertextLength'] != null)
        _field(
          'Ciphertext length',
          trKey(
            'packetAnalyzer.bytes',
            count: (number(payload['ciphertextLength']) ?? 0).toInt(),
          ),
        ),
      if (decrypted.isEmpty)
        _status(tr('Encrypted'))
      else ...[
        _status(tr('Decrypted')),
        _field(tr('Sender'), decrypted['sender']),
        if (decrypted['content'] != null)
          _field(tr('Message'), decrypted['content']),
        if (decrypted['sentAt'] != null)
          _field(
            tr('Sent at'),
            _timestamp(decrypted['sentAt'], milliseconds: true),
          ),
        for (final entry in decrypted.entries.where(
          (e) => !{'sender', 'content', 'sentAt'}.contains(e.key),
        ))
          _field(_label(entry.key), entry.value),
      ],
    ]);
  }

  Widget _envelope(String type, Json payload) {
    final source = object(observation['resolvedSource']);
    final destination = object(observation['resolvedDestination']);
    final decrypted = object(payload['decrypted']);
    return _fields([
      _endpoint(tr('From'), payload['sourceHash'], source),
      _endpoint(tr('To'), payload['destinationHash'], destination),
      _field('MAC', payload['cipherMac']),
      _field(tr('Ciphertext'), _hexValue(payload['ciphertext'])),
      if (payload['ciphertextLength'] != null)
        _field(
          'Ciphertext length',
          trKey(
            'packetAnalyzer.bytes',
            count: (number(payload['ciphertextLength']) ?? 0).toInt(),
          ),
        ),
      if (decrypted.isEmpty)
        _status(tr('Encrypted'))
      else ...[
        _status(tr('Decrypted')),
        ..._decryptedFields(type, decrypted),
      ],
    ]);
  }

  List<Widget> _decryptedFields(String type, Json decrypted) {
    final known = <String>{};
    final fields = <Widget>[];
    void add(String key, String label, {bool timestamp = false}) {
      final value = decrypted[key];
      if (value == null) return;
      known.add(key);
      fields.add(
        _field(label, timestamp ? _timestamp(value) : _display(key, value)),
      );
    }

    switch (type) {
      case 'TEXT_MESSAGE':
        add('message', 'Message');
        add('timestamp', 'Timestamp', timestamp: true);
        add('attempt', 'Attempt');
        add('flags', 'Flags');
      case 'REQUEST':
        add('requestTypeName', 'Request type');
        add('requestData', 'Request data');
        add('timestamp', 'Timestamp', timestamp: true);
      case 'RESPONSE':
        add('tag', 'Tag');
        add('content', 'Message');
      case 'PATH':
        add('pathLength', 'Hops');
        add('pathHashSize', 'Hash size');
        add('pathHashes', 'Path');
        add('extraTypeName', 'Bundled type');
        add('extraData', 'Bundled data');
    }
    for (final entry in decrypted.entries.where(
      (e) => !known.contains(e.key),
    )) {
      fields.add(_field(_label(entry.key), _display(entry.key, entry.value)));
    }
    return fields;
  }

  Widget _anon(Json payload) => _fields([
    _endpoint(
      'Destination',
      payload['destination'] is num
          ? '0x${number(payload['destination'])!.toInt().toRadixString(16).padLeft(2, '0')}'
          : payload['destination'],
      object(observation['resolvedDestination']),
    ),
    _field('Ephemeral public key', payload['ephemeralPubKey']),
  ]);

  Widget _trace(Json payload) {
    final hashes = payload['pathHashes'] is List
        ? payload['pathHashes'] as List
        : const [];
    final route = rows(detail['resolvedRoute']);
    final snrs = payload['snrValues'] is List
        ? payload['snrValues'] as List
        : const [];
    return _fields([
      _field('Trace tag', payload['traceTag']),
      _field(
        'Auth code',
        payload['authCode'] == null
            ? null
            : '0x${number(payload['authCode'])?.toInt().toRadixString(16).toUpperCase()}',
      ),
      _field('Flags', payload['flags']),
      if (hashes.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('Trace path')),
              Wrap(
                spacing: 4,
                children: [
                  for (var i = 0; i < hashes.length; i++) ...[
                    if (i > 0) const Text('→'),
                    _resolvedHash(
                      textOf(hashes[i]),
                      i < route.length ? route[i] : const {},
                      snr: i < snrs.length ? snrs[i] : null,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
    ]);
  }

  Widget _unknown(Json payload) {
    final entries = payload.entries.where(
      (e) => e.key != 'type' && e.key != 'raw' && e.value != null,
    );
    return _fields([
      for (final entry in entries)
        _field(_label(entry.key), _display(entry.key, entry.value)),
    ]);
  }

  Widget _endpoint(String label, dynamic hash, Json resolved) {
    if (hash == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('$label '),
          PathHopChip(hash: _hashLabel(hash), hop: resolved, onOpen: onOpen),
        ],
      ),
    );
  }

  Widget _resolvedHash(String hash, Json resolved, {dynamic snr}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PathHopChip(hash: _hashLabel(hash), hop: resolved, onOpen: onOpen),
        if (snr != null) Text('$snr dB'),
      ],
    );
  }

  String _hashLabel(dynamic hash) => hash is num
      ? hash.toInt().toRadixString(16).padLeft(2, '0')
      : textOf(hash);

  Widget _status(String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        const Icon(Icons.lock_outline, size: 14),
        const SizedBox(width: 5),
        Text(tr(value)),
      ],
    ),
  );

  Widget _fields(List<Widget> fields) => DefaultTextStyle.merge(
    style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: fields.where((field) => field is! SizedBox).toList(),
    ),
  );

  Widget _field(String label, dynamic value) {
    if (value == null || value == '') return const SizedBox.shrink();
    return _inlineField(tr(label), value is String ? value : value.toString());
  }

  Widget _inlineField(
    String label,
    String value, {
    BuildContext? context,
    VoidCallback? onTap,
    Widget? trailing,
  }) => Builder(
    builder: (fieldContext) {
      final palette = BeaconColors.of(fieldContext);
      final accent =
          {
            tr('Public key'),
            tr('Location'),
            tr('Ephemeral public key'),
          }.contains(label)
          ? palette.success
          : {tr('Signature'), tr('From'), tr('Trace path')}.contains(label)
          ? palette.secondary
          : {
              tr('Timestamp'),
              tr('Channel'),
              tr('To'),
              tr('Trace tag'),
            }.contains(label)
          ? palette.primary
          : {tr('Checksum'), tr('Flags'), 'MAC'}.contains(label)
          ? palette.warning
          : label == tr('Ciphertext')
          ? palette.danger
          : palette.muted;
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.fromLTRB(8, 3, 0, 3),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: accent.withValues(alpha: .5), width: 2),
          ),
        ),
        child: Wrap(
          spacing: 5,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                color: palette.muted,
                fontFamily: 'JetBrainsMono',
                fontSize: 12,
              ),
            ),
            if (onTap == null)
              SelectableText(
                value,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 12,
                  color: palette.normal,
                ),
              )
            else
              InkWell(
                onTap: onTap,
                child: Text(
                  value,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                    color: accent,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ?trailing,
          ],
        ),
      );
    },
  );

  String _label(String key) => key
      .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m[1]}')
      .replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase());

  String _hexValue(dynamic value) {
    if (value is! String) return textOf(value);
    return value.toUpperCase();
  }

  String _display(String key, dynamic value) {
    if (value is List) return value.join(' · ');
    if (value is Map) {
      return value.entries
          .map((e) => '${_label(textOf(e.key))}: ${e.value}')
          .join(', ');
    }
    if (value is num &&
        (key.toLowerCase().contains('timestamp') || key == 'since') &&
        value > 1000000000 &&
        value < 10000000000) {
      return _timestamp(value);
    }
    return textOf(value);
  }

  String _timestamp(dynamic value, {bool milliseconds = false}) {
    final seconds = number(value);
    if (seconds == null) return textOf(value);
    return epoch(
          milliseconds ? seconds : seconds * 1000,
          isUtc: true,
        )?.toIso8601String() ??
        textOf(value);
  }
}
