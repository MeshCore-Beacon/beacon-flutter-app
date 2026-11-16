import 'package:flutter/material.dart';

import '../../core/json.dart';
import '../../core/strings.dart';
import '../../core/theme.dart';

/// Optional backend evidence assessment, not proof of authenticity or an RF collision.
class TraceQualityNotice extends StatelessWidget {
  const TraceQualityNotice({
    super.key,
    required this.quality,
    this.compact = false,
  });
  final dynamic quality;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final assessment = object(quality);
    final status = textOf(assessment['status']);
    if (status != 'suspect' && status != 'ambiguous') {
      return const SizedBox.shrink();
    }
    final reasons = assessment['reasons'] is List
        ? (assessment['reasons'] as List)
              .whereType<String>()
              .map((reason) {
                final key = 'traces.quality.$reason';
                final translated = trKey(key);
                return translated == key ? reason : translated;
              })
              .join(' · ')
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 11, color: BeaconColors.of(context).warning),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(trKey('traces.quality.$status')),
            if (!compact && reasons.isNotEmpty) Text(reasons),
            if (!compact) Text(trKey('traces.quality.evidenceOnly')),
          ],
        ),
      ),
    );
  }
}
