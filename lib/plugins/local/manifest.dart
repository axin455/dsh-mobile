import 'dart:convert';

String _stringValue(Object? value) => value is String ? value.trim() : '';

/// 手机端本地插件的最小声明式模型。
///
/// 插件只是 App 私有目录里的一个文件夹：
/// `<App 数据目录>/plugins/<id>/manifest.json`。
/// App 只读取 manifest，不执行插件目录里的任何代码。
class LocalPluginCapability {
  const LocalPluginCapability({
    required this.type,
    this.label = '',
    this.icon = '',
    this.actionKind = '',
    this.actionText = '',
    this.title = '',
    this.prompt = '',
    this.rows = const <LocalPluginSettingRow>[],
  });

  final String type;
  final String label;
  final String icon;
  final String actionKind;
  final String actionText;
  final String title;

  /// `chatTemplate` 的系统提示词；只在本机纯文本对话里生效。
  final String prompt;
  final List<LocalPluginSettingRow> rows;

  bool get isComposerAction =>
      type == 'composerAction' && actionKind == 'insertText' && actionText.isNotEmpty;

  bool get isSettingsSection => type == 'settingsSection';

  /// 角色扮演 / 提示词模板：启用后在本地纯文本对话前注入系统提示。
  bool get isChatTemplate =>
      type == 'chatTemplate' && prompt.trim().isNotEmpty;

  static LocalPluginCapability? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    if (type is! String || type.isEmpty) return null;
    final action = raw['action'];
    final actionMap = action is Map ? action : const {};
    final rows = <LocalPluginSettingRow>[];
    final rawRows = raw['rows'];
    if (rawRows is List) {
      for (final item in rawRows) {
        final row = LocalPluginSettingRow.fromJson(item);
        if (row != null) rows.add(row);
      }
    }
    final rawPrompt = raw['prompt'] ?? raw['systemPrompt'];
    return LocalPluginCapability(
      type: type,
      label: _stringValue(raw['label']),
      icon: _stringValue(raw['icon']),
      actionKind: _stringValue(actionMap['kind']),
      actionText: _stringValue(actionMap['text']),
      title: _stringValue(raw['title']),
      // 限制长度：manifest 只有 64KB，模板再长也没有意义。
      prompt: _promptOf(rawPrompt),
      rows: rows,
    );
  }

  static String _promptOf(Object? raw) {
    if (raw is! String) return '';
    final text = raw.trim();
    return text.length <= 8000 ? text : text.substring(0, 8000);
  }
}

class LocalPluginSettingRow {
  const LocalPluginSettingRow({
    required this.kind,
    required this.key,
    required this.title,
    required this.defaultValue,
  });

  final String kind;
  final String key;
  final String title;
  final bool defaultValue;

  bool get isSwitch => kind == 'switch' && key.isNotEmpty;

  static LocalPluginSettingRow? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind'];
    final key = raw['key'];
    final title = raw['title'];
    if (kind is! String || key is! String || title is! String) return null;
    return LocalPluginSettingRow(
      kind: kind,
      key: key,
      title: title,
      defaultValue: raw['default'] == true,
    );
  }
}

class LocalPlugin {
  const LocalPlugin({
    required this.id,
    required this.version,
    required this.name,
    required this.description,
    required this.icon,
    required this.author,
    required this.capabilities,
    this.enabled = true,
    this.defaultEnabled = true,
  });

  final String id;
  final String version;
  final String name;
  final String description;
  final String icon;
  final String author;
  final List<LocalPluginCapability> capabilities;
  final bool enabled;

  /// 首次安装时的默认开关；会侵入对话的模板类插件建议默认关闭。
  final bool defaultEnabled;

  LocalPlugin copyWith({bool? enabled}) => LocalPlugin(
    id: id,
    version: version,
    name: name,
    description: description,
    icon: icon,
    author: author,
    capabilities: capabilities,
    enabled: enabled ?? this.enabled,
    defaultEnabled: defaultEnabled,
  );

  List<LocalPluginCapability> get composerActions => enabled
      ? capabilities.where((item) => item.isComposerAction).toList(growable: false)
      : const <LocalPluginCapability>[];

  List<LocalPluginCapability> get settingsSections => enabled
      ? capabilities.where((item) => item.isSettingsSection).toList(growable: false)
      : const <LocalPluginCapability>[];

  /// 启用中的提示词模板：多个模板会按声明顺序拼接。
  List<LocalPluginCapability> get chatTemplates => enabled
      ? capabilities.where((item) => item.isChatTemplate).toList(growable: false)
      : const <LocalPluginCapability>[];

  static LocalPlugin? fromManifest(String dirName, Object? raw) {
    if (raw is! Map) return null;
    final id = _stringValue(raw['id']);
    final name = _stringValue(raw['name']);
    final version = _stringValue(raw['version']);
    if (id.isEmpty || name.isEmpty || version.isEmpty) return null;
    // id 必须是反域名格式，且与目录名一致，避免两个目录声明同一个插件。
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$').hasMatch(id)) return null;
    if (dirName != id) return null;
    final capabilities = <LocalPluginCapability>[];
    final rawCapabilities = raw['capabilities'];
    if (rawCapabilities is List) {
      for (final item in rawCapabilities.take(8)) {
        final capability = LocalPluginCapability.fromJson(item);
        if (capability != null) capabilities.add(capability);
      }
    }
    return LocalPlugin(
      id: id,
      version: version,
      name: name,
      description: _stringValue(raw['description']),
      icon: _stringValue(raw['icon']),
      author: _stringValue(raw['author']),
      capabilities: capabilities,
      defaultEnabled: raw['defaultEnabled'] != false,
    );
  }

}

String encodeManifest(Map<String, Object?> value) =>
    const JsonEncoder.withIndent('  ').convert(value);
