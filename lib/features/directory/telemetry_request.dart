import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/account.dart';
import '../../core/api.dart';
import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../account/profile_screen.dart';
import '../account/request_text.dart';
import '../atlas/atlas_widgets.dart' show AtlasInfoTip;
import 'directory_widgets.dart';

const guestPasswordMaxBytes = 15;

/// Cuts the text to the server's 15-byte limit, counting UTF-8 bytes, so a
/// paste is shortened instead of refused.
class _ByteLimit extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (utf8.encode(newValue.text).length <= guestPasswordMaxBytes) {
      return newValue;
    }
    var kept = '';
    for (final rune in newValue.text.runes) {
      final next = kept + String.fromCharCode(rune);
      if (utf8.encode(next).length > guestPasswordMaxBytes) break;
      kept = next;
    }
    return TextEditingValue(
      text: kept,
      selection: TextSelection.collapsed(offset: kept.length),
    );
  }
}

/// The optional guest password field: obscured with a show control, capped, and
/// kept out of autofill and the keyboard's suggestions.
class GuestPasswordField extends StatefulWidget {
  const GuestPasswordField({
    super.key,
    required this.controller,
    required this.label,
  });
  final TextEditingController controller;
  final String label;
  @override
  State<GuestPasswordField> createState() => _GuestPasswordFieldState();
}

class _GuestPasswordFieldState extends State<GuestPasswordField> {
  bool shown = false;
  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    obscureText: !shown,
    autocorrect: false,
    enableSuggestions: false,
    autofillHints: null,
    textInputAction: TextInputAction.done,
    inputFormatters: [_ByteLimit()],
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

/// "Request telemetry" on a repeater's detail screen. Draws nothing unless the
/// user is signed in on this server and the server has requests on. [standalone]
/// wraps it in its own section, for a node with no readings.
class TelemetryRequestBlock extends StatefulWidget {
  const TelemetryRequestBlock({
    super.key,
    required this.api,
    required this.account,
    required this.nodeId,
    required this.publicKey,
    required this.onOpen,
    this.standalone = false,
  });
  final ApiClient api;
  final AccountState account;
  final String nodeId, publicKey;
  final void Function(String, String) onOpen;
  final bool standalone;
  @override
  State<TelemetryRequestBlock> createState() => _TelemetryRequestBlockState();
}

class _TelemetryRequestBlockState extends State<TelemetryRequestBlock> {
  final password = TextEditingController();
  bool enabled = false, loaded = false, failed = false, busy = false;
  List<Json> requests = [];
  int limit = 0, generation = 0;
  late int seenEpoch = widget.account.epoch;
  String? note;

  @override
  void initState() {
    super.initState();
    widget.account.addListener(load);
    load();
  }

  @override
  void didUpdateWidget(covariant TelemetryRequestBlock old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api || old.account != widget.account) {
      old.account.removeListener(load);
      widget.account.addListener(load);
    }
    if (old.api != widget.api ||
        old.account != widget.account ||
        old.nodeId != widget.nodeId) {
      load();
    }
  }

  @override
  void dispose() {
    generation++;
    widget.account.removeListener(load);
    password.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final token = ++generation;
    final epoch = widget.account.epoch;
    if (epoch != seenEpoch) {
      // A different account must not inherit a typed guest password.
      seenEpoch = epoch;
      password.clear();
      busy = false;
      note = null;
    }
    bool stale() =>
        !mounted || token != generation || widget.account.epoch != epoch;
    if (!widget.account.signedIn) {
      setState(() => enabled = loaded = false);
      return;
    }
    final features = await widget.api.features();
    if (stale()) return;
    if (!features.telemetryRequests) {
      setState(() => enabled = loaded = false);
      return;
    }
    try {
      final data = await widget.account.api.telemetryRequests();
      if (stale()) return;
      setState(() {
        enabled = loaded = true;
        failed = false;
        requests = rows(data['requests']);
        limit = (number(data['limit']) ?? 0).toInt();
        if (limit <= 0) enabled = false;
      });
    } catch (_) {
      if (stale()) return;
      setState(() {
        enabled = true;
        loaded = false;
        failed = true;
      });
    }
  }

  Json? get mine {
    for (final r in requests) {
      final node = object(r['node']);
      final id = textOf(node['id']);
      if (id.isNotEmpty && id == widget.nodeId) return r;
      if (widget.publicKey.isNotEmpty &&
          textOf(node['publicKey']).toLowerCase() ==
              widget.publicKey.toLowerCase()) {
        return r;
      }
    }
    return null;
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      note = null;
    });
    final typed = password.text;
    final epoch = widget.account.epoch;
    try {
      await widget.account.api.createTelemetryRequest(
        widget.nodeId,
        password: typed,
      );
      if (!mounted || widget.account.epoch != epoch) return;
      password.clear();
      busy = false;
      await load();
    } catch (e) {
      if (!mounted || widget.account.epoch != epoch) return;
      setState(() {
        busy = false;
        note = requestError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();
    final colors = BeaconColors.of(context);
    final muted = TextStyle(fontSize: 12, color: colors.muted);
    final info = [
      trKey('telemetryRequests.explain'),
      trKey('telemetryRequests.notice'),
    ];
    final children = <Widget>[
      if (!widget.standalone)
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: Row(
            children: [
              Text(
                trKey('telemetryRequests.request'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              AtlasInfoTip(info),
            ],
          ),
        ),
      ..._body(context, muted),
    ];
    if (widget.standalone) {
      return FoldSection(
        id: 'node-telemetry',
        title: trKey('telemetryRequests.request'),
        info: info,
        children: children,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  List<Widget> _body(BuildContext context, TextStyle muted) {
    if (failed && !loaded) {
      return [
        Row(
          children: [
            Icon(
              Icons.error_outline,
              size: 18,
              color: BeaconColors.of(context).danger,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(trKey('telemetryRequests.loadFailed'))),
            TextButton(
              onPressed: load,
              child: Text(trKey('telemetryRequests.retry')),
            ),
          ],
        ),
      ];
    }
    final request = mine;
    if (request != null) {
      return [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Icon(
              Icons.circle,
              size: 9,
              color: requestDotColor(request, BeaconColors.of(context)),
            ),
            Text(requestLineText(request)),
            TextButton(
              key: const ValueKey('request-open-profile'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ProfileScreen(
                    account: widget.account,
                    api: widget.api,
                    onOpen: widget.onOpen,
                  ),
                ),
              ),
              child: Text(trKey('nodePanel.manage')),
            ),
          ],
        ),
      ];
    }
    final full = requests.length >= limit;
    return [
      GuestPasswordField(
        key: const ValueKey('request-password'),
        controller: password,
        label: trKey('telemetryRequests.passwordLabel'),
      ),
      const SizedBox(height: 4),
      Text(
        trKey('nodePanel.passwordHint'),
        style: TextStyle(fontSize: 12, color: BeaconColors.of(context).warning),
      ),
      if (full)
        Text(
          trKey('telemetryRequests.limitReached'),
          style: TextStyle(
            fontSize: 12,
            color: BeaconColors.of(context).danger,
          ),
        ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: FilledButton(
              key: const ValueKey('request-submit'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: busy || full ? null : submit,
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(trKey('telemetryRequests.submit')),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            trKey('nodePanel.usedShort')
                .replaceAll('{{used}}', '${requests.length}')
                .replaceAll('{{limit}}', '$limit'),
            style: muted,
          ),
        ],
      ),
      if (note != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            note!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ];
  }
}
