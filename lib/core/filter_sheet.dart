import 'package:flutter/material.dart';

import 'strings.dart';

/// Space under each field of a filter sheet.
const double filterFieldGap = 14;

/// The box every filter sheet field wears: outlined, with a floating label.
InputDecoration filterFieldDecoration(String label) =>
    InputDecoration(labelText: tr(label));

/// The sheet footer: a text button on the left, the main button on the right.
class FilterSheetFooter extends StatelessWidget {
  const FilterSheetFooter({
    super.key,
    required this.onClear,
    required this.onPrimary,
    this.primaryLabel = 'Apply',
  });
  final VoidCallback onClear;
  final VoidCallback onPrimary;
  final String primaryLabel;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      TextButton(onPressed: onClear, child: Text(tr('Clear all'))),
      const Spacer(),
      FilledButton(onPressed: onPrimary, child: Text(tr(primaryLabel))),
    ],
  );
}
