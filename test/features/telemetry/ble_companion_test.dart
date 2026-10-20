import 'dart:async';

import 'package:beacon/features/telemetry/ble_companion.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

class TestCharacteristic implements BluetoothCharacteristic {
  TestCharacteristic(this.uuid, this.owner);
  @override
  final Guid uuid;
  final TestDevice owner;
  @override
  Stream<List<int>> get onValueReceived => owner.frames.stream;
  @override
  Future<bool> setNotifyValue(
    bool notify, {
    int timeout = 15,
    bool forceIndications = false,
  }) async {
    owner.order.add('notify');
    owner.notifying = notify;
    return true;
  }

  @override
  Future<void> write(
    List<int> value, {
    bool withoutResponse = false,
    bool allowLongWrite = false,
    int timeout = 15,
  }) async {
    expect(owner.notifying, true);
    expect(withoutResponse, false);
    expect(uuid, BleCompanion.rx);
    owner.writes.add(List.of(value));
    if (value.first == 22) owner.frames.add([13, 4]);
    if (value.first == 1) {
      owner.frames.add([5, 1, 20, 22, ...List.filled(32, 0xab)]);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestService implements BluetoothService {
  TestService(this.owner);
  final TestDevice owner;
  @override
  Guid get uuid => BleCompanion.service;
  @override
  List<BluetoothCharacteristic> get characteristics => [
    TestCharacteristic(BleCompanion.rx, owner),
    TestCharacteristic(BleCompanion.tx, owner),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestDevice implements BluetoothDevice {
  int negotiatedMtu = 185;
  bool cancelled = false, notifying = false;
  // Both controllers are closed by each test after the transport is disconnected.
  // ignore: close_sinks
  final frames = StreamController<List<int>>.broadcast(sync: true);
  // ignore: close_sinks
  final states = StreamController<BluetoothConnectionState>.broadcast();
  final writes = <List<int>>[];
  final order = <String>[];
  @override
  Stream<int> get mtu => Stream.value(negotiatedMtu);
  @override
  Stream<BluetoothConnectionState> get connectionState async* {
    yield BluetoothConnectionState.connected;
    yield* states.stream;
  }

  @override
  Future<void> connect({
    Duration timeout = const Duration(seconds: 35),
    int? mtu = 512,
    bool autoConnect = false,
  }) async {
    expect(mtu, null);
    expect(autoConnect, false);
    order.add('connect');
  }

  @override
  Future<int> requestMtu(
    int desiredMtu, {
    double predelay = .35,
    int timeout = 15,
  }) async {
    expect(desiredMtu, 512);
    order.add('mtu');
    return negotiatedMtu;
  }

  @override
  Future<List<BluetoothService>> discoverServices({
    bool subscribeToServicesChanged = true,
    int timeout = 15,
  }) async {
    order.add('discover');
    return [TestService(this)];
  }

  @override
  Future<void> disconnect({
    int timeout = 35,
    int androidDelay = 2000,
    bool queue = true,
  }) async {
    cancelled = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'a BLE MTU too small for saved contacts never sends a command',
    () async {
      final device = TestDevice()..negotiatedMtu = 23;
      final session = BleCompanion(
        device: (_) => device,
        android: false,
        ios: true,
      );
      await expectLater(session.connect('small'), throwsStateError);
      expect(device.writes, isEmpty);
      expect(device.cancelled, true);
      await device.frames.close();
      await device.states.close();
    },
  );
  test('BLE follows MeshMapper connect, MTU, discovery, notification, acknowledged write order', () async {
    final device = TestDevice();
    final session = BleCompanion(
      device: (_) => device,
      android: true,
      ios: false,
    );
    final radio = await session.connect('companion');
    expect(await radio.identify(), 'ab' * 32);
    expect(device.order, ['connect', 'mtu', 'discover', 'notify']);
    expect(device.writes.map((w) => w.first), [22, 1]);
    expect(device.writes.first, [22, 4]);
    await radio.close();
    expect(device.cancelled, true);
    expect(radio.closed, true);
    await device.frames.close();
    await device.states.close();
  });
  test(
    'iOS reads negotiated MTU instead of requesting Android-only negotiation',
    () async {
      final device = TestDevice();
      final session = BleCompanion(
        device: (_) => device,
        android: false,
        ios: true,
      );
      final radio = await session.connect('companion');
      expect(device.order, ['connect', 'discover', 'notify']);
      await radio.close();
      await device.frames.close();
      await device.states.close();
    },
  );
  test(
    'only a confirmed GATT busy refusal is retried; ambiguous failures are not',
    () async {
      var calls = 0;
      final delays = <int>[];
      await writeRetryingGattBusy(
        () async {
          calls++;
          if (calls < 4) throw StateError('ERROR_GATT_WRITE_REQUEST_BUSY');
        },
        sleep: (d) async {
          delays.add(d.inMilliseconds);
        },
      );
      expect(calls, 4);
      expect(delays, [50, 100, 150]);
      calls = 0;
      await expectLater(
        writeRetryingGattBusy(() async {
          calls++;
          throw StateError('write timed out');
        }),
        throwsStateError,
      );
      expect(calls, 1);
    },
  );
}
