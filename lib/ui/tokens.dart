import 'package:flutter/material.dart';

/// 圆角刻度。取自 FlClash v0.9.2 lib/ui/shape.dart。
///
/// [alert] 是 iOS 27 上 UIAlertController 的圆角，比 sheet 更圆。
abstract final class AppCorner {
  static const double none = 0;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 28;

  /// iOS 27 上 UIAlertController 的圆角。
  static const double alert = 34;
  static const double full = 1000;

  /// 短边最多只能占三分之一，避免圆角把形状吃掉。
  static double fit(double shortestSide) {
    final limit = shortestSide / 3;
    if (limit >= xxl) return xxl;
    if (limit >= xl) return xl;
    if (limit >= lg) return lg;
    if (limit >= md) return md;
    if (limit >= sm) return sm;
    if (limit >= xs) return xs;
    return none;
  }
}

/// 与 [AppCorner] 对应的 [BorderRadius]。取自 FlClash v0.9.2 lib/ui/shape.dart。
abstract final class AppRadius {
  static const BorderRadius none = BorderRadius.zero;
  static const BorderRadius xs = BorderRadius.all(
    Radius.circular(AppCorner.xs),
  );
  static const BorderRadius sm = BorderRadius.all(
    Radius.circular(AppCorner.sm),
  );
  static const BorderRadius md = BorderRadius.all(
    Radius.circular(AppCorner.md),
  );
  static const BorderRadius lg = BorderRadius.all(
    Radius.circular(AppCorner.lg),
  );
  static const BorderRadius xl = BorderRadius.all(
    Radius.circular(AppCorner.xl),
  );
  static const BorderRadius xxl = BorderRadius.all(
    Radius.circular(AppCorner.xxl),
  );
  static const BorderRadius full = BorderRadius.all(
    Radius.circular(AppCorner.full),
  );

  static BorderRadius all(double corner) => BorderRadius.circular(corner);

  static BorderRadius top(double corner) =>
      BorderRadius.vertical(top: Radius.circular(corner));

  static BorderRadius vertical({
    double top = AppCorner.none,
    double bottom = AppCorner.none,
  }) => BorderRadius.vertical(
    top: Radius.circular(top),
    bottom: Radius.circular(bottom),
  );
}

/// 超椭圆形状。取自 FlClash v0.9.2 lib/ui/shape.dart。
///
/// 使用 Flutter 3.47.9 自带的 [RoundedSuperellipseBorder]
/// （见 flutter/lib/src/painting/rounded_rectangle_border.dart）。
abstract final class AppShape {
  static const RoundedSuperellipseBorder none = RoundedSuperellipseBorder();
  static const RoundedSuperellipseBorder xs = RoundedSuperellipseBorder(
    borderRadius: AppRadius.xs,
  );
  static const RoundedSuperellipseBorder sm = RoundedSuperellipseBorder(
    borderRadius: AppRadius.sm,
  );
  static const RoundedSuperellipseBorder md = RoundedSuperellipseBorder(
    borderRadius: AppRadius.md,
  );
  static const RoundedSuperellipseBorder lg = RoundedSuperellipseBorder(
    borderRadius: AppRadius.lg,
  );
  static const RoundedSuperellipseBorder xl = RoundedSuperellipseBorder(
    borderRadius: AppRadius.xl,
  );
  static const RoundedSuperellipseBorder xxl = RoundedSuperellipseBorder(
    borderRadius: AppRadius.xxl,
  );
  static const RoundedSuperellipseBorder full = RoundedSuperellipseBorder(
    borderRadius: AppRadius.full,
  );
  static const CircleBorder circle = CircleBorder();

  static RoundedSuperellipseBorder all(double corner) =>
      RoundedSuperellipseBorder(borderRadius: AppRadius.all(corner));

  static RoundedSuperellipseBorder top(double corner) =>
      RoundedSuperellipseBorder(borderRadius: AppRadius.top(corner));

  static RoundedSuperellipseBorder vertical({
    double top = AppCorner.none,
    double bottom = AppCorner.none,
  }) => RoundedSuperellipseBorder(
    borderRadius: AppRadius.vertical(top: top, bottom: bottom),
  );

  static RoundedSuperellipseBorder of(BorderRadius borderRadius) =>
      RoundedSuperellipseBorder(borderRadius: borderRadius);
}

/// 底部导航 dock 的尺寸常量。取自 FlClash v0.9.2 lib/ui/navigation_dock.dart 顶部常量。
abstract final class AppDockMetrics {
  static const double barHeight = 62;
  static const double barPadding = 4;
  static const double edgeMargin = 21;
  static const double shadowRoom = 8;
  static const double sideWidth = 104;
  static const double sideItemHeight = 96;
  static const double hitSlop = 8;
  static const double maxItemExtent = 86;
  static const double minLensWidth = 84;
  static const int fullWidthCount = 5;
  static const double iconSize = 28;
  static const double labelGap = 2;
  static const double labelInset = 2;
  static const double labelSize = 10;
  static const double labelLeading = 14.5;
  static const double minLabelSize = 9;
  static const double pressGrowth = 1 / 8;
  static const double maxPressGrowth = 16;
  static const double lensGrowth = 8;
  static const double lensMagnify = 0.16;
}
