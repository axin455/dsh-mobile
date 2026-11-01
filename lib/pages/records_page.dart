import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings.dart';
import '../protocol/models.dart';
import '../state/app_providers.dart';
import '../state/chat_provider.dart';
import '../state/records_provider.dart';
import '../ui/colors.dart';
import '../ui/glyphs.dart';
import '../ui/segmented.dart';
import '../ui/tokens.dart';
import '../ui/typography.dart';
import '../ui/widgets.dart';

class RecordsPage extends ConsumerStatefulWidget {
  const RecordsPage({super.key, required this.onOpenSession});

  final ValueChanged<String> onOpenSession;

  @override
  ConsumerState<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends ConsumerState<RecordsPage> {
  /// 记录页也分「本地 / 电脑端」，与对话页的切换一一对应。
  bool _pcOnly = false;

  @override
  Widget build(BuildContext context) {
    final records = ref.watch(recordsProvider);
    final settings = ref.watch(settingsProvider);
    final pluginEnabled = settings.pcLinkPluginEnabled;
    // 插件关闭时只列本地会话，避免把电脑端缓存混进来。
    final pcOnly = pluginEnabled && _pcOnly;
    final items = [
      for (final item in records.items)
        if ((!item.sessionId.startsWith('local-')) == pcOnly) item,
    ];

    return Column(
      children: [
        if (pluginEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                GlassSegmented(
                  labels: const ['本地', '电脑端'],
                  selectedIndex: pcOnly ? 1 : 0,
                  onChanged: (index) =>
                      setState(() => _pcOnly = index == 1),
                ),
              ],
            ),
          )
        else
          const SizedBox(height: 8),
        if (records.loading) const LinearProgressIndicator(minHeight: 2),
        if (records.error != null)
          InlineBanner(text: records.error!, tone: BannerTone.error),
        Expanded(
          child: items.isEmpty
              ? EmptyState(
                  icon: pcOnly ? AppGlyphs.plugins : AppGlyphs.records,
                  title: pcOnly ? '电脑端还没有对话' : '还没有对话记录',
                  description: records.loading
                      ? '正在读取…'
                      : pcOnly
                      ? '电脑端发起过的对话会同步显示在这里。'
                      : '与 DSH 对话后，记录会出现在这里。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) => _RecordTile(
                    session: items[index],
                    onOpen: () {
                      final item = items[index];
                      final sessionId = item.sessionId;
                      final scope = !settings.pcLinkPluginEnabled ||
                              sessionId.startsWith('local-')
                          ? ChatScope.local
                          : (sessionId.startsWith('pcc-')
                                ? ChatScope.pcChat
                                : ChatScope.pc);
                      ref.read(chatProvider.notifier).setScope(scope);
                      ref.read(chatProvider.notifier).attach(sessionId);
                      widget.onOpenSession(sessionId);
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _RecordTile extends ConsumerWidget {
  const _RecordTile({required this.session, required this.onOpen});

  final SessionSummary session;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = AppColors.of(context);

    return GestureDetector(
      onTap: onOpen,
      onLongPress: () => _showMenu(context, ref),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (session.pinned) ...[
              Padding(
                padding: const EdgeInsets.only(top: 3, right: 8),
                child: GlyphIcon(
                  AppGlyphs.pin,
                  size: 14,
                  color: scheme.primary,
                ),
              ),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.headline.of(context),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    session.running ? '正在生成…' : _timeLabel(session.updatedAt),
                    style: AppTextStyle.caption1
                        .of(context)
                        .copyWith(
                          color: session.running
                              ? scheme.primary
                              : AppColors.textSecondaryOf(context),
                        ),
                  ),
                ],
              ),
            ),
            Icon(
              AppGlyphs.chevronRight,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  static String _timeLabel(int updatedAt) {
    if (updatedAt <= 0) return '本地缓存';
    final time = DateTime.fromMillisecondsSinceEpoch(updatedAt * 1000);
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')}';
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: session.title);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('重命名对话', style: AppTextStyle.headline.of(context)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: AppTextStyle.callout.of(context),
          decoration: const InputDecoration(hintText: '输入新的名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty) return;
    await ref.read(recordsProvider.notifier).rename(session.sessionId, result);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final removed = await ref
        .read(recordsProvider.notifier)
        .archive(session.sessionId);
    if (removed == null) return;
    // 无障碍模式下带 action 的 SnackBar 不会自动超时；这里显式定时关闭，
    // 同时清掉之前排队的提示，避免连续删除后一直挂着「已删除」。
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        content: const Text('已删除该对话'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            messenger.hideCurrentSnackBar();
            ref.read(recordsProvider.notifier).restore(removed);
          },
        ),
      ),
    );
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (messenger.mounted) messenger.hideCurrentSnackBar();
    });
  }

  Future<void> _showMenu(BuildContext context, WidgetRef ref) async {
    final settings = ref.read(settingsProvider);
    final scheme = AppColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: AppCard(
            radius: AppCorner.xl,
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _menuRow(
                  context,
                  icon: AppGlyphs.pin,
                  label: session.pinned ? '取消置顶' : '置顶',
                  onTap: () {
                    Navigator.of(context).pop();
                    ref
                        .read(recordsProvider.notifier)
                        .setPinned(session.sessionId, !session.pinned);
                  },
                ),
                _menuRow(
                  context,
                  icon: AppGlyphs.rename,
                  label: '重命名',
                  onTap: () {
                    Navigator.of(context).pop();
                    _rename(context, ref);
                  },
                ),
                if (settings.startStrategy == StartStrategy.pinned)
                  _menuRow(
                    context,
                    icon: AppGlyphs.checkCircle,
                    label: '设为默认打开',
                    onTap: () {
                      Navigator.of(context).pop();
                      ref
                          .read(settingsProvider.notifier)
                          .setPinnedSession(session.sessionId);
                    },
                  ),
                _menuRow(
                  context,
                  icon: AppGlyphs.delete,
                  label: '删除',
                  color: scheme.error,
                  onTap: () {
                    Navigator.of(context).pop();
                    _delete(context, ref);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final scheme = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            GlyphIcon(icon, size: 20, color: color ?? scheme.onSurface),
            const SizedBox(width: 12),
            Text(
              label,
              style: AppTextStyle.callout
                  .of(context)
                  .copyWith(color: color ?? scheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}
