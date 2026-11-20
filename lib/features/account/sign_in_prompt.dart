import 'package:flutter/material.dart';

import '../../core/account.dart';
import '../../core/api.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'sign_in.dart';

/// The signed-out block: what signing in gets and its button, then the wait
/// for the browser with Cancel, and whatever went wrong. Settings and the
/// Atlas alerts sheet both show it.
class SignInPrompt extends StatefulWidget {
  const SignInPrompt({
    super.key,
    required this.account,
    required this.intro,
    required this.portal,
    this.muted = true,
  });
  final AccountState account;

  /// The line above the button.
  final String intro;

  /// The server signs in through the portal, which names the button.
  final bool portal;

  /// Draws [intro] small and muted, as Settings does.
  final bool muted;
  @override
  State<SignInPrompt> createState() => _SignInPromptState();
}

class _SignInPromptState extends State<SignInPrompt> {
  String? error;
  bool starting = false;

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
  Widget build(BuildContext context) {
    final flow = SignInScope.maybeOf(context);
    final colors = BeaconColors.of(context);
    final failed = flow?.lastResult?.outcome == SignInOutcome.failed
        ? flow?.lastResult?.message
        : null;
    final problem = error ?? failed;
    final waiting = flow?.pending != null;
    final label = trKey(
      widget.portal ? 'account.signInPortal' : 'account.signIn',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
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
            widget.intro,
            style: widget.muted
                ? TextStyle(fontSize: 13, color: colors.muted)
                : null,
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
    );
  }
}
