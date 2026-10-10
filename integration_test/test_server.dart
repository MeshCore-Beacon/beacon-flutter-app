/// The live Beacon server the native tests read from, passed as
/// `--dart-define=BEACON_SERVER=https://your-server`.
String get testServer {
  const url = String.fromEnvironment('BEACON_SERVER');
  if (url.isEmpty) {
    throw StateError(
      'Pass --dart-define=BEACON_SERVER=<url> to run the native tests.',
    );
  }
  return url;
}
