part of 'profile_screen.dart';

/// The user's telemetry requests, one row each. Draws nothing unless the server
/// has requests on.
class _TelemetryRequests extends StatefulWidget {
  const _TelemetryRequests({
    required this.account,
    required this.api,
    this.onOpen,
    this.refresh,
  });
  final AccountState account;
  final ApiClient api;
  final void Function(String, String)? onOpen;
  final ValueNotifier<int>? refresh;
  @override
  State<_TelemetryRequests> createState() => _TelemetryRequestsState();
}

class _TelemetryRequestsState extends State<_TelemetryRequests> {
  bool enabled = false, loaded = false, failed = false;
  List<Json> requests = [];
  int limit = 0;

  @override
  void initState() {
    super.initState();
    widget.refresh?.addListener(load);
    load();
  }

  @override
  void dispose() {
    widget.refresh?.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final epoch = widget.account.epoch;
    bool stale() => !mounted || widget.account.epoch != epoch;
    try {
      final features = await widget.api.features();
      if (stale()) return;
      if (!features.telemetryRequests) return;
      setState(() => enabled = true);
      final data = await widget.account.api.telemetryRequests();
      if (stale()) return;
      setState(() {
        loaded = true;
        failed = false;
        requests = rows(data['requests']);
        limit = (number(data['limit']) ?? 0).toInt();
      });
    } catch (_) {
      if (!stale()) setState(() => failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();
    final muted = BeaconColors.of(context).muted;
    return section(trKey('telemetryRequests.title'), [
      if (loaded)
        Text(
          trKey('telemetryRequests.count')
              .replaceAll('{{used}}', '${requests.length}')
              .replaceAll('{{limit}}', '$limit'),
          style: TextStyle(fontSize: 12, color: muted),
        ),
      if (failed && !loaded)
        _LoadFailed(
          text: trKey('telemetryRequests.loadFailed'),
          retry: trKey('telemetryRequests.retry'),
          onRetry: () {
            setState(() => failed = false);
            load();
          },
        )
      else if (!loaded)
        const _Loading()
      else if (requests.isEmpty)
        _Empty(trKey('telemetryRequests.empty'))
      else
        for (final request in requests)
          _RequestRow(
            key: ValueKey('request-row-${textOf(request['id'])}'),
            request: request,
            account: widget.account,
            onOpen: widget.onOpen,
            changed: load,
          ),
    ]);
  }
}

class _RequestRow extends StatefulWidget {
  const _RequestRow({
    super.key,
    required this.request,
    required this.account,
    required this.onOpen,
    required this.changed,
  });
  final Json request;
  final AccountState account;
  final void Function(String, String)? onOpen;

  /// Reads the list again after this row changed it.
  final Future<void> Function() changed;
  @override
  State<_RequestRow> createState() => _RequestRowState();
}

class _RequestRowState extends State<_RequestRow> with _Action {
  final password = TextEditingController();
  bool editing = false, confirming = false;

  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  String get id => textOf(widget.request['id']);

  Future<void> savePassword() async {
    final ok = await run(
      () async {
        await widget.account.api.updateTelemetryRequest(
          id,
          withPassword: true,
          password: password.text,
        );
        return null;
      },
      describe: (e) {
        // A stopped request cannot take a blank login, so a refusal there reads differently.
        final stopped = widget.request['status'] == 'admin_stopped';
        if (stopped && e is ApiException && e.code == 'password_invalid') {
          return trKey('telemetryRequests.errors.password_invalid_stopped');
        }
        return requestError(e);
      },
    );
    if (!ok || !mounted) return;
    password.clear();
    setState(() => editing = false);
    await widget.changed();
  }

  Future<void> reenable() async {
    final ok = await run(() async {
      await widget.account.api.updateTelemetryRequest(id, enabled: true);
      return null;
    }, describe: requestError);
    if (ok) await widget.changed();
  }

  Future<void> remove() async {
    final ok = await run(() async {
      await widget.account.api.deleteTelemetryRequest(id);
      return null;
    }, describe: requestError);
    if (ok) {
      await widget.changed();
    } else if (mounted) {
      setState(() => confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final node = object(r['node']);
    final nodeId = textOf(node['id']);
    final muted = TextStyle(
      fontSize: 12,
      color: BeaconColors.of(context).muted,
    );
    final poller = object(r['poller']);
    final reason = requestReasonText(r);
    // Only a new password restarts these; enable and a blank login do nothing.
    final stopped = r['status'] == 'admin_stopped';
    final needsNew = stopped || r['status'] == 'login_failed';
    final name = textOf(
      node['name'],
      trKey('telemetryRequests.unknownRepeater'),
    );
    final colors = BeaconColors.of(context);
    final tone = requestDotColor(r, colors);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      decoration: BoxDecoration(
        border: Border.all(color: colors.borderSubtle),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('request-open-$id'),
            onTap: nodeId.isEmpty || widget.onOpen == null
                ? null
                : () => widget.onOpen!('node', nodeId),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Icon(Icons.circle, size: 9, color: tone),
              ),
              Expanded(child: Text(requestLineText(r))),
            ],
          ),
          if (reason.isNotEmpty) Text(reason, style: muted),
          if (stopped)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                trKey('telemetryRequests.adminStoppedHelp'),
                style: TextStyle(fontSize: 13, color: colors.danger),
              ),
            ),
          if (poller.isNotEmpty && !requestLineNamesPoller(r))
            Text(
              trKey('telemetryRequests.polledBy')
                  .replaceAll('{{name}}', textOf(poller['name'], '?')),
              style: muted,
            ),
          Text(
            r['latestReadingAt'] == null
                ? trKey('telemetryRequests.noReading')
                : trKey('telemetryRequests.lastReading')
                      .replaceAll('{{when}}', age(r['latestReadingAt'])),
            style: muted,
          ),
          Text(
            trKey(
              r['hasPassword'] == true
                  ? 'telemetryRequests.passwordSet'
                  : 'telemetryRequests.passwordNone',
            ),
            style: muted,
          ),
          if (editing) ...[
            const SizedBox(height: 8),
            GuestPasswordField(
              key: ValueKey('request-pw-field-$id'),
              controller: password,
              label: trKey(
                stopped
                    ? 'telemetryRequests.newPasswordRequired'
                    : 'telemetryRequests.newPassword',
              ),
            ),
            Text(trKey('telemetryRequests.notice'), style: muted),
            Row(
              children: [
                ListenableBuilder(
                  listenable: password,
                  builder: (_, _) => FilledButton(
                    key: ValueKey('request-pw-save-$id'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: busy || (stopped && password.text.isEmpty)
                        ? null
                        : savePassword,
                    child: Text(trKey('telemetryRequests.save')),
                  ),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          editing = false;
                          password.clear();
                        }),
                  child: Text(trKey('telemetryRequests.cancel')),
                ),
              ],
            ),
          ] else if (confirming) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(trKey('telemetryRequests.confirmRemove')),
            ),
            Row(
              children: [
                _Button(
                  id: 'request-remove-confirm-$id',
                  label: trKey('telemetryRequests.remove'),
                  busy: busy,
                  danger: true,
                  wide: false,
                  onPressed: remove,
                ),
                TextButton(
                  key: ValueKey('request-remove-cancel-$id'),
                  onPressed: busy
                      ? null
                      : () => setState(() => confirming = false),
                  child: Text(trKey('telemetryRequests.cancel')),
                ),
              ],
            ),
          ] else
            Wrap(
              children: [
                TextButton(
                  key: ValueKey('request-pw-$id'),
                  onPressed: busy ? null : () => setState(() => editing = true),
                  child: Text(
                    trKey(
                      needsNew
                          ? 'telemetryRequests.enterNewPassword'
                          : 'telemetryRequests.changePassword',
                    ),
                  ),
                ),
                if (r['status'] == 'disabled')
                  TextButton(
                    key: ValueKey('request-enable-$id'),
                    onPressed: busy ? null : reenable,
                    child: Text(trKey('telemetryRequests.reenable')),
                  ),
                TextButton(
                  key: ValueKey('request-remove-$id'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: busy
                      ? null
                      : () => setState(() => confirming = true),
                  child: Text(trKey('telemetryRequests.remove')),
                ),
              ],
            ),
          noteLine(context),
        ],
      ),
    );
  }
}
