part of 'profile_screen.dart';

/// Alert rules for the radios on the user's Atlas. Only built when the server
/// has alerts on.
class _Alerts extends StatefulWidget {
  const _Alerts({
    required this.account,
    required this.unit,
    this.serverName = '',
    this.refresh,
  });
  final AccountState account;
  final ValueNotifier<int>? refresh;

  /// The instance's temperature unit, 'c' or 'f'.
  final String unit;

  /// The saved server's name, for the push line.
  final String serverName;
  @override
  State<_Alerts> createState() => _AlertsState();
}

class _AlertsState extends State<_Alerts> {
  // Shared with the Atlas cards, so a change in either place shows in both.
  AlertsState get alerts => widget.account.alerts;

  @override
  void initState() {
    super.initState();
    final push = widget.account.push;
    if (push != null && push.status == PushStatus.off) {
      unawaited(push.refresh());
    }
    widget.refresh?.addListener(load);
    alerts.addListener(_changed);
    load();
  }

  @override
  void dispose() {
    widget.refresh?.removeListener(load);
    alerts.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> load() => alerts.load();

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      fontSize: 12,
      color: BeaconColors.of(context).muted,
    );
    final loaded = alerts.data;
    final error = alerts.error;
    final targets = alerts.targets;
    final hasRules = targets.any(
      (t) => rows(t['rules']).any((r) => r['enabled'] == true),
    );
    final list = section(trKey('alerts.title'), [
      if (loaded == null && error != null)
        _LoadFailed(
          text: alertError(error),
          retry: trKey('alerts.retry'),
          onRetry: alerts.retry,
        )
      else if (loaded == null)
        const _Loading()
      else ...[
        if (targets.isEmpty) _Empty(trKey('alerts.empty')),
        for (final target in targets)
          _AlertTarget(
            key: ValueKey('alert-target-${textOf(target['publicKey'])}'),
            target: target,
            account: widget.account,
            unit: widget.unit,
            changed: load,
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(trKey('alerts.requestAttention'), style: muted),
        ),
      ],
    ]);
    if (loaded == null) return list;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AlertChannels(
          account: widget.account,
          channels: alerts.channels,
          hasRules: hasRules,
          serverName: widget.serverName,
          changed: alerts.setChannels,
        ),
        list,
      ],
    );
  }
}

/// Where this phone stands for push; asks for permission only on the button.
class _PushStatus extends StatelessWidget {
  const _PushStatus({required this.push});
  final PushRegistration? push;
  @override
  Widget build(BuildContext context) {
    final push = this.push;
    if (push == null) return _line(trKey('alerts.push.notSetUp'));
    return ListenableBuilder(
      listenable: push,
      builder: (context, _) => switch (push.status) {
        PushStatus.notSetUp => _line(trKey('alerts.push.notSetUp')),
        PushStatus.denied => _line(trKey('alerts.push.denied')),
        PushStatus.needsPermission => _action(
          'alerts-enable-push',
          trKey('alerts.push.enable'),
          push.enable,
        ),
        PushStatus.failed => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _line(trKey('alerts.push.failed')),
            _action('alerts-retry-push', trKey('alerts.retry'), push.refresh),
          ],
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }

  Widget _line(String text) =>
      Padding(padding: const EdgeInsets.only(top: 6), child: Text(text));

  Widget _action(String id, String label, Future<void> Function() run) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton(key: ValueKey(id), onPressed: run, child: Text(label)),
  );
}

class _AlertTarget extends StatelessWidget {
  const _AlertTarget({
    super.key,
    required this.target,
    required this.account,
    required this.unit,
    required this.changed,
  });
  final Json target;
  final AccountState account;
  final String unit;
  final Future<void> Function() changed;

  @override
  Widget build(BuildContext context) {
    final rules = rows(target['rules']);
    final key = textOf(target['publicKey']);
    final enabled = rules.where((r) => r['enabled'] == true).toList();
    final firing = [
      for (final r in enabled)
        if (r['state'] == 'firing') textOf(r['kind']),
    ];
    final colors = BeaconColors.of(context);
    final small = TextStyle(fontSize: 12, color: colors.muted);
    final lead = firing.isEmpty
        ? null
        : firing.length == 1
        ? trKey(
            'alerts.summaryFiring',
            count: 1,
          ).replaceAll('{{name}}', trKey('alerts.kind.${firing.first}'))
        : trKey('alerts.summaryFiring', count: firing.length);
    final tail = enabled.isEmpty
        ? trKey('alerts.summaryNone')
        : trKey('alerts.summaryOnCount', count: enabled.length);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      // Kept built while collapsed, so an unsaved threshold survives.
      child: ExpansionTile(
        key: ValueKey('alert-tile-$key'),
        tilePadding: EdgeInsets.zero,
        minTileHeight: 56,
        maintainState: true,
        childrenPadding: EdgeInsets.zero,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        title: Text(
          textOf(target['name'], shortKey(key)),
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        subtitle: Text.rich(
          TextSpan(
            style: small,
            children: [
              if (lead != null)
                TextSpan(
                  text: lead,
                  style: TextStyle(
                    color: colors.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (lead != null && enabled.isNotEmpty)
                const TextSpan(text: ' \u00b7 '),
              if (lead == null || enabled.isNotEmpty) TextSpan(text: tail),
            ],
          ),
        ),
        children: [
          const Divider(height: 12),
          AlertRuleList(
            target: target,
            account: account,
            unit: unit,
            changed: changed,
          ),
        ],
      ),
    );
  }
}
