import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:beacon/core/instance.dart';
import 'package:beacon/features/telemetry/companion.dart';
import 'package:beacon/features/telemetry/sharing.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeRadio {
  final key = Ed25519().newKeyPairFromSeed(List.filled(32, 7));
  late ServerSocket server;
  final sockets = <Socket>[];
  final commands = <int>[];
  final target = 'ab' * 32;
  List<int> signed = [];
  int uptime = 100, queue = 0;
  bool learned = false;

  Future<void> open() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      sockets.add(socket);
      final buffer = <int>[];
      socket.listen((bytes) async {
        buffer.addAll(bytes);
        while (buffer.length >= 3) {
          final length = buffer[1] | (buffer[2] << 8);
          if (buffer.length < length + 3) return;
          final command = buffer.sublist(3, length + 3);
          buffer.removeRange(0, length + 3);
          commands.add(command[0]);
          void send(List<int> frame) =>
              socket.add([62, frame.length, 0, ...frame]);
          List<int> contact() {
            final b = Uint8List(148)..[0] = 3;
            b.setRange(1, 33, keyBytes(target));
            b[33] = 2;
            b[35] = learned ? 1 : 255;
            b[36] = 0;
            b.setRange(100, 104, utf8.encode('Test'));
            return b;
          }

          switch (command[0]) {
            case 22:
              send([13, 4]);
            case 1:
              send([
                5,
                1,
                20,
                22,
                ...(await (await key).extractPublicKey()).bytes,
              ]);
            case 4:
              send([2, 1, 0, 0, 0]);
              send(contact());
              send([4, 0, 0, 0, 0]);
            case 30:
              send(contact());
            case 13:
              learned = false;
              send([0]);
            case 33:
              signed = [];
              send([19, 0, 0, 32, 0, 0]);
            case 34:
              signed.addAll(command.skip(1));
              send([0]);
            case 35:
              send([
                20,
                ...(await Ed25519().sign(signed, keyPair: await key)).bytes,
              ]);
            case 56:
              final f = Uint8List(command[1] == 0 ? 11 : 14)
                ..[0] = 24
                ..[1] = command[1];
              if (command[1] == 0) {
                ByteData.sublistView(f).setUint32(4, uptime, Endian.little);
                f[10] = queue;
              }
              send(f);
            case 26:
              learned = true;
              // Push arrives BEFORE SEND. The client must retain it.
              send([0x85, 1, ...keyBytes(target).take(6)]);
              send([6, 1, 3, 4, 5, 6, 0, 0, 0, 0]);
            case 50:
              final type = command[33];
              final body = type == 1
                  ? Uint8List(52)
                  : Uint8List.fromList([1, 116, 1, 144, 2, 103, 0, 100]);
              if (type == 1) {
                ByteData.sublistView(body).setUint16(0, 4000, Endian.little);
              }
              send([0x8c, 0, 90, 90, 90, 90, 99]); // wrong tag must be ignored
              send([0x8c, 0, 3, 4, 5, 6, ...body]);
              send([6, 0, 3, 4, 5, 6, 0, 0, 0, 0]);
          }
        }
      });
    });
  }

  Future<Companion> connect() async {
    final radio = await Companion.connect('127.0.0.1', server.port);
    await radio.identify();
    return radio;
  }

  Future<void> close() async {
    for (final s in sockets) {
      s.destroy();
    }
    await server.close();
  }

  int get rf => commands.where((code) => code == 26 || code == 50).length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final instance = BeaconInstance.create('Test', 'https://telemetry.example');

  test('unsupported intake blocks all RF', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final fake = FakeRadio();
    await fake.open();
    addTearDown(fake.close);
    final radio = await fake.connect();
    final sharing = TelemetrySharing(
      instance,
      radio,
      [PollTarget((await radio.contacts()).single)],
      6,
      client: MockClient((_) async => http.Response('{}', 404)),
    );
    await expectLater(sharing.start(), throwsA(isA<IntakeFailure>()));
    expect(fake.rf, 0);
  });

  test('signed delivery retry reuses exact payload and never polls again', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final fake = FakeRadio();
    await fake.open();
    addTearDown(fake.close);
    final radio = await fake.connect();
    var now = DateTime.utc(2026, 10, 20);
    final reports = <Map<String, dynamic>>[];
    Map<String, dynamic>? submitted;
    final api = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(request.followRedirects, false);
      if (request.url.path.endsWith('/challenge')) {
        final claims = {
          'kind': 'challenge',
          'instance': instance.url,
          ...body,
          'expires': now.millisecondsSinceEpoch ~/ 1000 + 120,
          'nonce': 'fixture',
        };
        final token =
            '${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.test';
        return http.Response(
          jsonEncode({
            'challenge': token,
            'instance': instance.url,
            'message': 'BEACON-TELEMETRY-ENROLL-V1\n$token',
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/enroll')) {
        expect(body.keys.toSet(), {
          'challenge',
          'radioSignature',
          'collectorSignature',
        });
        expect(fake.rf, 0);
        return http.Response(
          jsonEncode({
            'authorization': 'fixture-session',
            'instance': instance.url,
            'expires':
                now.add(const Duration(days: 30)).millisecondsSinceEpoch ~/
                1000,
          }),
          200,
        );
      }
      reports.add(body);
      final payload = base64Decode(body['payload'] as String);
      submitted = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      final signature = body['signature'] as String;
      expect(
        await Ed25519().verify(
          payload,
          signature: Signature(
            [
              for (var i = 0; i < signature.length; i += 2)
                int.parse(signature.substring(i, i + 2), radix: 16),
            ],
            publicKey: SimplePublicKey(
              keyBytes(submitted!['collectorKey'] as String),
              type: KeyPairType.ed25519,
            ),
          ),
        ),
        true,
      );
      expect(utf8.decode(payload), isNot(contains('secret-password')));
      return reports.length == 1
          ? http.Response('{}', 503, headers: {'retry-after': '60'})
          : http.Response('{"accepted":true}', 202);
    });
    final sharing = TelemetrySharing(
      instance,
      radio,
      [
        PollTarget(
          (await radio.contacts()).single,
          password: 'secret-password',
          requireAdmin: true,
        ),
      ],
      6,
      client: api,
      now: () => now,
    );
    addTearDown(sharing.stop);
    await sharing.start();
    await sharing.step();
    expect(fake.rf, 0);
    now = now.add(const Duration(seconds: 20));
    fake.uptime += 20;
    await sharing.step();
    expect(fake.rf, 3);
    expect(sharing.queued, 1);
    expect(submitted!['values'], containsPair('batteryMv', 4000));
    expect((submitted!['sensors'] as List).last, containsPair('channel', 2));
    expect(submitted!['route'], {
      'login': 'flood',
      'request': 'direct',
      'learned': true,
    });
    now = now.add(const Duration(seconds: 61));
    fake.uptime += 61;
    await sharing.step();
    expect(fake.rf, 3);
    expect(sharing.queued, 0);
    expect(sharing.accepted, 1);
    expect(reports[0], reports[1]);
    await sharing.stop();
    expect(radio.closed, true);
  });
}
