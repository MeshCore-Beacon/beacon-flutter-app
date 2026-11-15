part of 'profile_screen.dart';

/// Alert rules for the radios on the user's Atlas. Only built when the server
/// has alerts on.
class _Alerts extends StatefulWidget {
  const _Alerts({required this.account, required this.deliveryHint});
  final AccountState account;

  /// The delivery the server's features announce, used until the list loads.
  final String? deliveryHint;
  @override
  State<_Alerts> createState() => _AlertsState();
}

class _AlertsState extends State<_Alerts> {
  Json? data;
  Object? error;

  @override
  void initState() {
    super.initState();
    final push = widget.account.push;
    if (push != null && push.status == PushStatus.off) {
      unawaited(push.refresh());
    }
    load();
  }

  Future<void> load() async {
    final epoch = widget.account.epoch;
    try {
      final next = await widget.account.api.alerts();
      if (mounted && widget.account.epoch == epoch) {
        setState(() {
          data = next;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && widget.account.epoch == epoch) {
        setState(() => error = e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      fontSize: 12,
      color: BeaconColors.of(context).muted,
    );
    final loaded = data;
    final delivery = textOf(loaded?['delivery'], widget.deliveryHint ?? '');
    final targets = rows(loaded?['targets']);
    return section(trKey('alerts.title'), [
      if (loaded == null && error != null)
        Row(
          children: [
            Expanded(child: Text(alertError(error!))),
            TextButton(
              onPressed: () {
                setState(() => error = null);
                load();
              },
              child: Text(trKey('alerts.retry')),
            ),
          ],
        )
      else if (loaded == null)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        )
      else ...[
        _delivery(delivery),
        if (delivery == 'push') _PushStatus(push: widget.account.push),
        if (targets.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(trKey('alerts.empty')),
          ),
        for (final target in targets)
          _AlertTarget(
            key: ValueKey('alert-target-${textOf(target['publicKey'])}'),
            target: target,
            account: widget.account,
            changed: load,
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(trKey('alerts.requestAttention'), style: muted),
        ),
      ],
    ]);
  }

  Widget _delivery(String delivery) {
    if (delivery == 'push') return Text(trKey('alerts.toPhone'));
    final email = textOf(widget.account.user?['email']);
    return Text(
      email.isEmpty
          ? trKey('alerts.byEmail')
          : trKey('alerts.toEmail').replaceAll('{{email}}', email),
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
    required this.changed,
  });
  final Json target;
  final AccountState account;
  final Future<void> Function() changed;

  @override
  Widget build(BuildContext context) {
    final available = [
      for (final k in target['available'] as List? ?? []) '$k',
    ];
    final unavailable = object(target['unavailable']);
    final rules = rows(target['rules']);
    final goneQuiet = rules.any(
      (r) => r['kind'] == 'gone_quiet' && r['enabled'] == true,
    );
    final key = textOf(target['publicKey']);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            textOf(target['name'], shortKey(key)),
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          for (final spec in alertKinds)
            if (available.contains(spec.kind) ||
                unavailable.containsKey(spec.kind))
              _AlertRow(
                key: ValueKey('alert-$key-${spec.kind}'),
                target: target,
                spec: spec,
                available: available,
                rule: rules.where((r) => r['kind'] == spec.kind).firstOrNull,
                reason: available.contains(spec.kind)
                    ? null
                    : textOf(unavailable[spec.kind]),
                goneQuietOn: goneQuiet,
                account: account,
                changed: changed,
              ),
        ],
      ),
    );
  }
}

class _AlertRow extends StatefulWidget {
  const _AlertRow({
    super.key,
    required this.target,
    required this.spec,
    required this.available,
    required this.rule,
    required this.reason,
    required this.goneQuietOn,
    required this.account,
    required this.changed,
  });
  final Json target;
  final AlertKindSpec spec;
  final List<String> available;
  final Json? rule;

  /// Set for a kind the server marked unavailable for this radio.
  final String? reason;
  final bool goneQuietOn;
  final AccountState account;
  final Future<void> Function() changed;
  @override
  State<_AlertRow> createState() => _AlertRowState();
}

class _AlertRowState extends State<_AlertRow> with _Action {
  final text = TextEditingController();
  final low = TextEditingController();
  final high = TextEditingController();
  late int selected;

  String get kind => widget.spec.kind;
  String get publicKey => textOf(widget.target['publicKey']);
  String get id => 'alert-$publicKey-$kind';
  bool get enabled => widget.rule?['enabled'] == true;
  int? _stored(String field) => number(widget.rule?[field])?.toInt();

  List<int> get options => widget.spec.input == AlertInput.hours
      ? goneQuietHours(textOf(widget.target['kind']), widget.available)
      : widget.spec.options;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(_AlertRow old) {
    super.didUpdateWidget(old);
    final a = old.rule, b = widget.rule;
    if (a?['threshold'] != b?['threshold'] ||
        a?['thresholdHigh'] != b?['thresholdHigh']) {
      _reset();
    }
  }

  void _reset() {
    final threshold = _stored('threshold');
    selected = threshold ?? defaultThreshold[kind] ?? 0;
    text.text = switch (widget.spec.input) {
      AlertInput.volts => voltsText(threshold),
      AlertInput.dbm => '${threshold ?? defaultThreshold['noise_high']}',
      _ => '',
    };
    low.text = tenthsText(threshold);
    high.text = tenthsText(_stored('thresholdHigh'));
  }

  @override
  void dispose() {
    text.dispose();
    low.dispose();
    high.dispose();
    super.dispose();
  }

  void _complain(String message) => setState(() {
    note = message;
    bad = true;
  });

  /// The thresholds the inputs show, or null after saying what is wrong.
  ({int? low, int? high})? _read() {
    switch (widget.spec.input) {
      case AlertInput.none:
        return (low: null, high: null);
      case AlertInput.hours ||
          AlertInput.drop ||
          AlertInput.drift ||
          AlertInput.minutes:
        return (low: selected, high: null);
      case AlertInput.volts:
        final mv = parseVolts(text.text);
        if (mv == null) _complain(trKey('alerts.errors.volts'));
        return mv == null ? null : (low: mv, high: null);
      case AlertInput.dbm:
        final dbm = parseDbm(text.text);
        if (dbm == null) _complain(trKey('alerts.errors.dbm'));
        return dbm == null ? null : (low: dbm, high: null);
      case AlertInput.temperature:
        final l = low.text.trim(), h = high.text.trim();
        if (l.isEmpty && h.isEmpty) {
          _complain(trKey('alerts.errors.temperatureNone'));
          return null;
        }
        final a = l.isEmpty ? null : parseTenths(l);
        final b = h.isEmpty ? null : parseTenths(h);
        if ((l.isNotEmpty && a == null) || (h.isNotEmpty && b == null)) {
          _complain(trKey('alerts.errors.temperature'));
          return null;
        }
        if ((a != null && !tenthsInRange(a)) ||
            (b != null && !tenthsInRange(b))) {
          _complain(trKey('alerts.errors.temperatureRange'));
          return null;
        }
        return (low: a, high: b);
    }
  }

  Future<void> _send(bool on, int? threshold, int? thresholdHigh) async {
    final ok = await run(() async {
      await widget.account.api.putAlertRule(
        targetKind: textOf(widget.target['kind'], 'node'),
        publicKey: publicKey,
        kind: kind,
        threshold: threshold,
        thresholdHigh: thresholdHigh,
        enabled: on,
      );
      return null;
    }, describe: alertError);
    if (ok) await widget.changed();
  }

  Future<void> toggle(bool on) async {
    if (!on) {
      // Turning off keeps what is stored, whatever is typed in the inputs.
      return _send(false, _stored('threshold'), _stored('thresholdHigh'));
    }
    setState(() => note = null);
    final values = _read();
    if (values != null) await _send(true, values.low, values.high);
  }

  /// A changed value on an enabled rule goes out at once.
  Future<void> commit() async {
    if (!enabled || busy || !mounted) return;
    final values = _read();
    if (values == null) return;
    if (values.low == _stored('threshold') &&
        values.high == _stored('thresholdHigh')) {
      setState(() => note = null);
      return;
    }
    await _send(true, values.low, values.high);
  }

  String _optionLabel(int value) => switch (widget.spec.input) {
    AlertInput.hours => trKey('alerts.hours', count: value),
    AlertInput.minutes => minutesLabel(value),
    AlertInput.drop => trKey(
      'alerts.voltsPerDay',
    ).replaceAll('{{volts}}', (value / 1000).toStringAsFixed(1)),
    AlertInput.drift => trKey('alerts.drift.$value'),
    _ => '$value',
  };

  String _inputLabel() => trKey(switch (widget.spec.input) {
    AlertInput.hours => 'alerts.input.hours',
    AlertInput.volts => 'alerts.input.volts',
    AlertInput.drop => 'alerts.input.drop',
    AlertInput.dbm => 'alerts.input.dbm',
    AlertInput.drift => 'alerts.input.drift',
    AlertInput.minutes => 'alerts.input.minutes',
    _ => 'alerts.input.hours',
  });

  Widget _input() {
    final inputId = 'alert-input-$publicKey-$kind';
    switch (widget.spec.input) {
      case AlertInput.none:
        return const SizedBox.shrink();
      case AlertInput.hours ||
          AlertInput.drop ||
          AlertInput.drift ||
          AlertInput.minutes:
        final choices = options.contains(selected)
            ? options
            : ([...options, selected]..sort());
        return InputDecorator(
          decoration: InputDecoration(labelText: _inputLabel(), isDense: true),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              key: ValueKey(inputId),
              isDense: true,
              isExpanded: true,
              value: selected,
              items: [
                for (final v in choices)
                  DropdownMenuItem(value: v, child: Text(_optionLabel(v))),
              ],
              onChanged: busy
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() => selected = v);
                      if (enabled) unawaited(commit());
                    },
            ),
          ),
        );
      case AlertInput.volts || AlertInput.dbm:
        return _field(
          inputId,
          text,
          _inputLabel(),
          decimal: widget.spec.input == AlertInput.volts,
        );
      case AlertInput.temperature:
        return Row(
          children: [
            Expanded(
              child: _field(
                '$inputId-low',
                low,
                trKey('alerts.input.low'),
                decimal: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _field(
                '$inputId-high',
                high,
                trKey('alerts.input.high'),
                decimal: true,
              ),
            ),
          ],
        );
    }
  }

  Widget _field(
    String key,
    TextEditingController controller,
    String label, {
    required bool decimal,
  }) => Focus(
    onFocusChange: (focused) {
      if (!focused) unawaited(commit());
    },
    child: TextField(
      key: ValueKey(key),
      controller: controller,
      enabled: !busy,
      keyboardType: TextInputType.numberWithOptions(
        signed: true,
        decimal: decimal,
      ),
      decoration: InputDecoration(labelText: label, isDense: true),
      onSubmitted: (_) => unawaited(commit()),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      fontSize: 12,
      color: BeaconColors.of(context).muted,
    );
    final reason = widget.reason;
    final label = trKey('alerts.kind.$kind');
    final needsGoneQuiet = kind == 'back_online' && !widget.goneQuietOn;
    final locked = busy || (needsGoneQuiet && !enabled);
    final rule = widget.rule;
    return Opacity(
      opacity: reason != null ? .6 : 1,
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (reason == null)
                  Switch(
                    key: ValueKey('alert-switch-$publicKey-$kind'),
                    value: enabled,
                    onChanged: locked ? null : toggle,
                  ),
              ],
            ),
            if (reason != null)
              Text(reason, style: muted)
            else ...[
              Text(trKey('alerts.when.$kind'), style: muted),
              if (needsGoneQuiet && !enabled)
                Text(
                  trKey('alerts.needsGoneQuiet')
                      .replaceAll('{{name}}', trKey('alerts.kind.gone_quiet')),
                  style: muted,
                ),
              _input(),
              if (enabled && rule != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    alertStateText(
                      textOf(rule['state']),
                      _date(rule['stateChangedAt']),
                    ),
                    style: muted,
                  ),
                ),
              noteLine(context),
            ],
          ],
        ),
      ),
    );
  }
}
