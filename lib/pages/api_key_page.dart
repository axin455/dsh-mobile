import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/model_providers.dart';
import '../data/settings.dart';
import '../protocol/direct_chat.dart';
import '../state/app_providers.dart';
import '../state/auth_provider.dart';
import '../ui/colors.dart';
import '../ui/glyphs.dart';
import '../ui/tokens.dart';
import '../ui/typography.dart';
import '../ui/widgets.dart';
import 'scan_page.dart';

/// API Key 登录：可以同时登录多家供应商，对话用当前选中的那一家。
///
/// 与账号登录（走浏览器、用 DeepSeek 余额）互不影响：这里按 Key 用量计费。
class ApiKeyPage extends ConsumerStatefulWidget {
  const ApiKeyPage({super.key});

  @override
  ConsumerState<ApiKeyPage> createState() => _ApiKeyPageState();
}

class _ApiKeyPageState extends ConsumerState<ApiKeyPage> {
  final _keyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  final _customModelController = TextEditingController();
  final _nameController = TextEditingController();

  late ModelProvider _provider;

  /// 勾选的模型（可多选，对话使用第一个）。
  late List<String> _selected;
  bool _editing = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _provider =
        providerById(settings.apiKeyProvider) ??
        providerById('deepseek') ??
        kModelProviders.first;
    _editing = settings.credentials.isEmpty;
    // 必须先给 _selected 赋初值：没有任何已登录供应商时 page 直接进入编辑态，
    // 之前 _prefill 不会被调用，late 字段未初始化会让整页白屏。
    _selected = _provider.models.isEmpty
        ? <String>[]
        : [_provider.models.first.value];
    if (_editing) {
      _nameController.text = _provider.id == 'custom' ? '' : _provider.name;
    } else {
      _prefill(settings.activeCredential);
    }
  }

  void _prefill(ApiCredential? credential) {
    if (credential == null) return;
    _provider =
        providerById(credential.providerId) ??
        providerById('deepseek') ??
        kModelProviders.first;
    _baseUrlController.text = credential.baseUrl;
    _modelController.text = credential.model;
    _nameController.text = credential.name;
    _selected = credential.models.isEmpty
        ? (credential.model.isEmpty ? <String>[] : [credential.model])
        : [...credential.models];
  }

  @override
  void dispose() {
    _keyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _customModelController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _selectProvider(ModelProvider provider) {
    if (provider.id == _provider.id) return;
    setState(() {
      _provider = provider;
      _baseUrlController.text = '';
      _modelController.text = '';
      _customModelController.clear();
      _nameController.text = provider.id == 'custom' ? '' : provider.name;
      _selected = provider.models.isEmpty
          ? <String>[]
          : [provider.models.first.value];
      _error = null;
    });
  }

  void _toggleModel(String value) {
    setState(() {
      if (_selected.contains(value)) {
        _selected.remove(value);
      } else {
        _selected.add(value);
      }
    });
  }

  String get _effectiveBaseUrl {
    if (_provider.baseUrl.isNotEmpty) return _provider.baseUrl;
    return _baseUrlController.text.trim();
  }

  String get _effectiveName {
    if (_provider.id == 'custom') {
      final typed = _nameController.text.trim();
      return typed.isEmpty ? '自定义' : typed;
    }
    return _provider.name;
  }

  /// 预设模型取第一个勾选项，外加手填的自定义模型名；自定义供应商只用手填。
  String get _effectiveModel {
    final custom = _customModelController.text.trim();
    if (_provider.models.isEmpty) {
      return custom.isEmpty ? _modelController.text.trim() : custom;
    }
    if (_selected.isNotEmpty) return _selected.first;
    return custom;
  }

  List<String> get _effectiveModels {
    final models = <String>[];
    if (_provider.models.isEmpty) {
      final typed = _modelController.text.trim();
      if (typed.isNotEmpty) models.add(typed);
    } else {
      models.addAll(_selected);
    }
    final custom = _customModelController.text.trim();
    if (_provider.models.isNotEmpty && custom.isNotEmpty) models.add(custom);
    final active = _effectiveModel;
    if (active.isNotEmpty && !models.contains(active)) models.insert(0, active);
    return models;
  }

  /// 自定义供应商必须填地址，预设供应商地址固定。
  bool get _needsBaseUrl => _provider.baseUrl.isEmpty;

  Future<void> _submit() async {
    final store = ref.read(secureStoreProvider);
    final typedKey = _keyController.text.trim();
    final existing = await store.readProviderKey(_provider.id);
    final apiKey = typedKey.isEmpty ? existing : typedKey;

    if (apiKey == null || apiKey.isEmpty) {
      setState(() => _error = '请填入 API Key');
      return;
    }
    if (_needsBaseUrl && _effectiveBaseUrl.isEmpty) {
      setState(() => _error = '请填入 Base URL');
      return;
    }
    if (_effectiveModel.isEmpty) {
      setState(() => _error = '请选择或填写模型');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final client = DirectChatClient();
    final String? failure;
    try {
      failure = await client.validate(
        baseUrl: _effectiveBaseUrl,
        apiKey: apiKey,
      );
    } finally {
      client.dispose();
    }
    if (!mounted) return;

    if (failure != null) {
      setState(() {
        _busy = false;
        _error = failure;
      });
      return;
    }

    await store.saveProviderKey(providerId: _provider.id, apiKey: apiKey);
    final last4 = apiKey.length <= 4
        ? apiKey
        : apiKey.substring(apiKey.length - 4);
    await ref.read(authProvider.notifier).signInWithApiKey(
      credential: ApiCredential(
        providerId: _provider.id,
        name: _effectiveName,
        baseUrl: _effectiveBaseUrl,
        last4: last4,
        model: _effectiveModel,
        models: _effectiveModels,
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _remove(ApiCredential credential) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('移除 ${credential.name}？', style: AppTextStyle.headline.of(context)),
        content: Text(
          '会清除本机保存的 API Key，其他供应商不受影响。',
          style: AppTextStyle.callout.of(context),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(secureStoreProvider)
        .clearProviderKey(credential.providerId);
    await ref
        .read(settingsProvider.notifier)
        .removeApiCredential(credential.providerId);
    await ref.read(authProvider.notifier).reload();
  }

  void _startAdding() {
    setState(() {
      _editing = true;
      _provider =
          providerById('deepseek') ?? kModelProviders.first;
      _keyController.clear();
      _baseUrlController.clear();
      _modelController.clear();
      _customModelController.clear();
      _nameController.clear();
      _selected = _provider.models.isEmpty
          ? <String>[]
          : [_provider.models.first.value];
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final secondary = AppTextStyle.footnote
        .of(context)
        .copyWith(color: AppColors.textSecondaryOf(context));
    final settings = ref.watch(settingsProvider);
    if (!_editing) {
      return _buildList(context, settings, secondary);
    }
    String? existingLast4;
    for (final item in settings.credentials) {
      if (item.providerId == _provider.id) {
        existingLast4 = item.last4;
        break;
      }
    }

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () {
                    if (settings.credentials.isEmpty) {
                      Navigator.of(context).pop();
                    } else {
                      setState(() => _editing = false);
                    }
                  },
                  icon: Icon(
                    AppGlyphs.close,
                    size: 22,
                    color: AppColors.textSecondaryOf(context),
                  ),
                  tooltip: '返回',
                ),
                const SizedBox(width: 4),
                Text('API Key 登录', style: AppTextStyle.largeTitle.of(context)),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '选一个供应商，填上它的 API Key。可以分别登录多家，模型按已登录的 Key 列出。',
                style: secondary,
              ),
            ),
            const SizedBox(height: 20),
            SecondaryButton(
              label: '扫码连接电脑（推荐）',
              icon: AppGlyphs.scan,
              onPressed: () async {
                final navigator = Navigator.of(context);
                final connected = await navigator.push<bool>(
                  MaterialPageRoute<bool>(builder: (_) => const ScanPage()),
                );
                if (connected == true && mounted) navigator.pop();
              },
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '同一个局域网下扫码即可配对，手机直接使用电脑端 DSH 的模型和插件，不用填 Key。',
                style: secondary,
              ),
            ),
            const SizedBox(height: 24),

            const _GroupLabel('供应商'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final provider in kModelProviders)
                  _ProviderChip(
                    provider: provider,
                    selected: provider.id == _provider.id,
                    onTap: () => _selectProvider(provider),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            if (_provider.note.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(_provider.note, style: secondary),
              ),
              const SizedBox(height: 16),
            ],

            if (_provider.id == 'custom') ...[
              const _GroupLabel('供应商名称'),
              _FieldCard(
                child: TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: '例如：我的自建服务',
                    hintStyle: AppTextStyle.callout
                        .of(context)
                        .copyWith(color: scheme.onSurfaceVariant),
                  ),
                  style: AppTextStyle.callout.of(context),
                ),
              ),
              const SizedBox(height: 20),
            ],

            const _GroupLabel('API Key'),
            _FieldCard(
              child: TextField(
                controller: _keyController,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  hintText: existingLast4?.isNotEmpty == true
                      ? '已保存（末四位 $existingLast4），留空沿用'
                      : '粘贴 ${_provider.name} 的 API Key',
                  hintStyle: AppTextStyle.callout
                      .of(context)
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
                style: AppTextStyle.callout.of(context),
              ),
            ),
            const SizedBox(height: 20),

            if (_needsBaseUrl) ...[
              const _GroupLabel('Base URL'),
              _FieldCard(
                child: TextField(
                  controller: _baseUrlController,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: 'https://api.example.com/v1',
                    hintStyle: AppTextStyle.callout
                        .of(context)
                        .copyWith(color: scheme.onSurfaceVariant),
                  ),
                  style: AppTextStyle.callout.of(context),
                ),
              ),
              const SizedBox(height: 20),
            ],

            const _GroupLabel('模型'),
            if (_provider.models.isNotEmpty) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final model in _provider.models)
                    _ModelChip(
                      label: model.label,
                      selected: _selected.contains(model.value),
                      onTap: () => _toggleModel(model.value),
                    ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            _FieldCard(
              child: TextField(
                controller: _provider.models.isEmpty
                    ? _modelController
                    : _customModelController,
                autocorrect: false,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  hintText: _provider.models.isEmpty
                      ? '模型名，例如 gpt-4o-mini'
                      : '自定义模型名（可选，填写后优先使用）',
                  hintStyle: AppTextStyle.callout
                      .of(context)
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
                style: AppTextStyle.callout.of(context),
              ),
            ),
            if (_provider.models.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text('可勾选多个，对话使用第一个；也可直接手填模型名。', style: secondary),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 20),
              InlineBanner(
                text: _error!,
                tone: BannerTone.error,
                margin: EdgeInsets.zero,
              ),
            ],

            const SizedBox(height: 28),
            PrimaryButton(
              label: _busy ? '正在验证…' : '验证并登录',
              icon: _busy ? null : AppGlyphs.checkCircle,
              onPressed: _busy ? null : _submit,
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'Key 只保存在本机安全存储，不会上传。',
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: AppColors.textSecondaryOf(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    AppSettings settings,
    TextStyle secondary,
  ) {
    final scheme = AppColors.of(context);
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(
                    AppGlyphs.close,
                    size: 22,
                    color: AppColors.textSecondaryOf(context),
                  ),
                  tooltip: '关闭',
                ),
                const SizedBox(width: 4),
                Text('API Key 登录', style: AppTextStyle.largeTitle.of(context)),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '已登录 ${settings.credentials.length} 家供应商。点模型即可切换当前使用，彼此不会覆盖。',
                style: secondary,
              ),
            ),
            const SizedBox(height: 20),
            for (final credential in settings.credentials) ...[
              _CredentialCard(
                credential: credential,
                active: credential.providerId == settings.activeProviderId,
                onSelectModel: (model) => ref
                    .read(settingsProvider.notifier)
                    .selectApiCredential(
                      providerId: credential.providerId,
                      model: model,
                    ),
                onEdit: () {
                  setState(() {
                    _editing = true;
                    _prefill(credential);
                    _error = null;
                  });
                },
                onRemove: () => _remove(credential),
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 8),
            PrimaryButton(
              label: '添加供应商',
              icon: AppGlyphs.plus,
              onPressed: _startAdding,
            ),
          ],
        ),
      ),
    );
  }
}

class _CredentialCard extends StatelessWidget {
  const _CredentialCard({
    required this.credential,
    required this.active,
    required this.onSelectModel,
    required this.onEdit,
    required this.onRemove,
  });

  final ApiCredential credential;
  final bool active;
  final ValueChanged<String> onSelectModel;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final synced = credential.providerId.startsWith('pc:');
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: AppRadius.full,
                ),
                child: Center(
                  child: Text(
                    credential.name.isEmpty
                        ? '?'
                        : credential.name.substring(0, 1).toUpperCase(),
                    style: AppTextStyle.callout.of(context).copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      credential.name,
                      style: AppTextStyle.headline.of(context),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${active ? '当前使用 · ' : ''}'
                      '${synced ? '电脑同步 · ' : ''}末四位 ${credential.last4}',
                      style: AppTextStyle.caption1
                          .of(context)
                          .copyWith(
                            color: active
                                ? scheme.primary
                                : AppColors.textSecondaryOf(context),
                          ),
                    ),
                  ],
                ),
              ),
              if (!synced)
                TextButton(onPressed: onEdit, child: const Text('更新'))
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '电脑管理',
                    style: AppTextStyle.caption2
                        .of(context)
                        .copyWith(color: AppColors.textSecondaryOf(context)),
                  ),
                ),
              TextButton(
                onPressed: onRemove,
                child: Text('移除', style: TextStyle(color: scheme.error)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final model in credential.models)
                _ModelChip(
                  label: model,
                  selected: active && credential.model == model,
                  onTap: () => onSelectModel(model),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  const _FieldCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.cardOf(scheme),
        borderRadius: AppRadius.all(AppCorner.md),
      ),
      child: child,
    );
  }
}

class _ProviderChip extends StatelessWidget {
  const _ProviderChip({
    required this.provider,
    required this.selected,
    required this.onTap,
  });

  final ModelProvider provider;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.12)
          : AppColors.cardOf(scheme),
      shape: AppShape.full,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            provider.name,
            style: AppTextStyle.callout
                .of(context)
                .copyWith(
                  color: selected ? scheme.primary : scheme.onSurface,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
          ),
        ),
      ),
    );
  }
}

class _ModelChip extends StatelessWidget {
  const _ModelChip({
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
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.12)
          : scheme.surfaceContainerHigh,
      shape: AppShape.full,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
          ),
        ),
      ),
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
