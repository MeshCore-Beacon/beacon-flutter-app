import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'json.dart';

@immutable
class BeaconColors extends ThemeExtension<BeaconColors> {
  const BeaconColors({
    required this.primary,
    required this.secondary,
    required this.normal,
    required this.bright,
    required this.dim,
    required this.muted,
    required this.border,
    required this.borderSubtle,
    required this.raised,
    required this.success,
    required this.warning,
    required this.danger,
    required this.base,
    required this.surface,
  });
  final Color primary,
      secondary,
      normal,
      bright,
      dim,
      muted,
      border,
      borderSubtle,
      raised,
      success,
      warning,
      danger,
      base,
      surface;
  static BeaconColors of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return theme.extension<BeaconColors>() ??
        BeaconColors(
          primary: scheme.primary,
          secondary: scheme.secondary,
          normal: scheme.onSurfaceVariant,
          bright: scheme.onSurface,
          dim: scheme.onSurfaceVariant,
          muted: scheme.onSurfaceVariant,
          border: scheme.outline,
          borderSubtle: scheme.outlineVariant,
          raised: scheme.surfaceContainerHighest,
          success: const Color(0xff22c55e),
          warning: const Color(0xffeab308),
          danger: scheme.error,
          base: scheme.surface,
          surface: scheme.surface,
        );
  }

  @override
  BeaconColors copyWith({
    Color? primary,
    Color? secondary,
    Color? normal,
    Color? bright,
    Color? dim,
    Color? muted,
    Color? border,
    Color? borderSubtle,
    Color? raised,
    Color? success,
    Color? warning,
    Color? danger,
    Color? base,
    Color? surface,
  }) => BeaconColors(
    primary: primary ?? this.primary,
    secondary: secondary ?? this.secondary,
    normal: normal ?? this.normal,
    bright: bright ?? this.bright,
    dim: dim ?? this.dim,
    muted: muted ?? this.muted,
    border: border ?? this.border,
    borderSubtle: borderSubtle ?? this.borderSubtle,
    raised: raised ?? this.raised,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    base: base ?? this.base,
    surface: surface ?? this.surface,
  );
  @override
  BeaconColors lerp(covariant BeaconColors? other, double t) {
    if (other == null) return this;
    return BeaconColors(
      primary: Color.lerp(primary, other.primary, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      normal: Color.lerp(normal, other.normal, t)!,
      bright: Color.lerp(bright, other.bright, t)!,
      dim: Color.lerp(dim, other.dim, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      base: Color.lerp(base, other.base, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
    );
  }
}

class BeaconTheme {
  BeaconTheme(this.id, this.name, this.vars);
  final String id;
  final String name;
  final Json vars;
  static List<BeaconTheme> all = [];
  static Future<void> load() async {
    all = rows(jsonDecode(await rootBundle.loadString('assets/themes.json')))
        .where((e) => e['hidden'] != true)
        .map(
          (e) => BeaconTheme(
            textOf(e['id']),
            textOf(e['name']),
            object(e['vars']),
          ),
        )
        .toList();
  }

  Color color(String token, String fallback) => Color(
    int.parse(
      textOf(vars['--palette-$token'], fallback).replaceFirst('#', 'ff'),
      radix: 16,
    ),
  );
  ThemeData get data {
    final base = color('bg-base', '#09090B');
    final surface = color('bg-surface', '#111114');
    final primary = color('primary', '#3B82F6');
    final normal = color('text-normal', '#A1A1AA');
    final bright = color('text-bright', '#FAFAFA');
    final border = color('border', '#27272A');
    final palette = BeaconColors(
      primary: primary,
      secondary: color('secondary', '#A78BFA'),
      normal: normal,
      bright: bright,
      dim: color('text-dim', '#5F5F65'),
      muted: color('text-muted', '#73737B'),
      border: border,
      borderSubtle: color('border-subtle', '#1E1E22'),
      raised: color('bg-raised', '#1A1A1F'),
      success: color('green', '#22C55E'),
      warning: color('warn', '#EAB308'),
      danger: color('danger', '#EF4444'),
      base: base,
      surface: surface,
    );
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: base.computeLuminance() > 0.5
              ? Brightness.light
              : Brightness.dark,
        ).copyWith(
          primary: primary,
          surface: surface,
          onSurface: bright,
          onSurfaceVariant: normal,
          outlineVariant: palette.borderSubtle,
          surfaceTint: Colors.transparent,
          surfaceContainer: palette.raised,
          surfaceContainerLow: surface,
          surfaceContainerHigh: palette.raised,
          primaryContainer: Color.alphaBlend(
            primary.withValues(alpha: .12),
            surface,
          ),
          onPrimaryContainer: primary,
          secondaryContainer: Color.alphaBlend(
            palette.secondary.withValues(alpha: .12),
            surface,
          ),
          onSecondaryContainer: palette.secondary,
          onPrimary: primary.computeLuminance() > .4 ? base : bright,
          surfaceContainerHighest: color('bg-raised', '#1A1A1F'),
          outline: border,
          error: color('danger', '#EF4444'),
          secondary: color('secondary', '#A78BFA'),
        );
    return ThemeData(
      useMaterial3: true,
      extensions: [palette],
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: palette.raised,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: border),
        ),
        textStyle: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 11,
          color: bright,
        ),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: palette.raised,
        headerForegroundColor: bright,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: border),
        ),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: border),
        ),
        hourMinuteColor: palette.raised,
        hourMinuteTextColor: primary,
        dialBackgroundColor: palette.raised,
        dialHandColor: primary,
      ),
      iconTheme: IconThemeData(color: palette.muted, size: 18),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 12,
          color: normal,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: border),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
              side: BorderSide(color: border),
            ),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 14,
          color: bright,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: border),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: normal,
          textStyle: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          textStyle: const TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: primary,
        collapsedIconColor: palette.muted,
        textColor: bright,
        collapsedTextColor: normal,
        shape: const Border(),
        collapsedShape: const Border(),
      ),
      checkboxTheme: CheckboxThemeData(
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
      colorScheme: scheme,
      scaffoldBackgroundColor: base,
      fontFamily: 'Inter',
      visualDensity: VisualDensity.compact,
      textTheme: ThemeData.dark().textTheme
          .apply(fontFamily: 'Inter', bodyColor: normal, displayColor: bright)
          .copyWith(
            bodyMedium: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              color: normal,
              height: 1.5,
            ),
            bodySmall: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              color: normal,
              height: 1.4,
            ),
            titleMedium: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: bright,
            ),
          ),
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: bright,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 50,
        titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: bright,
        ),
      ),
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        labelStyle: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 11,
          color: palette.muted,
        ),
        hintStyle: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 12,
          color: palette.muted,
        ),
        floatingLabelStyle: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 11,
          color: primary,
        ),
        filled: true,
        fillColor: color('bg-raised', '#1A1A1F'),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: border),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        iconColor: palette.muted,
        textColor: normal,
        selectedColor: primary,
        selectedTileColor: primary.withValues(alpha: .08),
        titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          color: bright,
        ),
        subtitleTextStyle: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 11,
          color: palette.muted,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: primary.withValues(alpha: .12),
        checkmarkColor: primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: border),
        labelStyle: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 11,
          color: normal,
        ),
      ),
    );
  }

  static ThemeData resolve(String id) =>
      (all.where((e) => e.id == id).firstOrNull ??
              (all.isEmpty
                  ? BeaconTheme('neutral-blue', 'Neutral Blue', {})
                  : all.first))
          .data;
}
