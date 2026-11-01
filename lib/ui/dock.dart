import 'dart:ui';

import 'package:flutter/material.dart';

import 'colors.dart';
import 'glyphs.dart';
import 'tokens.dart';
import 'typography.dart';

class DockItem {
  const DockItem({required this.glyph, required this.label});

  final IconData glyph;
  final String label;
}

/// 悬浮毛玻璃导航。
///
/// 结构对照 FlClash v0.9.2 lib/ui/navigation_dock.dart：
/// `extendBody: true` 让内容透出到 dock 下方；`BackdropFilter` 外层强制
/// [RepaintBoundary]，把模糊重绘与页面滚动隔离；指示器用 quintic ease-out
/// 在四个图标之间滑动。中低端设备可用 [blurSigma] = 0 降级为纯半透明填充。
class FloatingDock extends StatelessWidget {
  const FloatingDock({
    super.key,
    required this.items,
    required this.index,
    required this.onSelected,
    this.blurSigma = 20,
    this.vertical = false,
  });

  final List<DockItem> items;
  final int index;
  final ValueChanged<int> onSelected;
  final double blurSigma;

  /// 平板放左侧：竖排吸边，不再悬浮在底部。
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final isDark = scheme.brightness == Brightness.dark;
    final glassColor = (isDark ? scheme.surfaceContainerHigh : Colors.white)
        .withValues(alpha: isDark ? 0.64 : 0.72);
    final height = vertical
        ? AppDockMetrics.sideItemHeight * items.length +
              AppDockMetrics.barPadding * 2
        : AppDockMetrics.barHeight;
    final width = vertical ? AppDockMetrics.sideWidth : null;

    final padded = Padding(
      padding: vertical
          ? const EdgeInsets.fromLTRB(
              AppDockMetrics.shadowRoom + 8,
              AppDockMetrics.edgeMargin,
              4,
              AppDockMetrics.edgeMargin,
            )
          : const EdgeInsets.fromLTRB(
              AppDockMetrics.edgeMargin,
              AppDockMetrics.shadowRoom,
              AppDockMetrics.edgeMargin,
              AppDockMetrics.shadowRoom + 6,
            ),
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: AppRadius.all(AppCorner.xxl),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.36 : 0.10),
                blurRadius: 24,
                spreadRadius: -4,
                offset: vertical ? const Offset(4, 0) : const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: AppRadius.all(AppCorner.xxl),
            child: BackdropFilter(
              filter: blurSigma > 0
                  ? ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma)
                  : ImageFilter.blur(sigmaX: 0, sigmaY: 0),
              child: Container(
                height: height,
                width: width,
                decoration: BoxDecoration(
                  color: glassColor,
                  borderRadius: AppRadius.all(AppCorner.xxl),
                  border: Border.all(
                    color: (isDark ? Colors.white : Colors.white).withValues(
                      alpha: isDark ? 0.08 : 0.5,
                    ),
                    width: 0.5,
                  ),
                ),
                padding: const EdgeInsets.all(AppDockMetrics.barPadding),
                child: vertical
                    ? _buildVertical(context, scheme, isDark)
                    : _buildHorizontal(context, scheme, isDark),
              ),
            ),
          ),
        ),
      ),
    );

    return SafeArea(
      top: vertical,
      right: false,
      // 竖排 dock 在左侧：垂直居中，不让它贴着屏幕顶部，视觉重心才稳。
      child: vertical ? Center(child: padded) : padded,
    );
  }

  Widget _buildHorizontal(
    BuildContext context,
    ColorScheme scheme,
    bool isDark,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth / items.length;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutQuint,
              left: itemWidth * index,
              top: 0,
              bottom: 0,
              width: itemWidth,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: AppRadius.full,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.18 : 0.06,
                        ),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _DockButton(
                      item: items[i],
                      selected: i == index,
                      onTap: () => onSelected(i),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildVertical(
    BuildContext context,
    ColorScheme scheme,
    bool isDark,
  ) {
    const itemHeight = AppDockMetrics.sideItemHeight;
    // 竖排时如果让指示器铺满整格，圆角会被拉成一个巨大的圆；这里固定成
    // 一块 80×64 的圆角片，仍随选中项上下滑动，但视觉上是一个精致的边框。
    const indicatorHeight = 64.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutQuint,
              top: itemHeight * index + (itemHeight - indicatorHeight) / 2,
              left: 8,
              right: 8,
              height: indicatorHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: AppRadius.all(AppCorner.lg),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.18 : 0.06,
                      ),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
            Column(
              children: [
                for (var i = 0; i < items.length; i++)
                  SizedBox(
                    height: itemHeight,
                    // 竖排时让每一项铺满整格：图标/文字才会落在灰色胶囊的
                    // 中间，点击区域也从一个字形扩大到整格。
                    width: double.infinity,
                    child: _DockButton(
                      item: items[i],
                      selected: i == index,
                      onTap: () => onSelected(i),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final DockItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.full,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedGlyph(item.glyph, filled: selected, size: 26, color: color),
          const SizedBox(height: AppDockMetrics.labelGap),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: AppTextStyle.caption2
                .of(context)
                .copyWith(
                  fontSize: AppDockMetrics.labelSize,
                  height: 1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                ),
            child: Text(item.label),
          ),
        ],
      ),
    );
  }
}
