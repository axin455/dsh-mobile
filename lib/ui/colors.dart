import 'package:flutter/material.dart';

/// 固定的视觉色板，不做 Material You 动态取色。
///
/// 依据 FlClash v0.9.2 lib/ui/color.dart 与 lib/ui/surface.dart：
/// 表面色度上限为 3（`_surfaceChroma`），层级靠 surface 填充叠加与阴影表达，
/// 不靠色相区分。accent 取 FlClash 默认主题种子 `defaultPrimaryColor`
/// （lib/common/constant.dart: 0xFF007AFF），暗色对应 iOS 系统蓝 #0A84FF。
abstract final class AppColors {
  /// 表面色度上限，与 FlClash `_surfaceChroma` 一致。
  static const double surfaceChroma = 3;

  /// 中性强调色：亮色近黑，暗色近白。整体只用灰 / 白 / 黑三档，
  /// 不再使用任何蓝色作为强调色。
  static const Color accent = Color(0xFF1C1C1E);
  static const Color accentDark = Color(0xFFEDEDED);

  /// 页面底色。
  static const Color canvas = Color(0xFFF2F2F4);

  /// FlClash 的暗色 surface 由 seededColorScheme 从 HCT 中性色 tone 6 生成
  /// （lib/ui/color.dart: `neutral(MaterialDynamicColors.surface, _surfaceChroma)`），
  /// theme.dart 没有写死取值；这里取最接近的近黑 #121212。
  static const Color canvasDark = Color(0xFF121212);

  /// 卡片底色：亮色纯白；暗色对应 FlClash `SurfaceLevel.card`
  /// （即暗色 `surfaceContainer`，HCT tone 15）。
  static const Color card = Color(0xFFFFFFFF);
  static const Color cardDark = Color(0xFF1E1E20);

  /// iOS 标签色。
  static const Color textPrimary = Color(0xFF1C1C1E);
  static const Color textSecondary = Color(0xFF8E8E93);
  static const Color textPrimaryDark = Color(0xFFFFFFFF);

  /// iOS 暗色 secondary label：EBEBF5 @ 60%。
  static const Color textSecondaryDark = Color(0x99EBEBF5);

  /// 亮色主题。
  static const ColorScheme light = ColorScheme(
    brightness: Brightness.light,
    primary: accent,
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFECECEE),
    onPrimaryContainer: Color(0xFF1C1C1E),
    secondary: Color(0xFF6B7280),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFEEF1F5),
    onSecondaryContainer: Color(0xFF37404B),
    tertiary: Color(0xFF6B7280),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFEEF1F5),
    onTertiaryContainer: Color(0xFF37404B),
    error: Color(0xFFFF3B30),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFE5E3),
    onErrorContainer: Color(0xFF8A1F17),
    surface: canvas,
    onSurface: textPrimary,
    surfaceDim: Color(0xFFE7EAEE),
    surfaceBright: card,
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF8F9FB),
    surfaceContainer: card,
    surfaceContainerHigh: Color(0xFFEDF0F3),
    surfaceContainerHighest: Color(0xFFE4E8EC),
    onSurfaceVariant: textSecondary,
    outline: Color(0xFFC7CBD1),
    outlineVariant: Color(0xFFDDE1E6),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFF1C1C1E),
    onInverseSurface: Color(0xFFF2F4F7),
    inversePrimary: accentDark,
    surfaceTint: accent,
  );

  /// 暗色主题。
  static const ColorScheme dark = ColorScheme(
    brightness: Brightness.dark,
    primary: accentDark,
    onPrimary: Color(0xFF111111),
    primaryContainer: Color(0xFF2C2C2E),
    onPrimaryContainer: Color(0xFFEDEDED),
    secondary: Color(0xFF99A0AA),
    onSecondary: Color(0xFF101214),
    secondaryContainer: Color(0xFF2C2F33),
    onSecondaryContainer: Color(0xFFDDE1E6),
    tertiary: Color(0xFF99A0AA),
    onTertiary: Color(0xFF101214),
    tertiaryContainer: Color(0xFF2C2F33),
    onTertiaryContainer: Color(0xFFDDE1E6),
    error: Color(0xFFFF453A),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFF5C0F0C),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: canvasDark,
    onSurface: textPrimaryDark,
    surfaceDim: Color(0xFF0D0D0D),
    surfaceBright: Color(0xFF2C2C2E),
    surfaceContainerLowest: Color(0xFF0A0A0A),
    surfaceContainerLow: Color(0xFF171719),
    surfaceContainer: cardDark,
    surfaceContainerHigh: Color(0xFF262629),
    surfaceContainerHighest: Color(0xFF2F2F31),
    onSurfaceVariant: textSecondaryDark,
    outline: Color(0xFF545458),
    outlineVariant: Color(0xFF38383A),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFFF2F4F7),
    onInverseSurface: Color(0xFF1C1C1E),
    inversePrimary: accent,
    surfaceTint: accentDark,
  );

  static ColorScheme of(BuildContext context) => Theme.of(context).colorScheme;

  static Color textPrimaryOf(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface;

  static Color textSecondaryOf(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;

  /// 卡片填充色，对应 FlClash `SurfaceLevel.card.colorOf`。
  static Color cardOf(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
      ? scheme.surfaceContainer
      : scheme.surfaceBright;

  /// 玻璃磁贴填充：比纯白卡片略灰、带一点透明，透出页面底纹。
  static Color glassOf(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
      ? const Color(0xB81E1E21)
      : const Color(0xC9F3F4F6);

  static Color glassBorderOf(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
      ? const Color(0x1AFFFFFF)
      : const Color(0xB8FFFFFF);

  /// 页面底纹：极轻的灰阶渐变，给玻璃磁贴提供可透出的层次。
  static LinearGradient canvasGradientOf(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
      ? const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF17171A), Color(0xFF111113), Color(0xFF18181B)],
          stops: [0, 0.55, 1],
        )
      : const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF7F8FA), Color(0xFFEEF1F4), Color(0xFFF4F5F7)],
          stops: [0, 0.55, 1],
        );
}
