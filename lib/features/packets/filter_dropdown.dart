import 'dart:math' as math;

import 'package:flutter/material.dart';

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
      math.min(200.0, math.max(48.0, matching.length * 48.0)),
      math.max(80.0, (viewport.size.height - viewport.viewInsets.bottom) * .3),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr(widget.label), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, constraints) => MenuAnchor(
              controller: menu,
              consumeOutsideTap: true,
              style: const MenuStyle(
                padding: WidgetStatePropertyAll(EdgeInsets.zero),
              ),
              onOpen: () => setState(() => search.clear()),
              onClose: () => FocusManager.instance.primaryFocus?.unfocus(),
              menuChildren: [
                SizedBox(
                  width: constraints.maxWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                                itemCount: matching.length,
                                itemBuilder: (context, index) {
                                  final option = matching[index];
                                  return CheckboxListTile(
                                    dense: true,
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    title: Text(option.value),
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
              builder: (context, controller, child) => OutlinedButton(
                key: ValueKey('filter-${widget.label}'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        values.isEmpty ? tr('All') : values,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_drop_down, size: 20),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
