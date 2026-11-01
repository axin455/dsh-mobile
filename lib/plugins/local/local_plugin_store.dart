import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manifest.dart';

/// 扫描与存储本地插件。只读取 `<App 数据目录>/plugins/<id>/manifest.json`，
/// 不执行插件目录里的任何脚本或二进制。
class LocalPluginStore {
  static const _pluginsDir = 'plugins';
  static const _maxManifestBytes = 64 * 1024;

  Future<Directory> pluginsDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, _pluginsDir));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await _seedSample(dir);
    await _seedRoleplaySample(dir);
    return dir;
  }

  /// 首次运行放一个示例插件，用户能立刻在插件页看到本地插件长什么样。
  Future<void> _seedSample(Directory dir) async {
    final sample = Directory(p.join(dir.path, 'com.dsh.example.quick-note'));
    if (await sample.exists()) return;
    try {
      await sample.create(recursive: true);
      final manifest = <String, Object?>{
        'id': 'com.dsh.example.quick-note',
        'version': '1.0.0',
        'name': '快捷便签',
        'description': '在输入框里插入一行带时间戳的便签',
        'author': 'DSH',
        'minAppVersion': '0.1.0',
        'capabilities': [
          {
            'type': 'composerAction',
            'label': '插入便签',
            'icon': 'note',
            'action': {
              'kind': 'insertText',
              'text': '【便签】',
            },
          },
          {
            'type': 'settingsSection',
            'title': '快捷便签',
            'rows': [
              {
                'kind': 'switch',
                'key': 'autoAppendTime',
                'title': '插入时附加当前时间',
                'default': true,
              },
            ],
          },
        ],
      };
      await File(
        p.join(sample.path, 'manifest.json'),
      ).writeAsString(encodeManifest(manifest));
    } catch (_) {
      // 示例写不进去不影响用户自己安装插件。
    }
  }

  /// 示例二：角色扮演模板。演示 chatTemplate —— 本地纯文本对话的系统提示注入。
  Future<void> _seedRoleplaySample(Directory dir) async {
    final sample = Directory(p.join(dir.path, 'com.dsh.example.roleplay'));
    if (await sample.exists()) return;
    try {
      await sample.create(recursive: true);
      final manifest = <String, Object?>{
        'id': 'com.dsh.example.roleplay',
        'version': '1.0.0',
        'name': '角色扮演',
        'description': '给本地纯文本对话加一个固定人设（示例模板）',
        'author': 'DSH',
        'minAppVersion': '0.1.0',
        'defaultEnabled': false,
        'capabilities': [
          {
            'type': 'chatTemplate',
            'title': '古风客栈掌柜',
            'prompt':
                '你正在扮演「阿岚」，一位开在江南水乡的客栈掌柜。'
                '说话温和、爱用比喻，回答保持第一人称与人设，不提及自己是 AI 或模型。'
                '遇到超出人设的问题，就用掌柜的口吻把话题绕回客栈与旅途。',
          },
          {
            'type': 'settingsSection',
            'title': '角色扮演',
            'rows': [
              {
                'kind': 'switch',
                'key': 'stayInCharacter',
                'title': '保持人设口吻',
                'default': true,
              },
            ],
          },
        ],
      };
      await File(
        p.join(sample.path, 'manifest.json'),
      ).writeAsString(encodeManifest(manifest));
    } catch (_) {
      // 示例写不进去不影响用户自己安装插件。
    }
  }

  Future<List<LocalPlugin>> scan() async {    final dir = await pluginsDirectory();
    final prefs = await SharedPreferences.getInstance();
    final plugins = <LocalPlugin>[];
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final manifestFile = File(p.join(entry.path, 'manifest.json'));
      try {
        final stat = await manifestFile.stat();
        if (stat.size > _maxManifestBytes) continue;
        final decoded = jsonDecode(await manifestFile.readAsString());
        final plugin = LocalPlugin.fromManifest(p.basename(entry.path), decoded);
        if (plugin == null) continue;
        final enabled =
            prefs.getBool(_enabledKey(plugin.id)) ?? plugin.defaultEnabled;
        plugins.add(plugin.copyWith(enabled: enabled));
      } catch (_) {
        // 单个插件损坏只跳过它，不影响其他插件。
      }
    }
    plugins.sort((a, b) => a.name.compareTo(b.name));
    return plugins;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey(id), enabled);
  }

  Future<bool> readSetting(String pluginId, String key, bool fallback) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_settingKey(pluginId, key)) ?? fallback;
  }

  Future<void> writeSetting(String pluginId, String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_settingKey(pluginId, key), value);
  }

  static String _enabledKey(String id) => 'localPlugin.$id.enabled';

  static String _settingKey(String pluginId, String key) =>
      'localPlugin.$pluginId.settings.$key';
}
