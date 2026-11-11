// Connection sequencing and GATT-busy policy follow MeshMapper (MIT).
// See docs/licenses/meshmapper-MIT.txt and docs/telemetry-sharing.md.
import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'companion.dart';

typedef BlePeer = ({String id, String name, int rssi});

Future<void> writeRetryingGattBusy(
  Future<void> Function() write, {
  Future<void> Function(Duration)? sleep,
}) async {
  const delays = [50, 100, 150];
  for (var attempt = 0; ; attempt++) {
    try {
      await write();
      return;
    } catch (e) {
      // This specific refusal means Android did not submit the write. Never
      // retry an ambiguous failure: a repeated command could cause extra RF.
      if (!e.toString().contains('ERROR_GATT_WRITE_REQUEST_BUSY') ||
          attempt >= delays.length) {
        rethrow;
      }
      await (sleep ?? Future<void>.delayed)(
        Duration(milliseconds: delays[attempt]),
      );
    }
  }
}

class BleCompanion {
  BleCompanion({
    BluetoothDevice Function(String)? device,
    bool? android,
    bool? ios,
  }) : _deviceFor = device ?? BluetoothDevice.fromId,
       _android = android ?? Platform.isAndroid,
       _ios = ios ?? Platform.isIOS;
  final BluetoothDevice Function(String) _deviceFor;
  final bool _android, _ios;
  static final service = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  static final rx = Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
  static final tx = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e');
  StreamSubscription<List<ScanResult>>? _scan;
  StreamSubscription<BluetoothConnectionState>? _connection;
  BluetoothDevice? _device;
  bool _closed = false, _scanning = false;

  Future<void> _permission() async {
    // The plugin defaults to debug logging; companion writes can contain passwords.
    if (_android || _ios) await FlutterBluePlus.setLogLevel(LogLevel.none);
    if (_android) {
      final version = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      final permissions = version >= 31
          ? [Permission.bluetoothScan, Permission.bluetoothConnect]
          : [Permission.locationWhenInUse];
      final result = await permissions.request();
      if (result.values.any((status) => !status.isGranted)) {
        throw StateError('Bluetooth permission is required');
      }
    } else if (_ios) {
      if (!(await Permission.bluetooth.request()).isGranted) {
        throw StateError('Bluetooth permission is required');
      }
    } else {
      throw UnsupportedError('BLE collection requires Android or iOS');
    }
    final status = await FlutterBluePlus.adapterState
        .where((s) => s != BluetoothAdapterState.unknown)
        .first
        .timeout(const Duration(seconds: 10));
    if (_closed || status != BluetoothAdapterState.on) {
      throw StateError('Bluetooth is not ready');
    }
  }

  Future<List<BlePeer>> scan() async {
    await _permission();
    if (FlutterBluePlus.isScanningNow) {
      throw StateError('Bluetooth scan already running');
    }
    final peers = <String, BlePeer>{};
    Object? error;
    _scan = FlutterBluePlus.onScanResults.listen(
      (results) {
        for (final r in results) {
          final id = r.device.remoteId.str;
          if (peers.length < 50 || peers.containsKey(id)) {
            peers[id] = (
              id: id,
              name: r.advertisementData.advName.isEmpty
                  ? r.device.platformName
                  : r.advertisementData.advName,
              rssi: r.rssi,
            );
          }
        }
      },
      onError: (Object e) {
        error = e;
      },
    );
    _scanning = true;
    try {
      await FlutterBluePlus.startScan(
        withServices: [service],
        timeout: const Duration(seconds: 8),
      );
      if (_closed) await FlutterBluePlus.stopScan();
      await FlutterBluePlus.isScanning
          .where((scanning) => !scanning)
          .first
          .timeout(const Duration(seconds: 12));
      if (error != null) throw StateError('Bluetooth scan failed');
      return _closed
          ? []
          : (peers.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi)));
    } finally {
      await _scan?.cancel();
      _scan = null;
      if (_scanning) await FlutterBluePlus.stopScan();
      _scanning = false;
    }
  }

  void _check() {
    if (_closed) throw StateError('Bluetooth operation cancelled');
  }

  Future<Companion> connect(String id, {bool pair = false}) async {
    _check();
    if (pair && !_android) {
      throw UnsupportedError('Explicit pairing is Android only');
    }
    for (var attempt = 1; ; attempt++) {
      final device = _deviceFor(id);
      _device = device;
      Companion? radio;
      try {
        // Same order as MeshMapper: connect first, Android MTU second, then
        // discover and await notification enablement before any protocol request.
        await device.connect(timeout: const Duration(seconds: 15), mtu: null);
        if (_closed) {
          await device.disconnect(queue: false, timeout: 5);
          _check();
        }
        if (pair) {
          // Let Android own PIN entry before the shorter protocol deadlines.
          // Do not collect a PIN, remove a bond or retry a cancelled pairing.
          await device.createBond(timeout: 90);
          _check();
        }
        if (_android) {
          try {
            await device.requestMtu(512);
            await Future<void>.delayed(const Duration(milliseconds: 100));
          } catch (_) {
            /* Use the actual negotiated MTU below, never assume 512. */
          }
        }
        final mtu = await device.mtu
            .firstWhere((size) => size >= 151)
            .timeout(const Duration(seconds: 5));
        _check();
        _connection = device.connectionState.skip(1).listen((state) {
          if (state == BluetoothConnectionState.disconnected) {
            unawaited(radio?.close());
          }
        });
        final services = await device.discoverServices();
        _check();
        final uart = services.singleWhere((s) => s.uuid == service);
        final input = uart.characteristics.singleWhere((c) => c.uuid == tx);
        final output = uart.characteristics.singleWhere((c) => c.uuid == rx);
        await input.setNotifyValue(true);
        _check();
        // onValueReceived avoids replaying a cached ACK on a new connection.
        radio = Companion.frames(input.onValueReceived, (command) async {
          _check();
          if (command.length > mtu - 3 || command.length > 172) {
            throw StateError('BLE command exceeds frame size');
          }
          Future<void> send() {
            _check();
            return output.write(command, withoutResponse: false);
          }

          if (_android) {
            await writeRetryingGattBusy(send);
          } else {
            await send();
          }
        }, close);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        _check();
        return radio;
      } catch (e) {
        await _connection?.cancel();
        _connection = null;
        // Once a protocol client exists its close owns this link; do not retry it.
        if (radio != null) {
          await radio.close();
          rethrow;
        }
        try {
          await device.disconnect(queue: false, timeout: 5);
        } catch (_) {}
        final staleBond =
            _ios &&
            (e.toString().contains('apple-code: 14') ||
                e.toString().contains('apple-code: 15') ||
                e.toString().contains('Peer removed pairing information'));
        if (pair || _closed || staleBond || attempt >= 3) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        _check();
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    final connection = _connection, scan = _scan, device = _device;
    _connection = null;
    _scan = null;
    _device = null;
    await connection?.cancel();
    await scan?.cancel();
    if (_scanning) {
      _scanning = false;
      await FlutterBluePlus.stopScan();
    }
    if (device != null) {
      try {
        await device.disconnect(queue: false, timeout: 5);
      } catch (_) {}
    }
  }
}
