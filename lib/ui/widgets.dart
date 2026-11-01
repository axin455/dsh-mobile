import 'package:flutter/material.dart';

import 'colors.dart';
import 'glyphs.dart';
import 'theme.dart';
import 'tokens.dart';
import 'typography.dart';

/// 卡片：唯一允许的层级手段是 surface 填充 + 轻阴影，不用色相区分。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.radius = AppCorner.md,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final isDark = scheme.brightness == Brightness.dark;
    final borderRadius = AppRadius.all(radius);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(
          color: AppColors.glassBorderOf(scheme),
          width: 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.06),
            blurRadius: isDark ? 18 : 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: AppColors.glassOf(scheme)),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: isDark ? 0.05 : 0.22),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            // 水波纹必须画在卡片自己的 Material 上，否则会溢出圆角，点击时看到方形白边。
            Material(
              type: MaterialType.transparency,
              child: Padding(padding: padding, child: child),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分组卡片：把若干 [SettingRow] 按 1px 分隔线连成一块。
class AppGroupCard extends StatelessWidget {
  const AppGroupCard({
    super.key,
    required this.children,
    this.header,
    this.footer,
  });

  final List<Widget> children;
  final String? header;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            color: scheme.outlineVariant,
            indent: 16,
            endIndent: 16,
          ),
        );
      }
      rows.add(children[i]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              header!,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondaryOf(context),
                    letterSpacing: 0.4,
                  ),
            ),
          ),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: rows),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              footer!,
              style: AppTextStyle.caption1
                  .of(context)
                  .copyWith(color: AppColors.textSecondaryOf(context)),
            ),
          ),
      ],
    );
  }
}

class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppTextStyle.headline.of(context)),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: AppTextStyle.subheadline
                        .of(context)
                        .copyWith(color: AppColors.textSecondaryOf(context)),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ] else if (onTap != null)
            Icon(
              AppGlyphs.chevronRight,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      splashColor: scheme.primary.withValues(alpha: 0.08),
      highlightColor: scheme.primary.withValues(alpha: 0.06),
      child: content,
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: AppTextStyle.pageTitle.of(context)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 页面标题行：四个 Tab 共用同一套字号、留白与右侧操作位。
class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 8),
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: AppTextStyle.largeTitle.of(context)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 主按钮：accent 填充，胶囊圆角，高度 50。
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final background = danger ? scheme.error : scheme.primary;
    return SizedBox(
      height: 50,
      child: Material(
        color: background,
        shape: AppShape.full,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  GlyphIcon(icon!, size: 18, color: Colors.white),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: AppTextStyle.headline
                      .of(context)
                      .copyWith(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 次要按钮：透明底 + 填充色弱背景。
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return SizedBox(
      height: 46,
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: AppShape.full,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  GlyphIcon(icon!, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: AppTextStyle.headline
                      .of(context)
                      .copyWith(color: scheme.onSurface),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 空状态 / 错误状态：图标 + 标题 + 一行说明 + 可选操作。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlyphIcon(icon, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppTextStyle.title3.of(context),
            ),
            if (description != null) ...[
              const SizedBox(height: 8),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: AppTextStyle.footnote
                    .of(context)
                    .copyWith(color: AppColors.textSecondaryOf(context)),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// 顶部提示条（断线、错误）。
class InlineBanner extends StatelessWidget {
  const InlineBanner({
    super.key,
    required this.text,
    this.tone = BannerTone.warning,
    this.action,
    this.margin = const EdgeInsets.fromLTRB(16, 8, 16, 0),
  });

  final String text;
  final BannerTone tone;
  final Widget? action;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final color = switch (tone) {
      BannerTone.warning => const Color(0xFFFF9500),
      BannerTone.error => scheme.error,
      BannerTone.info => scheme.primary,
    };
    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: AppRadius.all(AppCorner.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: AppTextStyle.footnote.of(context).copyWith(color: color),
            ),
          ),
          if (action != null) const SizedBox(width: 8),
          ?action,
        ],
      ),
    );
  }
}

enum BannerTone { warning, error, info }

/// 页面骨架：画布底色 + 收起键盘 + 统一横向留白。
class AppPageBody extends StatelessWidget {
  const AppPageBody({
    super.key,
    required this.child,
    this.scrollable = true,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
  });

  final Widget child;
  final bool scrollable;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (!scrollable) {
      return Padding(padding: padding, child: child);
    }
    return SingleChildScrollView(padding: padding, child: child);
  }
}

/// 极简 logo：胶囊里一个实心方块，仅用于配对页与关于页。
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: AppRadius.all(size / 3.2),
      ),
      child: Center(
        child: Text(
          'D',
          style: AppTextStyle.custom(
            context,
            size: size / 2.2,
            leading: size / 2.2 * 1.1,
            weight: FontWeight.w700,
          ).copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

/// 让页面跟随主题重建的小工具（避免每个页面重复写 MediaQuery 判断）。
ColorScheme schemeOf(BuildContext context) => AppColors.of(context);

ThemeData themeOf(BuildContext context) => buildAppTheme(AppColors.of(context));
