import 'package:flutter/material.dart';

import '../../core/account.dart';
import '../../core/api.dart';
import '../../core/features.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'profile_screen.dart';
import 'sign_in.dart';

/// The account block in Settings for one server. Draws nothing until the
/// server's features say accounts are on.
class AccountSection extends StatefulWidget {
  const AccountSection({
    super.key,
    required this.account,
    required this.api,
    required this.serverName,
    this.onOpen,
  });
  final AccountState account;
  final ApiClient api;
  final String serverName;
  final void Function(String, String)? onOpen;
  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  late Future<ServerFeatures> features = widget.api.features();
  String? error;
  bool starting = false;

  @override
  void didUpdateWidget(AccountSection old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api) features = widget.api.features();
  }

  Future<void> signIn(SignInFlow flow) async {
    setState(() {
      starting = true;
      error = null;
    });
    try {
      await flow.start(widget.account.api.base);
    } on ApiException catch (e) {
      error = e.message;
    }
    if (mounted) setState(() => starting = false);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ServerFeatures>(
    future: features,
    builder: (context, snapshot) {
      final data = snapshot.data;
      if (data == null || data.accounts == 'off') {
        return const SizedBox.shrink();
      }
      final flow = SignInScope.maybeOf(context);
      return ListenableBuilder(
        listenable: Listenable.merge([widget.account, ?flow]),
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                trKey('account.heading')
                    .replaceAll('{{server}}', widget.serverName)
                    .toUpperCase(),
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  letterSpacing: .8,
                  color: BeaconColors.of(context).bright,
                ),
              ),
            ),
            if (widget.account.signedIn)
              ..._signedIn(context)
            else
              ..._signedOut(context, flow, data),
          ],
        ),
      );
    },
  );

  /// What signing in gets, from the features the server has on.
  String intro(ServerFeatures f) => trKey(
    f.telemetryRequests && f.alerts
        ? 'accountUi.introBoth'
        : f.telemetryRequests
        ? 'accountUi.introTelemetry'
        : f.alerts
        ? 'accountUi.introAlerts'
        : 'accountUi.introBase',
  );

  List<Widget> _signedOut(
    BuildContext context,
    SignInFlow? flow,
    ServerFeatures features,
  ) {
    final colors = BeaconColors.of(context);
    final failed = flow?.lastResult?.outcome == SignInOutcome.failed
        ? flow?.lastResult?.message
        : null;
    final problem = error ?? failed;
    final waiting = flow?.pending != null;
    final label = trKey(
      features.portal ? 'account.signInPortal' : 'account.signIn',
    );
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (waiting && flow != null) ...[
              Row(
                key: const ValueKey('account-waiting'),
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      trKey('accountUi.waiting'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                trKey('accountUi.waitingNote'),
                style: TextStyle(fontSize: 13, color: colors.muted),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                key: const ValueKey('account-cancel'),
                onPressed: flow.cancel,
                child: Text(trKey('accountUi.cancel')),
              ),
            ] else ...[
              Text(
                intro(features),
                style: TextStyle(fontSize: 13, color: colors.muted),
              ),
              if (flow != null) ...[
                const SizedBox(height: 12),
                FilledButton(
                  key: const ValueKey('account-sign-in'),
                  onPressed: starting ? null : () => signIn(flow),
                  child: starting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(label),
                ),
              ],
            ],
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, size: 18, color: colors.danger),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        problem,
                        style: TextStyle(color: colors.danger, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ];
  }

  Future<void> _confirmSignOut() async {
    final yes = await confirmAction(
      context,
      title: trKey('accountUi.signOutTitle'),
      body: trKey('accountUi.signOutBody'),
      action: trKey('account.signOut'),
    );
    if (yes && mounted) await widget.account.signOut();
  }

  List<Widget> _signedIn(BuildContext context) {
    final user = widget.account.user!;
    final colors = BeaconColors.of(context);
    final username = textOf(user['username']);
    final name = textOf(user['displayName'], username);
    final email = textOf(user['email']);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: colors.primary.withValues(alpha: .16),
              foregroundColor: colors.primary,
              child: Text(
                name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                      color: colors.muted,
                    ),
                  ),
                  if (email.isNotEmpty)
                    Text(
                      email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      ListTile(
        key: const ValueKey('account-profile'),
        leading: const Icon(Icons.badge_outlined, size: 21),
        title: Text(trKey('account.profile')),
        subtitle: Text(trKey('accountUi.profileNote')),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => ProfileScreen(
              account: widget.account,
              api: widget.api,
              onOpen: widget.onOpen,
              serverName: widget.serverName,
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('account-sign-out'),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: colors.muted,
            ),
            onPressed: _confirmSignOut,
            icon: const Icon(Icons.logout, size: 18),
            label: Text(trKey('account.signOut')),
          ),
        ),
      ),
    ];
  }
}

/// A confirmation dialog; true only when the action is chosen. [danger] paints
/// the action as destructive.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool danger = false,
}) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          key: const ValueKey('confirm-cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: Text(trKey('accountUi.cancel')),
        ),
        FilledButton(
          key: const ValueKey('confirm-yes'),
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return yes == true;
}
