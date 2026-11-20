import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/account.dart';
import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/sheet.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../account/alert_rule_list.dart';
import '../account/alert_rules.dart';
import '../account/sign_in.dart';
import 'atlas.dart';

/// The `/me/alerts` target for [pin], or null when the server lists none yet.
/// The server keys targets by public key and lists each key once. An observer
/// pin holds only its id, so it matches on that, or on [observerKey], the key
/// the account's Atlas gave for the id.
Json? alertTargetFor(AtlasPin pin, List<Json> targets, {String? observerKey}) {
  String lower(dynamic value) => textOf(value).toLowerCase();
  if (pin.isNode) {
    final key = pin.publicKey!.toLowerCase();
    return targets.where((t) => lower(t['publicKey']) == key).firstOrNull;
  }
  final id = pin.observerId!.toLowerCase();
  final key = observerKey?.toLowerCase();
  return targets
          .where((t) => t['kind'] == 'observer' && lower(t['id']) == id)
          .firstOrNull ??
      // A stand-in id is not the server's; a radio that is gone has no id.
      (key == null
          ? null
          : targets.where((t) => lower(t['publicKey']) == key).firstOrNull);
}

/// A target's enabled rules, and how many of those are firing.
({int on, int firing}) alertCounts(Json? target) {
  final enabled = rows(target?['rules']).where((r) => r['enabled'] == true);
  return (
    on: enabled.length,
    firing: enabled.where((r) => r['state'] == 'firing').length,
  );
}

/// Whether email or push reaches the user now. True without channels, which a
/// server older than the switches does not send.
bool alertsReachUser(Json channels) {
  if (channels.isEmpty) return true;
  final email = object(channels['email']), push = object(channels['push']);
  return (email['available'] == true && email['enabled'] == true) ||
      (push['available'] == true &&
          push['enabled'] == true &&
          push['hasDevice'] == true);
}

/// Opens one card's alerts over the Atlas.
Future<void> showAtlasAlerts(
  BuildContext context, {
  required AccountState account,
  required String name,
  required String unit,
  required bool portal,
  required Json? Function() target,
  required VoidCallback onProfile,
}) => showBeaconSheet<void>(
  context,
  builder: (_) => AtlasAlertsSheet(
    account: account,
    name: name,
    unit: unit,
    portal: portal,
    target: target,
    onProfile: onProfile,
  ),
);

/// One radio's alert rules, as Profile lists them. Signed out it asks for a
/// sign-in instead.
class AtlasAlertsSheet extends StatefulWidget {
  const AtlasAlertsSheet({
    super.key,
    required this.account,
    required this.name,
    required this.unit,
    required this.portal,
    required this.target,
    required this.onProfile,
  });
  final AccountState account;

  /// The radio's name as its card shows it.
  final String name;

  /// The instance's temperature unit, 'c' or 'f'.
  final String unit;

  /// The server signs in through the portal, which names the button.
  final bool portal;

  /// The radio's target in the alerts as loaded now; read on every build.
  final Json? Function() target;

  /// Opens Profile at its alerts, where the channels are.
  final VoidCallback onProfile;
  @override
  State<AtlasAlertsSheet> createState() => _AtlasAlertsSheetState();
}

class _AtlasAlertsSheetState extends State<AtlasAlertsSheet> {
  bool starting = false;
  String? signInError;

  @override
  void initState() {
    super.initState();
    // The rule states may have moved since the cards loaded them.
    unawaited(widget.account.alerts.load());
  }

  Future<void> signIn(SignInFlow flow) async {
    setState(() {
      starting = true;
      signInError = null;
    });
    try {
      await flow.start(widget.account.api.base);
    } on ApiException catch (e) {
      signInError = e.message;
    }
    if (mounted) setState(() => starting = false);
  }

  @override
  Widget build(BuildContext context) {
    final flow = SignInScope.maybeOf(context);
    final alerts = widget.account.alerts;
    return BeaconSheet(
      title: trKey('atlasAlerts.title').replaceAll('{{name}}', widget.name),
      // Rule lists run long, so this one may take most of the screen.
      maxHeight: .9,
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(
          BeaconSheet.gutter,
          8,
          BeaconSheet.gutter,
          16,
        ),
        child: ListenableBuilder(
          listenable: Listenable.merge([widget.account, alerts]),
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.account.signedIn)
                ..._rules(context)
              else
                ..._signedOut(context, flow),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _signedOut(BuildContext context, SignInFlow? flow) => [
    Text(trKey('atlasAlerts.signInPrompt')),
    const SizedBox(height: 12),
    Align(
      alignment: Alignment.centerLeft,
      child: FilledButton(
        key: const ValueKey('atlas-alerts-sign-in'),
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: flow == null || starting ? null : () => signIn(flow),
        child: Text(
          trKey(widget.portal ? 'account.signInPortal' : 'account.signIn'),
        ),
      ),
    ),
    if (signInError case final text?)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          text,
          style: TextStyle(color: BeaconColors.of(context).danger),
        ),
      ),
  ];

  List<Widget> _rules(BuildContext context) {
    final colors = BeaconColors.of(context);
    final alerts = widget.account.alerts;
    final target = widget.target();
    final error = alerts.error;
    Widget retry(String text, {Color? color}) => Row(
      children: [
        Expanded(
          child: Text(text, style: TextStyle(color: color)),
        ),
        TextButton(
          key: const ValueKey('atlas-alerts-retry'),
          onPressed: alerts.retry,
          child: Text(trKey('alerts.retry')),
        ),
      ],
    );
    final reaches = alertsReachUser(alerts.channels);
    return [
      if (target != null)
        AlertRuleList(
          key: ValueKey('atlas-alert-rules-${textOf(target['publicKey'])}'),
          target: target,
          account: widget.account,
          unit: widget.unit,
          changed: alerts.load,
        )
      else if (alerts.data == null && error != null)
        retry(alertError(error), color: colors.danger)
      else if (alerts.data == null || alerts.loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        )
      else
        // Pinned here but not yet saved to the account, so the server has no target.
        retry(trKey('atlasAlerts.notYet'), color: colors.muted),
      if (alerts.data != null) ...[
        const Divider(height: 24),
        InkWell(
          key: const ValueKey('atlas-alerts-profile'),
          onTap: () {
            Navigator.of(context).pop();
            widget.onProfile();
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                if (!reaches) ...[
                  Icon(
                    Icons.warning_amber_rounded,
                    key: const ValueKey('atlas-alerts-no-channel'),
                    size: 18,
                    color: colors.warning,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    trKey(
                      reaches
                          ? 'atlasAlerts.channels'
                          : 'atlasAlerts.noChannel',
                    ),
                    style: TextStyle(
                      fontSize: 13,
                      color: reaches ? colors.primary : colors.warning,
                      fontWeight: reaches ? null : FontWeight.w600,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, size: 20, color: colors.muted),
              ],
            ),
          ),
        ),
      ],
    ];
  }
}
