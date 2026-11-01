import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

/// 语义化图标表。
///
/// FlClash v0.9.2 的图标是自有字体字形（lib/ui/icons/app_glyphs.dart），有版权，
/// 不能照搬；这里改用 cupertino_icons 的字形，但对外只暴露语义名称。
/// 降级说明：cupertino_icons 1.0.9 只提供字体资源，没有 `cupertino_icons.dart`，
/// 因此 [CupertinoIcons] 从 `flutter/cupertino.dart` 取。
/// 业务代码禁止直接使用 `Icons.xxx`。
abstract final class AppGlyphs {
  static const IconData chat = CupertinoIcons.chat_bubble;
  static const IconData chatFilled = CupertinoIcons.chat_bubble_fill;
  static const IconData records = CupertinoIcons.doc_text;
  static const IconData recordsFilled = CupertinoIcons.doc_text_fill;
  static const IconData plugins = CupertinoIcons.cube;
  static const IconData pluginsFilled = CupertinoIcons.cube_fill;
  static const IconData profile = CupertinoIcons.person;
  static const IconData profileFilled = CupertinoIcons.person_fill;
  static const IconData delete = CupertinoIcons.trash;
  static const IconData rename = CupertinoIcons.pencil;
  static const IconData pin = CupertinoIcons.pin;
  static const IconData scan = CupertinoIcons.viewfinder;
  static const IconData reconnect = CupertinoIcons.arrow_clockwise;
  static const IconData chevronRight = CupertinoIcons.chevron_right;
  static const IconData send = CupertinoIcons.arrow_up;
  static const IconData close = CupertinoIcons.xmark;
  static const IconData more = CupertinoIcons.ellipsis;
  static const IconData checkCircle = CupertinoIcons.check_mark_circled;
  static const IconData warning = CupertinoIcons.exclamationmark_triangle;
  static const IconData link = CupertinoIcons.link;
  static const IconData gear = CupertinoIcons.settings;
  static const IconData info = CupertinoIcons.info;
  static const IconData plus = CupertinoIcons.add;
  static const IconData camera = CupertinoIcons.camera;
  static const IconData photo = CupertinoIcons.photo;
  static const IconData file = CupertinoIcons.folder;
  static const IconData expand = CupertinoIcons.fullscreen;
  static const IconData collapse = CupertinoIcons.fullscreen_exit;
  static const IconData chevronDown = CupertinoIcons.chevron_down;
  static const IconData chevronUp = CupertinoIcons.chevron_up;
  static const IconData chevronLeft = CupertinoIcons.chevron_left;
}

/// 取 [glyph] 的选中（filled）变体；没有实心版本的语义图标回落到原字形。
IconData _filledOf(IconData glyph) => switch (glyph) {
  AppGlyphs.chat => AppGlyphs.chatFilled,
  AppGlyphs.records => AppGlyphs.recordsFilled,
  AppGlyphs.plugins => AppGlyphs.pluginsFilled,
  AppGlyphs.profile => AppGlyphs.profileFilled,
  AppGlyphs.delete => CupertinoIcons.trash_fill,
  AppGlyphs.pin => CupertinoIcons.pin_fill,
  _ => glyph,
};

/// 与 FlClash v0.9.2 lib/ui/icons/glyph_icon.dart 对齐的图标尺寸与颜色约定：
/// 依次读取 [IconTheme] 的 size、color、opacity，未指定时用 [size]。
class GlyphIcon extends StatelessWidget {
  const GlyphIcon(
    this.glyph, {
    super.key,
    this.filled = false,
    this.size,
    this.color,
  });

  final IconData glyph;

  /// 选中态使用 filled 变体。
  final bool filled;

  final double? size;
  final Color? color;

  static const double defaultSize = 24;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final opacity = iconTheme.opacity ?? 1;
    final side = size ?? iconTheme.size ?? defaultSize;
    final color = this.color ?? iconTheme.color ?? Colors.black;
    return SizedBox.square(
      dimension: side,
      child: Center(
        child: Icon(
          filled ? _filledOf(glyph) : glyph,
          size: side,
          color: color.withValues(alpha: color.a * opacity),
        ),
      ),
    );
  }
}

const _fillDuration = Duration(milliseconds: 350);
const _popScale = 0.1;

/// 对应 FlClash v0.9.2 lib/ui/icons/animated_glyph.dart。
///
/// 降级说明：FlClash 在自绘字形上插值填充比例；这里只有 outlined / filled
/// 两个 [IconData]，所以改为在 350ms 内交叉淡入淡出，并保留同样的弹跳放大。
class AnimatedGlyph extends StatefulWidget {
  const AnimatedGlyph(
    this.glyph, {
    super.key,
    required this.filled,
    this.size,
    this.color,
  });

  final IconData glyph;
  final bool filled;
  final double? size;
  final Color? color;

  @override
  State<AnimatedGlyph> createState() => _AnimatedGlyphState();
}

class _AnimatedGlyphState extends State<AnimatedGlyph>
    with TickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _fillDuration,
    value: widget.filled ? 1 : 0,
  );
  late final CurvedAnimation _fill = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: _fillDuration,
  );
  late final Listenable _animation = Listenable.merge([_fill, _pop]);

  @override
  void didUpdateWidget(covariant AnimatedGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filled == widget.filled) {
      return;
    }
    if (widget.filled) {
      _controller.forward();
      if (!_pop.isAnimating) {
        _pop.forward(from: 0);
      }
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _fill.dispose();
    _controller.dispose();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final side =
        widget.size ?? IconTheme.of(context).size ?? GlyphIcon.defaultSize;
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final pop = _pop.isAnimating
            ? math.sin(math.pi * _pop.value) * _popScale
            : 0.0;
        return Transform.scale(
          scale: 1 + pop,
          child: SizedBox.square(
            dimension: side,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Opacity(
                  opacity: 1 - _fill.value,
                  child: GlyphIcon(
                    widget.glyph,
                    size: side,
                    color: widget.color,
                  ),
                ),
                Opacity(
                  opacity: _fill.value,
                  child: GlyphIcon(
                    widget.glyph,
                    filled: true,
                    size: side,
                    color: widget.color,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
