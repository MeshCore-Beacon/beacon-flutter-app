/// Persist this state BEFORE transmitting. It is shared by radio, not by server.
class PollPolicy {
  PollPolicy(this.state);
  final Map<String, dynamic> state;

  String? nextNode(
    String radio,
    Iterable<String> selected,
    int hours,
    DateTime now,
  ) {
    final nodes =
        (state[radio] as Map<String, dynamic>?)?['nodes']
            as Map<String, dynamic>?;
    final candidates = selected
        .where(
          (node) => blocked(radio, node, now, intervalHours: hours) == null,
        )
        .toList();
    candidates.sort(
      (a, b) => ((nodes?[a]?['at'] as int?) ?? 0).compareTo(
        (nodes?[b]?['at'] as int?) ?? 0,
      ),
    );
    return candidates.isEmpty ? null : candidates.first;
  }

  String? blocked(
    String radio,
    String node,
    DateTime now, {
    int? intervalHours,
  }) {
    final r = state[radio] as Map<String, dynamic>?;
    if (r == null) return null;
    final ms = now.millisecondsSinceEpoch;
    final clock = r['clock'] as int;
    if (ms < clock) return 'Clock moved backwards; waiting for the saved time.';
    final previous =
        (r['nodes'] as Map<String, dynamic>)[node] as Map<String, dynamic>?;
    final storedDue = previous?['due'] as int?;
    final requestedDue = previous == null || intervalHours == null
        ? 0
        : (previous['at'] as int) +
              Duration(hours: intervalHours).inMilliseconds;
    final due = storedDue == null
        ? null
        : storedDue > requestedDue
        ? storedDue
        : requestedDue;
    if (due != null && ms < due) {
      return 'Next attempt: ${DateTime.fromMillisecondsSinceEpoch(due).toLocal()}';
    }
    if (ms - clock < const Duration(minutes: 1).inMilliseconds) {
      return 'Spacing repeater attempts by at least one minute.';
    }
    final recent = (r['attempts'] as List).cast<int>().where(
      (at) => ms - at < const Duration(hours: 1).inMilliseconds,
    );
    // Reserve three commands (login, status, telemetry), even if a poll fails.
    if (recent.length >= 2) {
      return 'Companion budget: at most six poll commands per hour.';
    }
    return null;
  }

  void reserve(String radio, String node, int hours, DateTime now) {
    if (hours < 1 || hours > 72) {
      throw ArgumentError('Interval must be 1–72 hours');
    }
    final reason = blocked(radio, node, now, intervalHours: hours);
    if (reason != null) throw StateError(reason);
    final ms = now.millisecondsSinceEpoch;
    final r = state.putIfAbsent(
      radio,
      () => <String, dynamic>{
        'clock': ms,
        'nodes': <String, dynamic>{},
        'attempts': <int>[],
      },
    ) as Map<String, dynamic>;
    r['clock'] = ms;
    r['attempts'] = [
      ...(r['attempts'] as List).cast<int>().where(
        (at) => ms - at < const Duration(hours: 1).inMilliseconds,
      ),
      ms,
    ];
    final nodes = r['nodes'] as Map<String, dynamic>;
    nodes.removeWhere(
      (_, previous) =>
          ms - (previous['at'] as int) >
          const Duration(hours: 72).inMilliseconds,
    );
    nodes[node] = {'at': ms, 'due': ms + Duration(hours: hours).inMilliseconds};
  }
}
