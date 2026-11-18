import 'dart:convert';

import 'push_notice.dart';
import 'push_store.dart';

/// A notification ready to show: the server's name over the app's sentence.
class ShownNotice {
  const ShownNotice({
    required this.id,
    required this.title,
    required this.body,
    required this.payload,
  });
  final int id;
  final String title, body;

  /// Handed back on tap: the Push ID and the radio, never the ciphertext.
  final String payload;
}

abstract class Notifier {
  Future<void> show(ShownNotice notice);
}

/// A stable 31-bit id per message, so a repeat replaces rather than stacks.
int _noticeId(String messageId) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(messageId)) {
    h = ((h ^ b) * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}

/// Opens one push message (FCM data) and shows it. Anything that does not
/// open to a notice of a known kind is dropped without a trace.
Future<bool> deliverNotice(
  Map<String, Object?> data, {
  required PushStore store,
  required Notifier notifier,
}) async {
  final pushId = data['pushId'];
  if (data['v'] != '1' || pushId is! String || pushId.isEmpty) return false;
  final entry = await store.read(pushId);
  if (entry == null) return false;
  final notice = await openNotice(entry.keyBytes, pushId, data['ct']);
  if (notice == null) return false;
  final body = alertSentence(notice);
  if (body == null) return false;
  final sent = data['serverName'] is String ? data['serverName'] as String : '';
  var title = capName(entry.name);
  if (title.isEmpty) title = capName(sent);
  if (title.isEmpty) title = 'BEACON';
  final messageId = data['messageId'];
  await notifier.show(
    ShownNotice(
      id: _noticeId(messageId is String ? messageId : '${data['ct']}'),
      title: title,
      body: body,
      payload: jsonEncode({
        'pushId': pushId,
        'targetKind': notice.targetKind,
        'publicKey': notice.publicKey,
        'id': notice.id,
      }),
    ),
  );
  return true;
}
