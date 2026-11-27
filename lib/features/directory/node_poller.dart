import 'package:flutter/material.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'directory_widgets.dart';
import 'node_chips.dart';

const _mono = 'JetBrainsMono';

enum PollerSeatKind { own, requested, free, notOffered }

/// One seat per slot the radio has: own, requested, free, then any not offered.
List<PollerSeatKind> pollerSeats(Json slots) {
  int n(String key) => (number(slots[key]) ?? 0).round().clamp(0, 256);
  final max = n('max');
  final seats = [
    for (var i = 0; i < n('own'); i++) PollerSeatKind.own,
    for (var i = 0; i < n('requested'); i++) PollerSeatKind.requested,
    for (var i = 0; i < n('free'); i++) PollerSeatKind.free,
  ];
  while (seats.length < max) {
    seats.add(PollerSeatKind.notOffered);
  }
  return seats.take(max).toList();
}

String _fill(String key, Map<String, Object?> values) {
  final count = values['count'];
  var text = trKey(key, count: count is int ? count : null);
  for (final MapEntry(:key, :value) in values.entries) {
    text = text.replaceAll('{{$key}}', '$value');
  }
  return text;
}

String _snr(dynamic value) {
  final n = number(value);
  return n == null ? '—' : n.toStringAsFixed(2);
}

/// A slot in the seat meter, also the swatch in its legend.
class PollerSeat extends StatelessWidget {
  const PollerSeat(this.kind, {super.key, this.height = 12});
  final PollerSeatKind kind;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: CustomPaint(
      painter: _SeatPainter(kind, BeaconColors.of(context).border),
    ),
  );
}

class _SeatPainter extends CustomPainter {
  const _SeatPainter(this.kind, this.border);
  final PollerSeatKind kind;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final box = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(.5),
      const Radius.circular(2),
    );
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    switch (kind) {
      case PollerSeatKind.own:
        canvas.drawRRect(box, Paint()..color = pollerColor);
      case PollerSeatKind.requested:
        canvas.save();
        canvas.clipRRect(box);
        final stripe = Paint()
          ..color = pollerColor
          ..strokeWidth = 2;
        for (var x = -size.height; x < size.width; x += 5) {
          canvas.drawLine(
            Offset(x, size.height),
            Offset(x + size.height, 0),
            stripe,
          );
        }
        canvas.restore();
        canvas.drawRRect(box, line..color = pollerColor);
      case PollerSeatKind.free:
        line.color = border;
        final path = Path()..addRRect(box);
        for (final metric in path.computeMetrics()) {
          for (var d = 0.0; d < metric.length; d += 5) {
            canvas.drawPath(metric.extractPath(d, d + 3), line);
          }
        }
      case PollerSeatKind.notOffered:
        canvas.drawRRect(box, Paint()..color = border.withValues(alpha: .45));
    }
  }

  @override
  bool shouldRepaint(_SeatPainter old) =>
      old.kind != kind || old.border != border;
}

/// The Poller view of a node: its slots and the repeaters it polls.
class NodePollerSection extends StatelessWidget {
  const NodePollerSection({super.key, required this.data, this.onOpenNode});

  /// The answer of `/nodes/{id}/poller`.
  final Json data;
  final void Function(String nodeId)? onOpenNode;

  @override
  Widget build(BuildContext context) {
    final colors = BeaconColors.of(context);
    final claim = data['claim'] is Map ? object(data['claim']) : null;
    if (claim == null) {
      return section(trKey('nodePoller.slots'), [
        _note(trKey('nodePoller.noClaim'), colors),
      ]);
    }
    final stale = claim['live'] == false;
    final targets = rows(data['targets']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        section(trKey('nodePoller.slots'), _summary(claim, stale, colors)),
        section(trKey('nodePoller.targets'), [
          if (targets.isEmpty)
            _note(trKey('nodePoller.noTargets'), colors)
          else
            Opacity(
              opacity: stale ? .5 : 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, t) in targets.indexed) ...[
                    if (i > 0) const SizedBox(height: 8),
                    _card(t, colors),
                  ],
                ],
              ),
            ),
        ]),
      ],
    );
  }

  Widget _note(String text, BeaconColors colors) =>
      Text(text, style: TextStyle(fontSize: 12, color: colors.muted));

  List<Widget> _summary(Json claim, bool stale, BeaconColors colors) {
    final slots = object(claim['slots']);
    int n(String key) => (number(slots[key]) ?? 0).round();
    final seats = pollerSeats(slots);
    final notOffered = seats
        .where((s) => s == PollerSeatKind.notOffered)
        .length;
    Widget legend(PollerSeatKind kind, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 12, child: PollerSeat(kind, height: 8)),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(
            fontFamily: _mono,
            fontSize: 11,
            color: colors.muted,
          ),
        ),
      ],
    );
    Widget line(String title, String value) => Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$title ',
              style: TextStyle(color: colors.dim),
            ),
            TextSpan(
              text: value,
              style: TextStyle(color: colors.normal),
            ),
          ],
        ),
        style: const TextStyle(fontFamily: _mono, fontSize: 12),
      ),
    );
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '${n('used')}'),
                TextSpan(
                  text: ' / ${n('max')}',
                  style: TextStyle(color: colors.dim),
                ),
              ],
            ),
            style: TextStyle(
              fontFamily: _mono,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: colors.bright,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              trKey('nodePoller.slotsUsed'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: _mono,
                fontSize: 12,
                color: colors.muted,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Opacity(
        opacity: stale ? .4 : 1,
        child: Semantics(
          key: const ValueKey('poller-meter'),
          container: true,
          image: true,
          label: _fill('nodePoller.meter', {
            'used': n('used'),
            'max': n('max'),
          }),
          child: ExcludeSemantics(
            child: Row(
              children: [
                for (final (i, kind) in seats.indexed) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(child: PollerSeat(kind)),
                ],
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 7),
      Wrap(
        spacing: 12,
        runSpacing: 3,
        children: [
          legend(
            PollerSeatKind.own,
            _fill('nodePoller.own', {'count': n('own')}),
          ),
          legend(
            PollerSeatKind.requested,
            _fill('nodePoller.requested', {'count': n('requested')}),
          ),
          legend(
            PollerSeatKind.free,
            _fill('nodePoller.free', {'count': n('free')}),
          ),
          if (notOffered > 0)
            legend(
              PollerSeatKind.notOffered,
              _fill('nodePoller.notOffered', {'count': notOffered}),
            ),
        ],
      ),
      const SizedBox(height: 7),
      if (stale)
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            _fill('nodePoller.stale', {'age': age(claim['receivedAt'])}),
            style: TextStyle(
              fontFamily: _mono,
              fontSize: 12,
              color: colors.warning,
            ),
          ),
        )
      else
        line(trKey('nodePoller.lastClaim'), age(claim['receivedAt'])),
      Opacity(
        opacity: stale ? .5 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            line(
              trKey('nodePoller.requests'),
              trKey(
                claim['acceptsRequests'] == true
                    ? 'nodePoller.accepting'
                    : 'nodePoller.notAccepting',
              ),
            ),
            line(
              trKey('nodePoller.readings24h'),
              '${(number(data['readings24h']) ?? 0).round()}',
            ),
          ],
        ),
      ),
    ];
  }

  Widget _tag(String text, Color color, {Color? fill, Color? border}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: border ?? Colors.transparent),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          text.toUpperCase(),
          maxLines: 1,
          style: TextStyle(
            fontFamily: _mono,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: .5,
            height: 1.2,
            color: color,
          ),
        ),
      );

  (String, Color)? _state(Json t, BeaconColors colors) {
    final state = textOf(t['state']);
    return switch (state) {
      '' => null,
      'ok' => (trKey('nodePoller.state.ok'), colors.success),
      'pending' => (trKey('nodePoller.state.pending'), colors.muted),
      'no_reply' => (
        _fill('nodePoller.state.noReply', {
          'count': (number(t['misses']) ?? 0).round(),
        }),
        colors.warning,
      ),
      'not_direct' => (trKey('nodePoller.state.notDirect'), colors.danger),
      'login_failed' => (trKey('nodePoller.state.loginFailed'), colors.danger),
      'admin_stop' => (trKey('nodePoller.state.adminStop'), colors.danger),
      _ => (state, colors.muted),
    };
  }

  Widget _card(Json t, BeaconColors colors) => LayoutBuilder(
    builder: (context, box) => _cardBody(t, colors, box.maxWidth),
  );

  Widget _cardBody(Json t, BeaconColors colors, double width) {
    final name = textOf(t['name']);
    final nodeId = textOf(t['nodeId']);
    final open = onOpenNode;
    final requested = t['requested'] == true;
    final role = textOf(t['role']);
    final state = _state(t, colors);
    final snr = number(t['claimedSnr']);
    final evidence = (number(t['evidenceCount']) ?? 0).round();
    Widget stat(String title, String value, Color color) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: _mono,
              fontSize: 9,
              letterSpacing: .5,
              color: colors.dim,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: _mono,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
    Widget ago(String title, dynamic value) => value == null
        ? stat(title, trKey('nodePoller.never'), colors.dim)
        : stat(title, age(value), colors.normal);
    return InkWell(
      key: ValueKey('poller-target-${textOf(t['publicKey'])}'),
      borderRadius: BorderRadius.circular(4),
      onTap: nodeId.isEmpty || open == null ? null : () => open(nodeId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name.isEmpty ? shortKey(t['publicKey']) : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: _mono,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: .3,
                      fontStyle: name.isEmpty ? FontStyle.italic : null,
                      color: name.isEmpty ? colors.dim : colors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Tags keep their size; shrunk only when they would crowd out the name.
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: width * .65),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        requested
                            ? _tag(
                                trKey('nodePoller.originRequested'),
                                colors.primary,
                                fill: colors.primary.withValues(alpha: .1),
                              )
                            : _tag(
                                trKey('nodePoller.originOwn'),
                                colors.normal,
                                fill: colors.muted.withValues(alpha: .12),
                              ),
                        const SizedBox(width: 4),
                        switch (role) {
                          'poller' => _tag(
                            trKey('nodePoller.rolePoller'),
                            pollerColor,
                            border: pollerColor.withValues(alpha: .55),
                          ),
                          'standby' => _tag(
                            _fill('nodePoller.roleStandby', {
                              'rank': number(t['rank'])?.round() ?? '',
                            }).trim(),
                            colors.normal,
                            border: colors.border,
                          ),
                          _ => _tag(
                            trKey('nodePoller.roleUnassigned'),
                            colors.dim,
                            border: colors.borderSubtle,
                          ),
                        },
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (state != null) ...[
              const SizedBox(height: 5),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: state.$2,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      state.$1,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: _mono,
                        fontSize: 11,
                        color: state.$2,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 7),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ago(trKey('nodePoller.lastReply'), t['lastOk']),
                const SizedBox(width: 10),
                stat(
                  trKey('nodePoller.snr'),
                  _snr(t['claimedSnr']),
                  snr == null
                      ? colors.normal
                      : snr >= 10
                      ? colors.success
                      : snr >= 5
                      ? colors.warning
                      : colors.danger,
                ),
                const SizedBox(width: 10),
                ago(trKey('nodePoller.reading'), t['latestReadingAt']),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              evidence > 0
                  ? _fill('nodePoller.evidence', {
                      'count': evidence,
                      'snr': _snr(t['evidenceSnr']),
                    })
                  : trKey('nodePoller.noEvidence'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: _mono,
                fontSize: 11,
                color: evidence > 0 ? colors.muted : colors.dim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
