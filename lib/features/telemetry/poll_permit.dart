/// Server permission is checked before the local reservation and every RF step.
/// A missing, expired or mismatched permit never falls back to offline polling.
class PollPermit {
  PollPermit(this.id, this.expiresAt);
  final String id;
  final DateTime expiresAt;

  void check(DateTime now) {
    if (!now.isBefore(expiresAt)) {
      throw StateError(
        'Polling permit expired; waiting for the next interval.',
      );
    }
  }

  static PollPermit? parse(
    Map<String, dynamic> reply,
    Map<String, dynamic> request,
    DateTime now,
  ) {
    for (final field in [
      'instance',
      'requestId',
      'nodeKey',
      'radioKey',
      'collectorKey',
      'intervalHours',
      'commandBudget',
      'routeMode',
    ]) {
      if (reply[field] != request[field]) {
        throw const FormatException(
          'Polling permit belongs to another request',
        );
      }
    }
    if (reply['allowed'] == false) {
      final retry = reply['retryAfterSeconds'];
      if (retry is! int || retry < 1 || retry > 300) {
        throw const FormatException('Invalid polling retry window');
      }
      return null;
    }
    final issued = reply['issuedAt'], expires = reply['expiresAt'];
    final next = reply['nextAllowedAt'];
    final ms = now.millisecondsSinceEpoch;
    if (reply['allowed'] != true ||
        issued is! int ||
        expires is! int ||
        next is! int ||
        issued > ms + 30000 ||
        issued < ms - 300000 ||
        expires <= ms ||
        expires > issued + 300000 ||
        next !=
            issued +
                Duration(hours: request['intervalHours'] as int)
                    .inMilliseconds) {
      throw const FormatException('Invalid or expired polling permit');
    }
    return PollPermit(
      request['requestId'] as String,
      DateTime.fromMillisecondsSinceEpoch(expires),
    );
  }
}

bool nearbyRouteIsUnambiguous(
  int? hops,
  List<int> path,
  String targetKey,
  Iterable<String> repeaterKeys,
) {
  if (hops == 0) return path.isEmpty;
  if (hops != 1 || path.isEmpty || path.length > 3) return false;
  final prefix = path.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return repeaterKeys
          .where((key) => key != targetKey && key.startsWith(prefix))
          .length ==
      1;
}
