import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/filter_sheet.dart';
import '../../core/strings.dart';

class FilterDropdown<T> extends StatefulWidget {
  const FilterDropdown({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });
  final String label;
  final Map<T, String> options;
  final Set<T> selected;
  final ValueChanged<Set<T>> onChanged;

  @override
  State<FilterDropdown<T>> createState() => _FilterDropdownState<T>();
}

class _FilterDropdownState<T> extends State<FilterDropdown<T>> {
  static const _rowHeight = 48.0;
  final menu = MenuController();
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final values = widget.selected
        .map((id) => widget.options[id] ?? '$id')
        .join(', ');
    final matching = widget.options.entries
        .where(
          (e) =>
              e.value.toLowerCase().contains(search.text.trim().toLowerCase()),
        )
        .toList();
    final viewport = MediaQuery.of(context);
    final listHeight = math.min(
      math.min(200.0, math.max(48.0, matching.length * _rowHeight)),
      math.max(80.0, (viewport.size.height - viewport.viewInsets.bottom) * .3),
    );
    final theme = Theme.of(context);
    // Same look as the DropdownButtonFormField menu the directory sheet uses.
    final valueStyle = theme.textTheme.titleMedium;
    final showSearch = widget.options.length > 8;
    return Padding(
      padding: const EdgeInsets.only(bottom: filterFieldGap),
      child: LayoutBuilder(
        builder: (context, constraints) => MenuAnchor(
          controller: menu,
          consumeOutsideTap: true,
          style: MenuStyle(
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            backgroundColor: WidgetStatePropertyAll(theme.canvasColor),
            elevation: const WidgetStatePropertyAll(8),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
            ),
          ),
          onOpen: () => setState(() => search.clear()),
          onClose: () => FocusManager.instance.primaryFocus?.unfocus(),
          menuChildren: [
            SizedBox(
              width: constraints.maxWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showSearch)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: TextField(
                        key: ValueKey('search-${widget.label}'),
                        controller: search,
                        decoration: InputDecoration(
                          hintText: tr('Search'),
                          prefixIcon: const Icon(Icons.search, size: 18),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  SizedBox(
                    height: listHeight,
                    child: matching.isEmpty
                        ? Center(child: Text(tr('No results')))
                        : ListView.builder(
                            primary: false,
                            padding: EdgeInsets.zero,
                            itemExtent: _rowHeight,
                            itemCount: matching.length,
                            itemBuilder: (context, index) {
                              final option = matching[index];
                              return CheckboxListTile(
                                dense: true,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(option.value, style: valueStyle),
                                value: widget.selected.contains(option.key),
                                onChanged: (checked) {
                                  final next = {...widget.selected};
                                  checked == true
                                      ? next.add(option.key)
                                      : next.remove(option.key);
                                  widget.onChanged(next);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
          builder: (context, controller, child) => InkWell(
            key: ValueKey('filter-${widget.label}'),
            borderRadius: BorderRadius.circular(6),
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: InputDecorator(
              decoration: filterFieldDecoration(widget.label),
              isEmpty: false,
              // DropdownButtonFormField's row is 24dp tall (the chevron); match it.
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
                        child: const Icon(Icons.arrow_drop_down),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
