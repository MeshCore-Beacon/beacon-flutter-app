import 'package:flutter/material.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';

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
Widget section(String title, List<Widget> children) => Builder(
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
            Text(
              tr(title).toUpperCase(),
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: colors.primary,
              ),
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
