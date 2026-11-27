import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One sign-in token per server, keyed by the saved server URL.
abstract class TokenStore {
  Future<String?> read(String serverUrl);
  Future<void> write(String serverUrl, String token);
  Future<void> delete(String serverUrl);

  /// Deletes only while the stored token is still [token], so a newer sign-in
  /// is never removed by a late 401 or logout.
  Future<void> deleteIfEquals(String serverUrl, String token);

  /// Carries a token to an edited URL. A token the new URL already has wins.
  Future<void> move(String fromUrl, String toUrl);
}

class MemoryTokenStore implements TokenStore {
  final _tokens = <String, String>{};

  @override
  Future<String?> read(String serverUrl) async => _tokens[serverUrl];

  @override
  Future<void> write(String serverUrl, String token) async =>
      _tokens[serverUrl] = token;

  @override
  Future<void> delete(String serverUrl) async => _tokens.remove(serverUrl);

  @override
  Future<void> deleteIfEquals(String serverUrl, String token) async {
    if (_tokens[serverUrl] == token) _tokens.remove(serverUrl);
  }

  @override
  Future<void> move(String fromUrl, String toUrl) async {
    if (fromUrl == toUrl) return;
    final token = _tokens.remove(fromUrl);
    if (token != null) _tokens.putIfAbsent(toUrl, () => token);
  }
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
            // Android uses the package's default AES-GCM storage in the keystore.
            aOptions: AndroidOptions(),
          );
  final FlutterSecureStorage storage;

  // The keychain has no compare-and-delete; this queue makes writes and
  // conditional deletes in this process take turns.
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() job) {
    final done = _tail.then((_) => job());
    _tail = done.then((_) {}, onError: (_) {});
    return done;
  }

  String _key(String serverUrl) => 'beacon.token.$serverUrl';

  /// A broken keystore reads as signed out, so the app still opens.
  @override
  Future<String?> read(String serverUrl) async {
    try {
      return await storage.read(key: _key(serverUrl));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String serverUrl, String token) =>
      _serial(() => storage.write(key: _key(serverUrl), value: token));

  @override
  Future<void> deleteIfEquals(String serverUrl, String token) =>
      _serial(() async {
        if (await read(serverUrl) == token) {
          await storage.delete(key: _key(serverUrl));
        }
      });

  @override
  Future<void> delete(String serverUrl) => storage.delete(key: _key(serverUrl));

  @override
  Future<void> move(String fromUrl, String toUrl) async {
    if (fromUrl == toUrl) return;
    final token = await read(fromUrl);
    if (token == null) return;
    if (await read(toUrl) == null) await write(toUrl, token);
    await delete(fromUrl);
  }
}
