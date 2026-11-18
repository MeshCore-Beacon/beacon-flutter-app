import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/account.dart';
import '../../core/api.dart';
import '../../core/features.dart';
import '../../core/json.dart';
import '../../core/push.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../../core/units.dart';
import '../directory/directory_widgets.dart';
import '../directory/telemetry_request.dart';
import 'account_errors.dart';
import 'account_section.dart' show confirmAction;
import 'alert_rules.dart';
import 'password_rule.dart';
import 'request_text.dart';

part 'alert_channels.dart';
part 'alerts_section.dart';
part 'telemetry_requests_section.dart';

/// Profile for the signed-in user: account, password, devices, deletion.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.account,
    this.api,
    this.onOpen,
    this.serverName = '',
  });
  final AccountState account;

  /// The saved server's name, shown in the push line.
  final String serverName;

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

  /// Bumped by pull to refresh so the server lists reload.
  final refresh = ValueNotifier<int>(0);
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
    refresh.dispose();
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
        return RefreshIndicator(
          onRefresh: () async {
            devices.value++;
            refresh.value++;
            await Future<void>.delayed(const Duration(milliseconds: 500));
          },
          child: ListView(
            // New account, new forms: typed passwords never carry over.
            key: ValueKey('profile-${widget.account.epoch}'),
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              12,
              12,
              12,
              24 + MediaQuery.viewPaddingOf(context).bottom,
            ),
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
                  refresh: refresh,
                ),
              if (features.alerts)
                _Alerts(
                  account: widget.account,
                  unit: features.temperatureUnit,
                  serverName: widget.serverName,
                  refresh: refresh,
                ),
              section(trKey('account.sectionDevices'), [
                _Devices(account: widget.account, revision: devices),
              ]),
              section(trKey('account.sectionDelete'), [
                _DeleteForm(account: widget.account),
              ]),
            ],
          ),
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

/// The spinner every loading list shows.
class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 16),
    child: Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

/// A load error with its Retry, used by every list that reads the server.
class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.text, required this.retry, this.onRetry});
  final String text, retry;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final danger = BeaconColors.of(context).danger;
    return Row(
      children: [
        Icon(Icons.error_outline, size: 18, color: danger),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
        TextButton(onPressed: onRetry, child: Text(retry)),
      ],
    );
  }
}

/// Text under a heading that says what to do when a list is empty.
class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      text,
      style: TextStyle(color: BeaconColors.of(context).muted, fontSize: 13),
    ),
  );
}

/// Full width and 48 high. A spinner replaces the label while [busy]; it is
/// off then and whenever [onPressed] is null. [danger] fills it red,
/// [quiet] is an outlined red button for the step before a confirmation.
class _Button extends StatelessWidget {
  const _Button({
    required this.id,
    required this.label,
    required this.busy,
    required this.onPressed,
    this.danger = false,
    this.quiet = false,
    this.wide = true,
  });
  final String id;
  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final bool danger, quiet, wide;
  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    final size = Size(wide ? double.infinity : 48, 48);
    final child = busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label);
    final press = busy ? null : onPressed;
    final button = quiet
        ? OutlinedButton(
            key: ValueKey(id),
            style: OutlinedButton.styleFrom(
              minimumSize: size,
              foregroundColor: error,
              side: BorderSide(color: error.withValues(alpha: .6)),
            ),
            onPressed: press,
            child: child,
          )
        : FilledButton(
            key: ValueKey(id),
            style: FilledButton.styleFrom(
              minimumSize: size,
              backgroundColor: danger ? error : null,
              foregroundColor: danger
                  ? Theme.of(context).colorScheme.onError
                  : null,
            ),
            onPressed: press,
            child: child,
          );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Align(alignment: Alignment.centerLeft, child: button),
    );
  }
}

/// Spacing between fields of one form.
const _gap = SizedBox(height: 12);

class _PasswordField extends StatefulWidget {
  const _PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.hint = AutofillHints.password,
    this.helper,
    this.error,
    this.onChanged,
    this.action = TextInputAction.next,
    this.onDone,
  });
  final TextEditingController controller;
  final String label;
  final String hint;
  final String? helper, error;
  final ValueChanged<String>? onChanged;
  final TextInputAction action;
  final VoidCallback? onDone;
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
    textInputAction: widget.action,
    onChanged: widget.onChanged,
    onSubmitted: (_) => widget.onDone?.call(),
    decoration: InputDecoration(
      labelText: widget.label,
      helperText: widget.helper,
      helperMaxLines: 3,
      errorText: widget.error,
      errorMaxLines: 3,
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

  String get stored => textOf(widget.account.user?['displayName']);
  bool get valid => name.text.trim().isNotEmpty && name.text.trim() != stored;

  Future<void> save() => run(() async {
    final user = await widget.account.api.setDisplayName(name.text.trim());
    widget.account.adopt(user);
    if (mounted) name.text = textOf(user['displayName'], name.text);
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
        maxLengthEnforcement: MaxLengthEnforcement.enforced,
        buildCounter: (
          _, {
          required currentLength,
          required isFocused,
          maxLength,
        }) => null,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.name],
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (valid && !busy) save();
        },
        decoration: InputDecoration(
          labelText: trKey('account.displayName'),
          helperText: trKey('accountUi.nameHelper'),
        ),
      ),
      _Button(
        id: 'name-save',
        label: trKey('account.save'),
        busy: busy,
        onPressed: valid ? save : null,
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

  static final _shape = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  bool get emailOk => _shape.hasMatch(email.text.trim());
  bool get valid => emailOk && password.text.isNotEmpty;

  Future<void> save() async {
    final address = email.text.trim();
    final ok = await run(() async {
      await widget.account.api.changeEmail(address, password.text);
      return trKey('account.emailSent').replaceAll('{{email}}', address);
    });
    if (!ok) return;
    if (mounted) password.clear();
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
            style: TextStyle(
              fontSize: 12,
              color: user['emailVerified'] == true
                  ? BeaconColors.of(context).success
                  : BeaconColors.of(context).warning,
            ),
          ),
          if (pending is String && pending.isNotEmpty)
            Text(
              trKey('account.pendingFor').replaceAll('{{email}}', pending),
              style: TextStyle(fontSize: 12, color: muted),
            ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('email-new'),
            controller: email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            textCapitalization: TextCapitalization.none,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.email],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: trKey('account.newEmail'),
              helperText: trKey('accountUi.emailHelper'),
              helperMaxLines: 2,
              errorText: email.text.trim().isNotEmpty && !emailOk
                  ? trKey('accountUi.emailInvalid')
                  : null,
            ),
          ),
          _gap,
          _PasswordField(
            key: const ValueKey('email-password'),
            controller: password,
            label: trKey('account.currentPassword'),
            helper: trKey('accountUi.passwordHelper'),
            action: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onDone: () {
              if (valid && !busy) save();
            },
          ),
          _Button(
            id: 'email-save',
            label: trKey('account.changeEmail'),
            busy: busy,
            onPressed: valid ? save : null,
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

  bool get valid => current.text.isNotEmpty && newPasswordOk(next.text);

  Future<void> save() async {
    final ok = await run(() async {
      await widget.account.api.changePassword(current.text, next.text);
      return trKey('account.passwordChanged');
    });
    if (!ok || !mounted) return;
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
          onChanged: (_) => setState(() {}),
        ),
        _gap,
        _PasswordField(
          key: const ValueKey('pw-new'),
          controller: next,
          label: trKey('account.newPassword'),
          hint: AutofillHints.newPassword,
          helper: trKey('passwordRule.hint'),
          // Red only once something is typed, so the form opens calm.
          error: passwordTooLong(next.text)
              ? trKey('passwordRule.tooLong')
              : next.text.isNotEmpty && !newPasswordOk(next.text)
              ? trKey('passwordRule.hint')
              : null,
          action: TextInputAction.done,
          onChanged: (_) => setState(() {}),
          onDone: () {
            if (valid && !busy) save();
          },
        ),
        _Button(
          id: 'pw-save',
          label: trKey('account.changePassword'),
          busy: busy,
          onPressed: valid ? save : null,
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
    if (ok && !current && mounted) await load();
  }

  Future<void> endOthers() async {
    final yes = await confirmAction(
      context,
      title: trKey('accountUi.endOthersTitle'),
      body: trKey('accountUi.endOthersBody'),
      action: trKey('account.endOthers'),
      danger: true,
    );
    if (!yes || !mounted) return;
    final ok = await run(() async {
      await widget.account.api.endOtherSessions();
      return trKey('account.othersEnded');
    });
    if (ok && mounted) await load();
  }

  Widget _row(BuildContext context, Json row) {
    final colors = BeaconColors.of(context);
    final muted = TextStyle(fontSize: 12, color: colors.muted);
    final id = textOf(row['id']);
    final current = row['current'] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: current
              ? colors.primary.withValues(alpha: .5)
              : colors.borderSubtle,
        ),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      textOf(row['label']),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (current)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          trKey('account.thisDevice'),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: colors.primary,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  trKey(
                    row['kind'] == 'app' ? 'account.app' : 'account.browser',
                  ),
                  style: muted,
                ),
                Text(
                  trKey('account.lastUsed')
                      .replaceAll('{{when}}', age(row['lastUsedAt'])),
                  style: muted,
                ),
                Text(
                  trKey('account.created')
                      .replaceAll('{{when}}', _date(row['createdAt'])),
                  style: muted,
                ),
              ],
            ),
          ),
          if (busy && endingId == id)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton(
              key: ValueKey('session-end-$id'),
              onPressed: busy ? null : () => end(row),
              child: Text(trKey('account.endSession')),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = sessions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (list == null && failed)
          _LoadFailed(
            text: trKey('account.devicesFailed'),
            retry: trKey('account.retry'),
            onRetry: load,
          )
        else if (list == null)
          const _Loading()
        else if (list.isEmpty)
          _Empty(trKey('accountUi.noDevices'))
        else
          for (final row in list) _row(context, row),
        _Button(
          id: 'devices-others',
          label: trKey('account.endOthers'),
          busy: busy && endingId == null,
          quiet: true,
          onPressed: busy ? null : endOthers,
        ),
        noteLine(context),
      ],
    );
  }
}

class _DeleteForm extends StatefulWidget {
  const _DeleteForm({required this.account});
  final AccountState account;
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

  /// Portal accounts have no password; the typed username confirms. The
  /// account decides, as on the server, not the server's mode.
  bool get portal => widget.account.user?['provider'] == 'portal';

  // The account and its token are gone on success, which closes this screen.
  Future<void> delete() => run(() async {
    await (portal
        ? widget.account.api.deleteAccount(confirmUsername: typed.text.trim())
        : widget.account.api.deleteAccount(currentPassword: password.text));
    return null;
  }, describe: (e) => deleteError(e, portal: portal));

  Future<void> confirmDelete() async {
    final yes = await confirmAction(
      context,
      title: trKey('accountUi.deleteTitle'),
      body: trKey('account.deleteExplain'),
      action: trKey('account.deleteButton'),
      danger: true,
    );
    if (yes && mounted) await delete();
  }

  @override
  Widget build(BuildContext context) => AutofillGroup(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(trKey('account.deleteExplain')),
        const SizedBox(height: 12),
        if (!portal) ...[
          _PasswordField(
            key: const ValueKey('delete-password'),
            controller: password,
            label: trKey('account.currentPassword'),
            onChanged: (_) => setState(() {}),
          ),
          _gap,
        ],
        TextField(
          key: const ValueKey('delete-username'),
          controller: typed,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: trKey('account.typeUsername')
                .replaceAll('{{username}}', username),
            helperText: trKey('accountUi.deleteUsernameHelper'),
          ),
        ),
        _Button(
          id: 'delete-confirm',
          label: trKey('account.deleteButton'),
          busy: busy,
          danger: true,
          onPressed:
              typed.text.trim() == username &&
                  username.isNotEmpty &&
                  (portal || password.text.isNotEmpty)
              ? confirmDelete
              : null,
        ),
        noteLine(context),
      ],
    ),
  );
}
