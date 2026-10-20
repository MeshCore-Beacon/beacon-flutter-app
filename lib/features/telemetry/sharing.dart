import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../core/instance.dart';
import 'companion.dart';
import 'poll_policy.dart';

List<int> enrollmentMessage(
  Map<String, dynamic> reply,
  String instance,
  String radio,
  String client,
  DateTime now,
) {
  final token = reply['challenge'];
  if (token is! String ||
      token.length > 1800 ||
      token.split('.').length != 2 ||
      reply['instance'] != instance ||
      reply['message'] != 'BEACON-TELEMETRY-ENROLL-V1\n$token') {
    throw const FormatException('Invalid enrollment challenge');
  }
  final claims = jsonDecode(
    utf8.decode(base64Url.decode(base64Url.normalize(token.split('.').first))),
  );
  final seconds = now.millisecondsSinceEpoch ~/ 1000;
  if (claims is! Map<String, dynamic>) {
    throw const FormatException('Invalid challenge claims');
  }
  final expiry = claims['expires'];
  if (claims['kind'] != 'challenge' ||
      claims['instance'] != instance ||
      claims['radioKey'] != radio ||
      claims['collectorKey'] != client ||
      expiry is! int ||
      expiry <= seconds ||
      expiry > seconds + 300) {
    throw const FormatException(
      'Challenge is expired or belongs to another client or server',
    );
  }
  return utf8.encode(reply['message'] as String);
}

class IntakeFailure implements Exception {
  IntakeFailure(this.status, this.retrySeconds);
  final int status, retrySeconds;
  @override
  String toString() => status == 404
      ? 'This Beacon instance does not offer telemetry sharing yet. No repeater was polled.'
      : 'Telemetry intake unavailable (HTTP $status). Reports are retained for retry.';
}

class PollTarget {
  PollTarget(this.contact, {this.password = '', this.requireAdmin = false});
  final CompanionContact contact;
  String password;
  final bool requireAdmin;
}

/// A visible, foreground session. Intake and radio ownership are prerequisites to RF.
class TelemetrySharing {
  TelemetrySharing(
    this.instance,
    this.radio,
    this.targets,
    this.hours, {
    http.Client? client,
    FlutterSecureStorage? storage,
    DateTime Function()? now,
    this.environment = true,
  }) : _http = client ?? http.Client(),
       _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(resetOnError: false),
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.unlocked_this_device,
             ),
           ),
       _now = now ?? DateTime.now;
  static TelemetrySharing? _owner;
  final BeaconInstance instance;
  final Companion radio;
  final List<PollTarget> targets;
  final int hours;
  final bool environment;
  final http.Client _http;
  final FlutterSecureStorage _storage;
  final DateTime Function() _now;
  static const _storageKey = 'beacon.telemetry.v1';
  final _algorithm = Ed25519();
  Map<String, dynamic> _state = {'outbox': <dynamic>[]};
  late SimpleKeyPair _key;
  late String _clientKey;
  String? _authorization;
  DateTime? _authorizationUntil;
  bool _running = false, _busy = false;
  Completer<void>? _idle;
  ({int queue, int uptime, int tx, int rx})? _lastStats;
  DateTime? _statsAt;
  final _unavailable = <String>{};
  String status = 'Not sharing';
  int accepted = 0;
  bool get running => _running;
  int get queued => (_state['outbox'] as List).length;

  Future<void> _save() =>
      _storage.write(key: _storageKey, value: jsonEncode(_state));
  void _checkActive() {
    if (!_running || radio.closed) throw StateError('Sharing stopped');
  }

  Future<void> start() async {
    if (_owner != null) {
      throw StateError('Another telemetry session is still stopping');
    }
    if (instance.base.scheme != 'https' ||
        hours < 1 ||
        hours > 72 ||
        targets.isEmpty ||
        targets.length > 6) {
      throw const FormatException(
        'Use HTTPS, select 1–6 repeaters and an interval of 1–72 hours',
      );
    }
    if (radio.radioKey == null) {
      throw StateError('Identify the companion first');
    }
    _owner = this;
    _running = true;
    _busy = true;
    _idle = Completer<void>();
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw == null) {
        final key = await _algorithm.newKeyPair();
        _state = {
          'seed': base64Encode(await key.extractPrivateKeyBytes()),
          'policy': <String, dynamic>{},
          'outbox': <dynamic>[],
          'retryAt': <String, dynamic>{},
        };
        await _save();
      } else {
        // Corrupt or unavailable persistent state must never silently reset RF cooldowns.
        _state = jsonDecode(raw) as Map<String, dynamic>;
        if (_state['policy'] is! Map ||
            _state['outbox'] is! List ||
            _state['retryAt'] is! Map) {
          throw const FormatException(
            'Telemetry storage is unreadable; sharing stays off',
          );
        }
      }
      final seed = base64Decode(_state['seed'] as String);
      if (seed.length != 32) {
        throw const FormatException('Invalid signing identity');
      }
      _key = await _algorithm.newKeyPairFromSeed(seed);
      _clientKey = hexBytes((await _key.extractPublicKey()).bytes);
      _checkActive();
      await _enroll(); // A missing/unsupported intake blocks RF, rather than collecting unsendable data.
      status = 'Sharing enabled. Checking the companion before the first poll.';
    } catch (_) {
      _running = false;
      _http.close();
      await radio.close();
      for (final target in targets) {
        target.password = '';
      }
      rethrow;
    } finally {
      _busy = false;
      _idle!.complete();
      if (!_running && identical(_owner, this)) _owner = null;
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    _checkActive();
    final request =
        http.Request(
            'POST',
            Uri.parse('${instance.url}/api/v1/node-telemetry/$path'),
          )
          ..followRedirects = false
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(body);
    if (utf8.encode(request.body).length > 12000) {
      throw const FormatException('Oversized report');
    }
    final response = await _http
        .send(request)
        .timeout(const Duration(seconds: 15));
    final bytes = <int>[];
    await for (final part in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      bytes.addAll(part);
      if (bytes.length > 16000) {
        throw const FormatException('Oversized intake response');
      }
    }
    if (response.statusCode != 200 &&
        response.statusCode != 201 &&
        response.statusCode != 202) {
      final seconds = int.tryParse(response.headers['retry-after'] ?? '') ?? 60;
      throw IntakeFailure(response.statusCode, seconds.clamp(60, 86400));
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid intake response');
    }
    return value;
  }

  Future<void> _enroll() async {
    if (_authorization != null && _now().isBefore(_authorizationUntil!)) {
      return;
    }
    final challenge = await _post('challenge', {
      'radioKey': radio.radioKey,
      'collectorKey': _clientKey,
    });
    final message = enrollmentMessage(
      challenge,
      instance.url,
      radio.radioKey!,
      _clientKey,
      _now(),
    );
    _checkActive();
    final signature = await radio.sign(message);
    if (!await _algorithm.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          keyBytes(radio.radioKey!),
          type: KeyPairType.ed25519,
        ),
      ),
    )) {
      throw const FormatException(
        'Companion signature does not match its public key',
      );
    }
    final local = await _algorithm.sign(message, keyPair: _key);
    final reply = await _post('enroll', {
      'challenge': challenge['challenge'],
      'radioSignature': hexBytes(signature),
      'collectorSignature': hexBytes(local.bytes),
    });
    if (reply['instance'] != instance.url ||
        reply['authorization'] is! String ||
        (reply['authorization'] as String).length > 1800 ||
        reply['expires'] is! int) {
      throw const FormatException('Invalid enrollment response');
    }
    final until = DateTime.fromMillisecondsSinceEpoch(
      (reply['expires'] as int) * 1000,
    );
    if (!until.isAfter(_now()) ||
        until.difference(_now()) > const Duration(days: 31)) {
      throw const FormatException('Invalid enrollment lifetime');
    }
    _authorization = reply['authorization'] as String;
    _authorizationUntil = until.subtract(const Duration(minutes: 1));
  }

  Future<void> step() async {
    if (!_running || _busy) return;
    _busy = true;
    _idle = Completer<void>();
    try {
      final now = _now();
      final retry =
          (_state['retryAt'] as Map<String, dynamic>)[instance.url] as int?;
      if (retry != null && now.millisecondsSinceEpoch < retry) {
        status = 'Waiting for the intake retry window; no RF polling.';
        return;
      }
      await _enroll();
      await _flush(); // Delivery failures never trigger another RF request.
      _checkActive();
      if (queued >= 12) {
        status = 'Saved report queue is full; polling paused.';
        return;
      }
      final stats = await radio.stats();
      final previous = _lastStats, at = _statsAt;
      _lastStats = stats;
      _statsAt = now;
      if (previous == null || at == null || now.difference(at).inSeconds < 15) {
        status = 'Measuring companion airtime before polling.';
        return;
      }
      final elapsed = now.difference(at).inMilliseconds / 1000;
      if (stats.queue != 0 ||
          stats.uptime <= previous.uptime ||
          stats.tx < previous.tx ||
          stats.rx < previous.rx ||
          ((stats.tx - previous.tx) + (stats.rx - previous.rx)) / elapsed >
              .10) {
        status = 'Companion is busy or counters reset; polling deferred.';
        return;
      }
      final policy = PollPolicy(_state['policy'] as Map<String, dynamic>);
      final next = policy.nextNode(
        radio.radioKey!,
        targets
            .map((t) => t.contact.key)
            .where((key) => !_unavailable.contains(key)),
        hours,
        now,
      );
      if (next == null) {
        status =
            'Waiting for a repeater interval or the shared companion budget.';
        return;
      }
      // Oldest-attempt-first prevents short intervals from starving later selections.
      final target = targets.firstWhere((t) => t.contact.key == next);
      final key = target.contact.key;
      final contacts = await radio.contacts();
      // Firmware matches pending login by four bytes; reject even earlier ambiguity than its six-byte push.
      if (contacts.where((c) => c.key.startsWith(key.substring(0, 8))).length !=
          1) {
        _unavailable.add(key);
        status =
            'Ambiguous companion contact prefix; this repeater was not polled.';
        return;
      }
      var contact = contacts.where((c) => c.key == key).firstOrNull;
      if (contact == null || contact.type != 2 || (contact.hops ?? 0) > 3) {
        _unavailable.add(key);
        status = 'Repeater missing or learned route exceeds three hops.';
        return;
      }
      policy.reserve(radio.radioKey!, key, hours, now);
      final routes = _state.putIfAbsent(
        'learnedRoutes',
        () => <String, dynamic>{},
      ) as Map<String, dynamic>;
      final routeKey = '${radio.radioKey}/$key';
      final preferLearned = routes[routeKey] == true;
      routes[routeKey] = false;
      await _save(); // Durable reservation precedes every possible over-the-air request.
      _checkActive();
      // First use floods once. A failed route is rediscovered only after the full interval.
      if (!preferLearned && contact.hops != null) {
        await radio.resetPath(key);
        contact = await radio.contact(key);
      }
      final loginRoute = contact.hops == null ? 'flood' : 'direct';
      await radio.login(
        key,
        target.password,
        requireAdmin: target.requireAdmin,
      );
      contact = await radio.contact(
        key,
      ); // Login can learn a route. Do not flood again if it did.
      if ((contact.hops ?? 0) > 3) {
        throw StateError('Learned route exceeds three hops');
      }
      _checkActive();
      final values = parseStatus(await radio.binary(key, 1));
      _checkActive();
      var telemetry = TelemetrySample({}, []);
      if (environment) {
        try {
          telemetry = parseTelemetry(await radio.binary(key, 3));
        } catch (_) {
          // Preserve a valid status sample if optional environment data is unavailable.
        }
      }
      values.addAll(telemetry.values);
      final random = List<int>.generate(
        16,
        (_) => Random.secure().nextInt(256),
      );
      random[6] = (random[6] & 15) | 64;
      random[8] = (random[8] & 63) | 128;
      final id = hexBytes(random);
      final sample = {
        'schema': 1,
        'sampleId':
            '${id.substring(0, 8)}-${id.substring(8, 12)}-${id.substring(12, 16)}-${id.substring(16, 20)}-${id.substring(20)}',
        'receivedAt': _now().millisecondsSinceEpoch,
        'instance': instance.url,
        'collectorKey': _clientKey,
        'radioKey': radio.radioKey,
        'nodeKey': key,
        'source': 'companion-poll',
        'intervalHours': hours,
        'values': values,
        'sensors': telemetry.sensors,
        'route': {
          'login': loginRoute,
          'request': contact.hops == null ? 'flood' : 'direct',
          'learned': loginRoute == 'flood' && contact.hops != null,
        },
      };
      final payload = utf8.encode(jsonEncode(sample));
      if (payload.length > 8192) {
        throw const FormatException('Oversized telemetry sample');
      }
      final signed = await _algorithm.sign(payload, keyPair: _key);
      routes[routeKey] = contact.hops != null;
      (_state['outbox'] as List).add({
        'instance': instance.url,
        'radioKey': radio.radioKey,
        'at': sample['receivedAt'],
        'payload': base64Encode(payload),
        'signature': hexBytes(signed.bytes),
      });
      await _save();
      if (!radio.closed) await _flush();
      status = radio.closed
          ? 'Status report saved; reconnect to deliver it. Optional telemetry was unavailable.'
          : '${target.contact.name}: report accepted. Waiting for the next scheduled attempt.';
      if (radio.closed) _running = false;
    } catch (e) {
      if (!_running) return;
      if (e is IntakeFailure && e.status == 401) {
        _authorization = null;
      }
      final delay = e is IntakeFailure ? e.retrySeconds : 60;
      (_state['retryAt'] as Map<String, dynamic>)[instance.url] = _now()
          .add(Duration(seconds: delay))
          .millisecondsSinceEpoch;
      try {
        await _save();
      } catch (_) {
        _running = false;
        await radio.close();
      }
      status = e is IntakeFailure ? e.toString() : 'Sharing paused after a connection, storage or validation failure. Reconnect to continue.';
      // A lost companion requires an explicit reconnect; no automatic flood retry.
      if (radio.closed) _running = false;
    } finally {
      _busy = false;
      _idle!.complete();
    }
  }

  Future<void> _flush() async {
    final outbox = _state['outbox'] as List;
    outbox.removeWhere(
      (entry) =>
          _now().millisecondsSinceEpoch - (entry['at'] as int) >
          const Duration(hours: 24).inMilliseconds,
    );
    await _save();
    for (final entry in List.of(outbox)) {
      if (entry['instance'] != instance.url ||
          entry['radioKey'] != radio.radioKey) {
        continue;
      }
      final reply = await _post('reports', {
        'authorization': _authorization,
        'payload': entry['payload'],
        'signature': entry['signature'],
      });
      if (reply['accepted'] != true) {
        throw const FormatException('Report was not accepted');
      }
      outbox.remove(entry);
      await _save();
      accepted++;
    }
  }

  Future<void> stop() async {
    _running = false;
    await radio.close();
    _http.close();
    for (final target in targets) {
      target.password = '';
    }
    if (_busy) await _idle!.future;
    if (identical(_owner, this)) _owner = null;
    status =
        'Sharing stopped. Saved cooldowns and pending reports are retained.';
  }
}
