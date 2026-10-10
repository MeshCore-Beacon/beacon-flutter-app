import 'package:beacon/core/runtime_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('reads only JSON config and keeps supported tabs in source order', () {
    final config = RuntimeConfig.parse(
      'window.__BEACON_CONFIG__ = {"VITE_BANNER":"Development","VITE_DISABLED_TABS":"map, NODES"};',
    );
    expect(config.banner, 'Development');
    expect(config.tabs, [
      'Packets',
      'Channels',
      'Observers',
      'Routes',
      'Traces',
      'Analytics',
    ]);
  });
  test('never executes JavaScript and falls back for malformed config', () {
    expect(
      RuntimeConfig.parse('window.__BEACON_CONFIG__ = runCode();').tabs,
      hasLength(8),
    );
    expect(
      RuntimeConfig.parse('window.__BEACON_CONFIG__ = {}; bad();').banner,
      '',
    );
  });
  test('load ignores config bodies over 1 MB', () async {
    const source = 'window.__BEACON_CONFIG__ = {"VITE_BANNER":"Big"};';
    final small = await RuntimeConfig.load(
      Uri.parse('https://host'),
      client: MockClient((r) async => http.Response(source, 200)),
    );
    expect(small.banner, 'Big');
    final big = await RuntimeConfig.load(
      Uri.parse('https://host'),
      client: MockClient(
        (r) async => http.Response(
          source.replaceFirst('{', '{${' ' * (1024 * 1024)}'),
          200,
        ),
      ),
    );
    expect(big.banner, '');
  });
}
