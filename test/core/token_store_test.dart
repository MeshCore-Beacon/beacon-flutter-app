import 'package:beacon/core/token_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Backing implements FlutterSecureStorage {
  final values = <String, String>{};
  bool failing = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (failing) throw StateError('keystore is corrupted');
    final key = invocation.namedArguments[#key] as String;
    switch (invocation.memberName) {
      case #write:
        values[key] = invocation.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        values.remove(key);
        return Future<void>.value();
      case #read:
        return Future<String?>.value(values[key]);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test('MemoryTokenStore reads, writes, moves and deletes', () async {
    final store = MemoryTokenStore();
    expect(await store.read('https://a.test'), isNull);
    await store.write('https://a.test', 'tok');
    expect(await store.read('https://a.test'), 'tok');
    await store.move('https://a.test', 'https://b.test');
    expect(await store.read('https://a.test'), isNull);
    expect(await store.read('https://b.test'), 'tok');
    await store.delete('https://b.test');
    expect(await store.read('https://b.test'), isNull);
  });

  test('move keeps a token the destination already has', () async {
    final store = MemoryTokenStore();
    await store.write('https://a.test', 'old');
    await store.write('https://b.test', 'kept');
    await store.move('https://a.test', 'https://b.test');
    expect(await store.read('https://b.test'), 'kept');
    expect(await store.read('https://a.test'), isNull);
  });

  test('SecureTokenStore keys each server as beacon.token.<url>', () async {
    final backing = _Backing();
    final store = SecureTokenStore(storage: backing);
    await store.write('https://a.test', 'tok');
    expect(backing.values, {'beacon.token.https://a.test': 'tok'});
    expect(await store.read('https://a.test'), 'tok');
    await store.move('https://a.test', 'https://b.test');
    expect(backing.values, {'beacon.token.https://b.test': 'tok'});
    await store.delete('https://b.test');
    expect(backing.values, isEmpty);
  });

  test('a failing keystore reads as no token', () async {
    final backing = _Backing()..failing = true;
    final store = SecureTokenStore(storage: backing);
    expect(await store.read('https://a.test'), isNull);
  });

  test('the default storage uses first_unlock_this_device on iOS', () {
    final storage = SecureTokenStore().storage;
    expect(
      storage.iOptions.toMap()['accessibility'],
      'first_unlock_this_device',
    );
  });
}
