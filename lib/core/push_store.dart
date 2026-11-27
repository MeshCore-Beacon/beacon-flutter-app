import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Shared with the iOS Notification Service Extension (keychain-access-groups).
const iosKeychainGroup = 'DQC6TNKG5P.meshcorebeacon.app.shared';

/// The keychain service the extension reads push entries from.
const pushKeychainService = 'beacon.push';
const _prefix = 'beacon.push.';

/// This phone's registration with one Beacon server through the push server.
class PushEntry {
  const PushEntry({
    required this.pushId,
    required this.relay,
    required this.handle,
    required this.handleSecret,
    required this.key,
    required this.url,
    required this.name,
    this.token = '',
  });

  /// The Beacon server's Push ID, which every notification carries.
  final String pushId;

  /// The push server that issued [handle].
  final Uri relay;
  final String handle, handleSecret;

  /// Base64 of the 32-byte AES key this server seals notices with.
  final String key;

  /// The saved server URL and name, to route a tap and title a notification.
  final String url, name;

  /// The FCM token [handle] points at, so an unchanged one needs no call.
  final String token;

  List<int> get keyBytes => base64.decode(key);

  PushEntry copyWith({String? url, String? name, String? token}) => PushEntry(
    pushId: pushId,
    relay: relay,
    handle: handle,
    handleSecret: handleSecret,
    key: key,
    url: url ?? this.url,
    name: name ?? this.name,
    token: token ?? this.token,
  );

  Map<String, String> toJson() => {
    'pushId': pushId,
    'relay': '$relay',
    'handle': handle,
    'handleSecret': handleSecret,
    'key': key,
    'url': url,
    'name': name,
    'token': token,
  };

  static PushEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final v = {
      for (final k in ['pushId', 'relay', 'handle', 'handleSecret', 'key'])
        k: json[k] is String ? json[k] as String : '',
    };
    if (v.values.any((e) => e.isEmpty)) return null;
    final relay = Uri.tryParse(v['relay']!);
    if (relay == null) return null;
    try {
      if (base64.decode(v['key']!).length != 32) return null;
    } on FormatException {
      return null;
    }
    return PushEntry(
      pushId: v['pushId']!,
      relay: relay,
      handle: v['handle']!,
      handleSecret: v['handleSecret']!,
      key: v['key']!,
      url: json['url'] is String ? json['url'] as String : '',
      name: json['name'] is String ? json['name'] as String : '',
      token: json['token'] is String ? json['token'] as String : '',
    );
  }
}

/// Push entries by Push ID.
abstract class PushStore {
  Future<PushEntry?> read(String pushId);
  Future<List<PushEntry>> all();
  Future<void> write(PushEntry entry);
  Future<void> delete(String pushId);

  Future<PushEntry?> forUrl(String url) async {
    for (final e in await all()) {
      if (e.url == url) return e;
    }
    return null;
  }
}

class MemoryPushStore extends PushStore {
  final entries = <String, PushEntry>{};
  @override
  Future<PushEntry?> read(String pushId) async => entries[pushId];
  @override
  Future<List<PushEntry>> all() async => entries.values.toList();
  @override
  Future<void> write(PushEntry entry) async => entries[entry.pushId] = entry;
  @override
  Future<void> delete(String pushId) async => entries.remove(pushId);
}

/// Keychain on iOS, in a group the Notification Service Extension can read;
/// the keystore-backed store on Android, which the background isolate reads.
class SecurePushStore extends PushStore {
  SecurePushStore({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage storage;

  // After first unlock, so the extension can read it while the phone is locked.
  static const iosOptions = IOSOptions(
    accountName: pushKeychainService,
    groupId: iosKeychainGroup,
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  @override
  Future<PushEntry?> read(String pushId) async {
    final raw = await storage.read(
      key: '$_prefix$pushId',
      iOptions: iosOptions,
    );
    return _decode(raw);
  }

  @override
  Future<List<PushEntry>> all() async {
    final raw = await storage.readAll(iOptions: iosOptions);
    return [
      for (final MapEntry(:key, :value) in raw.entries)
        if (key.startsWith(_prefix)) ?_decode(value),
    ];
  }

  @override
  Future<void> write(PushEntry entry) => storage.write(
    key: '$_prefix${entry.pushId}',
    value: jsonEncode(entry.toJson()),
    iOptions: iosOptions,
  );

  @override
  Future<void> delete(String pushId) =>
      storage.delete(key: '$_prefix$pushId', iOptions: iosOptions);

  static PushEntry? _decode(String? raw) {
    if (raw == null) return null;
    try {
      return PushEntry.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }
}
