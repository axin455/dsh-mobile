import 'dart:ui';

import 'package:flutter/material.dart';

import 'colors.dart';
import 'tokens.dart';
import 'typography.dart';

/// 玻璃分段切换：选中框是一整块半透明胶囊，在两个选项之间滑过去。
///
/// 尺寸固定为 64×34 的段，保证滑块的 left 可以直接按段宽计算；
/// 动效与底部 dock 一致（280ms / easeOutQuint），不另起一套节拍。
class GlassSegmented extends StatelessWidget {
  const GlassSegmented({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    this.segmentWidth = 64,
    this.height = 34,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final double segmentWidth;
  final double height;

  static const _inset = 3.0;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final isDark = scheme.brightness == Brightness.dark;
    final width = labels.length * segmentWidth + _inset * 2;
    final radius = AppRadius.all(height / 2);

    return RepaintBoundary(
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.glassOf(
                        scheme,
                      ).withValues(alpha: isDark ? 0.48 : 0.52),
                      borderRadius: radius,
                      border: Border.all(
                        color: AppColors.glassBorderOf(
                          scheme,
                        ).withValues(alpha: isDark ? 0.5 : 0.7),
                        width: 0.5,
                      ),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutQuint,
                  left: _inset + selectedIndex * segmentWidth,
                  top: _inset,
                  width: segmentWidth,
                  height: height - _inset * 2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0x2EFFFFFF)
                          : const Color(0xF2FFFFFF),
                      borderRadius: radius,
                      border: Border.all(
                        color: isDark
                            ? const Color(0x24FFFFFF)
                            : const Color(0xE6FFFFFF),
                        width: 0.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.24 : 0.08,
                          ),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      SizedBox(
                        width: segmentWidth,
                        height: height,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onChanged(i),
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOutCubic,
                              style: AppTextStyle.caption1
                                  .of(context)
                                  .copyWith(
                                    fontWeight: i == selectedIndex
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: i == selectedIndex
                                        ? scheme.onSurface
                                        : scheme.onSurfaceVariant,
                                  ),
                              child: Text(labels[i]),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
