import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/strings.dart';
import '../map/map_markers.dart' show nodeColors;

/// Simplified marker glyphs for the node chips, drawn in `currentColor`.
const _glyphs = <String, String>{
  'repeater': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="12 8 40 48"><g fill="none" stroke="currentColor" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"><line x1="32" y1="26" x2="32" y2="45"/><path d="M32 45 L25 51 M32 45 L39 51"/><circle cx="32" cy="23" r="2.6" fill="currentColor" stroke="none"/><path d="M25.5 17.5 A 10 10 0 0 0 25.5 30.5"/><path d="M20 13.5 A 15 15 0 0 0 20 34.5"/><path d="M38.5 17.5 A 10 10 0 0 1 38.5 30.5"/><path d="M44 13.5 A 15 15 0 0 1 44 34.5"/></g></svg>',
  'companion': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="12 8 40 48"><g fill="none" stroke="currentColor" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"><rect x="24" y="22" width="16" height="30" rx="4"/><path d="M28.5 22 L23 11"/><circle cx="23" cy="11" r="1.8" fill="currentColor" stroke="none"/><rect x="28" y="40" width="8" height="7" rx="1.6"/></g></svg>',
  'room_server': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="12 8 40 48"><g fill="none" stroke="currentColor" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"><rect x="18" y="15" width="28" height="34" rx="3.5"/><line x1="18" y1="26.3" x2="46" y2="26.3"/><line x1="18" y1="37.7" x2="46" y2="37.7"/></g></svg>',
  'sensor': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="10 10 44 44"><g fill="none" stroke="currentColor" stroke-width="4" stroke-linecap="round"><circle cx="32" cy="32" r="13.5"/><circle cx="32" cy="32" r="3" fill="currentColor" stroke="none"/><line x1="32" y1="13" x2="32" y2="18.5"/><line x1="32" y1="45.5" x2="32" y2="51"/><line x1="13" y1="32" x2="18.5" y2="32"/><line x1="45.5" y1="32" x2="51" y2="32"/></g></svg>',
  'poller': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 12H7L10 5L14.5 19L17.5 12H22" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  'observer': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 12C5 6.5 19 6.5 22 12 19 17.5 5 17.5 2 12Z" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linejoin="round"/><circle cx="12" cy="12" r="3" fill="currentColor"/></svg>',
  'caution': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 3 22 20H2Z" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linejoin="round"/><path d="M12 10v5M12 17.6v.4" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>',
};

const pollerColor = Color(0xFFFFB454);
const observerColor = Color(0xFFC79BFF);
const cautionColor = Color(0xFFFB923C);

/// `Room Server`, `room server` and `room_server` all name one type.
String nodeTypeKey(dynamic name) =>
    '$name'.trim().toLowerCase().replaceAll(' ', '_');

/// The map marker colour of a node type, or null for an unknown type.
Color? nodeTypeColor(dynamic name) {
  final hex = nodeColors[nodeTypeKey(name)];
  return hex == null
      ? null
      : Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
}

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// The one chip for node type, roles, scope and cautions, in list and panel.
class NodeChip extends StatelessWidget {
  const NodeChip({
    super.key,
    required this.color,
    this.label,
    this.glyph,
    this.outline = false,
    this.tooltip,
  });
  final Color color;
  final String? label, glyph, tooltip;

  /// Roles and cautions: no fill, a stronger border.
  final bool outline;

  @override
  Widget build(BuildContext context) {
    final svg = _glyphs[glyph];
    final chip = Container(
      padding: EdgeInsets.symmetric(
        horizontal: label == null ? 5 : 7,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: outline ? null : color.withValues(alpha: .09),
        border: Border.all(color: color.withValues(alpha: outline ? .55 : .3)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (svg != null)
            SvgPicture.string(
              svg.replaceAll('currentColor', _hex(color)),
              width: 12,
              height: 12,
            ),
          if (svg != null && label != null) const SizedBox(width: 5),
          if (label != null)
            Text(
              label!,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: color,
                letterSpacing: .4,
                height: 1.2,
              ),
            ),
        ],
      ),
    );
    final named = tooltip ?? label;
    return named == null
        ? chip
        : Tooltip(
            message: named,
            child: Semantics(label: named, child: chip),
          );
  }
}

/// Type chip: glyph and name in the marker colour, muted grey when unknown.
Widget nodeTypeChip(
  BuildContext context,
  dynamic type,
  String label,
  Color muted,
) {
  final key = nodeTypeKey(type);
  return NodeChip(
    key: ValueKey('chip-type-$key'),
    color: nodeTypeColor(type) ?? muted,
    glyph: nodeColors.containsKey(key) ? key : null,
    label: label.replaceAll('_', ' '),
  );
}

NodeChip pollerChip({bool iconOnly = false}) => NodeChip(
  key: const ValueKey('chip-poller'),
  color: pollerColor,
  glyph: 'poller',
  outline: true,
  label: iconOnly ? null : trKey('nodeDetail.poller').toUpperCase(),
  tooltip: trKey('nodeDetail.poller'),
);

NodeChip observerChip({bool iconOnly = false}) => NodeChip(
  key: const ValueKey('chip-observer'),
  color: observerColor,
  glyph: 'observer',
  outline: true,
  label: iconOnly ? null : trKey('nodes.observer').toUpperCase(),
  tooltip: trKey('nodes.observer'),
);

NodeChip cautionChip(String text) => NodeChip(
  key: ValueKey('chip-caution-$text'),
  color: cautionColor,
  glyph: 'caution',
  outline: true,
  label: text,
);
