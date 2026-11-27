part of 'profile_screen.dart';

/// "How alerts reach you": the user's email and push switches, sent at once
/// and rolled back when the server refuses.
class _AlertChannels extends StatefulWidget {
  const _AlertChannels({
    required this.account,
    required this.channels,
    required this.hasRules,
    required this.serverName,
    required this.changed,
  });
  final AccountState account;
  final Json channels;
  final bool hasRules;
  final String serverName;

  /// The server's answer, so the parent keeps it.
  final void Function(Json channels) changed;
  @override
  State<_AlertChannels> createState() => _AlertChannelsState();
}

class _AlertChannelsState extends State<_AlertChannels> {
  /// Switches flipped but not yet confirmed; they win over the server's.
  final pending = <String, bool>{};
  String? error;

  Json get email => object(widget.channels['email']);
  Json get push => object(widget.channels['push']);
  bool enabled(String channel, Json value) =>
      pending[channel] ?? value['enabled'] != false;

  Future<void> toggle(String channel, bool next) async {
    // Each save returns both preferences. Finish it and any push registration before another change.
    if (pending.isNotEmpty) return;
    final epoch = widget.account.epoch;
    setState(() {
      pending[channel] = next;
      error = null;
    });
    try {
      final answer = await widget.account.api.putAlertChannels(
        email: channel == 'email' ? next : null,
        push: channel == 'push' ? next : null,
      );
      if (!mounted || widget.account.epoch != epoch) return;
      widget.changed(answer);
      if (channel == 'push' && next) {
        await widget.account.push?.enable();
        if (!mounted || widget.account.epoch != epoch) return;
      }
      setState(() => pending.remove(channel));
    } catch (_) {
      if (!mounted || widget.account.epoch != epoch) return;
      setState(() {
        pending.remove(channel);
        error = trKey('alertChannels.failed');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = BeaconColors.of(context);
    final muted = TextStyle(fontSize: 12, color: colors.muted);
    final emailAvailable = email['available'] == true;
    final pushAvailable = push['available'] == true;
    final emailOn = enabled('email', email);
    final pushOn = enabled('push', push);
    final address = textOf(widget.account.user?['email']);
    final reason = textOf(email['reason']);
    final server = widget.serverName.isEmpty
        ? trKey('alertChannels.thisServer')
        : widget.serverName;
    return section(trKey('alertChannels.title'), [
      _ChannelSwitch(
        id: 'channel-email',
        label: trKey('alertChannels.email'),
        value: emailAvailable && emailOn,
        onChanged: emailAvailable && pending.isEmpty
            ? (v) => toggle('email', v)
            : null,
        note: !emailAvailable
            ? trKey(switch (reason) {
                'server_off' ||
                'portal_account' ||
                'unverified_email' => 'alertChannels.reason.$reason',
                _ => 'alertChannels.reason.other',
              })
            : emailOn && address.isNotEmpty
            ? trKey('alerts.toEmail').replaceAll('{{email}}', address)
            : null,
        style: muted,
      ),
      _ChannelSwitch(
        id: 'channel-push',
        label: trKey('alertChannels.push'),
        value: pushAvailable && pushOn,
        onChanged: pushAvailable && pending.isEmpty
            ? (v) => toggle('push', v)
            : null,
        note: pushAvailable
            ? trKey('alertChannels.pushVia').replaceAll('{{server}}', server)
            : trKey('alertChannels.pushOff'),
        style: muted,
      ),
      if (pushAvailable && pushOn && !pending.containsKey('push'))
        _PushStatus(push: widget.account.push),
      if (error case final text?)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(text, style: TextStyle(color: colors.danger)),
        ),
      if (widget.hasRules &&
          !(emailAvailable && emailOn) &&
          !(pushAvailable && pushOn))
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            trKey('alertChannels.noChannel'),
            style: TextStyle(color: colors.danger, fontWeight: FontWeight.w600),
          ),
        ),
    ]);
  }
}

class _ChannelSwitch extends StatelessWidget {
  const _ChannelSwitch({
    required this.id,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.note,
    required this.style,
  });
  final String id, label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? note;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: ValueKey(id),
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    subtitle: note == null ? null : Text(note!, style: style),
    value: value,
    onChanged: onChanged,
  );
}
