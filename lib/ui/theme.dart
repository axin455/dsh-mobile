import 'package:flutter/material.dart';

import 'colors.dart';
import 'tokens.dart';

/// 从固定色板构造 ThemeData。
///
/// 不启用 Material You 动态取色：FlClash v0.9.2 默认主题已锁定 iOS 蓝，
/// 预览版第一版也不开放强调色自定义。
ThemeData buildAppTheme(ColorScheme scheme) {
  final isDark = scheme.brightness == Brightness.dark;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    splashFactory: InkSparkle.splashFactory,
    dividerColor: scheme.outlineVariant,
    iconTheme: IconThemeData(color: scheme.onSurface, size: 24),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      foregroundColor: scheme.onSurface,
    ),
    // modal 只 dim 不 blur：FlClash 的 scrim 规则是 32% 的 modalScrim。
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.cardOf(scheme),
      surfaceTintColor: Colors.transparent,
      barrierColor: scheme.scrim.withValues(alpha: 0.32),
      shape: AppShape.xl,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: scheme.scrim.withValues(alpha: 0.32),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      elevation: 0,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isDark
          ? scheme.surfaceContainerHigh
          : scheme.inverseSurface,
      contentTextStyle: TextStyle(
        fontSize: 14,
        height: 1.28,
        color: isDark ? scheme.onSurface : scheme.onInverseSurface,
      ),
      actionTextColor: isDark ? scheme.primary : scheme.inversePrimary,
      shape: AppShape.md,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : scheme.surfaceContainerHighest,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : scheme.outlineVariant,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.24),
      selectionHandleColor: scheme.primary,
    ),
  );
}
