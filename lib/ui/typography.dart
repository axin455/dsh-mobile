import 'package:flutter/material.dart';

/// Apple iOS Dynamic Type 默认字号表。
/// 取自 FlClash v0.9.2 lib/ui/typography.dart：一个 dp 对应一个 point，
/// 另加两档 Apple 没有的角色：[display] 用于仪表盘数字，[pageTitle] 用于导航栏标题。
enum AppTextStyle {
  display(40, 44, emphasizedWeight: FontWeight.w700),
  largeTitle(34, 41, emphasizedWeight: FontWeight.w700),
  title1(28, 34, emphasizedWeight: FontWeight.w700),
  pageTitle(24, 30, weight: FontWeight.w600, emphasizedWeight: FontWeight.w700),
  title2(22, 28, emphasizedWeight: FontWeight.w700),
  title3(20, 25),
  headline(17, 22, weight: FontWeight.w600),
  body(17, 22),
  callout(16, 21),
  subheadline(15, 20),
  footnote(13, 18),
  caption1(12, 16),
  caption2(11, 13);

  const AppTextStyle(
    this.size,
    this.leading, {
    this.weight = FontWeight.w400,
    this.emphasizedWeight = FontWeight.w600,
  });

  final double size;
  final double leading;
  final FontWeight weight;
  final FontWeight emphasizedWeight;

  TextStyle of(BuildContext context, {bool emphasized = false}) {
    final textTheme = Theme.of(context).textTheme;
    final base =
        _slotOf(textTheme) ?? textTheme.bodyMedium ?? const TextStyle();
    return _apply(base, emphasized: emphasized);
  }

  /// 供随图形尺寸缩放的文字使用，例如图标里的单字。
  static TextStyle custom(
    BuildContext context, {
    required double size,
    required double leading,
    FontWeight weight = FontWeight.w400,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final base = size < title3.size
        ? textTheme.bodyLarge
        : textTheme.titleLarge;
    return (base ?? const TextStyle()).copyWith(
      fontSize: size,
      height: leading / size,
      fontWeight: weight,
      letterSpacing: 0,
    );
  }

  // Typography.blackCupertino 给这些槽位用 SF Pro Display，其余用 SF Pro Text，
  // Apple 在 20 pt 处切换字体。
  TextStyle? _slotOf(TextTheme theme) => switch (this) {
    display || largeTitle => theme.headlineLarge,
    title1 => theme.headlineMedium,
    pageTitle || title2 => theme.headlineSmall,
    title3 => theme.titleLarge,
    headline => theme.titleMedium,
    body || callout => theme.bodyLarge,
    subheadline => theme.bodyMedium,
    footnote => theme.bodySmall,
    caption1 => theme.labelMedium,
    caption2 => theme.labelSmall,
  };

  TextStyle _apply(TextStyle base, {required bool emphasized}) => base.copyWith(
    fontSize: size,
    height: leading / size,
    fontWeight: emphasized ? emphasizedWeight : weight,
    letterSpacing: 0,
  );
}
