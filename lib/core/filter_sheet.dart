import 'package:flutter/material.dart';

import 'sheet.dart';
import 'strings.dart';
import 'theme.dart';

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

/// Whichever [FilterField] is open; opening another closes the first.
final ValueNotifier<Object?> _openField = ValueNotifier(null);

/// The one picker for every filter sheet field. It opens in place: the list
/// grows under the field and pushes the fields below it down.
///
/// [multi] fields tick several values and stay open; single fields start with
/// an Any row and close on a pick. An empty [selected] means Any.
class FilterField<T> extends StatefulWidget {
  const FilterField({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.multi = false,
  });
  final String label;
  final Map<T, String> options;
  final Set<T> selected;
  final ValueChanged<Set<T>> onChanged;
  final bool multi;

  /// A search row shows above this many options.
  static const int searchAbove = 8;
  static const double rowHeight = 44;

  @override
  State<FilterField<T>> createState() => _FilterFieldState<T>();
}

class _FilterFieldState<T> extends State<FilterField<T>> {
  final search = TextEditingController();
  final searchFocus = FocusNode();
  final panel = GlobalKey();
  bool open = false;

  @override
  void initState() {
    super.initState();
    _openField.addListener(_other);
    searchFocus.addListener(() {
      // Let the keyboard finish rising, then keep the list in view.
      if (searchFocus.hasFocus) Future.delayed(_settle, _reveal);
    });
  }

  static const _settle = Duration(milliseconds: 350);

  @override
  void dispose() {
    _openField.removeListener(_other);
    if (_openField.value == this) _openField.value = null;
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void _other() {
    if (open && _openField.value != this) setState(() => open = false);
  }

  void _reveal() {
    final context = panel.currentContext;
    if (mounted && context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 150),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    }
  }

  void toggle() {
    setState(() {
      open = !open;
      search.clear();
    });
    if (open) {
      _openField.value = this;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    } else if (_openField.value == this) {
      _openField.value = null;
    }
  }

  void pick(T? value) {
    if (widget.multi) {
      final next = {...widget.selected};
      next.contains(value) ? next.remove(value) : next.add(value as T);
      widget.onChanged(next);
      return;
    }
    widget.onChanged(value == null ? <T>{} : {value});
    toggle();
  }

  Widget row(BuildContext context, String text, bool selected, T? value) {
    final colors = BeaconColors.of(context);
    final marker = widget.multi
        ? (selected ? Icons.check_box : Icons.check_box_outline_blank)
        : (selected ? Icons.radio_button_checked : Icons.radio_button_off);
    return InkWell(
      onTap: () => pick(value),
      child: Container(
        constraints: const BoxConstraints(minHeight: FilterField.rowHeight),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: selected && !widget.multi ? colors.raised : null,
        child: Row(
          children: [
            Icon(
              marker,
              size: 20,
              color: selected ? colors.primary : colors.muted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text, style: Theme.of(context).textTheme.titleMedium),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = BeaconColors.of(context);
    final valueStyle = theme.textTheme.titleMedium;
    final values = widget.selected
        .map((id) => widget.options[id] ?? '$id')
        .join(', ');
    final term = search.text.trim().toLowerCase();
    final matching = widget.options.entries
        .where((e) => e.value.toLowerCase().contains(term))
        .toList();
    final maxList = MediaQuery.sizeOf(context).height * .4;
    return Padding(
      padding: const EdgeInsets.only(bottom: filterFieldGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('filter-${widget.label}'),
            borderRadius: BorderRadius.circular(6),
            onTap: toggle,
            child: InputDecorator(
              decoration: filterFieldDecoration(widget.label),
              isFocused: open,
              isEmpty: false,
              // DropdownButtonFormField's row is 24dp tall (the chevron).
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        values.isEmpty ? trKey('nodeFilters.any') : values,
                        style: valueStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Same icon theme DropdownButton gives its chevron.
                    IconTheme(
                      data: IconThemeData(
                        size: 24,
                        color: theme.brightness == Brightness.light
                            ? Colors.grey.shade700
                            : Colors.white70,
                      ),
                      // DropdownButton's chevron sits 4dp into the field padding.
                      child: Transform.translate(
                        offset: const Offset(4, 0),
                        child: AnimatedRotation(
                          turns: open ? .5 : 0,
                          duration: const Duration(milliseconds: 120),
                          child: const Icon(Icons.arrow_drop_down),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            Container(
              key: panel,
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.options.length > FilterField.searchAbove) ...[
                    SizedBox(
                      height: FilterField.rowHeight,
                      child: Row(
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Icon(Icons.search, size: 18),
                          ),
                          Expanded(
                            child: TextField(
                              key: ValueKey('search-${widget.label}'),
                              controller: search,
                              focusNode: searchFocus,
                              decoration: InputDecoration(
                                hintText: tr('Search'),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                filled: false,
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: colors.borderSubtle),
                  ],
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxList),
                    child: ListView(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      children: [
                        if (!widget.multi && term.isEmpty)
                          row(
                            context,
                            trKey('nodeFilters.any'),
                            widget.selected.isEmpty,
                            null,
                          ),
                        for (final e in matching)
                          row(
                            context,
                            e.value,
                            widget.selected.contains(e.key),
                            e.key,
                          ),
                        if (matching.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(tr('No results')),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A filter sheet's body: the fields scroll above, the footer stays pinned.
/// Short content sizes itself; long content scrolls instead of growing.
class FilterSheetBody extends StatelessWidget {
  const FilterSheetBody({
    super.key,
    required this.fields,
    required this.onClear,
    required this.onPrimary,
    this.primaryLabel = 'Apply',
  });
  final List<Widget> fields;
  final VoidCallback onClear;
  final VoidCallback onPrimary;
  final String primaryLabel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            BeaconSheet.gutter,
            8,
            BeaconSheet.gutter,
            0,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: fields,
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          BeaconSheet.gutter,
          4,
          BeaconSheet.gutter,
          16,
        ),
        child: FilterSheetFooter(
          onClear: onClear,
          onPrimary: onPrimary,
          primaryLabel: primaryLabel,
        ),
      ),
    ],
  );
}
