import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import '../atlas/atlas_widgets.dart' show AtlasInfoTip;

bool emptyDirectoryRegion(Json region) =>
    region['iatas'] == '' ||
    (region.containsKey('region') && !region.containsKey('iatas'));

Color senderColor(String name) {
  var hash = 5381;
  for (final unit in name.codeUnits) {
    hash = (hash * 33 + unit) & 0xffffffff;
    if (hash >= 0x80000000) hash -= 0x100000000;
  }
  return const [
    Color(0xff3b82f6),
    Color(0xffa78bfa),
    Color(0xff22c55e),
    Color(0xfff59e0b),
    Color(0xffef4444),
  ][hash.abs() % 5];
}

String stamp(dynamic value) {
  final d = epoch(value)?.toLocal();
  if (d == null) return tr('Unknown');
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String label(Json row) => textOf(
  row['name'] ??
      row['displayName'] ??
      row['nodeName'] ??
      row['id'] ??
      row['publicKey'],
  tr('Unknown'),
);
Widget mono(String s, {Color? color}) => Text(
  s,
  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: color),
);
Widget section(String title, List<Widget> children, {List<String>? info}) =>
    Builder(
      builder: (context) {
        final colors = BeaconColors.of(context);
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 7),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.raised.withValues(alpha: .28),
            border: Border.all(color: colors.borderSubtle),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Flexible(child: sectionTitle(title, colors)),
                    if (info != null) AtlasInfoTip(info),
                  ],
                ),
                const SizedBox(height: 9),
                ...children,
              ],
            ),
          ),
        );
      },
    );
Widget fact(String title, dynamic value) => Builder(
  builder: (context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 122,
          child: Text(
            tr(title),
            style: TextStyle(
              fontSize: 11,
              color: BeaconColors.of(context).muted,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value == null ? tr('Unknown') : '$value',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: BeaconColors.of(context).bright,
            ),
          ),
        ),
      ],
    ),
  ),
);

Widget failure(Object error, VoidCallback retry) => Padding(
  padding: const EdgeInsets.all(16),
  child: Column(
    children: [
      DirectoryText('$error'),
      TextButton.icon(
        onPressed: retry,
        icon: const Icon(Icons.refresh),
        label: const DirectoryText('Retry'),
      ),
    ],
  ),
);

class DirectoryText extends StatelessWidget {
  const DirectoryText(this.data, {super.key, this.style, this.textAlign});
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  @override
  Widget build(BuildContext context) =>
      Text(tr(data), style: style, textAlign: textAlign);
}

Text sectionTitle(String title, BeaconColors colors) => Text(
  tr(title).toUpperCase(),
  style: TextStyle(
    fontFamily: 'JetBrainsMono',
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 1,
    color: colors.primary,
  ),
);

/// Reference info: closed by default, a one-line summary when closed, and
/// remembered per [id].
class FoldSection extends StatefulWidget {
  const FoldSection({
    required this.id,
    required this.title,
    required this.children,
    this.summary = '',
    this.info,
    super.key,
  });
  final String id, title, summary;
  final List<String>? info;
  final List<Widget> children;

  static String _key(String id) => 'detailFold.$id';

  @override
  State<FoldSection> createState() => _FoldSectionState();
}

class _FoldSectionState extends State<FoldSection> {
  bool open = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(FoldSection._key(widget.id));
      if (saved == null || !mounted) return;
      setState(() => open = saved);
    } catch (_) {
      // No preferences store: the fold starts closed.
    }
  }

  Future<void> _toggle() async {
    setState(() => open = !open);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(FoldSection._key(widget.id), open);
    } catch (_) {
      // Not remembered without a preferences store.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = BeaconColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: colors.raised.withValues(alpha: .28),
        border: Border.all(color: colors.borderSubtle),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: ValueKey('fold-${widget.id}'),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      open ? Icons.expand_more : Icons.chevron_right,
                      size: 16,
                      color: colors.muted,
                    ),
                    const SizedBox(width: 4),
                    sectionTitle(widget.title, colors),
                    if (widget.info != null) AtlasInfoTip(widget.info!),
                    const SizedBox(width: 8),
                    if (!open && widget.summary.isNotEmpty)
                      Expanded(
                        child: Text(
                          widget.summary,
                          textAlign: TextAlign.end,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 11,
                            color: colors.muted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.children,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
