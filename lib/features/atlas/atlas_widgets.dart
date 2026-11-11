import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';
import 'observer_sample.dart';

const _mono = 'JetBrainsMono';

/// A catalog string with its `{{name}}` slots filled.
String at(String key, {int? count, Map<String, Object?> args = const {}}) {
  var text = trKey('atlas.$key', count: count);
  for (final MapEntry(:key, :value) in args.entries) {
    text = text.replaceAll('{{$key}}', '$value');
  }
  return text;
}

String formatHex(String value) => shortKey(value).toUpperCase();

/// Prints 915.0 as "915", as the web's number formatting does.
String _plain(double value) =>
    value == value.roundToDouble() ? '${value.round()}' : '$value';

String _trimmed(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// 932 -> "932", 14732 -> "14.7k", 8900000 -> "8.9M".
String formatCount(double? n) {
  if (n == null) return '—';
  if (n.abs() < 1000) return _plain(n);
  // The unit comes from the rounded value so 999999 rolls to "1M", not "1000k".
  bool fits(num div) => (n / div * 10).round().abs() < 10000;
  if (fits(1e3)) return '${_trimmed(n / 1e3)}k';
  if (fits(1e6)) return '${_trimmed(n / 1e6)}M';
  return '${_trimmed(n / 1e9)}B';
}

/// One decimal with its unit, "—" when there is no sample.
String average(double? value, [String unit = '']) => value == null
    ? '—'
    : '${value.toStringAsFixed(1)}${unit.isEmpty ? '' : ' $unit'}';

String percent(double v) => '${v < 10 ? v.toStringAsFixed(1) : v.round()}%';
String formatBattery(double volts) => '${volts.toStringAsFixed(2)}V';

String formatUptime(double seconds) {
  final s = seconds.floor();
  final d = s ~/ 86400, h = s % 86400 ~/ 3600, m = s % 3600 ~/ 60;
  String unit(String u, int count) => trKey('timestamp.unit.$u', count: count);
  if (d > 0) return '${unit('d', d)} ${unit('h', h)} ${unit('m', m)}';
  if (h > 0) return '${unit('h', h)} ${unit('m', m)}';
  return unit('m', m);
}

String? formatRadioParts({double? freq, double? sf, double? bw, double? cr}) {
  bool known(double? v) => v != null && v > 0;
  final parts = [
    if (known(freq)) '${_plain(freq!)} MHz',
    if (known(sf)) 'SF${_plain(sf!)}',
    if (known(bw)) '${_plain(bw!)} kHz',
    if (known(cr)) 'CR 4/${_plain(cr!)}',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Summaries carry radio as a compact "freq,bw,sf" string, e.g. "915,250,11".
String? formatRadio(String radio) {
  if (radio.isEmpty) return null;
  final parts = radio.split(',');
  if (parts.length < 3 || parts.take(3).any((part) => part.isEmpty)) {
    return radio;
  }
  final f = double.tryParse(parts[0].trim());
  final b = double.tryParse(parts[1].trim());
  final s = double.tryParse(parts[2].trim());
  if (f == null || b == null || s == null) return radio;
  return formatRadioParts(freq: f, sf: s, bw: b);
}

String formatAbsolute(int epochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  String pad(int n) => '$n'.padLeft(2, '0');
  return '${d.year}-${pad(d.month)}-${pad(d.day)} ${pad(d.hour)}:${pad(d.minute)}:${pad(d.second)}';
}

/// "3m ago", counted from the page's tick so every card agrees.
String ago(int epochMs, int now) {
  final seconds = math.max(0, (now - epochMs) ~/ 1000);
  final (unit, count) = seconds < 60
      ? ('s', seconds)
      : seconds < 3600
      ? ('m', seconds ~/ 60)
      : seconds < 86400
      ? ('h', seconds ~/ 3600)
      : ('d', seconds ~/ 86400);
  return tr('{{duration}} ago')
      .replaceAll('{{duration}}', trKey('timestamp.unit.$unit', count: count));
}

/// The fetched status goes stale, so recency of the last status decides when known.
String observerStatus(Json observer, int now) {
  final last = number(observer['lastStatusAt']);
  if (last == null) return textOf(observer['status']);
  return now - last < 5 * 60000 ? 'online' : 'offline';
}

TextStyle atlasMono(double size, Color color, {FontWeight? weight}) =>
    TextStyle(
      fontFamily: _mono,
      fontSize: size,
      color: color,
      fontWeight: weight,
    );

/// Titled surface card, as the Analytics panels.
class AtlasPanel extends StatelessWidget {
  const AtlasPanel({
    super.key,
    required this.title,
    this.right,
    required this.child,
  });
  final Widget title;
  final Widget? right;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      fontFamily: _mono,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: .55,
                      color: c.normal,
                    ),
                    child: title,
                  ),
                ),
                if (right != null) ...[const SizedBox(width: 8), right!],
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class AtlasBadge extends StatelessWidget {
  const AtlasBadge(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final color = BeaconColors.of(context).muted;
    const fill = .10, edge = .12;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: fill),
        border: Border.all(color: color.withValues(alpha: edge)),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: _mono,
          fontSize: 11,
          height: 16.5 / 11,
          fontWeight: FontWeight.w600,
          letterSpacing: .55,
          color: color,
        ),
      ),
    );
  }
}

/// Compact bordered action used inside cards and the Matches list.
class AtlasAction extends StatelessWidget {
  const AtlasAction(this.label, {super.key, this.onPressed, this.semantics});
  final String label;
  final VoidCallback? onPressed;
  final String? semantics;
  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: semantics,
      excludeSemantics: semantics != null,
      child: Opacity(
        opacity: onPressed == null ? .4 : 1,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label, style: atlasMono(11, c.primary)),
          ),
        ),
      ),
    );
  }
}

/// Icon-only header action; every one shares a box so the row stays even.
class AtlasIconButton extends StatelessWidget {
  const AtlasIconButton({
    super.key,
    required this.icon,
    required this.label,
    this.tooltip,
    this.onPressed,
    this.pressed,
    this.muted = false,
  });
  final CustomPainter Function(Color color) icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool? pressed;
  final bool muted;
  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    return Tooltip(
      message: tooltip ?? label,
      child: Semantics(
        button: true,
        label: label,
        toggled: pressed,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: 28,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: pressed == true ? c.primary.withValues(alpha: .1) : null,
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: CustomPaint(
              size: const Size(10, 14),
              painter: icon(muted ? c.muted : c.primary),
            ),
          ),
        ),
      ),
    );
  }
}

class PinIcon extends CustomPainter {
  const PinIcon(this.color, {required this.filled});
  final Color color;
  final bool filled;
  @override
  void paint(Canvas canvas, Size size) {
    final head = Path()
      ..moveTo(2.5, 1)
      ..lineTo(7.5, 1)
      ..lineTo(7.5, 2.5)
      ..lineTo(6.5, 3.5)
      ..lineTo(6.5, 7)
      ..lineTo(8.5, 9)
      ..lineTo(8.5, 10)
      ..lineTo(1.5, 10)
      ..lineTo(1.5, 9)
      ..lineTo(3.5, 7)
      ..lineTo(3.5, 3.5)
      ..lineTo(2.5, 2.5)
      ..close();
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    if (filled) canvas.drawPath(head, Paint()..color = color);
    canvas.drawPath(head, stroke);
    canvas.drawLine(const Offset(5, 10), const Offset(5, 13.3), stroke);
  }

  @override
  bool shouldRepaint(PinIcon old) => old.color != color || old.filled != filled;
}

class CrossIcon extends CustomPainter {
  const CrossIcon(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(1.5, 3.5), const Offset(8.5, 10.5), stroke);
    canvas.drawLine(const Offset(8.5, 3.5), const Offset(1.5, 10.5), stroke);
  }

  @override
  bool shouldRepaint(CrossIcon old) => old.color != color;
}

class GripIcon extends CustomPainter {
  const GripIcon(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color;
    for (final x in const [2.5, 7.5]) {
      for (final y in const [2.0, 7.0, 12.0]) {
        canvas.drawCircle(Offset(x, y), 1.3, fill);
      }
    }
  }

  @override
  bool shouldRepaint(GripIcon old) => old.color != color;
}

/// Pill group: the active pill gets a primary tint and ring.
class AtlasSegmented<T> extends StatelessWidget {
  const AtlasSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.label,
    this.stretch = false,
  });
  final Map<T, String> options;
  final T value;
  final ValueChanged<T> onChanged;
  final String label;

  /// Fill the container, every option the same width.
  final bool stretch;
  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    Widget pill(T option, String text) {
      final active = option == value;
      final child = Semantics(
        button: true,
        selected: active,
        child: InkWell(
          onTap: () => onChanged(option),
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            alignment: stretch ? Alignment.center : null,
            decoration: BoxDecoration(
              color: active ? c.primary.withValues(alpha: .15) : null,
              border: Border.all(
                color: active
                    ? c.primary.withValues(alpha: .3)
                    : Colors.transparent,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              style: TextStyle(
                fontFamily: _mono,
                fontSize: 11,
                height: 14 / 11,
                fontWeight: FontWeight.w600,
                letterSpacing: .275,
                color: active ? c.bright : c.muted,
              ),
            ),
          ),
        ),
      );
      return stretch ? Expanded(child: child) : child;
    }

    final pills = [
      for (final MapEntry(:key, :value) in options.entries) pill(key, value),
    ];
    return Semantics(
      container: true,
      label: label,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: c.raised,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Row(
            mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
            children: [
              for (var i = 0; i < pills.length; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                pills[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small (i) marker holding the notes that would crowd a card.
class AtlasInfoTip extends StatelessWidget {
  const AtlasInfoTip(this.lines, {super.key});
  final List<String> lines;
  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    return Tooltip(
      message: lines.join('\n\n'),
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 12),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Semantics(
        button: true,
        label: tr('More information'),
        child: Padding(
          // The marker is 14 px; the padding gives it a touchable box.
          padding: const EdgeInsets.fromLTRB(6, 4, 0, 4),
          child: Container(
            width: 14,
            height: 14,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.dim),
            ),
            child: Text(
              'i',
              style: TextStyle(
                fontFamily: _mono,
                fontSize: 9,
                height: 1,
                fontWeight: FontWeight.w600,
                color: c.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _sparkWidth = 120.0;
const sparkHeight = 20.0;

class SparklinePainter extends CustomPainter {
  const SparklinePainter(
    this.values,
    this.color, {
    this.markPeak = false,
    this.interpolateGaps = false,
  });
  final List<double?> values;
  final Color color;
  final bool markPeak, interpolateGaps;

  @override
  void paint(Canvas canvas, Size size) {
    final known = values.whereType<double>().toList();
    if (known.isEmpty) return;
    final max = known.reduce(math.max), min = known.reduce(math.min);
    final range = max - min == 0 ? 1.0 : max - min;
    final scale = size.width / _sparkWidth;
    double x(int i) =>
        (values.length == 1
            ? _sparkWidth / 2
            : i / (values.length - 1) * _sparkWidth) *
        scale;
    double y(double v) =>
        sparkHeight - 1 - (v - min) / range * (sparkHeight - 2);
    Paint stroke(double width, [double alpha = 1]) => Paint()
      ..color = color.withValues(alpha: color.a * alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // A null hour breaks the line, so an outage shows as a gap rather than a straight join.
    final runs = <List<Offset>>[[]];
    final samples = <(int, double)>[];
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) {
        runs.add([]);
      } else {
        runs.last.add(Offset(x(i), y(v)));
        samples.add((i, v));
      }
    }
    final line = stroke(1.5)..strokeCap = StrokeCap.butt;
    for (final run in runs) {
      if (run.length > 1) {
        canvas.drawPath(Path()..addPolygon(run, false), line);
      } else if (run.length == 1) {
        canvas.drawPoints(PointMode.points, run, stroke(3));
      }
    }
    if (interpolateGaps) {
      final dashed = stroke(1, .45)..strokeCap = StrokeCap.butt;
      for (var n = 1; n < samples.length; n++) {
        final (i, v) = samples[n];
        final (pi, pv) = samples[n - 1];
        if (i <= pi + 1) continue;
        final from = Offset(x(pi), y(pv)), to = Offset(x(i), y(v));
        final length = (to - from).distance;
        final step = 3 * scale;
        for (var d = 0.0; d < length; d += step * 2) {
          canvas.drawLine(
            Offset.lerp(from, to, d / length)!,
            Offset.lerp(from, to, math.min(d + step, length) / length)!,
            dashed,
          );
        }
      }
    }
    if (markPeak) {
      canvas.drawPoints(PointMode.points, [
        Offset(x(values.indexOf(max)), y(max)),
      ], stroke(5));
    }
  }

  @override
  bool shouldRepaint(SparklinePainter old) =>
      old.color != color ||
      old.markPeak != markPeak ||
      old.interpolateGaps != interpolateGaps ||
      !_same(old.values, values);
}

bool _same(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One bar per run of hours that reported, so gaps read at a glance.
class PresencePainter extends CustomPainter {
  const PresencePainter(this.hours, this.color);
  final List<bool> hours;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (hours.isEmpty) return;
    const mid = sparkHeight / 2;
    canvas.drawLine(
      const Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = color.withValues(alpha: color.a * .25)
        ..strokeWidth = 1,
    );
    final slot = size.width / hours.length;
    final fill = Paint()..color = color;
    for (var i = 0; i < hours.length; i++) {
      if (!hours[i]) continue;
      var end = i;
      while (end + 1 < hours.length && hours[end + 1]) {
        end++;
      }
      canvas.drawRect(
        Rect.fromLTWH(i * slot, mid - 4, (end - i + 1) * slot, 8),
        fill,
      );
      i = end;
    }
  }

  @override
  bool shouldRepaint(PresencePainter old) =>
      old.color != color || !_same(old.hours, hours);
}

/// Share bar of the payload types heard, busiest first, with the top ones named underneath.
class TypeMix extends StatelessWidget {
  const TypeMix({super.key, required this.types, required this.colors});
  final List<PayloadShare> types;
  final List<Color> colors;
  static const _slices = 5;
  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    final total = types.fold<double>(0, (sum, p) => sum + p.count);
    if (total == 0) return const SizedBox(height: sparkHeight);
    String name(PayloadShare p) => p.name.toLowerCase() == 'unknown'
        ? tr('Unknown')
        : p.name.toLowerCase();
    final rest = types.skip(_slices).fold<double>(0, (sum, p) => sum + p.count);
    final slices = [
      for (final (i, p) in types.take(_slices).indexed)
        (name(p), p.count, colors[i % colors.length]),
      if (rest > 0) (at('otherTypes'), rest, c.dim),
    ];
    String share(double n) => '${(n / total * 100).round()}%';
    return SizedBox(
      height: sparkHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (_, count, color) in slices)
                    Expanded(
                      flex: math.max(1, (count / total * 10000).round()),
                      child: ColoredBox(color: color),
                    ),
                ],
              ),
            ),
          ),
          // One line: entries that don't fit wrap out of sight rather than cut mid-word.
          SizedBox(
            height: 9,
            child: Wrap(
              spacing: 8,
              clipBehavior: Clip.hardEdge,
              children: [
                for (final (label, count, color) in slices.take(3))
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '■ ',
                          style: TextStyle(color: color),
                        ),
                        TextSpan(text: '$label ${share(count)}'),
                      ],
                    ),
                    softWrap: false,
                    style: TextStyle(
                      fontFamily: _mono,
                      fontSize: 9,
                      height: 1,
                      color: c.muted,
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

/// KPI tile: label, big mono value, sparkline (or presence strip) and sub-label.
class AtlasStatTile extends StatelessWidget {
  const AtlasStatTile({
    super.key,
    required this.label,
    required this.value,
    required this.accent,
    this.spark,
    this.markPeak = false,
    this.presence,
    this.sublabel,
    this.interpolateGaps = false,
    this.visual,
  });
  final Widget label;
  final String value;
  final Color accent;
  final List<double?>? spark;
  final bool markPeak, interpolateGaps;
  final List<bool>? presence;
  final String? sublabel;

  /// Replaces the sparkline.
  final Widget? visual;

  static Widget text(String label) => Builder(
    builder: (context) => Text(label.toUpperCase(), style: labelStyle(context)),
  );
  static TextStyle labelStyle(BuildContext context) => TextStyle(
    fontFamily: _mono,
    fontSize: 10,
    height: 1.5,
    fontWeight: FontWeight.w600,
    letterSpacing: .5,
    color: BeaconColors.of(context).muted,
  );

  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    final chart =
        visual ??
        SizedBox(
          height: sparkHeight,
          width: double.infinity,
          child: presence != null
              ? CustomPaint(painter: PresencePainter(presence!, accent))
              : spark != null
              ? CustomPaint(
                  painter: SparklinePainter(
                    spark!,
                    accent,
                    markPeak: markPeak,
                    interpolateGaps: interpolateGaps,
                  ),
                )
              : null,
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 8,
            runSpacing: 2,
            children: [
              label,
              if (sublabel != null)
                Text(
                  sublabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: _mono,
                    fontSize: 9,
                    height: 1.5,
                    color: c.dim,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: TextStyle(
              fontFamily: _mono,
              fontSize: 20,
              height: 1.4,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: c.bright,
            ),
          ),
          const Spacer(),
          const SizedBox(height: 6),
          chart,
        ],
      ),
    );
  }
}

/// A tile's own label is the trigger, so the picker costs the tile no room.
class TilePicker extends StatelessWidget {
  const TilePicker({
    super.key,
    required this.label,
    required this.options,
    required this.onPick,
    this.onReset,
  });
  final String label;
  final Map<String, String> options;
  final ValueChanged<String> onPick;

  /// Offered under the choices when the card is off its default layout.
  final VoidCallback? onReset;
  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    MenuItemButton item(String text, VoidCallback onPressed, Color color) =>
        MenuItemButton(
          onPressed: onPressed,
          style: MenuItemButton.styleFrom(
            minimumSize: const Size(152, 36),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: const TextStyle(fontFamily: _mono, fontSize: 12),
            foregroundColor: color,
          ),
          child: Text(text),
        );
    return MenuAnchor(
      style: const MenuStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
      ),
      menuChildren: [
        for (final MapEntry(:key, :value) in options.entries)
          item(value, () => onPick(key), c.muted),
        if (onReset != null) ...[
          const Divider(height: 9),
          item(at('resetTiles'), onReset!, c.primary),
        ],
      ],
      builder: (context, menu, _) => Semantics(
        button: true,
        label: at('changeTile', args: {'name': label}),
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  style: AtlasStatTile.labelStyle(context),
                ),
              ),
              const SizedBox(width: 4),
              AtlasCaret(color: c.dim),
            ],
          ),
        ),
      ),
    );
  }
}

/// Faint beacon mark and a message, as the web's empty state.
class AtlasEmpty extends StatelessWidget {
  const AtlasEmpty({super.key, required this.title, required this.subtitle});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) {
    final c = BeaconColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 192),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.explore_outlined, size: 36, color: c.border),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: atlasMono(14, c.muted).copyWith(letterSpacing: .35),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: atlasMono(12, c.dim),
            ),
          ],
        ),
      ),
    );
  }
}

/// A pan that claims the pointer on touch down, so the list behind never scrolls.
class EagerPanRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// A Row or Column that paints one child above its siblings.
class RaisedFlex extends Flex {
  const RaisedFlex({
    super.key,
    required super.direction,
    super.crossAxisAlignment,
    super.mainAxisSize,
    this.raised,
    super.children,
  });
  final int? raised;
  @override
  RenderFlex createRenderObject(BuildContext context) => _RenderRaisedFlex(
    direction: direction,
    mainAxisSize: mainAxisSize,
    crossAxisAlignment: crossAxisAlignment,
    textDirection: getEffectiveTextDirection(context),
  )..raised = raised;
  @override
  void updateRenderObject(BuildContext context, RenderFlex renderObject) {
    super.updateRenderObject(context, renderObject);
    (renderObject as _RenderRaisedFlex).raised = raised;
  }
}

class _RenderRaisedFlex extends RenderFlex {
  _RenderRaisedFlex({
    super.direction,
    super.mainAxisSize,
    super.crossAxisAlignment,
    super.textDirection,
  });
  int? _raised;
  set raised(int? value) {
    if (value == _raised) return;
    _raised = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_raised == null) return super.paint(context, offset);
    RenderBox? top;
    var child = firstChild;
    for (var i = 0; child != null; i++) {
      final data = child.parentData! as FlexParentData;
      if (i == _raised) {
        top = child;
      } else {
        context.paintChild(child, data.offset + offset);
      }
      child = data.nextSibling;
    }
    if (top != null) {
      context.paintChild(
        top,
        (top.parentData! as FlexParentData).offset + offset,
      );
    }
  }
}

/// The small down triangle on a picker; the mono font has no glyph for it.
class AtlasCaret extends StatelessWidget {
  const AtlasCaret({super.key, required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(6, 4), painter: _CaretPainter(color));
}

class _CaretPainter extends CustomPainter {
  const _CaretPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close(),
    Paint()..color = color,
  );
  @override
  bool shouldRepaint(_CaretPainter old) => old.color != color;
}
