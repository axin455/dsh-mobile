import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_skill.dart';

/// 本地技能库：`<App 文档目录>/skills/<id>/SKILL.md`。
///
/// 只保存文本，不执行脚本、不读取 assets。导入支持单个 `.md`
/// 或包含 `SKILL.md` 的 `.zip`。
class SkillStore {
  static const _dirName = 'skills';
  static const _maxFileBytes = 8 * 1024 * 1024;
  static const _maxSkillBytes = 512 * 1024;

  Future<Directory> skillsDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, _dirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<List<LocalSkill>> scan() async {
    final dir = await skillsDirectory();
    final prefs = await SharedPreferences.getInstance();
    final skills = <LocalSkill>[];
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final id = p.basename(entry.path);
      final file = File(p.join(entry.path, 'SKILL.md'));
      try {
        if (!await file.exists()) continue;
        final text = await file.readAsString();
        final parsed = SkillParser.parse(text, fileName: id);
        final meta = await _readMeta(entry);
        final enabled = prefs.getBool(_enabledKey(id)) ?? true;
        skills.add(
          LocalSkill(
            id: id,
            name: parsed.name,
            description: parsed.description,
            body: parsed.body,
            license: parsed.license,
            version: parsed.version,
            source: (meta['source'] ?? '').toString(),
            importedAt: _intOf(meta['importedAt']),
            enabled: enabled,
          ),
        );
      } catch (_) {
        // 单个技能损坏只跳过，不影响其他技能。
      }
    }
    skills.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    return skills;
  }

  /// 导入前预览：只解析，不落盘。UI 用它展示确认弹窗。
  static ParsedSkill preview({
    required String fileName,
    required Uint8List bytes,
  }) {
    if (bytes.length > _maxFileBytes) {
      throw const SkillParseException('文件超过 8MB，暂不支持导入');
    }
    final lower = fileName.toLowerCase();
    final raw = lower.endsWith('.zip')
        ? _readSkillFromZipStatic(bytes)
        : utf8.decode(bytes, allowMalformed: true);
    return SkillParser.parse(raw, fileName: fileName);
  }

  /// 读取用户选中的文件并落库。`.zip` 会取最浅的一层 `SKILL.md`。
  Future<LocalSkill> importFile({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final parsed = preview(fileName: fileName, bytes: bytes);
    final lower = fileName.toLowerCase();
    final raw = lower.endsWith('.zip')
        ? _readSkillFromZipStatic(bytes)
        : utf8.decode(bytes, allowMalformed: true);

    final dir = await skillsDirectory();
    final id = await _uniqueId(dir, _slug(parsed.name));
    final target = Directory(p.join(dir.path, id));
    await target.create(recursive: true);
    await File(p.join(target.path, 'SKILL.md')).writeAsString(raw);
    await File(p.join(target.path, 'meta.json')).writeAsString(
      jsonEncode({
        'source': fileName,
        'importedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    // 新导入默认启用，和导入确认弹窗的提示一致。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey(id), true);
    return LocalSkill(
      id: id,
      name: parsed.name,
      description: parsed.description,
      body: parsed.body,
      license: parsed.license,
      version: parsed.version,
      source: fileName,
      importedAt: DateTime.now().millisecondsSinceEpoch,
      enabled: true,
    );
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey(id), enabled);
  }

  Future<void> remove(String id) async {
    final dir = await skillsDirectory();
    final target = Directory(p.join(dir.path, id));
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_enabledKey(id));
  }

  /// 只解压出 SKILL.md，其余文件（脚本/资源）一律忽略。
  static String _readSkillFromZipStatic(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    ArchiveFile? best;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (p.basename(file.name).toLowerCase() != 'skill.md') continue;
      if (file.size > _maxSkillBytes) continue;
      if (best == null || file.name.length < best.name.length) {
        best = file;
      }
    }
    if (best == null) {
      throw const SkillParseException('压缩包里没有找到 SKILL.md');
    }
    final content = best.content;
    if (content.isEmpty) {
      throw const SkillParseException('SKILL.md 是空的');
    }
    return utf8.decode(content, allowMalformed: true);
  }

  Future<Map<String, dynamic>> _readMeta(Directory dir) async {
    final file = File(p.join(dir.path, 'meta.json'));
    if (!await file.exists()) return const {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? decoded.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  static int _intOf(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _enabledKey(String id) => 'localSkill.$id.enabled';

  static Future<String> _uniqueId(Directory dir, String base) async {
    final root = base.isEmpty
        ? 'skill-${DateTime.now().millisecondsSinceEpoch}'
        : base;
    var id = root;
    var index = 2;
    while (await Directory(p.join(dir.path, id)).exists()) {
      id = '$root-$index';
      index++;
    }
    return id;
  }

  /// 目录名/ID 只保留安全字符；中文名等全部丢掉时用时间戳兜底。
  static String _slug(String name) {
    final ascii = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (ascii.isEmpty) return '';
    return ascii.length > 48 ? ascii.substring(0, 48) : ascii;
  }
}
