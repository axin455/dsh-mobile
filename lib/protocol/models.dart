/// 协议数据模型。字段名严格对应 PROTOCOL.md 的帧结构。
library;

/// `{"kind":"sessions","items":[...]}` 中的一项。
class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    required this.title,
    required this.updatedAt,
    this.running = false,
    this.blank = false,
    this.pinned = false,
  });

  final String sessionId;
  final String title;

  /// 秒级 unix 时间戳（协议里是 `updatedAt` 秒，不是毫秒）。
  final int updatedAt;
  final bool running;
  final bool blank;

  /// 仅本地使用：客户端置顶，不写回 Host。
  final bool pinned;

  String get displayTitle => title.trim().isEmpty ? '未命名对话' : title.trim();

  DateTime get updatedTime =>
      DateTime.fromMillisecondsSinceEpoch(updatedAt * 1000);

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    final projections = json['projections'];
    String? title;
    if (projections is Map) {
      final values = projections['values'];
      if (values is Map && values['title'] is String) {
        title = values['title'] as String;
      }
    }
    final rawUpdated = json['updatedAt'];
    return SessionSummary(
      sessionId: (json['sessionId'] ?? '').toString(),
      title: title ?? '',
      updatedAt: rawUpdated is int
          ? rawUpdated
          : rawUpdated is num
          ? rawUpdated.toInt()
          : 0,
      running: json['running'] == true,
      blank: json['blank'] == true,
    );
  }

  SessionSummary copyWith({
    String? title,
    bool? pinned,
    bool? running,
    int? updatedAt,
  }) => SessionSummary(
    sessionId: sessionId,
    title: title ?? this.title,
    updatedAt: updatedAt ?? this.updatedAt,
    running: running ?? this.running,
    blank: blank,
    pinned: pinned ?? this.pinned,
  );
}

enum ChatRole { user, assistant }

/// 对话页显示的一条消息。
class ChatEntry {
  const ChatEntry({
    required this.id,
    required this.role,
    required this.text,
    this.streaming = false,
    this.seq = 0,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    this.attachmentNames = const <String>[],
    this.detail = false,
    this.detailLabel = '',
  });

  final String id;
  final ChatRole role;
  final String text;

  /// 流式输出中：用于在气泡尾部画光标。
  final bool streaming;
  final int seq;

  /// 供应商回传的用量；部分接口不返回，此时为 null。
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;

  /// 用户消息附带的图片/文件名（只用于气泡展示，不参与模型上下文）。
  final List<String> attachmentNames;

  /// 电脑端「工作」的中间步骤（推理、工具调用、工具结果）：
  /// 默认折叠，点开查看细节，不作为主消息展示。
  final bool detail;
  final String detailLabel;

  ChatEntry copyWith({
    String? text,
    bool? streaming,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
  }) => ChatEntry(
    id: id,
    role: role,
    text: text ?? this.text,
    streaming: streaming ?? this.streaming,
    seq: seq,
    promptTokens: promptTokens ?? this.promptTokens,
    completionTokens: completionTokens ?? this.completionTokens,
    cachedTokens: cachedTokens ?? this.cachedTokens,
    attachmentNames: attachmentNames,
    detail: detail,
    detailLabel: detailLabel,
  );
}

/// `session-stats` 返回的会话执行统计（输入框统计条数据源）。
class SessionStats {
  const SessionStats({
    this.turns = 0,
    this.steps = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.llmMs = 0,
    this.toolMs = 0,
    this.ttftMs = 0,
    this.ttftSteps = 0,
    this.decodeMs = 0,
    this.decodeTokens = 0,
    this.contextWindow,
    this.pressureTokens,
  });

  final int turns;
  final int steps;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int llmMs;
  final int toolMs;
  final int ttftMs;
  final int ttftSteps;
  final int decodeMs;
  final int decodeTokens;
  final int? contextWindow;
  final int? pressureTokens;

  bool get isEmpty => turns == 0 && steps == 0 && inputTokens == 0;

  double? get cacheHitPercent =>
      inputTokens > 0 ? cacheReadTokens * 100 / inputTokens : null;

  double? get tokensPerSecond =>
      decodeMs > 0 ? decodeTokens / (decodeMs / 1000) : null;

  double? get firstTokenMs => ttftSteps > 0 ? ttftMs / ttftSteps : null;

  factory SessionStats.fromFrame(Map<String, dynamic> frame) {
    final stats = frame['sessionStats'];
    final usage = frame['tokenUsage'];
    final pressure = frame['contextPressure'];
    final totals = usage is Map ? usage['totals'] : null;
    final statsMap = stats is Map ? stats : const {};
    final totalsMap = totals is Map ? totals : const {};
    final pressureMap = pressure is Map ? pressure : const {};
    int asInt(Object? value) => value is int ? value : 0;
    return SessionStats(
      turns: asInt(statsMap['turns']),
      steps: asInt(statsMap['steps']),
      inputTokens: asInt(totalsMap['inputTokens']),
      outputTokens: asInt(totalsMap['outputTokens']),
      cacheReadTokens: asInt(totalsMap['cacheReadTokens']),
      llmMs: asInt(statsMap['llmMs']),
      toolMs: asInt(statsMap['toolMs']),
      ttftMs: asInt(statsMap['ttftMs']),
      ttftSteps: asInt(statsMap['ttftSteps']),
      decodeMs: asInt(statsMap['decodeMs']),
      decodeTokens: asInt(statsMap['decodeTokens']),
      contextWindow: pressureMap['contextWindow'] is int
          ? pressureMap['contextWindow'] as int
          : null,
      pressureTokens: pressureMap['pressureTokens'] is int
          ? pressureMap['pressureTokens'] as int
          : null,
    );
  }
}

/// `plugin-catalog` 返回的一个插件条目（`plugins[]`）。
class PluginEntry {
  const PluginEntry({
    required this.id,
    required this.name,
    required this.type,
    required this.enabled,
    this.description = '',
  });

  final String id;
  final String name;
  final String type;
  final bool enabled;

  /// 宿主插件自带的说明；没有时为空串，界面用类型名兜底。
  final String description;

  PluginEntry copyWith({bool? enabled}) => PluginEntry(
    id: id,
    name: name,
    type: type,
    enabled: enabled ?? this.enabled,
    description: description,
  );

  factory PluginEntry.fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    final rawName = (json['name'] ?? '').toString().trim();
    return PluginEntry(
      id: (json['entryId'] ?? json['id'] ?? rawName).toString(),
      name: rawName,
      type: type is String && type.isNotEmpty ? type : 'unknown',
      enabled: json['enabled'] == true,
      description: (json['description'] ?? json['summary'] ?? '').toString(),
    );
  }
}

/// `plugin-catalog` 返回的一个插件包（`bundles[]`）。
class PluginBundle {
  const PluginBundle({
    required this.name,
    required this.version,
    required this.enabled,
    this.description = '',
    this.entries = const <PluginEntry>[],
  });

  final String name;
  final String version;
  final bool enabled;
  final String description;
  final List<PluginEntry> entries;

  PluginBundle copyWith({bool? enabled, List<PluginEntry>? entries}) =>
      PluginBundle(
        name: name,
        version: version,
        enabled: enabled ?? this.enabled,
        description: description,
        entries: entries ?? this.entries,
      );

  factory PluginBundle.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['plugins'] ?? json['entries'];
    final entries = rawEntries is List
        ? rawEntries
              .whereType<Map>()
              .map((e) => PluginEntry.fromJson(e.cast<String, dynamic>()))
              // 宿主没给名字的条目对用户没有意义，直接不展示，避免「未命名条目」刷屏。
              .where((entry) => entry.name.isNotEmpty && entry.id.isNotEmpty)
              .toList(growable: false)
        : const <PluginEntry>[];
    return PluginBundle(
      name: (json['name'] ?? json['id'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      enabled: json['enabled'] == true,
      description: (json['description'] ?? json['summary'] ?? '').toString(),
      entries: entries,
    );
  }
}

class PluginCatalog {
  const PluginCatalog({
    this.managementAvailable = false,
    this.settingsWritable = false,
    this.bundles = const <PluginBundle>[],
    this.plugins = const <PluginEntry>[],
  });

  final bool managementAvailable;
  final bool settingsWritable;
  final List<PluginBundle> bundles;
  final List<PluginEntry> plugins;

  bool get isEmpty => bundles.isEmpty && plugins.isEmpty;

  factory PluginCatalog.fromJson(Map<String, dynamic> json) {
    final bundles = (json['bundles'] is List)
        ? (json['bundles'] as List)
              .whereType<Map>()
              .map((e) => PluginBundle.fromJson(e.cast<String, dynamic>()))
              .toList(growable: false)
        : const <PluginBundle>[];
    final plugins = (json['plugins'] is List)
        ? (json['plugins'] as List)
              .whereType<Map>()
              .map((e) => PluginEntry.fromJson(e.cast<String, dynamic>()))
              .toList(growable: false)
        : const <PluginEntry>[];
    return PluginCatalog(
      managementAvailable: json['managementAvailable'] == true,
      settingsWritable: json['settingsWritable'] == true,
      bundles: bundles,
      plugins: plugins,
    );
  }
}
