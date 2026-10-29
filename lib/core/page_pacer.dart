/// One budget for the loaders that page a whole region in (map, neighbour graph), so they stay
/// under the API's per-minute limit, which is 300 on some deployments. A region-sized load fits in
/// the burst; past it, pages go out one per [interval]: at most [burst] + 200 in any minute.
class PagePacer {
  PagePacer({
    this.burst = 40,
    this.interval = const Duration(milliseconds: 300),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int burst;
  final Duration interval;
  final DateTime Function() _now;

  // when the slot after the last reserved one opens (GCRA)
  DateTime? _nextSlot;

  /// Reserves a slot for the next page and returns how long to wait before fetching it.
  Duration reserve() {
    final now = _now();
    final next = _nextSlot ?? now;
    var sendAt = next.subtract(interval * (burst - 1));
    if (sendAt.isBefore(now)) sendAt = now;
    _nextSlot = (next.isAfter(sendAt) ? next : sendAt).add(interval);
    return sendAt.difference(now);
  }

  /// Waits for the next page slot.
  Future<void> wait() {
    final delay = reserve();
    return delay == Duration.zero ? Future.value() : Future.delayed(delay);
  }
}

final pagePacer = PagePacer();
