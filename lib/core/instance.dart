import 'json.dart';

class BeaconInstance {
  const BeaconInstance({required this.name, required this.url});
  factory BeaconInstance.create(String name, String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        input.trim().contains(RegExp(r'\s'))) {
      throw const FormatException(
        'Enter a complete http:// or https:// server URL without credentials, query or fragment.',
      );
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    path = path.replaceFirst(RegExp(r'/api/v1$'), '');
    return BeaconInstance(
      name: name.trim().isEmpty ? uri.host : name.trim(),
      url: uri.replace(path: path).toString(),
    );
  }
  factory BeaconInstance.fromJson(Json json) =>
      BeaconInstance.create(textOf(json['name']), textOf(json['url']));
  final String name;
  final String url;
  Uri get base => Uri.parse(url);
  Uri get wsUri =>
      Uri.parse('$url/ws')
          .replace(scheme: base.scheme == 'https' ? 'wss' : 'ws');
  Json toJson() => {'name': name, 'url': url};
}
