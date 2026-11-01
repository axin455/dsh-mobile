import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings.dart';
import '../protocol/gateway_client.dart';
import '../state/app_providers.dart';
import '../state/auth_provider.dart';
import '../ui/colors.dart';
import '../ui/glyphs.dart';
import '../ui/tokens.dart';
import '../ui/typography.dart';
import '../ui/widgets.dart';
import 'api_key_page.dart';
import 'login_page.dart';
import 'scan_page.dart';

class MePage extends ConsumerWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final link = ref.watch(linkProvider);
    final auth = ref.watch(authProvider);
    final scheme = AppColors.of(context);
    final signedIn = auth.authorized;
    final profile = auth.profile;
    final apiKeyMode = settings.apiKeyModeEnabled;
    final hostMode = auth.hostMode;
    final localHostModel = settings.localHostModelEnabled
        ? (settings.localHostModelName.isNotEmpty
              ? settings.localHostModelName
              : settings.localHostModelId)
        : null;
    final credential = settings.activeCredential;
    final pluginEnabled = settings.pcLinkPluginEnabled;
    final host = link.account;
    final hostName = host?.name.trim() ?? '';
    final hostBalance = host?.primaryBalance;
    final synced = link.credentials;
    final hostOnline = link.status.isConnected;
    final hostTitle = hostName.isNotEmpty
        ? hostName
        : (profile?.nickname ?? '电脑上的 DSH');

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
          children: [
            const _GroupLabel('登录方式'),
            AppGroupCard(
              children: [
                SettingRow(
                  title: signedIn
                      ? (hostMode
                            ? hostTitle
                            : apiKeyMode
                            ? (credential?.name ?? 'API Key')
                            : (profile?.nickname ?? 'DeepSeek 用户'))
                      : '未配置',
                  subtitle: signedIn
                      ? (hostMode
                            ? (hostOnline
                                  ? '已连接电脑 · ${synced.isEmpty ? '可查看电脑端对话' : '已同步 ${synced.map((item) => item.displayName).join('、')} · 本机可直连'}'
                                  : (link.status.phase == GatewayPhase.reconnecting
                                        ? (link.status.message ?? '电脑离线，正在重连…')
                                        : (link.status.message ?? '电脑离线')))
                            : apiKeyMode
                            ? '已登录 ${settings.credentials.length} 家供应商 · 当前 ${credential?.model ?? ''}'
                            : '直接使用账号余额，无需 API Key')
                      : (pluginEnabled
                            ? '扫码连接电脑，或用 API Key 登录'
                            : '用 API Key 登录，不需要账号'),
                  leading: _AccountAvatar(
                    signedIn: signedIn,
                    nickname: hostMode
                        ? hostTitle
                        : (apiKeyMode
                              ? credential?.name
                              : profile?.nickname),
                    avatarUrl: hostMode
                        ? host?.avatarUrl
                        : profile?.avatarUrl,
                  ),
                  trailing: signedIn
                      ? Text(
                          hostMode
                              ? (hostBalance?.label ??
                                    (hostOnline ? '已连接' : '离线'))
                              : apiKeyMode
                              ? 'API Key'
                              : '¥${(profile?.balance ?? 0).toStringAsFixed(2)}',
                          style: AppTextStyle.headline
                              .of(context)
                              .copyWith(color: scheme.primary),
                        )
                      : Text(
                          '去配置',
                          style: AppTextStyle.callout
                              .of(context)
                              .copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                  onTap: signedIn
                      ? (hostMode && pluginEnabled
                            ? () => _openScan(context)
                            : () => _openApiKey(context))
                      : (pluginEnabled
                            ? () => _openLogin(context)
                            : () => _openApiKey(context)),
                ),
                if (pluginEnabled)
                  SettingRow(
                    title: '扫一扫连接电脑',
                    subtitle: link.paired
                        ? '已配对 · ${link.endpoint ?? '本机网关'}'
                        : '扫描电脑端 DSH 插件的二维码，直连电脑上的对话',
                    leading: GlyphIcon(AppGlyphs.scan, size: 20),
                    onTap: () => _openScan(context),
                  ),
                if (hostMode && link.paired && !hostOnline)
                  SettingRow(
                    title: '连接电脑',
                    subtitle:
                        link.status.phase == GatewayPhase.reconnecting
                        ? (link.status.message ?? '正在重连…')
                        : '自动重连已停止；点这里重新连接',
                    leading: GlyphIcon(AppGlyphs.reconnect, size: 20),
                    trailing: Text(
                      link.status.phase == GatewayPhase.reconnecting
                          ? '连接中'
                          : '连接',
                      style: AppTextStyle.callout
                          .of(context)
                          .copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    onTap: link.status.phase == GatewayPhase.reconnecting
                        ? null
                        : () async {
                            await ref.read(linkProvider.notifier).reconnect();
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(
                                const SnackBar(
                                  content: Text('正在重新连接电脑…'),
                                  duration: Duration(seconds: 3),
                                ),
                              );
                          },
                  ),
                SettingRow(
                  title: localHostModel != null
                      ? '本地模型 · 电脑账号'
                      : hostMode && synced.isNotEmpty
                      ? 'API Key · 已从电脑同步'
                      : apiKeyMode
                      ? 'API Key 登录 · 已配置'
                      : 'API Key 登录',
                  subtitle: localHostModel != null
                      ? '$localHostModel，按电脑账号余额计费'
                      : apiKeyMode
                      ? '${settings.credentials.length} 家已登录 · '
                            '${_effectiveModel(settings)}，按 Key 用量计费'
                      : synced.isNotEmpty
                      ? '已从电脑同步 ${synced.map((item) => item.displayName).join('、')}，本机可直接对话'
                      : '填供应商 Key 直连对话，可同时登录多家',
                  leading: GlyphIcon(AppGlyphs.link, size: 20),
                  onTap: () => _openApiKey(context),
                ),
                if (signedIn) ...[
                  if (!apiKeyMode || hostMode)
                    SettingRow(
                      title: hostMode ? '刷新账号与余额' : '刷新余额',
                      subtitle:
                          auth.error ??
                          (hostMode
                              ? '从电脑重新同步 DeepSeek 账号资料与余额'
                              : '从登录服务同步最新余额'),
                      leading: GlyphIcon(AppGlyphs.reconnect, size: 20),
                      onTap: () =>
                          ref.read(authProvider.notifier).refreshBalance(),
                    ),
                  SettingRow(
                    title: '退出登录',
                    subtitle: hostMode
                        ? '断开与这台电脑的连接，并清除同步过来的 API Key'
                        : apiKeyMode
                        ? '清除本机保存的 API Key，回到登录页'
                        : '清除本机保存的账号令牌，回到登录页',
                    leading: GlyphIcon(
                      AppGlyphs.delete,
                      size: 20,
                      color: scheme.error,
                    ),
                    trailing: Text(
                      '退出',
                      style: AppTextStyle.callout
                          .of(context)
                          .copyWith(color: scheme.error),
                    ),
                    onTap: () => _confirmSignOut(context, ref),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 24),

            const _GroupLabel('对话偏好'),
            AppGroupCard(
              children: [
                SettingRow(
                  title: '打开对话的方式',
                  subtitle: _strategyLabel(settings.startStrategy),
                  leading: GlyphIcon(AppGlyphs.chat, size: 20),
                  trailing: const SizedBox.shrink(),
                  onTap: () =>
                      _pickStrategy(context, ref, settings.startStrategy),
                ),
                SettingRow(
                  title: '模型命名',
                  subtitle: '开启后首轮结束用当前模型自动起名（消耗少量额度）；关闭则截取首轮内容',
                  leading: GlyphIcon(AppGlyphs.chat, size: 20),
                  trailing: Switch(
                    value: settings.modelNaming,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setModelNaming(value),
                  ),
                ),
                SettingRow(
                  title: '流式渲染',
                  subtitle: '订阅 assistantStream，逐字追加',
                  leading: GlyphIcon(AppGlyphs.send, size: 20),
                  trailing: Switch(
                    value: settings.streaming,
                    onChanged: (value) =>
                        ref.read(settingsProvider.notifier).setStreaming(value),
                  ),
                ),
                SettingRow(
                  title: '自动滚动',
                  subtitle: '上滑阅读历史时暂停，回到底部恢复',
                  leading: GlyphIcon(AppGlyphs.chevronRight, size: 20),
                  trailing: Switch(
                    value: settings.autoScroll,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setAutoScroll(value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            const _GroupLabel('模型'),
            AppGroupCard(
              children: [
                SettingRow(
                  title: '默认模型',
                  subtitle: localHostModel != null
                      ? '电脑 DeepSeek 账号 · 按账号余额计费'
                      : apiKeyMode
                      ? '由所选供应商提供，按 API Key 用量计费'
                      : hostMode
                      ? '电脑端会话在对话页切换模型；这里管本机直连的默认模型'
                      : '费用直接从 DeepSeek 账号余额扣除',
                  leading: GlyphIcon(AppGlyphs.plugins, size: 20),
                  trailing: Text(
                    localHostModel ??
                        ((apiKeyMode ||
                                (hostMode && settings.credentials.isNotEmpty))
                            ? _effectiveModel(settings)
                            : settings.model),
                    style: AppTextStyle.callout
                        .of(context)
                        .copyWith(color: AppColors.textSecondaryOf(context)),
                  ),
                  onTap: apiKeyMode || settings.credentials.isNotEmpty
                      ? () => _openApiKey(context)
                      : () => _pickModel(context, ref, settings.model),
                ),
                if (settings.hostModelsCache.isNotEmpty)
                  SettingRow(
                    title: '缓存的电脑模型',
                    subtitle: hostOnline
                        ? '${settings.hostModelsCache.length} 个 DeepSeek 账号模型 · 已随电脑同步'
                        : '${settings.hostModelsCache.length} 个 DeepSeek 账号模型 · 电脑离线时仅展示',
                    leading: GlyphIcon(
                      AppGlyphs.delete,
                      size: 20,
                      color: scheme.error,
                    ),
                    trailing: Text(
                      '清除',
                      style: AppTextStyle.callout
                          .of(context)
                          .copyWith(color: scheme.error),
                    ),
                    onTap: () => _confirmClearHostModels(context, ref),
                  ),
              ],
            ),
            const SizedBox(height: 24),

            const _GroupLabel('外观'),
            AppCard(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  for (final mode in ThemeMode.values)
                    Expanded(
                      child: _AppearanceOption(
                        label: _themeLabel(mode),
                        selected: settings.themeMode == mode,
                        onTap: () => ref
                            .read(settingsProvider.notifier)
                            .setThemeMode(mode),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            const _GroupLabel('关于'),
            AppGroupCard(
              children: [
                const SettingRow(
                  title: 'DSH 手机预览版',
                  subtitle: 'Android 首发 · v0.1.0',
                  leading: GlyphIcon(AppGlyphs.info, size: 20),
                ),
                SettingRow(
                  title: '日志导出',
                  subtitle: '导出前自动脱敏 s= / t= / token',
                  leading: GlyphIcon(AppGlyphs.records, size: 20),
                  onTap: () => ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('预览版暂未提供日志导出'))),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  static void _openLogin(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const LoginPage()));
  }

  static void _openApiKey(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const ApiKeyPage()));
  }

  static Future<void> _openScan(BuildContext context) async {
    final connected = await Navigator.of(context)
        .push<bool>(MaterialPageRoute<bool>(builder: (_) => const ScanPage()));
    if (connected == true && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已连接电脑，对话将走电脑上的 DSH')));
    }
  }

  static String _effectiveModel(AppSettings settings) {
    final credential = settings.activeCredential;
    if (credential == null) return '—';
    return '${credential.name} · ${credential.model}';
  }

  Future<void> _confirmClearHostModels(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('清除缓存的电脑模型？', style: AppTextStyle.headline.of(context)),
        content: Text(
          '只删掉手机里缓存的模型目录，不会影响电脑。下次连上电脑会重新同步。',
          style: AppTextStyle.callout.of(context),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(settingsProvider.notifier).clearHostModelsCache();
    ref.read(linkProvider.notifier).dropCachedModels();
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('退出登录？', style: AppTextStyle.headline.of(context)),
        content: Text(
          '将清除本机保存的登录凭证，并回到登录页。',
          style: AppTextStyle.callout.of(context),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(authProvider.notifier).signOut();
  }

  static String _strategyLabel(StartStrategy strategy) => switch (strategy) {
    StartStrategy.fresh => '每次打开新建对话',
    StartStrategy.restoreLast => '恢复上次打开的对话',
    StartStrategy.pinned => '始终打开指定对话',
  };

  static String _themeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };

  Future<void> _pickStrategy(
    BuildContext context,
    WidgetRef ref,
    StartStrategy current,
  ) async {
    final chosen = await _showOptions<StartStrategy>(
      context,
      title: '打开对话的方式',
      options: [
        for (final strategy in StartStrategy.values)
          (strategy, _strategyLabel(strategy)),
      ],
      current: current,
    );
    if (chosen == null) return;
    await ref.read(settingsProvider.notifier).setStartStrategy(chosen);
  }

  Future<void> _pickModel(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final chosen = await _showOptions<String>(
      context,
      title: '默认模型',
      options: const [
        ('deepseek-v4-flash', 'DeepSeek V4.1 Flash'),
        ('deepseek-v4-pro', 'DeepSeek V4.1 Pro'),
        ('__custom__', '自定义模型名…'),
      ],
      current: current,
    );
    if (chosen == null) return;
    if (chosen == '__custom__') {
      if (!context.mounted) return;
      final controller = TextEditingController();
      final typed = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('自定义模型名', style: AppTextStyle.headline.of(context)),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '例如 deepseek-v4-pro'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (typed == null || typed.isEmpty) return;
      await ref.read(settingsProvider.notifier).setModel(typed);
      return;
    }
    await ref.read(settingsProvider.notifier).setModel(chosen);
  }

  Future<T?> _showOptions<T>(
    BuildContext context, {
    required String title,
    required List<(T, String)> options,
    required T current,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: AppCard(
            radius: AppCorner.xl,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      style: AppTextStyle.headline.of(context),
                    ),
                  ),
                ),
                for (final option in options)
                  InkWell(
                    onTap: () => Navigator.of(context).pop(option.$1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              option.$2,
                              style: AppTextStyle.callout.of(context),
                            ),
                          ),
                          if (option.$1 == current)
                            GlyphIcon(
                              AppGlyphs.checkCircle,
                              size: 18,
                              color: AppColors.of(context).primary,
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({
    required this.signedIn,
    this.nickname,
    this.avatarUrl,
  });

  final bool signedIn;
  final String? nickname;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final initial = signedIn && (nickname?.isNotEmpty ?? false)
        ? nickname!.substring(0, 1).toUpperCase()
        : '';
    final fallback = Container(
      color: signedIn
          ? scheme.primary.withValues(alpha: 0.12)
          : scheme.surfaceContainerHigh,
      child: Center(
        child: signedIn
            ? Text(
                initial,
                style: AppTextStyle.callout
                    .of(context)
                    .copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
              )
            : GlyphIcon(
                AppGlyphs.profile,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
      ),
    );
    final url = avatarUrl?.trim() ?? '';
    final hasAvatar = signedIn && url.startsWith('https://');
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: signedIn
            ? scheme.primary.withValues(alpha: 0.12)
            : scheme.surfaceContainerHigh,
        borderRadius: AppRadius.full,
      ),
      clipBehavior: Clip.antiAlias,
      child: hasAvatar
          ? Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : fallback,
            )
          : fallback,
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: AppTextStyle.subheadline
            .of(context)
            .copyWith(
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondaryOf(context),
              letterSpacing: 0.3,
            ),
      ),
    );
  }
}

class _AppearanceOption extends StatelessWidget {
  const _AppearanceOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.12)
              : scheme.surfaceContainerLow,
          borderRadius: AppRadius.all(AppCorner.sm),
        ),
        child: Center(
          child: Text(
            label,
            style: AppTextStyle.footnote
                .of(context)
                .copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
          ),
        ),
      ),
    );
  }
}
