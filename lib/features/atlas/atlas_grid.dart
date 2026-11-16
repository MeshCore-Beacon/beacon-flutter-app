import 'dart:async';

import 'package:flutter/material.dart';

import 'atlas_widgets.dart';

/// Cards in one, two or three columns, reordered by dragging a card's grip:
/// the grabbed card follows the finger and the cards between its old and new
/// slot slide into the neighbouring slot, so a drop lands where it looks.
class AtlasGrid extends StatefulWidget {
  const AtlasGrid({
    super.key,
    required this.keys,
    required this.itemBuilder,
    required this.onReorder,
    this.gap = 14,
  });
  final List<String> keys;
  final Widget Function(
    BuildContext context,
    int index,
    Widget Function(Widget grip) handle,
  )
  itemBuilder;
  final void Function(int from, int to) onReorder;
  final double gap;

  /// The web's md and xl breakpoints.
  static int columnsFor(double width) => width >= 1280
      ? 3
      : width >= 768
      ? 2
      : 1;

  @override
  State<AtlasGrid> createState() => _AtlasGridState();
}

class _AtlasGridState extends State<AtlasGrid> {
  final _slots = <String, GlobalKey>{};
  int? _from;
  int _over = 0;
  Offset _delta = Offset.zero, _origin = Offset.zero, _pointer = Offset.zero;
  List<Rect> _rects = const [];
  Timer? _scroller;

  RenderBox get _box => context.findRenderObject()! as RenderBox;

  @override
  void dispose() {
    _scroller?.cancel();
    super.dispose();
  }

  void _start(int index, Offset global) {
    if (_from != null) return;
    final grid = _box;
    _rects = [
      for (final key in widget.keys)
        switch (_slots[key]?.currentContext?.findRenderObject()) {
          final RenderBox box =>
            grid.globalToLocal(box.localToGlobal(Offset.zero)) & box.size,
          _ => Rect.zero,
        },
    ];
    _pointer = global;
    _origin = grid.globalToLocal(global);
    _scroller = Timer.periodic(const Duration(milliseconds: 16), _scroll);
    setState(() {
      _from = _over = index;
      _delta = Offset.zero;
    });
  }

  void _move() {
    if (_from == null || !mounted) return;
    final local = _box.globalToLocal(_pointer);
    final hit = _rects.indexWhere((rect) => rect.contains(local));
    setState(() {
      _delta = local - _origin;
      if (hit != -1) _over = hit;
    });
  }

  // A phone shows about two cards, so the list follows a drag held near an edge.
  void _scroll(Timer _) {
    final scrollable = Scrollable.maybeOf(context);
    final view = scrollable?.context.findRenderObject();
    if (scrollable == null || view is! RenderBox) return;
    final top = view.localToGlobal(Offset.zero).dy;
    final position = scrollable.position;
    const edge = 56.0, step = 10.0;
    final target = _pointer.dy < top + edge
        ? position.pixels - step
        : _pointer.dy > top + view.size.height - edge
        ? position.pixels + step
        : null;
    if (target == null) return;
    final next = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) return;
    position.jumpTo(next);
    _move();
  }

  void _end(bool commit) {
    final from = _from;
    if (from == null) return;
    _scroller?.cancel();
    final over = _over;
    setState(() => _from = null);
    if (commit && over != from) widget.onReorder(from, over);
  }

  Offset _offset(int index) {
    final from = _from;
    if (from == null || index >= _rects.length) return Offset.zero;
    if (index == from) return _delta;
    // Cards between the two slots take the place of their neighbour on the side the card came from.
    final shift = from < index && index <= _over
        ? -1
        : _over <= index && index < from
        ? 1
        : 0;
    return shift == 0
        ? Offset.zero
        : _rects[index + shift].topLeft - _rects[index].topLeft;
  }

  Widget _handle(int index, Widget grip) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      EagerPanRecognizer:
          GestureRecognizerFactoryWithHandlers<EagerPanRecognizer>(
            EagerPanRecognizer.new,
            (pan) {
              pan
                ..onStart = ((details) => _start(index, details.globalPosition))
                ..onUpdate = (details) {
                  _pointer = details.globalPosition;
                  _move();
                }
                ..onEnd = ((_) => _end(true))
                ..onCancel = () => _end(false);
            },
          ),
    },
    child: grip,
  );

  Widget _slot(int index) {
    final offset = _offset(index);
    return KeyedSubtree(
      key: _slots.putIfAbsent(widget.keys[index], GlobalKey.new),
      child: AnimatedContainer(
        duration: _from != null && _from != index
            ? const Duration(milliseconds: 150)
            : Duration.zero,
        transform: Matrix4.translationValues(offset.dx, offset.dy, 0),
        child: widget.itemBuilder(
          context,
          index,
          (grip) => _handle(index, grip),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _slots.removeWhere((key, _) => !widget.keys.contains(key));
    final columns = AtlasGrid.columnsFor(MediaQuery.sizeOf(context).width);
    final count = widget.keys.length, from = _from;
    if (columns == 1) {
      return RaisedFlex(
        direction: Axis.vertical,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        raised: from == null ? null : from * 2,
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) SizedBox(height: widget.gap),
            _slot(i),
          ],
        ],
      );
    }
    return RaisedFlex(
      direction: Axis.vertical,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      raised: from == null ? null : from ~/ columns * 2,
      children: [
        for (var row = 0; row * columns < count; row++) ...[
          if (row > 0) SizedBox(height: widget.gap),
          // Every card in a row is as tall as the tallest.
          IntrinsicHeight(
            child: RaisedFlex(
              direction: Axis.horizontal,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              raised: from != null && from ~/ columns == row
                  ? from % columns * 2
                  : null,
              children: [
                for (var col = 0; col < columns; col++) ...[
                  if (col > 0) SizedBox(width: widget.gap),
                  Expanded(
                    child: row * columns + col < count
                        ? _slot(row * columns + col)
                        : const SizedBox(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
