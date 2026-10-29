import 'dart:async';

import 'map_data.dart';

/// The GeoJSON the map screen hands its native map.
typedef MapLayerData = ({
  Map<String, dynamic> points,
  Map<String, dynamic>? live,
  Map<String, dynamic> lines,
  Map<String, dynamic> borders,
});

/// Rebuilds each part only when its inputs change, so an unchanged rebuild sends the map nothing.
class MapLayers {
  final _typed = _Memo<Map<String, dynamic>>(),
      _live = _Memo<Map<String, dynamic>?>(),
      _points = _Memo<Map<String, dynamic>>(),
      _lines = _Memo<Map<String, dynamic>>(),
      _borders = _Memo<Map<String, dynamic>>();

  /// Inputs compare by identity, so a changed node list must be a new list.
  MapLayerData build({
    required List<Map<String, dynamic>> nodes,
    required String type,
    required bool flow,
    required String mode,
    required String? selected,
    required Map<String, dynamic>? selectedNode,
    required List<Map<String, dynamic>> neighbors,
    required List<Map<String, dynamic>> borders,
  }) {
    final typed = _typed([nodes, type], () => nodeFeatures(nodes, type: type));
    final all = flow && type.isNotEmpty;
    final live = _live([nodes, all], () => all ? nodeFeatures(nodes) : null);
    return (
      points: _points([
        typed,
        live,
        selected,
      ], () => withSelected(typed, live, selected)),
      live: live,
      lines: _lines(
        [nodes, mode, selected, selectedNode, neighbors],
        () => mode == 'selected' && selectedNode != null && neighbors.isNotEmpty
            ? focusedFeatures(selectedNode, neighbors)
            : neighborFeatures(nodes, mode, selected),
      ),
      borders: _borders([borders], () => collection(borders)),
    );
  }
}

class _Memo<T> {
  List<Object?>? _inputs;
  late T _value;

  T call(List<Object?> inputs, T Function() compute) {
    final old = _inputs;
    var same = old != null && old.length == inputs.length;
    for (var i = 0; same && i < inputs.length; i++) {
      same = old![i] == inputs[i];
    }
    if (!same) {
      _value = compute();
      _inputs = inputs;
    }
    return _value;
  }
}

/// One write to the native map, skipped while the map already holds [key] for [id].
typedef MapWrite = ({String id, Object? key, Future<void> Function() send});

/// One batch at a time, always the latest, so sends never queue and superseded data is dropped.
class MapSync {
  MapSync(this._writes, {required this.onError});
  final List<MapWrite> Function() _writes;
  final void Function(Object error) onError;
  final _held = <String, Object?>{};
  bool _busy = false, _stale = false, _closed = false;

  /// Stops sending; a batch in flight ends after its current write.
  void close() => _closed = true;

  Future<void> sync() async {
    _stale = true;
    if (_busy) return;
    _busy = true;
    try {
      while (_stale && !_closed) {
        _stale = false;
        try {
          for (final w in _writes()) {
            if (_closed) return;
            if (_held.containsKey(w.id) && _held[w.id] == w.key) continue;
            await w.send();
            _held[w.id] = w.key;
          }
        } catch (e) {
          if (!_closed) onError(e);
        }
      }
    } finally {
      _busy = false;
    }
  }
}

/// [source]'s latest at most once per [interval]; first, last and pre-error events pass at once.
Stream<T> throttleLatest<T>(Stream<T> source, Duration interval) {
  late final StreamController<T> out;
  StreamSubscription<T>? sub;
  Timer? hold;
  T? held;
  var holding = false;
  void flush() {
    if (!holding) return;
    holding = false;
    final value = held as T;
    held = null;
    out.add(value);
  }

  void startHold() {
    hold = Timer(interval, () {
      hold = null;
      if (holding) {
        flush();
        startHold();
      }
    });
  }

  void endHold() {
    hold?.cancel();
    hold = null;
    flush();
  }

  out = StreamController<T>(
    onListen: () {
      sub = source.listen(
        (value) {
          if (hold == null) {
            out.add(value);
            startHold();
          } else {
            held = value;
            holding = true;
          }
        },
        onError: (Object error, StackTrace stack) {
          endHold();
          out.addError(error, stack);
        },
        onDone: () {
          // finished, so closing must not wait on cancelling it
          sub = null;
          endHold();
          out.close();
        },
      );
    },
    onPause: () => sub?.pause(),
    onResume: () => sub?.resume(),
    onCancel: () {
      hold?.cancel();
      hold = null;
      return sub?.cancel();
    },
  );
  return out.stream;
}
