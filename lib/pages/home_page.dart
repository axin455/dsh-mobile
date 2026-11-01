import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_providers.dart';
import '../state/auth_provider.dart';
import '../ui/colors.dart';
import '../ui/dock.dart';
import '../ui/glyphs.dart';
import 'chat_page.dart';
import 'login_page.dart';
import 'me_page.dart';
import 'plugins_page.dart';
import 'records_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  late final AnimationController _tabAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );

  static const _items = [
    DockItem(glyph: AppGlyphs.chat, label: '对话'),
    DockItem(glyph: AppGlyphs.records, label: '记录'),
    DockItem(glyph: AppGlyphs.plugins, label: '插件'),
    DockItem(glyph: AppGlyphs.profile, label: '我的'),
  ];

  @override
  void dispose() {
    _tabAnimation.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    _tabAnimation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final settings = ref.watch(settingsProvider);
    final inputExpanded = ref.watch(inputExpandedProvider);

    // 启动时先恢复本地登录态，避免登录页闪烁。
    if (auth.phase == AuthPhase.restoring) {
      return Scaffold(
        backgroundColor: AppColors.of(context).surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    // 未登录且还没点过「稍后登录」：登录是唯一入口。
    if (!auth.authorized && !settings.guestMode) {
      return const LoginPage();
    }
    return _buildShell(context, inputExpanded);
  }

  Widget _buildShell(BuildContext context, bool inputExpanded) {
    final content = AnimatedBuilder(
      animation: _tabAnimation,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_tabAnimation.value);
        return Opacity(
          opacity: 0.7 + 0.3 * t,
          child: Transform.translate(
            offset: Offset(0, 6 * (1 - t)),
            child: child,
          ),
        );
      },
      child: IndexedStack(
        index: _index,
        children: [
          const ChatPage(),
          RecordsPage(onOpenSession: (_) => _select(0)),
          const PluginsPage(),
          const MePage(),
        ],
      ),
    );

    return Scaffold(
      // 必须 extendBody：否则底栏下方是空白，内容不会透出到毛玻璃后面。
      extendBody: true,
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppColors.canvasGradientOf(AppColors.of(context)),
        ),
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 只有「横屏 + 短边达到平板尺寸」才用左侧 dock。
              // 平板竖屏宽度同样很大，但应保持手机布局（底部 dock），
              // 否则会被误判成平板横屏。
              final media = MediaQuery.sizeOf(context);
              final useSideDock =
                  media.width > media.height && media.shortestSide >= 600;
              if (!useSideDock) return content;
              if (inputExpanded) return content;
              return Row(
                children: [
                  FloatingDock(
                    items: _items,
                    index: _index,
                    onSelected: _select,
                    vertical: true,
                  ),
                  Expanded(child: content),
                ],
              );
            },
          ),
        ),
      ),
      bottomNavigationBar: LayoutBuilder(
        builder: (context, constraints) {
          final media = MediaQuery.sizeOf(context);
          final useSideDock =
              media.width > media.height && media.shortestSide >= 600;
          // 宽屏已经用左侧 dock，底部不再重复；展开输入时整块让给编辑区。
          if (useSideDock || inputExpanded) return const SizedBox.shrink();
          // 恢复原版宽度：手机铺满，竖屏平板居中并限制 520。
          // heightFactor 必须为 1：bottomNavigationBar 的高度约束是宽松的，
          // 裸 Center 会把整屏高度都吃掉，dock 就会浮到屏幕中间。
          return Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: media.width >= 600 ? 520 : double.infinity,
              ),
              child: FloatingDock(
                items: _items,
                index: _index,
                onSelected: _select,
              ),
            ),
          );
        },
      ),
    );
  }
}
