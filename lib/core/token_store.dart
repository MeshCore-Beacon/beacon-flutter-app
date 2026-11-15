import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One sign-in token per server, keyed by the saved server URL.
abstract class TokenStore {
  Future<String?> read(String serverUrl);
  Future<void> write(String serverUrl, String token);
  Future<void> delete(String serverUrl);

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
      storage.write(key: _key(serverUrl), value: token);

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
