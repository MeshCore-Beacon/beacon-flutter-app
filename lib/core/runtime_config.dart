import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'json.dart';

class RuntimeConfig {
  const RuntimeConfig([this.values = const {}]);
  final Json values;
  static const allTabs = [
    'Packets',
    'Channels',
    'Map',
    'Nodes',
    'Observers',
    'Routes',
    'Traces',
    'Analytics',
  ];
  static RuntimeConfig parse(String source) {
    final match = RegExp(
      r'^\s*window\.__BEACON_CONFIG__\s*=\s*(\{[\s\S]*\})\s*;?\s*$',
    ).firstMatch(source);
    if (match == null) return const RuntimeConfig();
    try {
      return RuntimeConfig(object(jsonDecode(match.group(1)!)));
    } catch (_) {
      return const RuntimeConfig();
    }
  }

  String get banner => textOf(values['VITE_BANNER']);
  List<String> get tabs {
    final disabled = textOf(values['VITE_DISABLED_TABS'])
        .toLowerCase()
        .split(',')
        .map((e) => e.trim())
        .toSet();
    final enabled = allTabs
        .where((e) => !disabled.contains(e.toLowerCase()))
        .toList();
    return enabled.isEmpty ? allTabs : enabled;
  }

  static Future<RuntimeConfig> load(Uri base, {http.Client? client}) async {
    final owned = client == null;
    client ??= http.Client();
    try {
      final response = await getLimited(
        client,
        Uri.parse(
          '${base.toString().replaceFirst(RegExp(r'/+$'), '')}/config.js',
        ),
        1024 * 1024,
      ).timeout(const Duration(seconds: 8));
      return response.statusCode == 200
          ? parse(response.body)
          : const RuntimeConfig();
    } catch (_) {
      return const RuntimeConfig();
    } finally {
      if (owned) client.close();
    }
  }
}
