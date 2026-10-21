import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

String hexBytes(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
List<int> keyBytes(String hex) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
    throw const FormatException('Invalid public key');
  }
  return [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

ByteData dataBytes(List<int> bytes) =>
    ByteData.sublistView(Uint8List.fromList(bytes));

class CompanionFrames {
  final _buffer = <int>[];
  List<List<int>> add(List<int> bytes) {
    if (_buffer.length + bytes.length > 65536) {
      throw const FormatException('Oversized companion stream');
    }
    _buffer.addAll(bytes);
    final result = <List<int>>[];
    var offset = 0;
    while (_buffer.length - offset >= 3) {
      // MeshMapper-compatible resynchronization without repeated buffer copying.
      final marker = _buffer.indexOf(62, offset);
      if (marker < 0) {
        offset = _buffer.length;
        break;
      }
      offset = marker;
      if (_buffer.length - offset < 3) break;
      final length = _buffer[offset + 1] | (_buffer[offset + 2] << 8);
      if (length < 1 || length > 300) {
        offset++;
        continue;
      }
      if (_buffer.length - offset < length + 3) break;
      result.add(_buffer.sublist(offset + 3, offset + 3 + length));
      offset += length + 3;
    }
    _buffer.removeRange(0, offset);
    return result;
  }
}

class CompanionContact {
  CompanionContact(this.key, this.name, this.type, this.hops, this.path);
  factory CompanionContact.parse(List<int> bytes) {
    if (bytes.length < 148 || bytes[0] != 3) {
      throw const FormatException('Truncated contact');
    }
    final encoded = bytes[35];
    final hops = encoded == 255 ? null : encoded & 63;
    final width = (encoded >> 6) + 1;
    if (hops != null && (width > 3 || hops * width > 64)) {
      throw const FormatException('Invalid contact path');
    }
    return CompanionContact(
      hexBytes(bytes.sublist(1, 33)),
      utf8.decode(
        bytes.sublist(100, 132).takeWhile((b) => b != 0).toList(),
        allowMalformed: true,
      ),
      bytes[33],
      hops,
      hops == null ? [] : bytes.sublist(36, 36 + hops * width),
    );
  }
  final String key, name;
  final int type;
  final int? hops;
  final List<int> path;
}

class TelemetrySample {
  TelemetrySample(this.values, this.sensors);
  final Map<String, num> values;
  final List<Map<String, dynamic>> sensors;
}

TelemetrySample parseTelemetry(List<int> bytes) {
  final values = <String, num>{};
  final sensors = <Map<String, dynamic>>[];
  final seen = <String>{};
  const skippedSizes = {0: 1, 1: 1, 2: 2, 3: 2, 102: 1, 113: 6, 134: 6, 136: 9};
  for (var i = 0; i < bytes.length;) {
    if (i + 2 > bytes.length) {
      throw const FormatException('Truncated telemetry');
    }
    final channel = bytes[i++], type = bytes[i++];
    final size = type == 104
        ? 1
        : [101, 103, 115, 116].contains(type)
        ? 2
        : skippedSizes[type];
    if (size == null || i + size > bytes.length) {
      throw const FormatException('Unsupported or truncated telemetry');
    }
    final data = dataBytes(bytes.sublist(i, i + size));
    i += size;
    if (skippedSizes.containsKey(type)) {
      continue; // Never upload GPS, raw packets or unspecified fields.
    }
    final (kind, unit, value, minimum, maximum) = switch (type) {
      101 => ('illuminance', 'lux', data.getUint16(0).toDouble(), 0, 200000),
      103 => ('temperature', 'C', data.getInt16(0) / 10, -100, 200),
      104 => ('humidity', '%', data.getUint8(0) / 2, 0, 100),
      115 => ('pressure', 'hPa', data.getUint16(0) / 10, 100, 2000),
      116 => ('voltage', 'V', data.getUint16(0) / 100, 0, 100),
      _ => throw const FormatException('Unknown sensor'),
    };
    if (!value.isFinite ||
        value < minimum ||
        value > maximum ||
        !seen.add('$channel/$kind') ||
        sensors.length >= 32) {
      throw const FormatException('Invalid or duplicate telemetry measurement');
    }
    sensors.add({
      'channel': channel,
      'kind': kind,
      'value': value,
      'unit': unit,
    });
    if (channel == 1 && type == 116 && value > 0) {
      values['batteryMv'] = (value * 1000).round();
    }
  }
  return TelemetrySample(values, sensors);
}

Map<String, num> parseStatus(List<int> bytes) {
  if (bytes.length < 52) throw const FormatException('Truncated status');
  final b = dataBytes(bytes);
  final values = <String, num>{
    'queueLength': b.getUint16(2, Endian.little),
    'noiseFloorDbm': b.getInt16(4, Endian.little),
    'lastRssiDbm': b.getInt16(6, Endian.little),
    'receivedPackets': b.getUint32(8, Endian.little),
    'sentPackets': b.getUint32(12, Endian.little),
    'uptimeSeconds': b.getUint32(20, Endian.little),
    'lastSnrDb': b.getInt16(42, Endian.little) / 4,
  };
  final battery = b.getUint16(0, Endian.little);
  if (battery > 0) values['batteryMv'] = battery;
  if (values['noiseFloorDbm']! < -200 ||
      values['noiseFloorDbm']! > 0 ||
      values['lastRssiDbm']! < -200 ||
      values['lastRssiDbm']! > 0 ||
      values['lastSnrDb']!.abs() > 50) {
    throw const FormatException('Invalid repeater status');
  }
  return values;
}

/// Exclusive companion connection. No automatic RF retries or key-export command.
class Companion {
  factory Companion(Socket socket) {
    final decoder = CompanionFrames();
    return Companion.frames(
      socket.expand(decoder.add),
      (command) async {
        socket.add([60, command.length & 255, command.length >> 8, ...command]);
        await socket.flush();
      },
      () async {
        socket.destroy();
      },
    );
  }

  /// BLE supplies one complete frame per notification; TCP uses [CompanionFrames].
  Companion.frames(Stream<List<int>> frames, this._write, this._disconnect) {
    _subscription = frames.listen(
      (frame) {
        if (frame.isEmpty || frame.length > 300) {
          if (_frames.hasListener) {
            _frames.addError(const FormatException('Invalid companion frame'));
          }
          unawaited(close());
        } else {
          _frames.add(frame);
        }
      },
      onError: (Object error) {
        if (_frames.hasListener) _frames.addError(error);
        unawaited(close());
      },
      onDone: close,
    );
  }
  static Future<Companion> connect(String host, int port) async {
    if (port < 1 || port > 65535) {
      throw const FormatException('Invalid companion port');
    }
    final addresses = await InternetAddress.lookup(host.trim())
        .timeout(const Duration(seconds: 8));
    // MeshCore TCP has no transport authentication. Restrict it to a trusted LAN.
    bool local(InternetAddress a) {
      final b = a.rawAddress;
      return a.isLoopback ||
          (b.length == 4 &&
              (b[0] == 10 ||
                  (b[0] == 192 && b[1] == 168) ||
                  (b[0] == 172 && b[1] >= 16 && b[1] <= 31))) ||
          (b.length == 16 && (b[0] & 0xfe) == 0xfc);
    }

    if (addresses.isEmpty || addresses.any((a) => !local(a))) {
      throw const FormatException('Use a companion on a private, trusted LAN');
    }
    // Ownership transfers to Companion; close() destroys this socket.
    // ignore: close_sinks
    final socket = await Socket.connect(
      addresses.first,
      port,
      timeout: const Duration(seconds: 10),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    return Companion(socket);
  }

  final Future<void> Function(List<int>) _write;
  final Future<void> Function() _disconnect;
  final _frames = StreamController<List<int>>.broadcast(sync: true);
  late final StreamSubscription<List<int>> _subscription;
  bool closed = false, _busy = false;
  Future<void>? _closing;
  final _closed = Completer<void>();
  Future<void> get whenClosed => _closed.future;
  String? radioKey;

  Future<void> close() {
    if (_closing != null) return _closing!;
    if (!_closed.isCompleted) _closed.complete();
    closed = true;
    return _closing = () async {
      try {
        await _subscription.cancel();
        await _disconnect();
      } finally {
        unawaited(_frames.close());
      }
    }();
  }

  Future<T> exchange<T>(
    List<int> command,
    T? Function(List<int>) consume, {
    Duration timeout = const Duration(seconds: 12),
    Duration? silenceTimeout,
    List<int>? followup,
  }) async {
    if (closed || _busy) throw StateError('Companion unavailable or busy');
    if (command.length > 172 || (followup?.length ?? 0) > 172) {
      throw const FormatException('Command exceeds MeshCore frame size');
    }
    _busy = true;
    final done = Completer<T>();
    Timer? silence;
    void armSilenceTimeout() {
      if (silenceTimeout == null) return;
      silence?.cancel();
      silence = Timer(silenceTimeout, () {
        if (!done.isCompleted) {
          done.completeError(
            TimeoutException('Companion response stream stopped'),
          );
        }
      });
    }

    final subscription = _frames.stream.listen(
      (frame) {
        if (done.isCompleted) return;
        armSilenceTimeout();
        try {
          if (frame[0] == 1) throw StateError('Companion rejected the command');
          final value = consume(frame);
          if (value != null) done.complete(value);
        } catch (e, s) {
          done.completeError(e, s);
        }
      },
      onError: (Object e, StackTrace s) {
        if (!done.isCompleted) done.completeError(e, s);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.completeError(StateError('Companion disconnected'));
        }
      },
    );
    try {
      armSilenceTimeout();
      final results = await Future.wait<Object?>([
        () async {
          await _write(command);
          if (followup != null) {
            if (closed) throw StateError('Companion disconnected');
            await _write(followup);
          }
          return null;
        }(),
        done.future,
      ], eagerError: true).timeout(timeout);
      return results.last as T;
    } catch (_) {
      // A late ACK must not satisfy the next command after a failed exchange.
      await close();
      rethrow;
    } finally {
      silence?.cancel();
      await subscription.cancel();
      _busy = false;
    }
  }

  Future<List<int>> request(List<int> command, int response) =>
      exchange(command, (frame) => frame[0] == response ? frame : null);

  Future<String> identify() async {
    // Match MeshMapper's two exchanges: DEVICE_QUERY plus a wake-up APP_START,
    // followed by a fresh SELF_INFO request. Some BLE radios don't retain both
    // responses to the first pair; requiring both from that pair times out.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final appStart = [
      1,
      1,
      ...List.filled(6, 0),
      ...utf8.encode('Beacon telemetry'),
    ];
    await exchange<bool>(
      [22, 4],
      (frame) => frame[0] == 13 && frame.length >= 2 ? true : null,
      followup: appStart,
    );
    final identity = await request(appStart, 5);
    if (identity.length < 36) {
      throw const FormatException('Truncated companion identity');
    }
    return radioKey = hexBytes(identity.sublist(4, 36));
  }

  Future<List<CompanionContact>> contacts() async {
    final result = <CompanionContact>[];
    var started = false;
    return exchange(
      [4],
      (frame) {
        if (frame[0] == 2) started = true;
        if (started && frame[0] == 3) {
          if (result.length >= 4096) {
            throw const FormatException('Too many contacts');
          }
          result.add(CompanionContact.parse(frame));
        }
        return started && frame[0] == 4 ? result : null;
      },
      timeout: const Duration(minutes: 2),
      silenceTimeout: const Duration(seconds: 5),
    );
  }

  Future<CompanionContact> contact(String key) async {
    final value = CompanionContact.parse(
      await request([30, ...keyBytes(key)], 3),
    );
    if (value.key != key) {
      throw const FormatException('Contact identity changed');
    }
    return value;
  }

  Future<void> resetPath(String key) async {
    await request([13, ...keyBytes(key)], 0);
  }

  Future<List<int>> sign(List<int> message) async {
    final start = await request([33], 19);
    if (start.length != 6 ||
        message.length > dataBytes(start).getUint32(2, Endian.little)) {
      throw const FormatException('Companion cannot sign this challenge');
    }
    for (var offset = 0; offset < message.length; offset += 128) {
      await request([34, ...message.skip(offset).take(128)], 0);
    }
    final signature = await request([35], 20);
    if (signature.length != 65) {
      throw const FormatException('Invalid device signature');
    }
    return signature.sublist(1);
  }

  Future<void> login(
    String key,
    String password, {
    required bool requireAdmin,
  }) async {
    final bytes = utf8.encode(password);
    if (bytes.length > 15 || bytes.contains(0)) {
      throw const FormatException('Password must be at most 15 UTF-8 bytes');
    }
    final prefix = key.substring(0, 12);
    bool sent = false;
    List<int>? reply;
    await exchange<bool>([26, ...keyBytes(key), ...bytes], (frame) {
      if (frame[0] == 6 && frame.length >= 10) sent = true;
      if ((frame[0] == 0x85 || frame[0] == 0x86) &&
          frame.length >= 8 &&
          hexBytes(frame.sublist(2, 8)) == prefix) {
        reply = frame;
      }
      if (!sent || reply == null) return null;
      if (reply![0] == 0x86 || (requireAdmin && (reply![1] & 1) == 0)) {
        throw StateError('Repeater login or requested admin permission failed');
      }
      return true;
    }, timeout: const Duration(seconds: 60));
  }

  Future<List<int>> binary(String key, int type) async {
    String? tag;
    final early = <String, List<int>>{};
    return exchange(
      [
        50,
        ...keyBytes(key),
        type,
        if (type == 3) ...[0, 0, 0, 0],
      ],
      (frame) {
        if (frame[0] == 6 && frame.length >= 10) {
          tag = hexBytes(frame.sublist(2, 6));
        }
        if (frame[0] == 0x8c && frame.length >= 6) {
          if (early.length >= 16) {
            throw const FormatException('Too many unmatched replies');
          }
          early[hexBytes(frame.sublist(2, 6))] = frame.sublist(6);
        }
        return tag == null ? null : early[tag];
      },
      timeout: const Duration(seconds: 60),
    );
  }

  Future<({int queue, int uptime, int tx, int rx})> stats() async {
    final core = await exchange([
      56,
      0,
    ], (f) => f[0] == 24 && f.length >= 11 && f[1] == 0 ? f : null);
    final radio = await exchange([
      56,
      1,
    ], (f) => f[0] == 24 && f.length >= 14 && f[1] == 1 ? f : null);
    final c = dataBytes(core), r = dataBytes(radio);
    return (
      queue: core[10],
      uptime: c.getUint32(4, Endian.little),
      tx: r.getUint32(6, Endian.little),
      rx: r.getUint32(10, Endian.little),
    );
  }
}
