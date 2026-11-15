import 'package:flutter/material.dart';

import '../../core/account.dart';
import '../../core/api.dart';
import '../../core/features.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../directory/directory_widgets.dart';
import '../directory/telemetry_request.dart';
import 'account_errors.dart';
import 'request_text.dart';

part 'telemetry_requests_section.dart';

/// Profile for the signed-in user: account, password, devices, deletion.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.account,
    this.api,
    this.onOpen,
  });
  final AccountState account;

  /// With the server's client the profile can show telemetry requests, and
  /// [onOpen] opens a repeater from one.
  final ApiClient? api;
  final void Function(String, String)? onOpen;
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  /// Bumped when something ends other sessions, so Devices reloads.
  final devices = ValueNotifier<int>(0);
  bool left = false;

  /// Local until the server's features say otherwise; null while they load.
  ServerFeatures? features;

  @override
  void initState() {
    super.initState();
    widget.account.addListener(changed);
    final api = widget.api;
    if (api == null) {
      features = const ServerFeatures.off();
    } else {
      api.features().then((f) {
        if (mounted) setState(() => features = f);
      });
    }
  }

  /// A 401 anywhere (or a sign out) clears the account; nothing to show then.
  void changed() {
    if (widget.account.signedIn || left || !mounted) return;
    left = true;
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    widget.account.removeListener(changed);
    devices.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(trKey('account.profile'))),
    body: ListenableBuilder(
      listenable: widget.account,
      builder: (context, _) {
        final user = widget.account.user;
        final features = this.features;
        if (user == null) return const SizedBox.shrink();
        if (features == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final portal = features.portal;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            section(trKey('account.sectionAccount'), [
              _NameForm(account: widget.account),
              // The portal owns the email address of its users.
              if (!portal) ...[
                const SizedBox(height: 16),
                _EmailForm(account: widget.account),
              ],
            ]),
            if (portal)
              section(trKey('account.sectionPortal'), [
                Text(trKey('account.portalManaged')),
                if (features.portalUrl case final url?)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(url),
                  ),
              ])
            else
              section(trKey('account.sectionPassword'), [
                _PasswordForm(account: widget.account, devices: devices),
              ]),
            if (widget.api case final api?)
              _TelemetryRequests(
                account: widget.account,
                api: api,
                onOpen: widget.onOpen,
              ),
            section(trKey('account.sectionDevices'), [
              _Devices(account: widget.account, revision: devices),
            ]),
            section(trKey('account.sectionDelete'), [
              _DeleteForm(account: widget.account, portal: portal),
            ]),
          ],
        );
      },
    ),
  );
}

/// One action's progress and inline result, owned by the section that runs it.
mixin _Action<T extends StatefulWidget> on State<T> {
  bool busy = false;
  String? note;
  bool bad = false;

  /// Runs [action]; its returned text is the success note, a thrown error
  /// becomes the mapped failure note. True when it succeeded.
  Future<bool> run(
    Future<String?> Function() action, {
    String Function(Object)? describe,
  }) async {
    setState(() {
      busy = true;
      note = null;
    });
    String? result;
    Object? failure;
    try {
      result = await action();
    } catch (e) {
      failure = e;
    }
    if (!mounted) return failure == null;
    setState(() {
      busy = false;
      bad = failure != null;
      note = failure == null ? result : (describe ?? accountError)(failure);
    });
    return failure == null;
  }

  Widget noteLine(BuildContext context) {
    final text = note;
    if (text == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(text, style: TextStyle(color: bad ? colors.error : null)),
    );
  }
}

/// Shows a spinner in place of the label while [busy], and is off then.
class _Button extends StatelessWidget {
  const _Button({
    required this.id,
    required this.label,
    required this.busy,
    required this.onPressed,
    this.danger = false,
  });
  final String id;
  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final style = danger
        ? FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          )
        : null;
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton(
        key: ValueKey(id),
        style: style,
        onPressed: busy ? null : onPressed,
        child: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(label),
      ),
    );
  }
}

class _PasswordField extends StatefulWidget {
  const _PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.hint = AutofillHints.password,
  });
  final TextEditingController controller;
  final String label;
  final String hint;
  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool shown = false;
  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    obscureText: !shown,
    autocorrect: false,
    enableSuggestions: false,
    autofillHints: [widget.hint],
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: IconButton(
        tooltip: trKey(shown ? 'account.hidePassword' : 'account.showPassword'),
        icon: Icon(shown ? Icons.visibility_off : Icons.visibility, size: 20),
        onPressed: () => setState(() => shown = !shown),
      ),
    ),
  );
}

class _NameForm extends StatefulWidget {
  const _NameForm({required this.account});
  final AccountState account;
  @override
  State<_NameForm> createState() => _NameFormState();
}

class _NameFormState extends State<_NameForm> with _Action {
  late final name = TextEditingController(
    text: textOf(widget.account.user?['displayName']),
  );

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() => run(() async {
    final user = await widget.account.api.setDisplayName(name.text.trim());
    widget.account.adopt(user);
    name.text = textOf(user['displayName'], name.text);
    return trKey('account.saved');
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: const ValueKey('display-name'),
        controller: name,
        maxLength: 40,
        decoration: InputDecoration(labelText: trKey('account.displayName')),
      ),
      _Button(
        id: 'name-save',
        label: trKey('account.save'),
        busy: busy,
        onPressed: save,
      ),
      noteLine(context),
    ],
  );
}

class _EmailForm extends StatefulWidget {
  const _EmailForm({required this.account});
  final AccountState account;
  @override
  State<_EmailForm> createState() => _EmailFormState();
}

class _EmailFormState extends State<_EmailForm> with _Action {
  final email = TextEditingController();
  final password = TextEditingController();

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final address = email.text.trim();
    final ok = await run(() async {
      await widget.account.api.changeEmail(address, password.text);
      return trKey('account.emailSent').replaceAll('{{email}}', address);
    });
    if (!ok) return;
    password.clear();
    // The pending address shows once the server reports it.
    await widget.account.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.account.user ?? const {};
    final pending = user['pendingEmail'];
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            trKey('account.email'),
            style: TextStyle(fontSize: 11, color: muted),
          ),
          const SizedBox(height: 4),
          Text(textOf(user['email'])),
          Text(
            trKey(
              user['emailVerified'] == true
                  ? 'account.verified'
                  : 'account.pendingVerification',
            ),
            style: TextStyle(fontSize: 12, color: muted),
          ),
          if (pending is String && pending.isNotEmpty)
            Text(
              trKey('account.pendingFor').replaceAll('{{email}}', pending),
              style: TextStyle(fontSize: 12, color: muted),
            ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('email-new'),
            controller: email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(labelText: trKey('account.newEmail')),
          ),
          _PasswordField(
            key: const ValueKey('email-password'),
            controller: password,
            label: trKey('account.currentPassword'),
          ),
          const SizedBox(height: 8),
          _Button(
            id: 'email-save',
            label: trKey('account.changeEmail'),
            busy: busy,
            onPressed: save,
          ),
          noteLine(context),
        ],
      ),
    );
  }
}

class _PasswordForm extends StatefulWidget {
  const _PasswordForm({required this.account, required this.devices});
  final AccountState account;
  final ValueNotifier<int> devices;
  @override
  State<_PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends State<_PasswordForm> with _Action {
  final current = TextEditingController();
  final next = TextEditingController();

  @override
  void dispose() {
    current.dispose();
    next.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final ok = await run(() async {
      await widget.account.api.changePassword(current.text, next.text);
      return trKey('account.passwordChanged');
    });
    if (!ok) return;
    current.clear();
    next.clear();
    // Every other session just ended, so the list is stale.
    widget.devices.value++;
  }

  @override
  Widget build(BuildContext context) => AutofillGroup(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PasswordField(
          key: const ValueKey('pw-current'),
          controller: current,
          label: trKey('account.currentPassword'),
        ),
        _PasswordField(
          key: const ValueKey('pw-new'),
          controller: next,
          label: trKey('account.newPassword'),
          hint: AutofillHints.newPassword,
        ),
        const SizedBox(height: 8),
        _Button(
          id: 'pw-save',
          label: trKey('account.changePassword'),
          busy: busy,
          onPressed: save,
        ),
        noteLine(context),
      ],
    ),
  );
}

String _date(dynamic value) {
  final d = epoch(value);
  if (d == null) return '-';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class _Devices extends StatefulWidget {
  const _Devices({required this.account, required this.revision});
  final AccountState account;
  final ValueNotifier<int> revision;
  @override
  State<_Devices> createState() => _DevicesState();
}

class _DevicesState extends State<_Devices> with _Action {
  List<Json>? sessions;
  bool failed = false;
  String? endingId;

  @override
  void initState() {
    super.initState();
    widget.revision.addListener(load);
    load();
  }

  @override
  void dispose() {
    widget.revision.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    try {
      final list = await widget.account.api.sessions();
      if (mounted) {
        setState(() {
          sessions = list;
          failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  Future<void> end(Json row) async {
    final id = textOf(row['id']);
    setState(() => endingId = id);
    final current = row['current'] == true;
    final ok = await run(() async {
      if (current) {
        await widget.account.signOut();
      } else {
        await widget.account.api.endSession(id);
      }
      return null;
    });
    if (mounted) setState(() => endingId = null);
    if (ok && !current) await load();
  }

  Future<void> endOthers() async {
    final ok = await run(() async {
      await widget.account.api.endOtherSessions();
      return trKey('account.othersEnded');
    });
    if (ok) await load();
  }

  @override
  Widget build(BuildContext context) {
    final list = sessions;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (list == null && failed)
          Row(
            children: [
              Expanded(child: Text(trKey('account.devicesFailed'))),
              TextButton(onPressed: load, child: Text(trKey('account.retry'))),
            ],
          )
        else if (list == null)
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
        else
          for (final row in list)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          textOf(row['label']),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            Text(
                              trKey(
                                row['kind'] == 'app'
                                    ? 'account.app'
                                    : 'account.browser',
                              ),
                              style: TextStyle(fontSize: 12, color: muted),
                            ),
                            if (row['current'] == true)
                              Text(
                                trKey('account.thisDevice'),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                          ],
                        ),
                        Text(
                          trKey('account.lastUsed')
                              .replaceAll('{{when}}', age(row['lastUsedAt'])),
                          style: TextStyle(fontSize: 12, color: muted),
                        ),
                        Text(
                          trKey('account.created')
                              .replaceAll('{{when}}', _date(row['createdAt'])),
                          style: TextStyle(fontSize: 12, color: muted),
                        ),
                      ],
                    ),
                  ),
                  if (busy && endingId == textOf(row['id']))
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    TextButton(
                      key: ValueKey('session-end-${textOf(row['id'])}'),
                      onPressed: busy ? null : () => end(row),
                      child: Text(trKey('account.endSession')),
                    ),
                ],
              ),
            ),
        const SizedBox(height: 8),
        _Button(
          id: 'devices-others',
          label: trKey('account.endOthers'),
          busy: busy && endingId == null,
          onPressed: busy ? null : endOthers,
        ),
        noteLine(context),
      ],
    );
  }
}

class _DeleteForm extends StatefulWidget {
  const _DeleteForm({required this.account, required this.portal});
  final AccountState account;

  /// Portal accounts have no password; the typed username confirms.
  final bool portal;
  @override
  State<_DeleteForm> createState() => _DeleteFormState();
}

class _DeleteFormState extends State<_DeleteForm> with _Action {
  final password = TextEditingController();
  final typed = TextEditingController();

  @override
  void dispose() {
    password.dispose();
    typed.dispose();
    super.dispose();
  }

  String get username => textOf(widget.account.user?['username']);

  // The account and its token are gone on success, which closes this screen.
  Future<void> delete() => run(() async {
    await (widget.portal
        ? widget.account.api.deleteAccount(confirmUsername: typed.text.trim())
        : widget.account.api.deleteAccount(currentPassword: password.text));
    return null;
  });

  @override
  Widget build(BuildContext context) => AutofillGroup(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(trKey('account.deleteExplain')),
        if (!widget.portal)
          _PasswordField(
            key: const ValueKey('delete-password'),
            controller: password,
            label: trKey('account.currentPassword'),
          ),
        TextField(
          key: const ValueKey('delete-username'),
          controller: typed,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: trKey('account.typeUsername')
                .replaceAll('{{username}}', username),
          ),
        ),
        const SizedBox(height: 8),
        _Button(
          id: 'delete-confirm',
          label: trKey('account.deleteButton'),
          busy: busy,
          danger: true,
          onPressed: typed.text.trim() == username && username.isNotEmpty
              ? delete
              : null,
        ),
        noteLine(context),
      ],
    ),
  );
}
