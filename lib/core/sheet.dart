import 'package:flutter/material.dart';

import 'strings.dart';
import 'theme.dart';

/// Opens [builder]'s [BeaconSheet]; every bottom sheet in the app comes
/// through here so they share one frame.
Future<T?> showBeaconSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) => showModalBottomSheet<T>(
  context: context,
  useSafeArea: true,
  // The sheet sizes itself and moves up with the keyboard.
  isScrollControlled: true,
  // BeaconSheet draws its own slimmer handle.
  showDragHandle: false,
  builder: builder,
);

/// The frame every bottom sheet shares: handle, header with a close button,
/// and a body that wraps its content up to [maxHeight] of the screen.
class BeaconSheet extends StatelessWidget {
  const BeaconSheet({
    super.key,
    this.title,
    this.header,
    this.actions = const [],
    this.maxHeight = .65,
    this.fill = false,
    required this.child,
  }) : assert(title != null || header != null);

  /// Side inset for body content that doesn't pad itself.
  static const double gutter = 16;

  final String? title;

  /// Replaces [title] when the header needs more than one line of text.
  final Widget? header;

  /// Sits between the header and the close button.
  final List<Widget> actions;

  /// Share of the screen height the sheet may take.
  final double maxHeight;

  /// Holds the sheet at [maxHeight], so a searched list doesn't jump.
  final bool fill;

  /// Scrolls itself when it can outgrow the sheet.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = BeaconColors.of(context);
    final height = MediaQuery.sizeOf(context).height * maxHeight;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height),
          child: Column(
            mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10, bottom: 2),
                  decoration: BoxDecoration(
                    color: palette.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(gutter, 0, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child:
                          header ??
                          Text(
                            title!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: palette.bright,
                            ),
                          ),
                    ),
                    ...actions,
                    IconButton(
                      tooltip: tr('Close'),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
              ),
              fill ? Expanded(child: child) : Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// A sheet's list of rows, flat and split by hairlines.
class BeaconSheetRows extends StatelessWidget {
  const BeaconSheetRows({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final line = BeaconColors.of(context).borderSubtle;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 4),
      children: [
        for (final row in children) ...[
          row,
          Divider(
            height: 1,
            thickness: 1,
            indent: BeaconSheet.gutter,
            endIndent: BeaconSheet.gutter,
            color: line,
          ),
        ],
      ],
    );
  }
}
