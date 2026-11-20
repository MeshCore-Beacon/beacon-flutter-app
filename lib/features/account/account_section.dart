import 'package:flutter/material.dart';

import '../../core/account.dart';
import '../../core/api.dart';
import '../../core/features.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'profile_screen.dart';
import 'sign_in.dart';
import 'sign_in_prompt.dart';

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

  @override
  void didUpdateWidget(AccountSection old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api) features = widget.api.features();
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
              ..._signedOut(data),
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

  List<Widget> _signedOut(ServerFeatures features) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: SignInPrompt(
        account: widget.account,
        intro: intro(features),
        portal: features.portal,
      ),
    ),
  ];

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
