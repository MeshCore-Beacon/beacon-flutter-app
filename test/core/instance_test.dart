import 'package:beacon/core/instance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes pasted API URL and preserves deployment prefix', () {
    final instance = BeaconInstance.create(
      'Dev',
      ' https://beacon.example.com/beacon/api/v1/ ',
    );
    expect(instance.url, 'https://beacon.example.com/beacon');
    expect(instance.wsUri.toString(), 'wss://beacon.example.com/beacon/ws');
  });
  test('rejects credentials, query strings and non HTTP schemes', () {
    for (final url in [
      'file:///etc',
      'https://user:pass@host',
      'https://host?x=1',
      'https://host/#x',
      'no host',
    ]) {
      expect(() => BeaconInstance.create('X', url), throwsFormatException);
    }
  });
  test('supports local explicit HTTP and ports', () {
    final instance = BeaconInstance.create('', 'http://localhost:8080/');
    expect(instance.name, 'localhost');
    expect(instance.wsUri.toString(), 'ws://localhost:8080/ws');
    expect(BeaconInstance.fromJson(instance.toJson()).url, instance.url);
  });
}
