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
              ..._signedOut(context, flow),
          ],
        ),
      );
    },
  );

  List<Widget> _signedOut(BuildContext context, SignInFlow? flow) {
    final failed = flow?.lastResult?.outcome == SignInOutcome.failed
        ? flow?.lastResult?.message
        : null;
    final problem = error ?? failed;
    return [
      if (flow != null) ...[
        ListTile(
          key: const ValueKey('account-sign-in'),
          leading: const Icon(Icons.login, size: 21),
          title: Text(trKey('account.signIn')),
          subtitle: Text(trKey('account.signInNote')),
          onTap: starting ? null : () => signIn(flow),
        ),
      ],
      if (problem != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            problem,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ];
  }

  List<Widget> _signedIn(BuildContext context) {
    final user = widget.account.user!;
    final name = textOf(user['displayName'], textOf(user['username']));
    return [
      ListTile(
        leading: const Icon(Icons.account_circle_outlined, size: 21),
        title: Text(name),
        subtitle: Text(textOf(user['username'])),
      ),
      ListTile(
        key: const ValueKey('account-profile'),
        leading: const Icon(Icons.badge_outlined, size: 21),
        title: Text(trKey('account.profile')),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => ProfileScreen(
              account: widget.account,
              api: widget.api,
              onOpen: widget.onOpen,
            ),
          ),
        ),
      ),
      ListTile(
        key: const ValueKey('account-sign-out'),
        leading: const Icon(Icons.logout, size: 21),
        title: Text(trKey('account.signOut')),
        onTap: () => widget.account.signOut(),
      ),
    ];
  }
}
