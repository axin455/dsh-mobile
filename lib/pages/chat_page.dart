
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../data/chat_attachment.dart';
import '../data/model_providers.dart';
import '../data/settings.dart';
import '../plugins/local/manifest.dart';
import '../protocol/gateway_client.dart';
import '../protocol/host_state.dart';
import '../protocol/models.dart';
import '../state/app_providers.dart';
import '../state/auth_provider.dart';
import '../state/chat_provider.dart';
import '../state/local_plugins_provider.dart';
import '../ui/colors.dart';
import '../ui/glyphs.dart';
import '../ui/markdown.dart';
import '../ui/segmented.dart';
import '../ui/tokens.dart';
import '../ui/typography.dart';
import '../ui/widgets.dart';
import 'api_key_page.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _scrollController = ScrollController();
  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();
  bool _stickToBottom = true;
  bool _followPending = false;
  bool _expandedInput = false;
  final List<ChatAttachment> _attachments = [];

  /// 电脑端「工作」里折叠起来的中间步骤，记录被展开的分组。
  final Set<String> _expandedDetails = <String>{};

  /// 把连续的 detail 条目合成一个可展开的分组。
  List<_ChatNode> get _nodes {
    final entries = ref.read(chatProvider).entries;
    final nodes = <_ChatNode>[];
    final buffer = <ChatEntry>[];
    void flush() {
      if (buffer.isEmpty) return;
      nodes.add(_DetailNode(List<ChatEntry>.unmodifiable(buffer)));
      buffer.clear();
    }

    for (final entry in entries) {
      if (entry.detail) {
        buffer.add(entry);
      } else {
        flush();
        nodes.add(_EntryNode(entry));
      }
    }
    flush();
    return nodes;
  }
  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 用户上滑阅读历史时暂停自动滚动；回到底部附近再恢复。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final distance = position.maxScrollExtent - position.pixels;
    final stick = distance < 48;
    if (stick != _stickToBottom) {
      setState(() => _stickToBottom = stick);
    }
  }

  /// 跳到真正的底部。
  ///
  /// ListView.builder 首次布局时 maxScrollExtent 只是估算值，而历史里又有
  /// 很多长消息；只跳一次会停在估算的“底部”，实际内容还没铺开，屏幕就
  /// 是一片空白。这里连续几帧跟随重新估算后的 max，直到布局稳定。
  void _scrollToBottom({bool animate = true, int frames = 8}) {
    if (!_scrollController.hasClients) return;
    final target = _scrollController.position.maxScrollExtent;
    if (animate && frames == 8) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(target);
    }
    if (frames <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToBottom(animate: false, frames: frames - 1);
    });
  }

  /// 流式输出时贴底：每帧只排一次，直接 jumpTo，避免连续动画互相打断。
  void _followBottom() {
    if (!_stickToBottom || _followPending) return;
    _followPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followPending = false;
      if (!mounted || !_stickToBottom || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      final delta = target - _scrollController.position.pixels;
      if (delta > 0) _scrollController.jumpTo(target);
    });
  }

  Future<void> _send() async {
    final text = _inputController.text;
    if (text.trim().isEmpty && _attachments.isEmpty) return;
    final attachments = [..._attachments];
    _inputController.clear();
    setState(_attachments.clear);
    await ref.read(chatProvider.notifier).send(text, attachments: attachments);
    _stickToBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  /// 展开输入：面板留在页面内，不再弹路由；键盘 + 面板合计约 2/3 屏。
  void _toggleExpandedInput() {
    setState(() => _expandedInput = !_expandedInput);
    ref.read(inputExpandedProvider.notifier).setExpanded(_expandedInput);
    if (!_expandedInput) {
      _inputFocus.unfocus();
    }
  }

  String get _composerHint {
    final settings = ref.read(settingsProvider);
    final signedIn = ref.read(authProvider).authorized;
    final connected = ref.read(linkProvider).status.isConnected;
    final scope = ref.read(chatScopeProvider);
    final pcMode = scope != ChatScope.local && settings.pcLinkPluginEnabled;
    if (pcMode) {
      if (!connected) return '电脑未连接，暂不可发送';
      return scope == ChatScope.pcChat
          ? '发消息给电脑上的模型…'
          : '发消息给电脑上的 DSH…';
    }
    if (settings.apiKeyModeEnabled) return '发消息给 DSH…';
    if (signedIn) return connected ? '发消息给 DSH…' : '连接断开，暂不可发送';
    return '先扫码连电脑或填 API Key';
  }

  String _pcBannerText(GatewayStatus status) {
    final detail = status.detail;
    final base = status.message == null
        ? '电脑未连接：可以查看电脑端对话，但不能发送'
        : status.message!;
    if (detail == null || detail.isEmpty) return base;
    return '$base（$detail）';
  }

  /// 模型、上下文、思考强度共用一个面板：底部胶囊打开它。
  Future<void> _showComposerPanel() async {
    final scope = ref.read(chatScopeProvider);
    if (scope == ChatScope.pc || scope == ChatScope.pcChat) {
      ref.read(chatProvider.notifier).requestModels();
    }
    if (ref.read(linkProvider).accountModels.isEmpty) {
      // 老连接可能还没收到账号模型帧；打开面板时补一次 host-state。
      ref.read(linkProvider.notifier).refreshHostState();
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => const _ComposerPanel(),
    );
  }

  /// 本地模式的模型胶囊文案：账号模型优先，其次当前 API Key 模型。
  static String _modelLabelOf(AppSettings settings) {
    final credential = settings.activeCredential;
    if (credential == null) return '选择模型';
    if (credential.model.isNotEmpty) return credential.model;
    final provider = providerById(credential.providerId);
    if (provider != null && provider.models.isNotEmpty) {
      return provider.models.first.value;
    }
    return '选择模型';
  }

  static List<String> _modelsOf(ApiCredential credential) {
    final models = <String>[...credential.models];
    if (credential.model.isNotEmpty && !models.contains(credential.model)) {
      models.insert(0, credential.model);
    }
    if (models.isEmpty) {
      final provider = providerById(credential.providerId);
      if (provider != null) {
        models.addAll([for (final option in provider.models) option.value]);
      }
    }
    return models;
  }

  /// 统计详情：输入框左侧的基础信息点开就是这张卡片。
  Future<void> _showStatsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => const _StatsSheet(),
    );
  }

  static int _contextIndex(int value) {
    var best = 0;
    for (var i = 0; i < kContextOptions.length; i++) {
      if ((kContextOptions[i] - value).abs() <
          (kContextOptions[best] - value).abs()) {
        best = i;
      }
    }
    return best;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _insertLocalAction(_LocalComposerAction action) {
    final local = ref.read(localPluginsProvider);
    var appendTime = false;
    for (final section in action.plugin.settingsSections) {
      for (final row in section.rows) {
        if (row.key == 'autoAppendTime' && row.isSwitch) {
          appendTime = local.settingValue(
            action.plugin.id,
            row.key,
            fallback: row.defaultValue,
          );
        }
      }
    }
    var text = action.capability.actionText;
    if (appendTime) {
      final now = TimeOfDay.now();
      final stamp =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      text = '$text $stamp';
    }
    final value = _inputController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final next = value.text.replaceRange(start, end, text);
    _inputController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _inputFocus.requestFocus();
    _toast('已插入「${action.capability.label}」');
  }

  /// 加号菜单：全部走系统选择器——系统相机、系统相册（Photo Picker）、系统文件。
  Future<void> _pickAttachment() async {
    final localActions = <_LocalComposerAction>[
      for (final plugin in ref.read(localPluginsProvider).plugins)
        if (plugin.enabled)
          for (final capability in plugin.composerActions)
            _LocalComposerAction(plugin: plugin, capability: capability),
    ];
    final kind = await _showAttachSheet(context, localActions);
    if (kind == null || !mounted) return;
    if (kind.startsWith('local:')) {
      final index = int.tryParse(kind.substring('local:'.length));
      if (index == null || index < 0 || index >= localActions.length) return;
      _insertLocalAction(localActions[index]);
      return;
    }
    try {
      if (kind == 'camera' || kind == 'photo') {
        final image = await ImagePicker().pickImage(
          source: kind == 'camera' ? ImageSource.camera : ImageSource.gallery,
          imageQuality: 82,
          maxWidth: 1600,
        );
        if (image == null) return;
        final attachment = ChatAttachment.fromFile(image.path);
        if (attachment != null) _addAttachments([attachment]);
      } else {
        final files = await FilePicker.pickFiles();
        if (files.isEmpty) return;
        final picked = <ChatAttachment>[];
        final unsupported = <String>[];
        for (final file in files) {
          final path = file.path;
          if (path == null) continue;
          final attachment = ChatAttachment.fromFile(path);
          if (attachment == null) {
            unsupported.add(file.name);
          } else {
            picked.add(attachment);
          }
        }
        if (picked.isNotEmpty) _addAttachments(picked);
        if (unsupported.isNotEmpty) {
          _toast('暂不支持：${unsupported.join('、')}（仅图片或文本文件）');
        }
      }
    } catch (error) {
      _toast('无法打开选择器：$error');
    }
  }

  void _addAttachments(List<ChatAttachment> items) {
    final rejected = <String>[];
    setState(() {
      for (final item in items) {
        if (_attachments.length >= 4) {
          rejected.add(item.name);
          continue;
        }
        _attachments.add(item);
      }
    });
    if (rejected.isNotEmpty) {
      _toast('最多 4 个附件，已忽略：${rejected.join('、')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final link = ref.watch(linkProvider);
    final settings = ref.watch(settingsProvider);
    final auth = ref.watch(authProvider);
    final signedIn = auth.authorized;
    final pluginEnabled = settings.pcLinkPluginEnabled;
    final selectedScope = ref.watch(chatScopeProvider);
    // 插件关闭时强制回到本地，避免停在不可用的电脑端。
    if (!pluginEnabled &&
        (selectedScope == ChatScope.pc || selectedScope == ChatScope.pcChat)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(chatProvider.notifier).setScope(ChatScope.local);
      });
    }
    final scope = pluginEnabled ? selectedScope : ChatScope.local;
    final pcMode = scope != ChatScope.local;
    final pcWork = scope == ChatScope.pc;
    final pcChat = scope == ChatScope.pcChat;
    final pcModelLabel = pcMode
        ? (chat.currentModel?.label ??
              (chat.modelsLoading ? '读取模型…' : '选择模型'))
        : null;
    // API Key 模式直连供应商：本机存了 Key 就能对话，不依赖账号登录。
    final apiKeyMode = settings.apiKeyModeEnabled;
    // 本地模式选中电脑 DeepSeek 账号模型时，本轮请求要经过电脑。
    final localHost = settings.localHostModelEnabled;
    final localReady = localHost
        ? (link.status.isConnected && signedIn)
        : (apiKeyMode || (link.status.isConnected && signedIn));
    final localModelLabel = localHost
        ? (settings.localHostModelName.isNotEmpty
              ? settings.localHostModelName
              : settings.localHostModelId)
        : _modelLabelOf(settings);
    final pcReady = link.status.isConnected && signedIn;
    final ready = pcMode ? pcReady : localReady;
    // 重连进行中：按钮给文字反馈并暂时禁用，避免点了没反应。
    final retrying =
        link.status.phase == GatewayPhase.connecting ||
        link.status.phase == GatewayPhase.reconnecting;
    ref.listen<ChatState>(chatProvider, (previous, next) {
      if (previous == null) return;
      final sessionChanged = previous.sessionId != next.sessionId;
      final grew = next.entries.length > previous.entries.length;
      final changed = !identical(previous.entries, next.entries);
      if (!changed && !sessionChanged) return;
      // 切会话 / 载入历史时直接贴底；流式追加只做「无动画」的贴底，
      // 否则每帧都启动一次动画，画面会一直抽动。
      if (sessionChanged || grew) {
        _stickToBottom = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_stickToBottom) _scrollToBottom();
        });
      } else if (next.streaming) {
        _followBottom();
      }
    });

    return Scaffold(
      // 交给首页的灰阶底纹，玻璃磁贴和 dock 才有可透出的层次。
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 键盘不报 inset（MIUI）：body 已经被缩到键盘上方，
            // 用 body 高度减去 1/3 屏，面板 + 键盘就正好约占 2/3。
            final view = View.of(context);
            final screenHeight = view.physicalSize.height / view.devicePixelRatio;
            final panelHeight = math.max(
              240.0,
              math.min(
                constraints.maxHeight - screenHeight / 3,
                constraints.maxHeight - 120,
              ),
            );
            return Column(
              children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
              child: Row(
                children: [
                  if (pluginEnabled)
                    GlassSegmented(
                      labels: const ['本地', '电脑端'],
                      selectedIndex: pcMode ? 1 : 0,
                      onChanged: (index) {
                        if (index == 0) {
                          ref
                              .read(chatProvider.notifier)
                              .setScope(ChatScope.local);
                          return;
                        }
                        // 切回电脑端时沿用上次的子模式：对话或工作。
                        ref
                            .read(chatProvider.notifier)
                            .setScope(
                              settings.chatScope == ChatScope.pc.name
                                  ? ChatScope.pc
                                  : ChatScope.pcChat,
                            );
                      },
                    ),
                  const Spacer(),
                  _NewChatButton(
                    onTap: () {
                      ref.read(chatProvider.notifier).startFresh();
                      _inputFocus.requestFocus();
                    },
                  ),
                ],
              ),
            ),
            if (pcMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    GlassSegmented(
                      labels: const ['对话', '工作'],
                      selectedIndex: pcWork ? 1 : 0,
                      onChanged: (index) => ref
                          .read(chatProvider.notifier)
                          .setScope(
                            index == 0 ? ChatScope.pcChat : ChatScope.pc,
                          ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        pcWork
                            ? '完整 Agent：会调工具、读写工作区'
                            : '纯文本对话：不建会话、不跑工具',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.caption2.of(context).copyWith(
                          color: AppColors.textSecondaryOf(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (pcMode && !pcReady)
              InlineBanner(
                text: _pcBannerText(link.status),
                tone: BannerTone.warning,
                action: TextButton(
                  onPressed: retrying
                      ? null
                      : () {
                          ref.read(linkProvider.notifier).reconnect();
                          _toast('正在重新连接电脑…');
                        },
                  child: Text(
                    retrying
                        ? '连接中…'
                        : (link.status.phase == GatewayPhase.failed
                              ? '连接'
                              : '重连'),
                    style: AppTextStyle.footnote
                        .of(context)
                        .copyWith(
                          color: AppColors.of(context).primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
            if (!pcMode &&
                signedIn &&
                (localHost || !apiKeyMode) &&
                !link.status.isConnected)
              InlineBanner(
                text: link.status.phase == GatewayPhase.reconnecting
                    ? (link.status.message ?? '已断开，正在重连…')
                    : (link.status.message ?? link.status.label),
                tone: link.status.phase == GatewayPhase.reconnecting
                    ? BannerTone.warning
                    : BannerTone.error,
                action: TextButton(
                  onPressed: retrying
                      ? null
                      : () {
                          ref.read(linkProvider.notifier).reconnect();
                          _toast('正在重新连接电脑…');
                        },
                  child: Text(
                    retrying
                        ? '连接中…'
                        : (link.status.phase == GatewayPhase.failed
                              ? '连接'
                              : '重连'),
                    style: AppTextStyle.footnote
                        .of(context)
                        .copyWith(
                          color: AppColors.of(context).primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
            if (chat.error != null)
              InlineBanner(text: chat.error!, tone: BannerTone.error),
            Expanded(
              child: _BlurSurface(
                active: _expandedInput,
                child: chat.entries.isEmpty
                  ? EmptyState(
                      icon: AppGlyphs.chat,
                      title: pcMode
                          ? (pcChat ? '电脑端对话' : '电脑端新对话')
                          : '开始一段新对话',
                      description: pcMode
                          ? (pcReady
                                ? (pcChat
                                      ? '纯文本对话，由电脑上的模型直接回复；不建会话、不跑工具，历史两边各存一份。'
                                      : '消息会发给电脑上的 DSH，与本地对话互不干扰。')
                                : '电脑未连接，切回本地仍可继续对话。')
                          : ready
                          ? '输入消息后会在这里显示模型回复，支持流式输出。'
                          : (localHost
                                ? '电脑未连接，重新连上后即可使用 DeepSeek 账号模型。'
                                : '扫码连接电脑，或填一个 API Key，就可以开始对话。'),
                    )
                  : RepaintBoundary(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        itemCount: _nodes.length,
                        itemBuilder: (context, index) {
                          final node = _nodes[index];
                          if (node is _EntryNode) {
                            return _MessageBubble(entry: node.entry);
                          }
                          final group = node as _DetailNode;
                          final key = group.entries.first.id;
                          final expanded = _expandedDetails.contains(key);
                          return _DetailGroupView(
                            entries: group.entries,
                            expanded: expanded,
                            onToggle: () => setState(() {
                              if (expanded) {
                                _expandedDetails.remove(key);
                              } else {
                                _expandedDetails.add(key);
                              }
                            }),
                          );
                        },
                      ),
                    ),
              ),
            ),
            if (!_expandedInput && _attachments.isNotEmpty)
              _AttachmentBar(
                attachments: _attachments,
                onRemove: (index) =>
                    setState(() => _attachments.removeAt(index)),
              ),
            if (_expandedInput)
              SizedBox(
                height: panelHeight,
                child: _ExpandedInputSheet(
                  controller: _inputController,
                  enabled: ready,
                  hint: _composerHint,
                  stats: _ChatStats.from(chat),
                  onAttach: _pickAttachment,
                  onPanel: _showComposerPanel,
                  onStats: _showStatsSheet,
                  onClose: _toggleExpandedInput,
                  onSend: () {
                    _toggleExpandedInput();
                    _send();
                  },
                  modelLabel: pcMode ? pcModelLabel : localModelLabel,
                ),
              )
            else
              _Composer(
                controller: _inputController,
                focusNode: _inputFocus,
                enabled: ready,
                hint: pcMode
                    ? (pcReady
                          ? (pcChat ? '发消息给电脑上的模型…' : '发消息给电脑上的 DSH…')
                          : '电脑未连接，暂不可发送')
                    : (localHost
                          ? (link.status.isConnected
                                ? '发消息给 DSH…'
                                : '电脑未连接，暂不可发送')
                          : (apiKeyMode
                                ? '发消息给 DSH…'
                                : (signedIn
                                      ? '连接断开，暂不可发送'
                                      : '先扫码连电脑或填 API Key'))),
                stats: _ChatStats.from(chat),
                onSend: _send,
                onAttach: _pickAttachment,
                onPanel: _showComposerPanel,
                onStats: _showStatsSheet,
                onExpand: _toggleExpandedInput,
                modelLabel: pcMode ? pcModelLabel : localModelLabel,
              ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 页头右上角的新建对话入口：只有一个加号，不再写「新对话」。
class _NewChatButton extends StatelessWidget {
  const _NewChatButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return SizedBox(
      width: 40,
      height: 40,
      child: Material(
        color: Colors.transparent,
        shape: AppShape.circle,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: GlyphIcon(AppGlyphs.plus, size: 24, color: scheme.primary),
          ),
        ),
      ),
    );
  }
}

sealed class _ChatNode {}

class _EntryNode extends _ChatNode {
  _EntryNode(this.entry);
  final ChatEntry entry;
}

class _DetailNode extends _ChatNode {
  _DetailNode(this.entries);
  final List<ChatEntry> entries;
}

/// 默认折叠的中间步骤（思考 / 工具调用 / 工具结果），点开查看细节。
class _DetailGroupView extends StatelessWidget {
  const _DetailGroupView({
    required this.entries,
    required this.expanded,
    required this.onToggle,
  });

  final List<ChatEntry> entries;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final labels = <String>[];
    for (final entry in entries) {
      if (entry.detailLabel.isEmpty || labels.contains(entry.detailLabel)) {
        continue;
      }
      labels.add(entry.detailLabel);
    }
    final summary = labels.take(3).join(' · ');
    if (!expanded) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Material(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.55),
            borderRadius: AppRadius.full,
            child: InkWell(
              onTap: onToggle,
              borderRadius: AppRadius.full,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GlyphIcon(
                      AppGlyphs.chevronRight,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${entries.length} 个中间步骤',
                      style: AppTextStyle.caption1.of(context).copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (summary.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.caption2.of(context).copyWith(
                            color: AppColors.textSecondaryOf(context),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries) _DetailBubble(entry: entry),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onToggle,
            icon: GlyphIcon(
              AppGlyphs.chevronUp,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
            label: Text(
              '收起中间步骤',
              style: AppTextStyle.caption1.of(context).copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DetailBubble extends StatelessWidget {
  const _DetailBubble({required this.entry});

  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.45),
        borderRadius: AppRadius.all(AppCorner.sm),
        border: Border.all(color: scheme.outlineVariant, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.detailLabel.isEmpty ? '中间步骤' : entry.detailLabel,
            style: AppTextStyle.caption2.of(context).copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            entry.text,
            style: AppTextStyle.caption1.of(context).copyWith(
              color: AppColors.textSecondaryOf(context),
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.entry});

  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final isUser = entry.role == ChatRole.user;
    // 等第一个 token 的时候只显示一个小圈，别用「…」再换成文字造成跳变。
    final showSpinner = entry.streaming && entry.text.trim().isEmpty;
    final text = entry.streaming && !showSpinner
        ? '${entry.text}▍'
        : entry.text;

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.82,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isUser ? scheme.primary : AppColors.glassOf(scheme),
        borderRadius: AppRadius.all(AppCorner.md),
        border: isUser
            ? null
            : Border.all(
                color: AppColors.glassBorderOf(scheme),
                width: 0.5,
              ),
        boxShadow: isUser
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
      ),
      child: isUser
          ? SelectableText(
              text,
              style: AppTextStyle.callout
                  .of(context)
                  .copyWith(color: scheme.onPrimary, height: 1.42),
            )
          : showSpinner
          ? _TinySpinner(color: scheme.onSurfaceVariant)
          : AppMarkdown(
              text: text,
              style: AppTextStyle.callout
                  .of(context)
                  .copyWith(color: scheme.onSurface, height: 1.42),
            ),
    );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            bubble,
            if (entry.attachmentNames.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                child: Text(
                  '附件：${entry.attachmentNames.join('、')}',
                  style: AppTextStyle.caption2
                      .of(context)
                      .copyWith(color: AppColors.textSecondaryOf(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 首个 token 之前的等待指示：一个细线小圈，比跳动的点点安静。
class _TinySpinner extends StatelessWidget {
  const _TinySpinner({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
    );
  }
}

/// 输入框统计条的数据：优先用电脑端 `session-stats`，缺省时按消息用量累加。
class _ChatStats {
  const _ChatStats({
    required this.turns,
    this.steps,
    required this.input,
    required this.output,
    required this.cached,
  });

  final int turns;
  final int? steps;
  final int input;
  final int output;
  final int cached;

  factory _ChatStats.from(ChatState chat) {
    final projected = chat.stats;
    if (projected != null && !projected.isEmpty) {
      return _ChatStats(
        turns: projected.turns,
        steps: projected.steps > 0 ? projected.steps : null,
        input: projected.inputTokens,
        output: projected.outputTokens,
        cached: projected.cacheReadTokens,
      );
    }
    var turns = 0;
    var input = 0;
    var output = 0;
    var cached = 0;
    for (final entry in chat.entries) {
      if (entry.role == ChatRole.user) turns++;
      input += entry.promptTokens ?? 0;
      output += entry.completionTokens ?? 0;
      cached += entry.cachedTokens ?? 0;
    }
    return _ChatStats(
      turns: turns,
      input: input,
      output: output,
      cached: cached,
    );
  }

  bool get isEmpty => turns == 0 && input == 0 && output == 0;

  double? get cachePercent => input > 0 ? cached * 100 / input : null;

  static String compact(int value) => value >= 1000
      ? '${(value / 1000).toStringAsFixed(value >= 10000 ? 0 : 1)}k'
      : '$value';

  String get primaryLine =>
      steps == null ? '第 $turns 轮' : '第 $turns 轮 · $steps 步';

  String get secondaryLine {
    final percent = cachePercent;
    final buffer = StringBuffer('入${compact(input)}·出${compact(output)}');
    if (percent != null) buffer.write('·${percent.round()}%');
    return buffer.toString();
  }

  /// 手机底栏空间有限：轮次、输入、输出、缓存命中压成一条。
  String get oneLine {
    final percent = cachePercent;
    final buffer = StringBuffer();
    buffer.write('第$turns轮');
    if (steps != null && steps! > 0) buffer.write('·$steps步');
    buffer.write(' 入${compact(input)}·出${compact(output)}');
    if (percent != null) buffer.write('·命中${percent.round()}%');
    return buffer.toString();
  }
}

/// 输入条上的统计胶囊：轮次、输入、输出、缓存命中一条线展示。
class _ComposerStats extends StatelessWidget {
  const _ComposerStats({
    required this.stats,
    required this.onTap,
    required this.height,
  });

  final _ChatStats stats;
  final VoidCallback onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    const size = 10.5;
    final style = AppTextStyle.custom(
      context,
      size: size,
      leading: size * 1.2,
      weight: FontWeight.w500,
    ).copyWith(
      color: stats.isEmpty
          ? AppColors.textSecondaryOf(context)
          : scheme.onSurfaceVariant,
    );

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: height,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.72),
          borderRadius: AppRadius.full,
        ),
        child: Text(
          stats.isEmpty ? '暂无统计' : stats.oneLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
  }
}

/// 统计详情：轮次、步数、token、缓存命中、生成速度等。
class _StatsSheet extends ConsumerWidget {
  const _StatsSheet();

  static String _duration(int ms) {
    if (ms <= 0) return '—';
    if (ms < 1000) return '${ms}ms';
    final seconds = ms / 1000;
    if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
    return '${(seconds / 60).toStringAsFixed(1)}min';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider);
    final settings = ref.watch(settingsProvider);
    final projected = chat.stats;
    final local = _ChatStats.from(chat);
    final scheme = AppColors.of(context);

    final turns = projected?.turns ?? local.turns;
    final input = projected?.inputTokens ?? local.input;
    final output = projected?.outputTokens ?? local.output;
    final cached = projected?.cacheReadTokens ?? local.cached;
    final percent = input > 0 ? cached * 100 / input : null;
    final speed = projected?.tokensPerSecond;
    final firstToken = projected?.firstTokenMs;

    final rows = <(String, String)>[
      (
        '当前模型',
        settings.localHostModelEnabled
            ? (settings.localHostModelName.isNotEmpty
                  ? settings.localHostModelName
                  : settings.localHostModelId)
            : _ChatPageState._modelLabelOf(settings),
      ),
      ('上下文', contextLabel(settings.contextLimit)),
      ('思考强度', settings.thinking.label),
      ('轮次', '$turns'),
      (
        '步数',
        projected == null || projected.steps <= 0 ? '—' : '${projected.steps}',
      ),
      ('输入 token', _ChatStats.compact(input)),
      ('输出 token', _ChatStats.compact(output)),
      (
        '缓存命中',
        percent == null
            ? '—'
            : '${_ChatStats.compact(cached)}（${percent.round()}%）',
      ),
      ('生成速度', speed == null ? '—' : '${speed.toStringAsFixed(1)} tok/s'),
      ('首 token 平均', firstToken == null ? '—' : _duration(firstToken.round())),
      ('LLM 时长', _duration(projected?.llmMs ?? 0)),
      ('工具时长', _duration(projected?.toolMs ?? 0)),
      (
        '上下文占用',
        projected?.contextWindow == null
            ? '—'
            : '${_ChatStats.compact(projected!.pressureTokens ?? 0)} / '
                  '${_ChatStats.compact(projected.contextWindow!)}',
      ),
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: AppCard(
          radius: AppCorner.xl,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('会话统计', style: AppTextStyle.headline.of(context)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          row.$1,
                          style: AppTextStyle.footnote
                              .of(context)
                              .copyWith(
                                color: AppColors.textSecondaryOf(context),
                              ),
                        ),
                      ),
                      Text(
                        row.$2,
                        style: AppTextStyle.callout
                            .of(context)
                            .copyWith(
                              fontWeight: FontWeight.w600,
                              color: row.$2 == '—'
                                  ? AppColors.textSecondaryOf(context)
                                  : scheme.onSurface,
                            ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.hint,
    required this.stats,
    required this.onSend,
    required this.onAttach,
    required this.onPanel,
    required this.onStats,
    required this.onExpand,
    this.modelLabel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final String hint;
  final _ChatStats stats;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onPanel;
  final VoidCallback onStats;
  final VoidCallback onExpand;

  /// 电脑端显示当前会话模型；本地模式为 null，显示「模型设置」。
  final String? modelLabel;

  /// 加号、模型、上下文、思考、发送统一成同一个尺寸。
  static const double controlSize = 38;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    // 输入框随文字长高，最多到屏幕一半，再高就只滚动内部文本。
    final rawMax = MediaQuery.sizeOf(context).height * 0.5 - 96;
    final maxInputHeight = rawMax < 72 ? 72.0 : rawMax;
    return Padding(
      // safeBottom 已包含悬浮 dock 占位（Scaffold extendBody 传入），
      // 收起键盘时再留 12 的间距贴住 dock 上沿；弹起键盘时贴住键盘。
      padding: EdgeInsets.fromLTRB(8, 4, 8, keyboard > 0 ? 8 : safeBottom + 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        decoration: BoxDecoration(
          color: AppColors.glassOf(scheme),
          borderRadius: AppRadius.all(AppCorner.xxl),
          border: Border.all(
            color: AppColors.glassBorderOf(scheme),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: scheme.brightness == Brightness.dark ? 0.28 : 0.06,
              ),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxInputHeight),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 2, 0, 2),
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        enabled: enabled,
                        minLines: 1,
                        maxLines: null,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => onSend(),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 8,
                          ),
                          hintText: enabled ? '发消息给 DSH…' : hint,
                          hintStyle: AppTextStyle.callout
                              .of(context)
                              .copyWith(color: scheme.onSurfaceVariant),
                        ),
                        style: AppTextStyle.callout.of(context),
                      ),
                    ),
                  ),
                ),
                _MiniGlyphButton(
                  glyph: AppGlyphs.expand,
                  onTap: onExpand,
                  tooltip: '展开输入',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                // 加号与发送统一用深色圆钮，底栏左右对称。
                _ComposerCircle(
                  glyph: AppGlyphs.plus,
                  background: enabled
                      ? scheme.primary
                      : scheme.surfaceContainerHigh,
                  foreground: enabled
                      ? scheme.onPrimary
                      : scheme.onSurfaceVariant,
                  onTap: onAttach,
                  size: controlSize,
                ),
                const SizedBox(width: 6),
                // 中间两条胶囊刚好铺满手机宽度：统计 + 模型。
                Expanded(
                  child: _ComposerStats(
                    stats: stats,
                    onTap: onStats,
                    height: controlSize,
                  ),
                ),
                const SizedBox(width: 6),
                _ComposerPill(
                  label: modelLabel ?? '模型设置',
                  height: controlSize,
                  onTap: onPanel,
                ),
                const SizedBox(width: 6),
                _ComposerCircle(
                  glyph: AppGlyphs.send,
                  background: enabled
                      ? scheme.primary
                      : scheme.surfaceContainerHigh,
                  foreground: enabled
                      ? scheme.onPrimary
                      : scheme.onSurfaceVariant,
                  onTap: enabled ? onSend : null,
                  size: controlSize,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 展开输入：上方内容轻模糊，面板贴着键盘；面板 + 键盘合计约 2/3 屏。
/// 展开输入时，把上方对话做一层轻模糊，面板仍然留在页面里。
class _BlurSurface extends StatelessWidget {
  const _BlurSurface({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    return ClipRect(
      child: Stack(
        children: [
          child,
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpandedInputSheet extends StatelessWidget {
  const _ExpandedInputSheet({
    required this.controller,
    required this.enabled,
    required this.hint,
    required this.stats,
    required this.onAttach,
    required this.onPanel,
    required this.onStats,
    required this.onClose,
    required this.onSend,
    this.modelLabel,
  });

  final TextEditingController controller;
  final bool enabled;
  final String hint;
  final _ChatStats stats;
  final VoidCallback onAttach;
  final VoidCallback onPanel;
  final VoidCallback onStats;
  final VoidCallback onClose;
  final VoidCallback onSend;
  final String? modelLabel;

  static const double _controlSize = 42;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return SafeArea(
      top: false,
      bottom: false,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.cardOf(scheme),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppCorner.xl),
          ),
          border: Border.all(
            color: AppColors.glassBorderOf(scheme),
            width: 0.5,
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Text('展开输入', style: AppTextStyle.headline.of(context)),
                  const Spacer(),
                  _MiniGlyphButton(
                    glyph: AppGlyphs.collapse,
                    onTap: onClose,
                    tooltip: '收起',
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 2, 18, 6),
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  enabled: enabled,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: enabled ? '发消息给 DSH…' : hint,
                    hintStyle: AppTextStyle.callout
                        .of(context)
                        .copyWith(color: scheme.onSurfaceVariant),
                  ),
                  style: AppTextStyle.callout.of(context),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  _ComposerCircle(
                    glyph: AppGlyphs.plus,
                    background: enabled
                        ? scheme.primary
                        : scheme.surfaceContainerHigh,
                    foreground: enabled
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                    onTap: onAttach,
                    size: _controlSize,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _ComposerStats(
                      stats: stats,
                      onTap: onStats,
                      height: _controlSize,
                    ),
                  ),
                  const SizedBox(width: 6),
                  _ComposerPill(
                    label: modelLabel ?? '模型设置',
                    height: _controlSize,
                    onTap: onPanel,
                  ),
                  const SizedBox(width: 6),
                  _ComposerCircle(
                    glyph: AppGlyphs.send,
                    background: enabled
                        ? scheme.primary
                        : scheme.surfaceContainerHigh,
                    foreground: enabled
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                    onTap: enabled ? onSend : null,
                    size: _controlSize,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部小图标按钮（展开 / 收起）。
class _MiniGlyphButton extends StatelessWidget {
  const _MiniGlyphButton({
    required this.glyph,
    required this.onTap,
    required this.tooltip,
  });

  final IconData glyph;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Material(
          color: Colors.transparent,
          shape: AppShape.circle,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: GlyphIcon(glyph, size: 17, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}

/// 输入条上的小胶囊：模型、上下文、思考强度。高度与圆形按钮一致。
class _ComposerPill extends StatelessWidget {
  const _ComposerPill({
    required this.label,
    required this.onTap,
    required this.height,
  });

  final String label;
  final VoidCallback onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return SizedBox(
      height: height,
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: AppShape.full,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 108),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.caption2
                        .of(context)
                        .copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                const SizedBox(width: 3),
                GlyphIcon(
                  AppGlyphs.chevronDown,
                  size: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 选择态胶囊：模型与思考强度共用。
class _SelectPill extends StatelessWidget {
  const _SelectPill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 电脑离线时模型仍展示，但置灰不可选。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final disabled = !enabled;
    final base = disabled ? scheme.onSurfaceVariant : scheme.onSurface;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: disabled ? 0.06 : 0.14)
              : scheme.surfaceContainerHigh.withValues(
                  alpha: disabled ? 0.45 : 1,
                ),
          borderRadius: AppRadius.full,
        ),
        child: Text(
          label,
          style: AppTextStyle.caption1
              .of(context)
              .copyWith(
                color: disabled
                    ? base.withValues(alpha: 0.55)
                    : (selected ? scheme.primary : base),
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
        ),
      ),
    );
  }
}

/// 模型面板里的一家供应商：名称 + 末四位 + 模型胶囊。
class _ModelGroup extends StatelessWidget {
  const _ModelGroup({
    required this.credential,
    required this.models,
    required this.selected,
    required this.onSelect,
  });

  final ApiCredential credential;
  final List<String> models;
  final bool selected;
  final ValueChanged<String> onSelect;

  static String _labelOf(ModelProvider? provider, String model) {
    if (provider != null) {
      for (final option in provider.models) {
        if (option.value == model) return option.label;
      }
    }
    return model;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final provider = providerById(credential.providerId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                credential.name,
                style: AppTextStyle.callout
                    .of(context)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 6),
              Text(
                '••••${credential.last4}',
                style: AppTextStyle.caption2
                    .of(context)
                    .copyWith(color: scheme.onSurfaceVariant),
              ),
              if (selected) ...[
                const SizedBox(width: 8),
                Text(
                  '当前',
                  style: AppTextStyle.caption2
                      .of(context)
                      .copyWith(color: scheme.primary),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final model in models)
                _SelectPill(
                  label: _labelOf(provider, model),
                  selected: selected && credential.model == model,
                  onTap: () => onSelect(model),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 电脑端模型：按 provider 分组，点一下就把选择发给电脑上的会话。
class _PcModelGroups extends StatelessWidget {
  const _PcModelGroups({required this.chat, required this.onSelect});

  final ChatState chat;
  final ValueChanged<HostModelOption> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final groups = <String, List<HostModelOption>>{};
    for (final option in chat.models) {
      groups.putIfAbsent(option.providerName, () => <HostModelOption>[]).add(option);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in groups.entries) ...[
          Row(
            children: [
              Text(
                entry.key,
                style: AppTextStyle.callout
                    .of(context)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 6),
              Text(
                '${entry.value.length} 个模型',
                style: AppTextStyle.caption2
                    .of(context)
                    .copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in entry.value)
                _SelectPill(
                  label: option.label,
                  selected: option.matches(
                    chat.modelProvider,
                    chat.modelId,
                  ),
                  onTap: () => onSelect(option),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

/// 模型、上下文长度、思考强度合并成一个面板，三个胶囊都打开它。
class _ComposerPanel extends ConsumerStatefulWidget {
  const _ComposerPanel();

  @override
  ConsumerState<_ComposerPanel> createState() => _ComposerPanelState();
}

class _ComposerPanelState extends ConsumerState<_ComposerPanel> {
  late int _contextValue;
  late ThinkingLevel _thinking;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _contextValue = settings.contextLimit;
    _thinking = settings.thinking;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final chat = ref.watch(chatProvider);
    final link = ref.watch(linkProvider);
    final scope = ref.watch(chatScopeProvider);
    final pcMode = scope != ChatScope.local && settings.pcLinkPluginEnabled;
    final pcWork = scope == ChatScope.pc;
    final scheme = AppColors.of(context);
    final secondary = AppTextStyle.footnote
        .of(context)
        .copyWith(color: scheme.onSurfaceVariant);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.78;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: AppCard(
            radius: AppCorner.xl,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        pcMode ? '电脑端模型' : '模型与上下文',
                        style: AppTextStyle.headline.of(context),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                  if (pcMode) ...[
                    Text(
                      pcWork
                          ? '直接切换电脑上这条会话使用的模型；在电脑上新增的模型会自动同步。'
                          : '纯文本对话用的模型来自电脑；这里只影响电脑端「对话」，不动工作会话。',
                      style: secondary,
                    ),
                    const SizedBox(height: 12),
                    if (chat.models.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            if (chat.modelsLoading) ...[
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 10),
                            ],
                            Expanded(
                              child: Text(
                                chat.modelsLoading
                                    ? '正在读取电脑上的模型…'
                                    : (chat.modelsError ?? '电脑上没有可用模型'),
                                style: secondary,
                              ),
                            ),
                            TextButton(
                              onPressed: () => ref
                                  .read(chatProvider.notifier)
                                  .requestModels(),
                              child: const Text('重新读取'),
                            ),
                          ],
                        ),
                      )
                    else
                      _PcModelGroups(
                        chat: chat,
                        onSelect: (option) {
                          ref
                              .read(chatProvider.notifier)
                              .selectHostModel(option.provider, option.model);
                          Navigator.of(context).pop();
                        },
                      ),
                    if (chat.modelsError != null &&
                        chat.models.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(chat.modelsError!, style: secondary),
                    ],
                  ] else ...[
                    if (link.accountModels.isNotEmpty) ...[
                      Row(
                        children: [
                          Text(
                            'DeepSeek 账号',
                            style: AppTextStyle.callout
                                .of(context)
                                .copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '电脑',
                            style: AppTextStyle.caption2
                                .of(context)
                                .copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        link.status.isConnected
                            ? '使用电脑上已登录的 DeepSeek 账号，按账号余额计费；电脑需保持连接。'
                            : '电脑未连接：下面是上次同步的模型，连上电脑后才能使用。',
                        style: secondary,
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final option in link.accountModels)
                            _SelectPill(
                              label: option.label,
                              enabled: link.status.isConnected,
                              selected:
                                  settings.localHostModelEnabled &&
                                  settings.localHostModelProvider ==
                                      option.provider &&
                                  settings.localHostModelId == option.model,
                              onTap: () => ref
                                  .read(settingsProvider.notifier)
                                  .setLocalHostModel(
                                    provider: option.provider,
                                    model: option.model,
                                    name: option.label,
                                  ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '选择本机 API Key 模型即可切回直连。',
                        style: AppTextStyle.caption2
                            .of(context)
                            .copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 14),
                      Divider(height: 1, color: scheme.outlineVariant),
                      const SizedBox(height: 14),
                    ],
                    if (settings.credentials.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          link.accountModels.isEmpty
                              ? '还没有保存的 API Key，先到「我的 → API Key 登录」添加。'
                              : '没有本机 API Key；当前使用电脑账号模型。',
                          style: secondary,
                        ),
                      )
                    else ...[
                      Text(
                        '本机 API Key',
                        style: AppTextStyle.callout
                            .of(context)
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 300),
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final credential in settings.credentials)
                              _ModelGroup(
                                credential: credential,
                                models: _ChatPageState._modelsOf(credential),
                                selected:
                                    !settings.localHostModelEnabled &&
                                    settings.activeProviderId ==
                                        credential.providerId,
                                onSelect: (model) async {
                                  await ref
                                      .read(settingsProvider.notifier)
                                      .selectApiCredential(
                                        providerId: credential.providerId,
                                        model: model,
                                      );
                                },
                              ),
                          ],
                        ),
                      ),
                    ],
                    Divider(height: 1, color: scheme.outlineVariant),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text('上下文长度', style: AppTextStyle.headline.of(context)),
                        const Spacer(),
                        Text(
                          contextLabel(_contextValue),
                          style: AppTextStyle.headline
                              .of(context)
                              .copyWith(color: scheme.primary),
                        ),
                      ],
                    ),
                    Slider(
                      value: _ChatPageState._contextIndex(_contextValue)
                          .toDouble(),
                      min: 0,
                      max: (kContextOptions.length - 1).toDouble(),
                      divisions: kContextOptions.length - 1,
                      label: contextLabel(_contextValue),
                      onChanged: (value) {
                        final next = kContextOptions[value.round()];
                        setState(() => _contextValue = next);
                        ref
                            .read(settingsProvider.notifier)
                            .setContextLimit(next);
                      },
                    ),
                    Text('每次最多带多少历史发给模型，越大越费 token。', style: secondary),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Text('思考强度', style: AppTextStyle.headline.of(context)),
                        const Spacer(),
                        Text(
                          _thinking.label,
                          style: AppTextStyle.headline
                              .of(context)
                              .copyWith(color: scheme.primary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final level in ThinkingLevel.values)
                          _SelectPill(
                            label: level.label,
                            selected: _thinking == level,
                            onTap: () {
                              setState(() => _thinking = level);
                              ref
                                  .read(settingsProvider.notifier)
                                  .setThinking(level);
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '按供应商的 reasoning_effort 透传；默认交给模型自行决定。',
                      style: secondary,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          Navigator.of(context, rootNavigator: true).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ApiKeyPage(),
                            ),
                          );
                        },
                        child: const Text('管理 API Key'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 胶囊两端的圆形按钮。
class _ComposerCircle extends StatelessWidget {
  const _ComposerCircle({
    required this.glyph,
    required this.background,
    required this.foreground,
    required this.onTap,
    this.size = 38,
  });

  final IconData glyph;
  final Color background;
  final Color foreground;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: background,
        shape: AppShape.circle,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Center(child: GlyphIcon(glyph, size: 20, color: foreground)),
        ),
      ),
    );
  }
}

class _LocalComposerAction {
  const _LocalComposerAction({required this.plugin, required this.capability});

  final LocalPlugin plugin;
  final LocalPluginCapability capability;
}

Future<String?> _showAttachSheet(
  BuildContext context,
  List<_LocalComposerAction> localActions,
) async {
  final scheme = AppColors.of(context);
  final screen = MediaQuery.sizeOf(context);
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    builder: (context) => Padding(
      // 菜单抬到离底部约 1/4 屏高的位置，不再贴着手势条。
      padding: EdgeInsets.fromLTRB(12, 0, 12, screen.height * 0.22),
      child: AppCard(
        radius: AppCorner.xl,
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 10),
              child: Text(
                '添加附件',
                style: AppTextStyle.headline.of(context),
              ),
            ),
            Row(
              children: [
                for (final (glyph, label, value) in const [
                  (AppGlyphs.camera, '拍照', 'camera'),
                  (AppGlyphs.photo, '从相册选择', 'photo'),
                  (AppGlyphs.file, '选择文件', 'file'),
                ])
                  Expanded(
                    child: _AttachTile(
                      glyph: glyph,
                      label: label,
                      onTap: () => Navigator.of(context).pop(value),
                    ),
                  ),
              ],
            ),
            if (localActions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Divider(height: 1, color: scheme.outlineVariant),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: Text(
                  '本地插件动作',
                  style: AppTextStyle.caption2.of(context).copyWith(
                    color: AppColors.textSecondaryOf(context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (var i = 0; i < localActions.length; i++)
                SettingRow(
                  title: localActions[i].capability.label,
                  subtitle:
                      '${localActions[i].plugin.name} · ${localActions[i].plugin.description.isNotEmpty ? localActions[i].plugin.description : '在输入框插入预设文本'}',
                  leading: GlyphIcon(
                    AppGlyphs.plugins,
                    size: 22,
                    color: scheme.primary,
                  ),
                  trailing: const SizedBox(height: 1),
                  onTap: () => Navigator.of(context).pop('local:$i'),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// 附件菜单里的大号入口：52 的圆底 + 文字，比原来的小图标好点。
class _AttachTile extends StatelessWidget {
  const _AttachTile({
    required this.glyph,
    required this.label,
    required this.onTap,
  });

  final IconData glyph;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.all(AppCorner.lg),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: GlyphIcon(glyph, size: 24, color: scheme.primary),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.caption1.of(context).copyWith(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 输入框上方已选附件：缩略图 + 文件名 + 移除。
class _AttachmentBar extends StatelessWidget {
  const _AttachmentBar({required this.attachments, required this.onRemove});

  final List<ChatAttachment> attachments;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    return SizedBox(
      height: 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final attachment = attachments[index];
          return Container(
            constraints: const BoxConstraints(maxWidth: 210),
            padding: const EdgeInsets.fromLTRB(5, 5, 6, 5),
            decoration: BoxDecoration(
              color: AppColors.cardOf(scheme),
              borderRadius: AppRadius.all(AppCorner.sm),
              border: Border.all(color: scheme.outlineVariant, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: AppRadius.all(6),
                  child: attachment.isImage
                      ? Image.file(
                          attachment.file,
                          width: 34,
                          height: 34,
                          fit: BoxFit.cover,
                        )
                      : Container(
                          width: 34,
                          height: 34,
                          color: scheme.surfaceContainerHigh,
                          child: Center(
                            child: GlyphIcon(
                              AppGlyphs.file,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.caption1.of(context),
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => onRemove(index),
                  borderRadius: AppRadius.full,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: GlyphIcon(
                      AppGlyphs.close,
                      size: 14,
                      color: AppColors.textSecondaryOf(context),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
