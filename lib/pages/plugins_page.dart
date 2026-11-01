import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../protocol/models.dart';
import '../skills/local/local_skill.dart';
import '../skills/local/skill_store.dart';
import '../state/app_providers.dart';
import '../state/auth_provider.dart';
import '../state/chat_provider.dart';
import '../state/local_plugins_provider.dart';
import '../state/plugins_provider.dart';
import '../state/skills_provider.dart';
import '../ui/colors.dart';
import '../ui/glyphs.dart';
import '../ui/tokens.dart';
import '../ui/typography.dart';
import '../ui/widgets.dart';
import 'login_page.dart';

class PluginsPage extends ConsumerWidget {
  const PluginsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pluginsProvider);
    final local = ref.watch(localPluginsProvider);
    final link = ref.watch(linkProvider);
    final signedIn = ref.watch(authProvider).authorized;
    final settings = ref.watch(settingsProvider);
    final connected = link.status.isConnected && signedIn;
    final catalog = state.catalog;

    return Column(
      children: [
        const SizedBox(height: 8),
        if (state.loading) const LinearProgressIndicator(minHeight: 2),
        if (state.error != null)
          InlineBanner(text: state.error!, tone: BannerTone.error),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  const _SkillsSection(),
                  const SizedBox(height: 24),
                  const _SectionLabel('本地插件'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                    child: Text(
                      '只影响这台手机：可以给输入框加快捷动作、给本地对话加人设/提示词模板，不会改动电脑上的 DSH。',
                      style: AppTextStyle.caption1.of(context).copyWith(
                        color: AppColors.textSecondaryOf(context),
                        height: 1.4,
                      ),
                    ),
                  ),
                  if (local.loading) const LinearProgressIndicator(minHeight: 2),
                  if (local.error != null)
                    InlineBanner(text: local.error!, tone: BannerTone.error),
                  if (local.plugins.isEmpty && !local.loading)
                    AppCard(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '还没有本地插件',
                            style: AppTextStyle.headline.of(context),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '把插件目录放进 App 数据目录的 plugins/ 下，重启或点刷新即可识别。',
                            style: AppTextStyle.footnote.of(context).copyWith(
                              color: AppColors.textSecondaryOf(context),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    for (final plugin in local.plugins)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: AppCard(
                          padding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              SettingRow(
                                title: plugin.name,
                                subtitle:
                                    'v${plugin.version}${plugin.description.isEmpty ? '' : ' · ${plugin.description}'}',
                                leading: Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: AppColors.of(context).primary
                                        .withValues(alpha: 0.12),
                                    borderRadius: AppRadius.all(AppCorner.sm),
                                  ),
                                  child: Center(
                                    child: GlyphIcon(
                                      AppGlyphs.plugins,
                                      size: 18,
                                      color: AppColors.of(context).primary,
                                    ),
                                  ),
                                ),
                                trailing: Switch(
                                  value: plugin.enabled,
                                  onChanged: (value) => ref
                                      .read(localPluginsProvider.notifier)
                                      .setEnabled(plugin.id, value),
                                ),
                              ),
                              for (final section in plugin.settingsSections)
                                for (final row in section.rows.where(
                                  (item) => item.isSwitch,
                                ))
                                  SettingRow(
                                    title: row.title,
                                    subtitle: section.title,
                                    trailing: Switch(
                                      value: local.settingValue(
                                        plugin.id,
                                        row.key,
                                        fallback: row.defaultValue,
                                      ),
                                      onChanged: (value) => ref
                                          .read(localPluginsProvider.notifier)
                                          .setSetting(plugin.id, row.key, value),
                                    ),
                                  ),
                              // chatTemplate：本地纯文本对话的系统提示。
                              for (final template in plugin.capabilities.where(
                                (item) => item.isChatTemplate,
                              ))
                                SettingRow(
                                  title: template.title.isEmpty
                                      ? '提示词模板'
                                      : '提示词模板 · ${template.title}',
                                  subtitle: plugin.enabled
                                      ? '已注入本地纯文本对话'
                                      : '插件已停用，模板暂不生效',
                                  leading: GlyphIcon(
                                    AppGlyphs.chat,
                                    size: 18,
                                    color: AppColors.textSecondaryOf(context),
                                  ),
                                  trailing: const SizedBox.shrink(),
                                ),
                              // 输入框动作：告诉用户这个插件到底能干什么。
                              for (final action in plugin.capabilities.where(
                                (item) => item.isComposerAction,
                              ))
                                SettingRow(
                                  title: '输入框动作 · ${action.label}',
                                  subtitle: plugin.enabled
                                      ? '在输入框 + 面板里插入预设文本'
                                      : '插件已停用，动作暂不显示',
                                  leading: GlyphIcon(
                                    AppGlyphs.plus,
                                    size: 18,
                                    color: AppColors.textSecondaryOf(context),
                                  ),
                                  trailing: const SizedBox.shrink(),
                                ),
                            ],
                          ),
                        ),
                      ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () =>
                          ref.read(localPluginsProvider.notifier).refresh(),
                      icon: const Icon(AppGlyphs.reconnect, size: 16),
                      label: const Text('重新扫描本地插件'),
                    ),
                  ),
                  const _SectionLabel('手机与电脑'),
                  AppGroupCard(
                    children: [
                      SettingRow(
                        title: '电脑端互联',
                        subtitle: settings.pcLinkPluginEnabled
                            ? (connected
                                  ? '已启用并连接电脑 · 对话页可切换本地 / 电脑端'
                                  : '已启用 · 电脑离线时保留配对，可手动连接')
                            : '默认关闭。启用后会连接电脑；关闭只断开连接，配对信息保留',
                        leading: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: AppColors.of(context).primary
                                .withValues(alpha: 0.12),
                            borderRadius: AppRadius.all(AppCorner.sm),
                          ),
                          child: Center(
                            child: GlyphIcon(
                              AppGlyphs.scan,
                              size: 18,
                              color: AppColors.of(context).primary,
                            ),
                          ),
                        ),
                        trailing: Switch(
                          value: settings.pcLinkPluginEnabled,
                          onChanged: (value) =>
                              _togglePcLink(context, ref, value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const _SectionLabel('电脑端插件'),
                  if (!signedIn)
                    AppCard(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '登录后可管理电脑端插件',
                            style: AppTextStyle.headline.of(context),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '装上电脑端 DSH 插件并登录后，这里会显示可开关的插件目录。',
                            style: AppTextStyle.footnote
                                .of(context)
                                .copyWith(
                                  color: AppColors.textSecondaryOf(context),
                                ),
                          ),
                          const SizedBox(height: 12),
                          SecondaryButton(
                            label: '去登录',
                            icon: AppGlyphs.profile,
                            onPressed: () => _openLogin(context),
                          ),
                        ],
                      ),
                    )
                  else if (!connected)
                    const AppCard(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        '无法获取插件列表：请先扫码连接电脑，或在「我的」打开扫一扫。',
                        style: TextStyle(fontSize: 14),
                      ),
                    )
                  else if (catalog.isEmpty)
                    EmptyState(
                      icon: AppGlyphs.plugins,
                      title: '未检测到电脑端插件',
                      description: catalog.managementAvailable
                          ? 'Host 当前 profile 没有启用任何插件。'
                          : '当前 Host 不支持远程插件管理。',
                    )
                  else ...[
                    _PcPluginGroups(catalog: catalog),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    '插件开关即时生效；界面入口变化建议重启应用后查看。',
                    style: AppTextStyle.caption1
                        .of(context)
                        .copyWith(color: AppColors.textSecondaryOf(context)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _togglePcLink(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    await ref.read(settingsProvider.notifier).setPcLinkPluginEnabled(enabled);
    final link = ref.read(linkProvider.notifier);
    if (enabled) {
      // 已配对就立刻重连，开关不只是隐藏入口。
      if (ref.read(linkProvider).paired) {
        await link.reconnect();
      }
    } else {
      ref.read(chatProvider.notifier).setScope(ChatScope.local);
      await link.disconnect();
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(enabled ? '电脑端互联已启用，正在连接电脑…' : '电脑端互联已停用，配对信息已保留'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  static void _openLogin(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const LoginPage()));
  }

}

/// 技能：用户自行下载 SKILL.md / zip，App 只负责导入与本地提示注入。
class _SkillsSection extends ConsumerWidget {
  const _SkillsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skills = ref.watch(skillsProvider);
    final scheme = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('技能'),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(
            '技能是可移植的 SKILL.md 提示词包：导入后只注入本地纯文本对话，'
            '不会执行里面的脚本，也不会上传到电脑。请自行确认来源可信。',
            style: AppTextStyle.caption1.of(context).copyWith(
              color: AppColors.textSecondaryOf(context),
              height: 1.4,
            ),
          ),
        ),
        AppGroupCard(
          children: [
            SettingRow(
              title: '导入技能',
              subtitle: '支持 SKILL.md，或包含 SKILL.md 的 .zip；只读取文本',
              leading: GlyphIcon(
                AppGlyphs.file,
                size: 20,
                color: scheme.primary,
              ),
              trailing: Text(
                '导入',
                style: AppTextStyle.callout.of(context).copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () => _import(context, ref),
            ),
            if (skills.loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            for (final skill in skills.skills)
              SettingRow(
                title: skill.name,
                subtitle: skill.description.isEmpty
                    ? 'SKILL.md · ${skill.source.isEmpty ? skill.id : skill.source}'
                    : skill.description,
                leading: GlyphIcon(
                  AppGlyphs.plugins,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                trailing: Switch(
                  value: skill.enabled,
                  onChanged: (value) => ref
                      .read(skillsProvider.notifier)
                      .setEnabled(skill.id, value),
                ),
                onTap: () => _showDetail(context, ref, skill),
              ),
          ],
        ),
        if (skills.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: InlineBanner(text: skills.error!, tone: BannerTone.error),
          ),
        if (skills.skills.isEmpty && !skills.loading)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              '还没有导入技能。可以从 skills.sh 等目录下载 SKILL.md 或技能包，再回到这里导入。',
              style: AppTextStyle.caption1.of(context).copyWith(
                color: AppColors.textSecondaryOf(context),
                height: 1.4,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    late final PlatformFile file;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['md', 'zip'],
      );
      if (files.isEmpty) return;
      file = files.first;
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('无法打开文件选择器：$error')));
      return;
    }
    final sourceName = file.name;
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('读取文件失败：$error')));
      return;
    }
    ParsedSkill parsed;
    try {
      parsed = SkillStore.preview(fileName: sourceName, bytes: bytes);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
      return;
    }
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('导入技能', style: AppTextStyle.headline.of(context)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(parsed.name, style: AppTextStyle.headline.of(context)),
              const SizedBox(height: 6),
              Text(
                parsed.description.isEmpty ? '（没有描述）' : parsed.description,
                style: AppTextStyle.callout.of(context),
              ),
              const SizedBox(height: 10),
              Text(
                '来源：$sourceName\n正文：${parsed.body.length} 字',
                style: AppTextStyle.caption1.of(context).copyWith(
                  color: AppColors.textSecondaryOf(context),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '导入后只作为本地对话的系统提示，不执行脚本或命令。',
                style: AppTextStyle.caption1.of(context).copyWith(
                  color: AppColors.textSecondaryOf(context),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final skill = await ref
          .read(skillsProvider.notifier)
          .importFile(fileName: sourceName, bytes: bytes);
      messenger.showSnackBar(
        SnackBar(
          content: Text('已导入技能「${skill.name}」'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$error')));
    }
  }

  Future<void> _showDetail(
    BuildContext context,
    WidgetRef ref,
    LocalSkill skill,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: AppCard(
            radius: AppCorner.xl,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(skill.name, style: AppTextStyle.headline.of(sheetContext)),
                const SizedBox(height: 4),
                if (skill.description.isNotEmpty)
                  Text(
                    skill.description,
                    style: AppTextStyle.callout
                        .of(sheetContext)
                        .copyWith(color: AppColors.textSecondaryOf(sheetContext)),
                  ),
                const SizedBox(height: 8),
                Text(
                  [
                    if (skill.source.isNotEmpty) '来源 ${skill.source}',
                    if (skill.license.isNotEmpty) '许可 ${skill.license}',
                    if (skill.version.isNotEmpty) 'v${skill.version}',
                  ].join(' · '),
                  style: AppTextStyle.caption1.of(sheetContext).copyWith(
                    color: AppColors.textSecondaryOf(sheetContext),
                  ),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      skill.body,
                      style: AppTextStyle.callout.of(sheetContext),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: sheetContext,
                          builder: (context) => AlertDialog(
                            title: Text(
                              '删除这个技能？',
                              style: AppTextStyle.headline.of(context),
                            ),
                            content: const Text('只删除手机里的副本，不影响电脑和原始文件。'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: const Text('删除'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        await ref
                            .read(skillsProvider.notifier)
                            .remove(skill.id);
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                      child: Text(
                        '删除',
                        style: TextStyle(
                          color: AppColors.of(sheetContext).error,
                        ),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('关闭'),
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: AppTextStyle.footnote
            .of(context)
            .copyWith(
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondaryOf(context),
              letterSpacing: 0.4,
            ),
      ),
    );
  }
}

/// 电脑端插件分组：第三方/后装默认展开，官方内置默认折叠。
class _PcPluginGroups extends ConsumerStatefulWidget {
  const _PcPluginGroups({required this.catalog});

  final PluginCatalog catalog;

  @override
  ConsumerState<_PcPluginGroups> createState() => _PcPluginGroupsState();
}

class _PcPluginGroupsState extends ConsumerState<_PcPluginGroups> {
  bool _showOfficial = false;

  static bool _isOfficial(String name) =>
      name.startsWith('@deepseek-ai/') ||
      name == 'dshmarket' ||
      name.startsWith('@deepseek-ai-dsh');

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final bundles = widget.catalog.bundles;
    final userBundles =
        bundles.where((item) => !_isOfficial(item.name)).toList(growable: false);
    final officialBundles =
        bundles.where((item) => _isOfficial(item.name)).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (userBundles.isEmpty)
          AppCard(
            padding: const EdgeInsets.all(16),
            child: Text(
              '还没有安装第三方插件。通过 DSH 安装的插件会优先显示在这里。',
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: AppColors.textSecondaryOf(context)),
            ),
          )
        else
          for (final bundle in userBundles)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _BundleCard(bundle: bundle),
            ),
        if (officialBundles.isNotEmpty) ...[
          AppCard(
            padding: EdgeInsets.zero,
            child: SettingRow(
              title: '内置插件',
              subtitle:
                  '${officialBundles.length} 个官方自带插件 · ${_showOfficial ? '点击收起' : '默认折叠'}',
              leading: GlyphIcon(
                AppGlyphs.plugins,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              trailing: GlyphIcon(
                _showOfficial ? AppGlyphs.chevronUp : AppGlyphs.chevronDown,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              onTap: () => setState(() => _showOfficial = !_showOfficial),
            ),
          ),
          if (_showOfficial)
            for (final bundle in officialBundles)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _BundleCard(bundle: bundle),
              ),
          if (_showOfficial && widget.catalog.plugins.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: AppGroupCard(
                header: '独立条目',
                children: [
                  for (final entry in widget.catalog.plugins)
                    SettingRow(
                      title: entry.name,
                      subtitle: _BundleCard._typeOf(entry.type),
                      trailing: Switch(
                        value: entry.enabled,
                        onChanged: (value) => ref
                            .read(pluginsProvider.notifier)
                            .setEntryEnabled(entry.id, value),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _BundleCard extends ConsumerWidget {
  const _BundleCard({required this.bundle});

  final PluginBundle bundle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = AppColors.of(context);
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          SettingRow(
            title: bundle.name,
            subtitle: [
              if (bundle.description.trim().isNotEmpty)
                bundle.description.trim(),
              if (bundle.version.isNotEmpty) 'v${bundle.version}',
              if (bundle.description.trim().isEmpty && bundle.version.isEmpty)
                '插件包',
            ].join(' · '),
            leading: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: AppRadius.all(AppCorner.sm),
              ),
              child: Center(
                child: GlyphIcon(
                  AppGlyphs.plugins,
                  size: 18,
                  color: scheme.primary,
                ),
              ),
            ),
            trailing: Switch(
              value: bundle.enabled,
              onChanged: (value) => ref
                  .read(pluginsProvider.notifier)
                  .setBundleEnabled(bundle.name, value),
            ),
          ),
          for (final entry in bundle.entries)
            SettingRow(
              title: entry.name,
              subtitle: entry.description.trim().isNotEmpty
                  ? '${_typeOf(entry.type)} · ${entry.description.trim()}'
                  : _typeOf(entry.type),
              trailing: Switch(
                value: entry.enabled,
                onChanged: (value) => ref
                    .read(pluginsProvider.notifier)
                    .setEntryEnabled(entry.id, value),
              ),
            ),
        ],
      ),
    );
  }

  static String _typeOf(String type) => switch (type) {
    'tool' => '工具',
    'systemPrompt' => '系统提示',
    'agent' => '代理',
    'llm' => '模型',
    'unknown' => '插件条目',
    _ => type,
  };
}
