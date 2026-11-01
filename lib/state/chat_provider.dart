import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat_attachment.dart';
import '../data/model_providers.dart';
import '../data/settings.dart';
import '../protocol/direct_chat.dart';
import '../protocol/host_state.dart';
import '../protocol/models.dart';
import 'app_providers.dart';
import 'auth_provider.dart';
import 'local_plugins_provider.dart';
import 'records_provider.dart';
import 'skills_provider.dart';

/// 对话所属的一侧：手机本地对话、电脑端纯文本对话，或电脑端工作会话。
enum ChatScope {
  local,

  /// 电脑端「对话」：只走模型，不建 Agent 会话、不跑工具。
  pcChat,

  /// 电脑端「工作」：完整 Agent 会话，能调工具、读写工作区。
  pc,
}

/// 当前选中的对话侧。电脑端互联插件关闭时始终是 [ChatScope.local]。
final chatScopeProvider = NotifierProvider<ChatScopeNotifier, ChatScope>(
  ChatScopeNotifier.new,
);

class ChatScopeNotifier extends Notifier<ChatScope> {
  @override
  ChatScope build() {
    final saved = ref.watch(initialSettingsProvider).chatScope;
    return switch (saved) {
      'pc' => ChatScope.pc,
      'pcChat' => ChatScope.pcChat,
      _ => ChatScope.local,
    };
  }

  void select(ChatScope scope) {
    state = scope;
    // 记住用户的选择：扫码连电脑后默认继续停在「电脑端」。
    unawaited(ref.read(settingsProvider.notifier).setChatScope(scope.name));
  }
}

@immutable
class ChatState {
  const ChatState({
    this.sessionId,
    this.entries = const <ChatEntry>[],
    this.streaming = false,
    this.error,
    this.stats,
    this.models = const <HostModelOption>[],
    this.modelProvider,
    this.modelId,
    this.modelsLoading = false,
    this.modelsError,
  });

  final String? sessionId;
  final List<ChatEntry> entries;

  /// 正在接收流式输出。
  final bool streaming;
  final String? error;

  /// 电脑端 `session-stats` 投影；本地对话没有这个帧，保持 null。
  final SessionStats? stats;

  /// 电脑端会话可用模型（由 `models` 帧下发）。
  final List<HostModelOption> models;

  /// 当前电脑端会话选中的模型；新会话时是目录默认模型。
  final String? modelProvider;
  final String? modelId;
  final bool modelsLoading;
  final String? modelsError;

  bool get isEmpty => entries.isEmpty;

  HostModelOption? get currentModel {
    for (final option in models) {
      if (option.matches(modelProvider, modelId)) return option;
    }
    return null;
  }

  ChatState copyWith({
    String? sessionId,
    List<ChatEntry>? entries,
    bool? streaming,
    String? error,
    bool clearError = false,
    SessionStats? stats,
    List<HostModelOption>? models,
    String? modelProvider,
    String? modelId,
    bool? modelsLoading,
    String? modelsError,
    bool clearModelsError = false,
  }) => ChatState(
    sessionId: sessionId ?? this.sessionId,
    entries: entries ?? this.entries,
    streaming: streaming ?? this.streaming,
    error: clearError ? null : (error ?? this.error),
    stats: stats ?? this.stats,
    models: models ?? this.models,
    modelProvider: modelProvider ?? this.modelProvider,
    modelId: modelId ?? this.modelId,
    modelsLoading: modelsLoading ?? this.modelsLoading,
    modelsError: clearModelsError ? null : (modelsError ?? this.modelsError),
  );
}

final chatProvider = NotifierProvider<ChatNotifier, ChatState>(
  ChatNotifier.new,
);

/// 手机端直连的“仅模型”请求（本地或电脑对话侧）。
class _GatewayChat {
  const _GatewayChat({
    required this.scope,
    required this.sessionId,
    required this.attemptId,
    required this.provider,
    required this.model,
  });

  final ChatScope scope;
  final String sessionId;
  final String attemptId;
  final String provider;
  final String model;
}

class ChatNotifier extends Notifier<ChatState> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  DirectChatClient? _direct;
  Timer? _snapshotRetry;

  /// attemptId → 正在流式渲染的条目。
  String? _activeAttempt;
  int _localClock = 0;

  /// 两侧对话各自独立，切换不互相覆盖。
  final Map<ChatScope, ChatState> _scopeStates = <ChatScope, ChatState>{};
  final Map<ChatScope, String> _pendingText = <ChatScope, String>{};
  final Set<String> _namedSessions = <String>{};

  /// 新会话还没创建时选中的模型：等首条消息创建会话后由 Host 先落选择再执行。
  String? _pendingModelProvider;
  String? _pendingModelId;

  /// 纯文本通道（不经过 Agent / 工具）正在进行的请求。
  final Map<String, _GatewayChat> _gatewayChats = <String, _GatewayChat>{};

  @override
  ChatState build() {
    final client = ref.watch(gatewayProvider);
    _subscription = client.frames.listen(_onFrame);
    ref.onDispose(() {
      _subscription?.cancel();
      _snapshotRetry?.cancel();
      _direct?.cancel();
      _direct?.dispose();
    });

    // 只在首次构建时读取启动策略：监听整份设置会让改动主题/开关时重建
    // 本 Notifier，从而丢掉当前会话。
    final settings = ref.read(settingsProvider);
    if (settings.startStrategy != StartStrategy.fresh &&
        settings.pinnedSessionId != null) {
      unawaited(Future.microtask(() => attach(settings.pinnedSessionId!)));
    }
    return const ChatState();
  }

  ChatScope get _scope => ref.read(chatScopeProvider);

  ChatScope get _effectiveScope {
    final scope = _scope;
    if (scope != ChatScope.local &&
        !ref.read(settingsProvider).pcLinkPluginEnabled) {
      return ChatScope.local;
    }
    return scope;
  }

  /// 电脑侧当前使用的状态槽：对话（纯文本）或工作（Agent 会话）。
  ChatScope get _pcSide =>
      _scope == ChatScope.pcChat ? ChatScope.pcChat : ChatScope.pc;

  bool get _onPcSide => _scope != ChatScope.local;

  ChatState _stateFor(ChatScope scope) =>
      _scopeStates[scope] ?? const ChatState();

  void _write(ChatScope scope, ChatState next) {
    _scopeStates[scope] = next;
    if (_scope == scope) state = next;
  }

  /// 切换「本地 / 电脑端」：保留各自会话，切回来时继续原来的对话。
  void setScope(ChatScope scope) {
    if (_scope == scope) return;
    _scopeStates[_scope] = state;
    ref.read(chatScopeProvider.notifier).select(scope);
    final next = _stateFor(scope);
    state = next;
    if (scope == ChatScope.local) return;
    if (scope == ChatScope.pcChat) {
      // 纯文本侧只需要模型目录，不订阅 Agent 会话。
      if (next.models.isEmpty) requestModels();
      return;
    }
    final sessionId = next.sessionId;
    if (sessionId != null) {
      _subscribe(sessionId);
    } else {
      requestModels();
    }
  }

  /// 拉取电脑端模型目录 / 当前会话的模型选择。
  void requestModels() {
    final client = ref.read(gatewayProvider);
    if (!client.status.isConnected) return;
    final target = _pcSide;
    final current = _scopeStates[target] ?? const ChatState();
    _write(
      target,
      current.copyWith(modelsLoading: true, clearModelsError: true),
    );
    client.send({
      'type': 'models',
      if (target == ChatScope.pc && current.sessionId != null)
        'sessionId': current.sessionId,
    });
  }

  /// 切换电脑端模型：工作侧已有会话立刻下发；对话侧与新建工作会话先记住。
  void selectHostModel(String provider, String model) {
    final target = _pcSide;
    final current = _scopeStates[target] ?? const ChatState();
    _write(
      target,
      current.copyWith(
        modelProvider: provider,
        modelId: model,
        clearModelsError: true,
      ),
    );
    if (target == ChatScope.pc && current.sessionId != null) {
      ref.read(gatewayProvider).send({
        'type': 'model-select',
        'sessionId': current.sessionId,
        'provider': provider,
        'model': model,
      });
    } else {
      _pendingModelProvider = provider;
      _pendingModelId = model;
    }
  }

  static String _nowId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// 首轮内容截断成短标题：换行压成空格，最多 12 个字。
  static String shortTitle(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return '新对话';
    final runes = cleaned.runes.toList(growable: false);
    if (runes.length <= 12) return cleaned;
    return '${String.fromCharCodes(runes.take(12))}…';
  }

  static String _cleanGeneratedTitle(String raw) {
    var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    text = text.replaceAll(RegExp('[「」“”『』"]'), '').replaceAll("'", '');
    text = text.replaceFirst(RegExp(r'^(标题|会话名|名称)[:：]'), '').trim();
    text = text.replaceAll(RegExp(r'[。！？!?，,、；;：:.]$'), '');
    final runes = text.runes.toList(growable: false);
    if (runes.length > 12) {
      text = String.fromCharCodes(runes.take(12));
    }
    return text.trim();
  }

  /// 打开一条已有会话：先读本地缓存，再订阅电脑端基线。
  Future<void> attach(String sessionId) async {
    final scope = _effectiveScope;
    if (state.sessionId == sessionId && state.entries.isNotEmpty) return;
    final local = await ref.read(sessionStoreProvider).loadEntries(sessionId);
    if (scope == ChatScope.local) {
      _write(scope, ChatState(sessionId: sessionId, entries: local));
    } else {
      // 电脑侧两条通道共用模型目录，但会话内容各自独立。
      final side = _scopeStates[scope] ?? const ChatState();
      _write(
        scope,
        ChatState(
          sessionId: sessionId,
          entries: local,
          models: side.models,
          modelProvider: side.modelProvider,
          modelId: side.modelId,
        ),
      );
    }
    if (scope == ChatScope.local) {
      _subscribe(sessionId);
      unawaited(ref.read(settingsProvider.notifier).rememberSession(sessionId));
      return;
    }
    // 电脑端「对话」的历史只在本机与电脑的 JSONL 里，不进 Agent 订阅。
    if (scope == ChatScope.pcChat) {
      if (state.models.isEmpty) requestModels();
      return;
    }
    // 工作会话的统计帧不随快照下发，先用本地缓存兜底，连上后再刷新。
    unawaited(_restoreCachedStats(scope, sessionId));
    _subscribe(sessionId);
  }

  Future<void> _restoreCachedStats(ChatScope scope, String sessionId) async {
    final raw = await ref.read(sessionStoreProvider).loadStats(sessionId);
    if (raw == null || raw.isEmpty) return;
    final current = _stateFor(scope);
    if (current.sessionId != sessionId || current.stats != null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _write(
        scope,
        current.copyWith(
          stats: SessionStats.fromFrame(decoded.cast<String, dynamic>()),
        ),
      );
    } catch (_) {
      // 缓存损坏时忽略，等在线帧覆盖。
    }
  }

  /// 新建会话：只清空当前这一侧，另一侧原样保留。
  void startFresh() {
    _activeAttempt = null;
    _direct?.cancel();
    _direct = null;
    final scope = _effectiveScope;
    if (scope == ChatScope.pc || scope == ChatScope.pcChat) {
      // 新会话沿用刚才选的模型，用户不用每开一个对话都重选。
      final side = _scopeStates[scope] ?? const ChatState();
      _write(
        scope,
        ChatState(
          models: side.models,
          modelProvider: side.modelProvider,
          modelId: side.modelId,
        ),
      );
      return;
    }
    _write(scope, const ChatState());
  }

  void _subscribe(String sessionId) {
    final client = ref.read(gatewayProvider);
    final pc = _scopeStates[ChatScope.pc];
    if (pc != null && pc.sessionId == sessionId) {
      _write(
        ChatScope.pc,
        pc.copyWith(modelsLoading: true, clearModelsError: true),
      );
    }
    client.send({
      'type': 'subscribe',
      'sessionId': sessionId,
      'assistantStream': true,
    });
    // 输入框统计条：订阅后立刻取一次基线，之后由 turn/end 刷新。
    client.send({'type': 'session-stats', 'sessionId': sessionId});

    // 慢网络或刚重连时基线可能丢一帧；如果几秒后仍没有任何条目，
    // 自动重订阅一次，避免停在空白的「电脑端新对话」。
    _snapshotRetry?.cancel();
    _snapshotRetry = Timer(const Duration(seconds: 4), () {
      if (state.sessionId != sessionId || state.entries.isNotEmpty) return;
      if (!ref.read(gatewayProvider).status.isConnected) return;
      client.send({
        'type': 'subscribe',
        'sessionId': sessionId,
        'assistantStream': true,
      });
    });
  }

  Future<void> send(
    String text, {
    List<ChatAttachment> attachments = const <ChatAttachment>[],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return;
    final scope = _effectiveScope;
    final settings = ref.read(settingsProvider);

    if (scope == ChatScope.pc) {
      if (!ref.read(linkProvider).status.isConnected) {
        _write(
          scope,
          state.copyWith(error: '电脑未连接：电脑端对话暂不可发送'),
        );
        return;
      }
      await _sendHost(scope, trimmed, attachments);
      return;
    }

    // 电脑端「对话」：纯文本、只走模型，历史手机与电脑各存一份。
    if (scope == ChatScope.pcChat) {
      if (!ref.read(linkProvider).status.isConnected) {
        _write(
          scope,
          state.copyWith(error: '电脑未连接：电脑端对话暂不可发送'),
        );
        return;
      }
      await _sendGatewayChat(scope, trimmed, attachments);
      return;
    }

    // 本地侧：选电脑账号模型时走「仅模型」通道，不创建 Agent 会话；
    // 否则优先用本机 API Key 直连。
    if (settings.localHostModelEnabled) {
      await _sendGatewayChat(ChatScope.local, trimmed, attachments);
      return;
    }
    if (settings.apiKeyModeEnabled) {
      await _sendDirect(trimmed, attachments);
      return;
    }
    await _sendHost(scope, trimmed, attachments);
  }

  /// 仅模型通道：把历史直接发给电脑上的模型，不创建 Agent 会话、不挂工具。
  Future<void> _sendGatewayChat(
    ChatScope scope,
    String text,
    List<ChatAttachment> attachments,
  ) async {
    final settings = ref.read(settingsProvider);
    final scoped = _stateFor(scope);
    if (!ref.read(linkProvider).status.isConnected) {
      _write(
        scope,
        scoped.copyWith(error: '电脑未连接：账号模型需要电脑在线'),
      );
      return;
    }
    if (attachments.any((item) => item.isImage)) {
      _write(
        scope,
        scoped.copyWith(
          error: scope == ChatScope.pcChat
              ? '电脑端对话暂不支持图片'
              : '账号模型暂不支持图片，切到本机 API Key 后再发送',
        ),
      );
      return;
    }
    var prompt = text;
    for (final file in attachments.where((item) => !item.isImage)) {
      prompt =
          '$prompt\n\n文件：${file.name}\n```\n${file.textContent ?? ''}\n```';
    }
    if (prompt.trim().isEmpty) return;
    final selected = scope == ChatScope.pcChat
        ? _pcChatSelection(scoped)
        : (
            provider: settings.localHostModelProvider,
            model: settings.localHostModelId,
          );
    if (selected.provider.isEmpty || selected.model.isEmpty) {
      _write(
        scope,
        scoped.copyWith(
          error: scope == ChatScope.pcChat
              ? '电脑上还没有可用模型，先点模型名读取一次'
              : '还没有选择电脑账号模型',
        ),
      );
      return;
    }
    final provider = selected.provider;
    final model = selected.model;

    final budget = math.max(settings.contextLimit, 1024);
    var used = _estimateTokens(prompt);
    final messages = <Map<String, dynamic>>[];
    for (final entry in scoped.entries.reversed) {
      if (entry.streaming || entry.text.trim().isEmpty) continue;
      final tokens = _estimateTokens(entry.text);
      if (used + tokens > budget) break;
      used += tokens;
      messages.insert(0, {
        'role': entry.role == ChatRole.user ? 'user' : 'assistant',
        'content': [
          {'type': 'text', 'text': entry.text},
        ],
      });
    }
    messages.add({
      'role': 'user',
      'content': [
        {'type': 'text', 'text': prompt},
      ],
    });
    // 手机端插件只在本地对话生效；电脑端会话不带手机模板。
    if (scope == ChatScope.local) {
      final systemPrompt = _localSystemPrompt();
      if (systemPrompt.isNotEmpty) {
        messages.insert(0, {
          'role': 'system',
          'content': [
            {'type': 'text', 'text': systemPrompt},
          ],
        });
      }
    }

    final fresh = scoped.sessionId == null;
    final prefix = scope == ChatScope.pcChat ? 'pcc' : 'local';
    final sessionId =
        scoped.sessionId ??
        '$prefix-${DateTime.now().microsecondsSinceEpoch}';
    _localClock++;
    final requestId = _nowId('g');
    final userEntry = ChatEntry(
      id: _nowId('u'),
      role: ChatRole.user,
      text: text,
      seq: _localClock,
      attachmentNames: [for (final item in attachments) item.name],
    );
    _write(
      scope,
      scoped.copyWith(
        sessionId: sessionId,
        entries: [
          ...scoped.entries,
          userEntry,
          ChatEntry(
            id: requestId,
            role: ChatRole.assistant,
            text: '',
            streaming: true,
            seq: _localClock,
          ),
        ],
        streaming: true,
        clearError: true,
      ),
    );
    if (fresh) _pendingText[scope] = text;
    unawaited(ref.read(sessionStoreProvider).saveEntry(sessionId, userEntry));
    unawaited(_ensureSession(scope, sessionId, text));
    _gatewayChats[requestId] = _GatewayChat(
      scope: scope,
      sessionId: sessionId,
      attemptId: requestId,
      provider: provider,
      model: model,
    );
    ref.read(gatewayProvider).send({
      'type': 'chat',
      'requestId': requestId,
      'chatId': sessionId,
      'provider': provider,
      'model': model,
      'scope': scope == ChatScope.pcChat ? 'pc' : 'local',
      // 电脑端对话在电脑上也留一份 JSONL，离线时两边都还能翻。
      'store': scope == ChatScope.pcChat,
      'messages': messages,
    });
  }

  /// 电脑端「对话」用的模型：优先会话里选中的，其次目录默认。
  ({String provider, String model}) _pcChatSelection(ChatState scoped) {
    final provider = scoped.modelProvider ?? '';
    final model = scoped.modelId ?? '';
    if (provider.isNotEmpty && model.isNotEmpty) {
      return (provider: provider, model: model);
    }
    for (final option in scoped.models) {
      return (provider: option.provider, model: option.model);
    }
    final fallback = ref.read(settingsProvider);
    return (
      provider: fallback.localHostModelProvider,
      model: fallback.localHostModelId,
    );
  }

  Future<void> _sendHost(
    ChatScope scope,
    String text,
    List<ChatAttachment> attachments,
  ) async {
    if (!ref.read(authProvider).authorized) {
      _write(
        scope,
        state.copyWith(error: '还没有配置登录，先用 API Key 登录或连接电脑'),
      );
      return;
    }
    if (attachments.isNotEmpty) {
      _write(
        scope,
        state.copyWith(
          error: scope == ChatScope.pc
              ? '电脑端暂不支持附件，切到本地 API Key 后再发送'
              : '电脑账号模型暂不支持附件，切到本机 API Key 后再发送',
        ),
      );
      return;
    }
    final client = ref.read(gatewayProvider);
    if (!client.status.isConnected) {
      _write(scope, state.copyWith(error: '连接已断开，请先重连'));
      return;
    }
    _localClock++;
    final entry = ChatEntry(
      id: _nowId('u'),
      role: ChatRole.user,
      text: text,
      seq: _localClock,
    );
    _pendingText[scope] = text;
    _write(
      scope,
      state.copyWith(
        entries: [...state.entries, entry],
        streaming: true,
        clearError: true,
      ),
    );
    // 电脑端：新会话要带上刚选的模型；已有会话若刚切过模型，同样补一次选择。
    Map<String, String>? selection;
    if (scope == ChatScope.pc) {
      final provider = _pendingModelProvider ?? state.modelProvider;
      final model = _pendingModelId ?? state.modelId;
      if (state.sessionId == null && provider != null && model != null) {
        selection = {'provider': provider, 'model': model};
      }
    } else {
      final settings = ref.read(settingsProvider);
      if (settings.localHostModelEnabled) {
        selection = {
          'provider': settings.localHostModelProvider,
          'model': settings.localHostModelId,
        };
      }
    }
    client.send({
      'type': 'message',
      'text': text,
      'mode': 'queue',
      if (state.sessionId != null) 'sessionId': state.sessionId,
      'model': ?selection,
    });
  }

  /// API Key 模式：不经过网关，直接把历史消息发给供应商的 OpenAI 兼容接口。
  Future<void> _sendDirect(
    String text,
    List<ChatAttachment> attachments,
  ) async {
    final settings = ref.read(settingsProvider);
    final credential = settings.activeCredential;
    if (credential == null) {
      state = state.copyWith(error: '还没有登录任何供应商的 API Key');
      return;
    }

    final apiKey = await ref
        .read(secureStoreProvider)
        .readProviderKey(credential.providerId);
    final baseUrl = credential.baseUrl.isNotEmpty
        ? credential.baseUrl
        : (providerById(credential.providerId)?.baseUrl ?? '');
    final model = credential.model.isNotEmpty
        ? credential.model
        : (providerById(credential.providerId)?.model ?? '');
    if (apiKey == null || apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) {
      state = state.copyWith(error: 'API Key 配置不完整，请到「我的 → 登录方式」重新填写');
      return;
    }

    // 文本文件直接拼进正文；图片按 OpenAI 多模态格式放进同一条用户消息。
    var prompt = text;
    for (final file in attachments.where((item) => !item.isImage)) {
      prompt =
          '$prompt\n\n文件：${file.name}\n```\n${file.textContent ?? ''}\n```';
    }
    if (prompt.trim().isEmpty) prompt = '请看这些图片。';
    final images = attachments.where((item) => item.isImage).toList();
    final imageUrls = <String>[];
    for (final image in images) {
      final url = await image.toDataUrl();
      if (url != null) imageUrls.add(url);
    }
    final Object content = imageUrls.isEmpty
        ? prompt
        : <Map<String, dynamic>>[
            {'type': 'text', 'text': prompt},
            for (final url in imageUrls)
              {
                'type': 'image_url',
                'image_url': {'url': url},
              },
          ];

    final fresh = state.sessionId == null;
    final sessionId =
        state.sessionId ?? 'local-${DateTime.now().microsecondsSinceEpoch}';
    _localClock++;
    final attemptId = _nowId('a');
    final userEntry = ChatEntry(
      id: _nowId('u'),
      role: ChatRole.user,
      text: text,
      seq: _localClock,
      attachmentNames: [for (final item in attachments) item.name],
    );
    // 按「上下文长度」从后往前装历史，超出的旧消息不再发送。
    final budget = math.max(settings.contextLimit, 1024);
    var used = _estimateTokens(prompt);
    final history = <Map<String, dynamic>>[];
    for (final entry in state.entries.reversed) {
      if (entry.streaming || entry.text.trim().isEmpty) continue;
      final tokens = _estimateTokens(entry.text);
      if (used + tokens > budget) break;
      used += tokens;
      history.insert(0, {
        'role': entry.role == ChatRole.user ? 'user' : 'assistant',
        'content': entry.text,
      });
    }
    history.add({'role': 'user', 'content': content});
    // 本地纯文本对话：启用中的角色/提示词模板注入到最前面。
    final systemPrompt = _localSystemPrompt();
    if (systemPrompt.isNotEmpty) {
      history.insert(0, {'role': 'system', 'content': systemPrompt});
    }

    _direct?.cancel();
    final client = DirectChatClient();
    _direct = client;

    _write(
      ChatScope.local,
      state.copyWith(
        sessionId: sessionId,
        entries: [
          ...state.entries,
          userEntry,
          ChatEntry(
            id: attemptId,
            role: ChatRole.assistant,
            text: '',
            streaming: true,
            seq: _localClock,
          ),
        ],
        streaming: true,
        clearError: true,
      ),
    );
    if (fresh) _pendingText[ChatScope.local] = text;
    unawaited(
      ref.read(sessionStoreProvider).saveEntry(sessionId, userEntry),
    );
    unawaited(_ensureSession(ChatScope.local, sessionId, text));

    try {
      await for (final delta in client.stream(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        messages: history,
        reasoningEffort: settings.thinking.apiValue,
      )) {
        final entries = [...state.entries];
        final index = entries.indexWhere((entry) => entry.id == attemptId);
        if (index < 0) break;
        entries[index] = entries[index].copyWith(
          text: entries[index].text + delta,
          streaming: true,
        );
        _write(ChatScope.local, state.copyWith(entries: entries, streaming: true));
      }
      final entries = [...state.entries];
      final index = entries.indexWhere((entry) => entry.id == attemptId);
      if (index >= 0) {
        final reply = entries[index];
        final usage = client.usage;
        entries[index] = reply.copyWith(
          text: reply.text.isEmpty ? '（模型没有返回内容）' : reply.text,
          streaming: false,
          promptTokens: usage?.promptTokens,
          completionTokens: usage?.completionTokens,
          cachedTokens: usage?.cachedTokens,
        );
      }
      _write(
        ChatScope.local,
        state.copyWith(entries: entries, streaming: false),
      );
      _persist(entries);
      unawaited(_finishTurn(ChatScope.local, sessionId));
    } catch (error) {
      final entries = state.entries
          .where((entry) => entry.id != attemptId)
          .toList(growable: false);
      _write(
        ChatScope.local,
        state.copyWith(
          entries: entries,
          streaming: false,
          error: '对话失败：$error',
        ),
      );
    } finally {
      client.dispose();
      if (identical(_direct, client)) _direct = null;
    }
  }

  /// 新会话先落库：标题先用首轮内容截断，避免记录页出现「没有记录」。
  Future<void> _ensureSession(
    ChatScope scope,
    String sessionId,
    String seed,
  ) async {
    final store = ref.read(sessionStoreProvider);
    final existing = await store.readSessionTitle(sessionId);
    if (existing != null && existing.isNotEmpty) {
      await store.touchSession(sessionId);
      return;
    }
    await store.upsertSession(
      SessionSummary(
        sessionId: sessionId,
        title: shortTitle(seed),
        updatedAt: _nowSeconds(),
      ),
    );
    unawaited(ref.read(recordsProvider.notifier).reloadLocal());
  }

  /// 本地纯文本对话要注入的系统提示：启用的技能在前，插件模板在后。
  /// 只取文本，不执行 skill 里的脚本；总长度设上限，避免挤占上下文。
  String _localSystemPrompt() {
    final parts = <String>[];
    for (final skill in ref.read(skillsProvider).enabledSkills) {
      parts.add('# 技能：${skill.name}\n${skill.description}\n\n${skill.body}');
    }
    for (final template in ref.read(localPluginsProvider).chatTemplates) {
      parts.add(template.prompt);
    }
    if (parts.isEmpty) return '';
    final joined = parts.join('\n\n---\n\n');
    const maxChars = 24000;
    return joined.length <= maxChars ? joined : joined.substring(0, maxChars);
  }

  /// 粗略估算 token：中文接近 1 字 1 token，英文约 4 字符 1 token。
  static int _estimateTokens(String text) {
    var cjk = 0;
    var other = 0;
    for (final rune in text.runes) {
      if (rune <= 0x7F) {
        other++;
      } else {
        cjk++;
      }
    }
    return cjk + (other / 4).ceil();
  }

  /// 一轮回复结束：刷新时间戳；开启「模型命名」时用当前模型生成 ≤12 字标题。
  Future<void> _finishTurn(ChatScope scope, String sessionId) async {
    final store = ref.read(sessionStoreProvider);
    await store.touchSession(sessionId, updatedAt: _nowSeconds());
    unawaited(ref.read(recordsProvider.notifier).reloadLocal());
    final settings = ref.read(settingsProvider);
    if (!settings.modelNaming) return;
    if (!_namedSessions.add(sessionId)) return;
    final credential = settings.activeCredential;
    if (credential == null) return;
    final apiKey = await ref
        .read(secureStoreProvider)
        .readProviderKey(credential.providerId);
    if (apiKey == null || apiKey.isEmpty) return;

    final seed = _pendingText[scope] ?? '';
    if (seed.trim().isEmpty) return;
    final client = DirectChatClient();
    try {
      final buffer = StringBuffer();
      await for (final delta in client.stream(
        baseUrl: credential.baseUrl.isNotEmpty
            ? credential.baseUrl
            : (providerById(credential.providerId)?.baseUrl ?? ''),
        apiKey: apiKey,
        model: credential.model.isNotEmpty
            ? credential.model
            : (providerById(credential.providerId)?.model ?? ''),
        messages: [
          const {
            'role': 'system',
            'content':
                '你是会话命名助手。根据用户的第一条消息，用不超过 12 个汉字概括主题。'
                '只输出标题本身，不要引号、标点或解释。',
          },
          {'role': 'user', 'content': seed},
        ],
      )) {
        buffer.write(delta);
      }
      final title = _cleanGeneratedTitle(buffer.toString());
      if (title.isEmpty) return;
      await store.renameSession(sessionId, title);
      unawaited(ref.read(recordsProvider.notifier).applyTitle(sessionId, title));
    } catch (_) {
      // 命名失败不影响对话，保留首轮截断的标题。
    } finally {
      client.dispose();
    }
  }

  void _onFrame(Map<String, dynamic> frame) {
    switch (frame['kind']) {
      case 'chat-delta':
        _applyGatewayChatDelta(frame);
      case 'chat-done':
        _finishGatewayChat(frame);
      case 'chat-error':
        _failGatewayChat(frame);
      case 'chat-cancelled':
        _cancelGatewayChat(frame);
      case 'sent':
        final sessionId = frame['sessionId'];
        if (sessionId is String) {
          final scope = _scope;
          final fresh = state.sessionId == null;
          final changed = state.sessionId != sessionId;
          _write(scope, state.copyWith(sessionId: sessionId));
          if (changed) {
            _subscribe(sessionId);
            if (scope == ChatScope.local) {
              unawaited(
                ref.read(settingsProvider.notifier).rememberSession(sessionId),
              );
            }
          }
          if (fresh) {
            unawaited(
              _ensureSession(scope, sessionId, _pendingText[scope] ?? ''),
            );
          }
          if (scope == ChatScope.pc) {
            _pendingModelProvider = null;
            _pendingModelId = null;
          }
          _persist(state.entries);
        }
      case 'session-snapshot':
        _applySnapshot(frame);
      case 'session-stats':
        final sessionId = frame['sessionId'];
        if (sessionId is String && sessionId == state.sessionId) {
          state = state.copyWith(stats: SessionStats.fromFrame(frame));
          unawaited(
            ref
                .read(sessionStoreProvider)
                .saveStats(sessionId, jsonEncode(frame)),
          );
        }
      case 'assistant-stream':
        _applyStream(frame);
      case 'event':
        _applyEvent(frame);
      case 'models':
        _applyModels(frame);
      case 'model-selected':
        _applyModelSelected(frame);
      case 'error':
        if (frame['requestType'] == 'message') {
          state = state.copyWith(
            streaming: false,
            error: (frame['message'] ?? '发送失败').toString(),
          );
        } else if (frame['requestType'] == 'model-select') {
          final target = _pcSide;
          final pc = _scopeStates[target] ?? state;
          _write(
            target,
            pc.copyWith(
              modelsLoading: false,
              modelsError: (frame['message'] ?? '切换模型失败').toString(),
            ),
          );
        }
      case 'hello':
        if (_scope == ChatScope.pcChat) {
          requestModels();
          return;
        }
        final sessionId = state.sessionId;
        if (sessionId != null && _scope == ChatScope.pc) {
          _subscribe(sessionId);
        } else if (_scope == ChatScope.pc) {
          requestModels();
        }
    }
  }

  void _applyGatewayChatDelta(Map<String, dynamic> frame) {
    final requestId = frame['requestId'];
    if (requestId is! String) return;
    final pending = _gatewayChats[requestId];
    final delta = frame['text'];
    if (pending == null || delta is! String || delta.isEmpty) return;
    final scoped = _stateFor(pending.scope);
    final entries = [...scoped.entries];
    final index = entries.indexWhere((entry) => entry.id == pending.attemptId);
    if (index < 0) return;
    entries[index] = entries[index].copyWith(
      text: entries[index].text + delta,
      streaming: true,
    );
    _write(
      pending.scope,
      scoped.copyWith(entries: entries, streaming: true),
    );
  }

  void _finishGatewayChat(Map<String, dynamic> frame) {
    final requestId = frame['requestId'];
    if (requestId is! String) return;
    final pending = _gatewayChats.remove(requestId);
    if (pending == null) return;
    final scoped = _stateFor(pending.scope);
    final entries = [...scoped.entries];
    final index = entries.indexWhere((entry) => entry.id == pending.attemptId);
    final usage = frame['usage'] is Map
        ? (frame['usage'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final fallback = frame['text'];
    if (index >= 0) {
      entries[index] = entries[index].copyWith(
        text: entries[index].text.isEmpty
            ? (fallback is String && fallback.isNotEmpty
                  ? fallback
                  : '（模型没有返回内容）')
            : entries[index].text,
        streaming: false,
        promptTokens: _intOf(usage['inputTokens']),
        completionTokens: _intOf(usage['outputTokens']),
        cachedTokens: _intOf(
          usage['cachedInputTokens'] ?? usage['cacheReadTokens'],
        ),
      );
    }
    _write(
      pending.scope,
      scoped.copyWith(entries: entries, streaming: false),
    );
    _persist(entries);
    unawaited(
      ref
          .read(sessionStoreProvider)
          .touchSession(pending.sessionId, updatedAt: _nowSeconds()),
    );
    unawaited(ref.read(recordsProvider.notifier).reloadLocal());
  }

  void _failGatewayChat(Map<String, dynamic> frame) {
    final requestId = frame['requestId'];
    if (requestId is! String) return;
    final pending = _gatewayChats.remove(requestId);
    if (pending == null) return;
    final scoped = _stateFor(pending.scope);
    final entries = scoped.entries
        .where((entry) => entry.id != pending.attemptId)
        .toList(growable: false);
    _write(
      pending.scope,
      scoped.copyWith(
        entries: entries,
        streaming: false,
        error: (frame['message'] ?? '对话失败').toString(),
      ),
    );
  }

  void _cancelGatewayChat(Map<String, dynamic> frame) {
    final requestId = frame['requestId'];
    if (requestId is! String) return;
    final pending = _gatewayChats.remove(requestId);
    if (pending == null) return;
    final scoped = _stateFor(pending.scope);
    final entries = scoped.entries
        .where((entry) => entry.id != pending.attemptId)
        .toList(growable: false);
    _write(
      pending.scope,
      scoped.copyWith(entries: entries, streaming: false),
    );
  }

  static int? _intOf(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  void _applyModels(Map<String, dynamic> frame) {
    if (!_onPcSide) return;
    final target = _pcSide;
    final pc = _scopeStates[target] ?? state;
    final frameSession = frame['sessionId'];
    if (frameSession is String &&
        pc.sessionId != null &&
        frameSession != pc.sessionId) {
      return;
    }
    // 工作侧新会话默认目录可能在创建会话之后才到，此时以会话级目录为准。
    if (target == ChatScope.pc && frameSession == null && pc.sessionId != null) {
      return;
    }
    final options = HostModelOption.listFromGroups(frame['groups']);
    final current = frame['current'] is Map
        ? (frame['current'] as Map).cast<String, dynamic>()
        : (frame['default'] is Map
              ? (frame['default'] as Map).cast<String, dynamic>()
              : const <String, dynamic>{});
    final provider = current['provider']?.toString() ?? '';
    final model = current['model']?.toString() ?? '';
    _write(
      target,
      pc.copyWith(
        models: options,
        modelsLoading: false,
        clearModelsError: true,
        modelProvider: provider.isEmpty ? pc.modelProvider : provider,
        modelId: model.isEmpty ? pc.modelId : model,
      ),
    );
  }

  void _applyModelSelected(Map<String, dynamic> frame) {
    if (!_onPcSide) return;
    final target = _pcSide;
    final pc = _scopeStates[target] ?? state;
    if (frame['sessionId'] is String &&
        target == ChatScope.pc &&
        frame['sessionId'] != pc.sessionId) {
      return;
    }
    final selected = frame['selected'];
    if (selected is! Map) return;
    final provider = selected['provider']?.toString() ?? '';
    final model = selected['model']?.toString() ?? '';
    if (provider.isEmpty || model.isEmpty) return;
    _write(
      target,
      pc.copyWith(
        modelProvider: provider,
        modelId: model,
        clearModelsError: true,
      ),
    );
  }

  void _applySnapshot(Map<String, dynamic> frame) {
    final sessionId = frame['sessionId'];
    if (sessionId is! String || sessionId != state.sessionId) return;
    final events = frame['events'];
    if (events is! List) return;

    final entries = <ChatEntry>[];
    for (final raw in events) {
      if (raw is! Map) continue;
      entries.addAll(
        _entriesFromHistoryEvent(raw.cast<String, dynamic>()),
      );
    }

    final stream = frame['assistantStream'];
    if (stream is Map) {
      final active = stream['activeAttempt'];
      if (active is Map) {
        final attemptId = (active['attemptId'] ?? '').toString();
        final text = _textOfActiveAttempt(active);
        if (attemptId.isNotEmpty && text.isNotEmpty) {
          _activeAttempt = attemptId;
          entries.add(
            ChatEntry(
              id: attemptId,
              role: ChatRole.assistant,
              text: text,
              streaming: true,
            ),
          );
        }
      }
    }

    // 电脑端基线为空时保留本地缓存：记录以本地为准，空快照不能清空对话。
    for (final entry in state.entries) {
      if (!entry.id.startsWith('u-')) continue;
      final duplicated = entries.any(
        (e) => e.role == ChatRole.user && e.text == entry.text,
      );
      if (!duplicated) entries.add(entry);
    }
    if (entries.isEmpty && state.entries.isNotEmpty) {
      entries.addAll(state.entries);
    }

    state = ChatState(
      sessionId: sessionId,
      entries: entries,
      streaming: _activeAttempt != null,
      stats: state.stats,
      models: state.models,
      modelProvider: state.modelProvider,
      modelId: state.modelId,
      modelsLoading: state.modelsLoading,
      modelsError: state.modelsError,
    );
    _scopeStates[_scope] = state;
    _persist(entries);
  }

  String _textOfActiveAttempt(Map<Object?, Object?> active) {
    final stream = active['stream'];
    if (stream is! List) return '';
    final buffer = StringBuffer();
    for (final raw in stream) {
      if (raw is! Map) continue;
      if (raw['type'] != 'text-chunks') continue;
      final texts = raw['texts'];
      if (texts is List) {
        for (final part in texts) {
          if (part is String) buffer.write(part);
        }
      }
    }
    return buffer.toString();
  }

  /// DSH 事件 → 展示条目。
  ///
  /// 主消息只有用户输入与助手正文；推理、工具调用、工具结果都标成
  /// `detail`，由界面默认折叠，点开再看细节。
  List<ChatEntry> _entriesFromHistoryEvent(Map<String, dynamic> event) {
    final type = event['type'];
    final data = event['data'] is Map
        ? (event['data'] as Map).cast<String, dynamic>()
        : event;
    final seq = event['seq'] is int ? event['seq'] as int : 0;
    final out = <ChatEntry>[];
    switch (type) {
      case 'user/message':
        final content = _contentText(data['content']);
        final text = content.isNotEmpty
            ? content
            : (data['text'] is String ? data['text'] as String : '');
        if (text.trim().isNotEmpty) {
          out.add(
            ChatEntry(
              id: 'h-$seq-u',
              role: ChatRole.user,
              text: text.trim(),
              seq: seq,
            ),
          );
        }
      case 'assistant/message':
        final message = data['message'] is Map
            ? (data['message'] as Map).cast<String, dynamic>()
            : data;
        var reasoning = _contentText(message['content'], reasoning: true);
        if (reasoning.isEmpty && data['reasoning'] is String) {
          reasoning = (data['reasoning'] as String).trim();
        }
        if (reasoning.isNotEmpty) {
          out.add(
            ChatEntry(
              id: 'h-$seq-r',
              role: ChatRole.assistant,
              text: _clip(reasoning, 6000),
              seq: seq,
              detail: true,
              detailLabel: '思考过程',
            ),
          );
        }
        var text = _contentText(message['content']);
        if (text.isEmpty) {
          final wireText = message['text'] ?? data['text'];
          if (wireText is String) text = wireText;
        }
        if (text.trim().isNotEmpty) {
          // 带工具调用的助手正文是中间步骤，不和最终回答混在一起。
          final hasTools =
              data['tools'] is List && (data['tools'] as List).isNotEmpty;
          out.add(
            ChatEntry(
              id: 'h-$seq-a',
              role: ChatRole.assistant,
              text: text.trim(),
              seq: seq,
              detail: hasTools,
              detailLabel: hasTools ? '助手步骤' : '',
            ),
          );
        }
      case 'tool/call':
        final name = (data['name'] ?? '工具').toString();
        final args = (data['arguments'] ?? '').toString();
        out.add(
          ChatEntry(
            id: 'h-$seq-tc',
            role: ChatRole.assistant,
            text: _clip(args, 2000),
            seq: seq,
            detail: true,
            detailLabel: '调用工具 · $name',
          ),
        );
      case 'tool/result':
        final message = data['message'];
        final text = message is Map
            ? _contentText(message['content'])
            : (data['text'] is String ? data['text'] as String : '');
        if (text.trim().isNotEmpty) {
          out.add(
            ChatEntry(
              id: 'h-$seq-tr',
              role: ChatRole.assistant,
              text: _clip(text.trim(), 4000),
              seq: seq,
              detail: true,
              detailLabel: '工具结果',
            ),
          );
        }
    }
    return out;
  }

  static String _contentText(Object? content, {bool reasoning = false}) {
    if (content is String) return reasoning ? '' : content;
    if (content is! List) return '';
    final parts = <String>[];
    for (final block in content) {
      if (block is! Map) continue;
      final type = block['type'];
      final text = block['text'];
      if (text is! String || text.isEmpty) continue;
      if (reasoning && type == 'reasoning') parts.add(text);
      if (!reasoning && type == 'text') parts.add(text);
    }
    return parts.join('\n\n').trim();
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}\n…';

  void _applyEvent(Map<String, dynamic> frame) {
    final sessionId = frame['sessionId'];
    if (sessionId is! String || sessionId != state.sessionId) return;
    final event = frame['event'];
    if (event is! Map) return;
    final payload = event.cast<String, dynamic>();
    final type = payload['type'];
    final parsed = _entriesFromHistoryEvent(payload);

    switch (type) {
      case 'assistant/message':
        final entries = [...state.entries];
        final details = parsed.where((item) => item.detail).toList();
        final main = parsed.where((item) => !item.detail).toList();
        final streamingIndex = entries.lastIndexWhere(
          (e) => e.role == ChatRole.assistant && e.streaming,
        );
        var insertAt = streamingIndex >= 0 ? streamingIndex : entries.length;
        for (final detail in details) {
          if (entries.any((e) => e.id == detail.id)) continue;
          entries.insert(insertAt, detail);
          insertAt++;
        }
        if (main.isNotEmpty) {
          final text = main.first.text;
          final index = entries.lastIndexWhere(
            (e) => e.role == ChatRole.assistant && e.streaming,
          );
          if (index >= 0) {
            entries[index] = entries[index].copyWith(
              text: text,
              streaming: false,
            );
          } else if (!entries.any(
            (e) =>
                !e.detail &&
                e.role == ChatRole.assistant &&
                e.text == text,
          )) {
            entries.add(main.first);
          }
          _activeAttempt = null;
          state = state.copyWith(entries: entries, streaming: false);
          _scopeStates[_scope] = state;
          _persist(entries);
          unawaited(_finishTurn(_scope, sessionId));
        } else if (details.isNotEmpty) {
          state = state.copyWith(entries: entries);
          _scopeStates[_scope] = state;
          _persist(entries);
        }
      case 'tool/call':
      case 'tool/result':
        if (parsed.isEmpty) return;
        final entries = [...state.entries];
        for (final detail in parsed) {
          if (entries.any((e) => e.id == detail.id)) continue;
          entries.add(detail);
        }
        state = state.copyWith(entries: entries);
        _scopeStates[_scope] = state;
        _persist(entries);
      case 'user/message':
        final main = parsed.where((item) => !item.detail).toList();
        if (main.isEmpty) return;
        final entries = [...state.entries];
        if (!entries.any((e) => !e.detail && e.text == main.first.text)) {
          entries.add(main.first);
        }
        state = state.copyWith(entries: entries);
        _scopeStates[_scope] = state;
        _persist(main);
      case 'turn/end':
        state = state.copyWith(streaming: false);
        _scopeStates[_scope] = state;
        // 一轮结束后刷新统计条（轮次、步数、token、缓存命中）。
        final sid = state.sessionId;
        if (sid != null) {
          ref.read(gatewayProvider).send({
            'type': 'session-stats',
            'sessionId': sid,
          });
        }
    }
  }

  void _applyStream(Map<String, dynamic> frame) {
    final sessionId = frame['sessionId'];
    if (sessionId is! String || sessionId != state.sessionId) return;
    final inner = frame['frame'];
    if (inner is! Map) return;
    final attemptId = (inner['attemptId'] ?? '').toString();
    final type = inner['type'];

    if (type == 'start') {
      if (attemptId.isEmpty) return;
      _activeAttempt = attemptId;
      final entries = [...state.entries];
      if (!entries.any((e) => e.id == attemptId)) {
        entries.add(
          ChatEntry(
            id: attemptId,
            role: ChatRole.assistant,
            text: '',
            streaming: true,
          ),
        );
      }
      state = state.copyWith(entries: entries, streaming: true);
      _scopeStates[_scope] = state;
      return;
    }

    if (type == 'chunk') {
      final chunk = inner['chunk'];
      if (chunk is! Map) return;
      if (chunk['type'] != 'text-delta') return;
      final delta = chunk['text'];
      if (delta is! String || delta.isEmpty) return;
      final entries = [...state.entries];
      final index = entries.indexWhere((e) => e.id == attemptId);
      if (index >= 0) {
        entries[index] = entries[index].copyWith(
          text: entries[index].text + delta,
          streaming: true,
        );
      } else {
        entries.add(
          ChatEntry(
            id: attemptId,
            role: ChatRole.assistant,
            text: delta,
            streaming: true,
          ),
        );
      }
      _activeAttempt = attemptId;
      state = state.copyWith(entries: entries, streaming: true);
      _scopeStates[_scope] = state;
      return;
    }

    if (type == 'end') {
      final outcome = inner['outcome'];
      final kind = outcome is Map ? outcome['kind'] : null;
      if (kind == 'abandoned') {
        final entries = state.entries
            .where((e) => e.id != attemptId)
            .toList(growable: false);
        _activeAttempt = null;
        state = state.copyWith(entries: entries, streaming: false);
        _scopeStates[_scope] = state;
      }
    }
  }

  void _persist(List<ChatEntry> entries) {
    final sessionId = state.sessionId;
    if (sessionId == null) return;
    final store = ref.read(sessionStoreProvider);
    for (final entry in entries) {
      if (entry.streaming) continue;
      unawaited(store.saveEntry(sessionId, entry));
    }
  }

  static double estimatedTokens(String text) =>
      math.max(1, (text.runes.length / 3.2).round()).toDouble();
}
