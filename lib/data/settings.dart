import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model_providers.dart';
import '../protocol/host_state.dart';

/// 冷启动打开哪个对话。
enum StartStrategy { fresh, restoreLast, pinned }

/// 思考强度：默认不干预，其余按供应商的 `reasoning_effort` 透传。
enum ThinkingLevel { standard, low, high, xhigh }

extension ThinkingLevelX on ThinkingLevel {
  String get label => switch (this) {
    ThinkingLevel.standard => '默认',
    ThinkingLevel.low => '低',
    ThinkingLevel.high => '高',
    ThinkingLevel.xhigh => '极高',
  };

  /// 发给供应商的值；默认强度不发，交给模型自己决定。
  String? get apiValue => switch (this) {
    ThinkingLevel.standard => null,
    ThinkingLevel.low => 'low',
    ThinkingLevel.high => 'high',
    ThinkingLevel.xhigh => 'xhigh',
  };
}

/// 上下文长度滑块的档位（单位 token）。默认 1M。
const kContextOptions = <int>[
  32000,
  64000,
  128000,
  200000,
  256000,
  512000,
  1000000,
];

/// 把 512000 显示成 512K、1000000 显示成 1M。
String contextLabel(int tokens) {
  if (tokens >= 1000000) return '1M';
  return '${(tokens / 1000).round()}K';
}

/// 一个已登录的供应商 API Key（Key 本体在 secure storage，这里只留展示信息）。
@immutable
class ApiCredential {
  const ApiCredential({
    required this.providerId,
    required this.name,
    required this.baseUrl,
    required this.last4,
    required this.model,
    this.models = const <String>[],
  });

  final String providerId;
  final String name;
  final String baseUrl;
  final String last4;

  /// 当前选中的模型。
  final String model;

  /// 这个供应商下可供选择的模型（预设 + 用户手填）。
  final List<String> models;

  ApiCredential copyWith({
    String? name,
    String? baseUrl,
    String? last4,
    String? model,
    List<String>? models,
  }) => ApiCredential(
    providerId: providerId,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    last4: last4 ?? this.last4,
    model: model ?? this.model,
    models: models ?? this.models,
  );

  Map<String, dynamic> toJson() => {
    'providerId': providerId,
    'name': name,
    'baseUrl': baseUrl,
    'last4': last4,
    'model': model,
    'models': models,
  };

  factory ApiCredential.fromJson(Map<String, dynamic> json) {
    final models = (json['models'] is List)
        ? (json['models'] as List).whereType<String>().toList(growable: false)
        : const <String>[];
    return ApiCredential(
      providerId: (json['providerId'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      baseUrl: (json['baseUrl'] ?? '').toString(),
      last4: (json['last4'] ?? '').toString(),
      model: (json['model'] ?? '').toString(),
      models: models,
    );
  }
}

/// 客户端本地设置。API Key 只记录「已配置」与末四位，真实 Key 在 secure storage。
@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.startStrategy = StartStrategy.fresh,
    this.streaming = true,
    this.autoScroll = true,
    this.autoReconnect = true,
    this.keepDays = 7,
    this.modelNaming = false,
    this.pcLinkPluginEnabled = false,
    this.contextLimit = 1000000,
    this.thinking = ThinkingLevel.standard,
    this.model = 'deepseek-v4-flash',
    this.baseUrl = '',
    this.credentials = const <ApiCredential>[],
    this.activeProviderId = '',
    this.localHostModelProvider = '',
    this.localHostModelId = '',
    this.localHostModelName = '',
    this.hostModelsCache = const <HostModelOption>[],
    this.pinnedSessionId,
    this.guestMode = false,
    this.hostMode = false,
    this.authBaseUrl = defaultAuthBaseUrl,
    this.chatScope = 'local',
  });

  /// 预览版默认指向模拟器里的 mock gateway；真机调试时在「我的 → 高级」改成电脑局域网地址。
  static const defaultAuthBaseUrl = 'http://10.0.2.2:3081';

  final ThemeMode themeMode;
  final StartStrategy startStrategy;
  final bool streaming;
  final bool autoScroll;
  final bool autoReconnect;

  /// 登录保持天数，协议参照 dsh-mobile-bridge 默认 7 天，范围 1–365。
  final int keepDays;

  /// 开启后首轮对话结束会用当前模型花少量额度自动起名；关闭则截取首轮内容。
  final bool modelNaming;

  /// 「电脑端互联」本地插件是否启用。
  final bool pcLinkPluginEnabled;

  /// 发送历史时最多带多少 token，默认 1M。
  final int contextLimit;

  /// 思考强度。
  final ThinkingLevel thinking;

  final String model;
  final String baseUrl;

  /// 同时登录的多家供应商 API Key。
  final List<ApiCredential> credentials;

  /// 当前用于对话的供应商。
  final String activeProviderId;

  /// 本地模式选中的电脑 DeepSeek 账号模型；非空时优先经电脑发送。
  final String localHostModelProvider;
  final String localHostModelId;
  final String localHostModelName;

  /// 电脑下发过的 DeepSeek 账号模型目录缓存：断开/重启/取消配对后仍可展示，
  /// 只是需要重新连上电脑才能真正调用。
  final List<HostModelOption> hostModelsCache;

  /// 「始终打开指定对话」时选中的会话。
  final String? pinnedSessionId;

  /// 登录页点「稍后登录」后进入主界面（未登录，不能对话）。
  final bool guestMode;

  /// 当前登录态来自扫码配对的电脑；需要跨重启保留，否则会被 API Key 模式覆盖。
  final bool hostMode;

  /// 账号登录服务地址（设备码接口与登录网页所在 Origin）。
  final String authBaseUrl;

  /// 上次使用的对话侧：local / pc。扫码连接电脑后会自动切到 pc 并记住。
  final String chatScope;

  ApiCredential? get activeCredential {
    for (final credential in credentials) {
      if (credential.providerId == activeProviderId) return credential;
    }
    return credentials.isEmpty ? null : credentials.first;
  }

  bool get apiKeyConfigured => credentials.isNotEmpty;

  /// 只要登录过任意一家供应商，就能用 API Key 直连对话。
  bool get apiKeyModeEnabled => activeCredential != null;

  /// 本地模式正在使用电脑的 DeepSeek 账号模型。
  bool get localHostModelEnabled => localHostModelId.isNotEmpty;

  String get apiKeyProvider => activeCredential?.providerId ?? '';
  String get apiKeyLast4 => activeCredential?.last4 ?? '';
  String get apiKeyModel => activeCredential?.model ?? '';
  List<String> get apiKeyModels => activeCredential?.models ?? const <String>[];
  String get apiKeyBaseUrl => activeCredential?.baseUrl ?? '';

  AppSettings copyWith({
    ThemeMode? themeMode,
    StartStrategy? startStrategy,
    bool? streaming,
    bool? autoScroll,
    bool? autoReconnect,
    int? keepDays,
    bool? modelNaming,
    bool? pcLinkPluginEnabled,
    int? contextLimit,
    ThinkingLevel? thinking,
    String? model,
    String? baseUrl,
    List<ApiCredential>? credentials,
    String? activeProviderId,
    String? localHostModelProvider,
    String? localHostModelId,
    String? localHostModelName,
    List<HostModelOption>? hostModelsCache,
    String? pinnedSessionId,
    bool clearPinnedSession = false,
    bool? guestMode,
    bool? hostMode,
    String? authBaseUrl,
    String? chatScope,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    startStrategy: startStrategy ?? this.startStrategy,
    streaming: streaming ?? this.streaming,
    autoScroll: autoScroll ?? this.autoScroll,
    autoReconnect: autoReconnect ?? this.autoReconnect,
    keepDays: keepDays ?? this.keepDays,
    modelNaming: modelNaming ?? this.modelNaming,
    pcLinkPluginEnabled: pcLinkPluginEnabled ?? this.pcLinkPluginEnabled,
    contextLimit: contextLimit ?? this.contextLimit,
    thinking: thinking ?? this.thinking,
    model: model ?? this.model,
    baseUrl: baseUrl ?? this.baseUrl,
    credentials: credentials ?? this.credentials,
    activeProviderId: activeProviderId ?? this.activeProviderId,
    localHostModelProvider:
        localHostModelProvider ?? this.localHostModelProvider,
    localHostModelId: localHostModelId ?? this.localHostModelId,
    localHostModelName: localHostModelName ?? this.localHostModelName,
    hostModelsCache: hostModelsCache ?? this.hostModelsCache,
    pinnedSessionId: clearPinnedSession
        ? null
        : (pinnedSessionId ?? this.pinnedSessionId),
    guestMode: guestMode ?? this.guestMode,
    hostMode: hostMode ?? this.hostMode,
    authBaseUrl: authBaseUrl ?? this.authBaseUrl,
    chatScope: chatScope ?? this.chatScope,
  );
}

class SettingsStore {
  static const _kThemeMode = 'settings.themeMode';
  static const _kStartStrategy = 'settings.startStrategy';
  static const _kStreaming = 'settings.streaming';
  static const _kAutoScroll = 'settings.autoScroll';
  static const _kAutoReconnect = 'settings.autoReconnect';
  static const _kKeepDays = 'settings.keepDays';
  static const _kModelNaming = 'settings.modelNaming';
  static const _kPcLinkPlugin = 'settings.pcLinkPlugin';
  static const _kContextLimit = 'settings.contextLimit';
  static const _kThinking = 'settings.thinking';
  static const _kModel = 'settings.model';
  static const _kBaseUrl = 'settings.baseUrl';
  static const _kCredentials = 'settings.apiCredentials';
  static const _kActiveProvider = 'settings.activeProvider';
  static const _kPinnedSession = 'settings.pinnedSession';
  static const _kGuestMode = 'settings.guestMode';
  static const _kHostMode = 'settings.hostMode';
  static const _kChatScope = 'settings.chatScope';
  static const _kAuthBaseUrl = 'settings.authBaseUrl';
  static const _kLocalHostProvider = 'settings.localHostModelProvider';
  static const _kLocalHostModel = 'settings.localHostModelId';
  static const _kLocalHostName = 'settings.localHostModelName';
  static const _kHostModelsCache = 'settings.hostModelsCache';

  // 旧版单供应商字段，仅用于一次性迁移。
  static const _kLegacyLast4 = 'settings.apiKeyLast4';
  static const _kLegacyProvider = 'settings.apiKeyProvider';
  static const _kLegacyModel = 'settings.apiKeyModel';
  static const _kLegacyModels = 'settings.apiKeyModels';
  static const _kLegacyBaseUrl = 'settings.apiKeyBaseUrl';

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final credentials = _loadCredentials(prefs);
    return AppSettings(
      themeMode: _themeModeOf(prefs.getString(_kThemeMode)),
      startStrategy: _strategyOf(prefs.getString(_kStartStrategy)),
      streaming: prefs.getBool(_kStreaming) ?? true,
      autoScroll: prefs.getBool(_kAutoScroll) ?? true,
      autoReconnect: prefs.getBool(_kAutoReconnect) ?? true,
      keepDays: prefs.getInt(_kKeepDays) ?? 7,
      modelNaming: prefs.getBool(_kModelNaming) ?? false,
      pcLinkPluginEnabled: prefs.getBool(_kPcLinkPlugin) ?? false,
      contextLimit: prefs.getInt(_kContextLimit) ?? 1000000,
      thinking: _thinkingOf(prefs.getString(_kThinking)),
      model: prefs.getString(_kModel) ?? 'deepseek-v4-flash',
      baseUrl: prefs.getString(_kBaseUrl) ?? '',
      credentials: credentials,
      activeProviderId:
          prefs.getString(_kActiveProvider) ??
          (credentials.isEmpty ? '' : credentials.first.providerId),
      localHostModelProvider: prefs.getString(_kLocalHostProvider) ?? '',
      localHostModelId: prefs.getString(_kLocalHostModel) ?? '',
      localHostModelName: prefs.getString(_kLocalHostName) ?? '',
      hostModelsCache: _loadHostModelsCache(prefs),
      pinnedSessionId: prefs.getString(_kPinnedSession),
      guestMode: prefs.getBool(_kGuestMode) ?? false,
      hostMode: prefs.getBool(_kHostMode) ?? false,
      chatScope: prefs.getString(_kChatScope) ?? 'local',
      authBaseUrl:
          prefs.getString(_kAuthBaseUrl) ?? AppSettings.defaultAuthBaseUrl,
    );
  }

  List<ApiCredential> _loadCredentials(SharedPreferences prefs) {
    final raw = prefs.getString(_kCredentials);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map((e) => ApiCredential.fromJson(e.cast<String, dynamic>()))
              .where((c) => c.providerId.isNotEmpty)
              .toList(growable: false);
        }
      } on FormatException {
        // 损坏的旧数据直接忽略，回落到迁移逻辑。
      }
    }
    final legacyProvider = prefs.getString(_kLegacyProvider) ?? '';
    if (legacyProvider.isEmpty) return const <ApiCredential>[];
    final legacyModel = prefs.getString(_kLegacyModel) ?? '';
    final legacyModels =
        prefs.getStringList(_kLegacyModels) ??
        (legacyModel.isEmpty ? const <String>[] : <String>[legacyModel]);
    return [
      ApiCredential(
        providerId: legacyProvider,
        name: providerById(legacyProvider)?.name ?? legacyProvider,
        baseUrl: prefs.getString(_kLegacyBaseUrl) ?? '',
        last4: prefs.getString(_kLegacyLast4) ?? '',
        model: legacyModel,
        models: legacyModels,
      ),
    ];
  }

  List<HostModelOption> _loadHostModelsCache(SharedPreferences prefs) {
    final raw = prefs.getString(_kHostModelsCache);
    if (raw == null || raw.isEmpty) return const <HostModelOption>[];
    try {
      return HostModelOption.listFromCache(jsonDecode(raw));
    } on FormatException {
      return const <HostModelOption>[];
    }
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, settings.themeMode.name);
    await prefs.setString(_kStartStrategy, settings.startStrategy.name);
    await prefs.setBool(_kStreaming, settings.streaming);
    await prefs.setBool(_kAutoScroll, settings.autoScroll);
    await prefs.setBool(_kAutoReconnect, settings.autoReconnect);
    await prefs.setInt(_kKeepDays, settings.keepDays);
    await prefs.setBool(_kModelNaming, settings.modelNaming);
    await prefs.setBool(_kPcLinkPlugin, settings.pcLinkPluginEnabled);
    await prefs.setInt(_kContextLimit, settings.contextLimit);
    await prefs.setString(_kThinking, settings.thinking.name);
    await prefs.setString(_kModel, settings.model);
    await prefs.setString(_kBaseUrl, settings.baseUrl);
    await prefs.setString(
      _kCredentials,
      jsonEncode([for (final item in settings.credentials) item.toJson()]),
    );
    await prefs.setString(_kActiveProvider, settings.activeProviderId);
    await prefs.setBool(_kGuestMode, settings.guestMode);
    await prefs.setBool(_kHostMode, settings.hostMode);
    await prefs.setString(_kChatScope, settings.chatScope);
    await prefs.setString(_kAuthBaseUrl, settings.authBaseUrl);
    await prefs.setString(
      _kLocalHostProvider,
      settings.localHostModelProvider,
    );
    await prefs.setString(_kLocalHostModel, settings.localHostModelId);
    await prefs.setString(_kLocalHostName, settings.localHostModelName);
    await prefs.setString(
      _kHostModelsCache,
      jsonEncode([for (final item in settings.hostModelsCache) item.toJson()]),
    );
    if (settings.pinnedSessionId == null) {
      await prefs.remove(_kPinnedSession);
    } else {
      await prefs.setString(_kPinnedSession, settings.pinnedSessionId!);
    }
  }

  static ThemeMode _themeModeOf(String? value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static ThinkingLevel _thinkingOf(String? value) => switch (value) {
    'low' => ThinkingLevel.low,
    'high' => ThinkingLevel.high,
    'xhigh' => ThinkingLevel.xhigh,
    _ => ThinkingLevel.standard,
  };

  static StartStrategy _strategyOf(String? value) => switch (value) {
    'restoreLast' => StartStrategy.restoreLast,
    'pinned' => StartStrategy.pinned,
    _ => StartStrategy.fresh,
  };
}
