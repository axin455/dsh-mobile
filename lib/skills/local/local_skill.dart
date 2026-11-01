/// SKILL.md 的轻量模型与解析。
///
/// 只读取文本：不执行 skill 里的脚本，也不加载 assets。
/// 支持 Agent Skills 的常见 frontmatter（name / description / license / version）
/// 以及正文；缺字段时做保守的兜底。
library;

class ParsedSkill {
  const ParsedSkill({
    required this.name,
    required this.description,
    required this.body,
    this.license = '',
    this.version = '',
  });

  final String name;
  final String description;
  final String body;
  final String license;
  final String version;
}

class SkillParseException implements Exception {
  const SkillParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract final class SkillParser {
  static const int maxBodyChars = 30000;
  static const int maxDescriptionChars = 500;

  static ParsedSkill parse(String raw, {required String fileName}) {
    var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    text = text.trim();
    if (text.isEmpty) {
      throw const SkillParseException('文件是空的');
    }

    var frontmatter = <String, String>{};
    var body = text;
    if (text.startsWith('---')) {
      final end = text.indexOf('\n---', 3);
      if (end > 0) {
        final header = text.substring(3, end);
        frontmatter = _parseFrontmatter(header);
        body = text.substring(end + 4).trim();
      }
    }

    final fallbackName = _stripExtension(fileName);
    var name = (frontmatter['name'] ?? '').trim();
    if (name.isEmpty) {
      // 没有 frontmatter 时，从正文的一级标题兜底。
      for (final line in body.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('# ')) {
          name = trimmed.substring(2).trim();
          break;
        }
      }
    }
    if (name.isEmpty) name = fallbackName;
    if (name.isEmpty) name = '未命名技能';

    var description = (frontmatter['description'] ?? '').trim();
    if (description.isEmpty) {
      for (final line in body.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#') || trimmed == '---') {
          continue;
        }
        description = trimmed;
        break;
      }
    }
    if (description.length > maxDescriptionChars) {
      description = description.substring(0, maxDescriptionChars);
    }

    if (body.isEmpty) {
      throw const SkillParseException('SKILL.md 只有元数据，没有可用的正文');
    }
    if (body.length > maxBodyChars) {
      body = body.substring(0, maxBodyChars);
    }

    return ParsedSkill(
      name: name,
      description: description,
      body: body,
      license: (frontmatter['license'] ?? '').trim(),
      version: (frontmatter['version'] ?? '').trim(),
    );
  }

  static Map<String, String> _parseFrontmatter(String header) {
    final values = <String, String>{};
    String? currentKey;
    final buffer = StringBuffer();
    void flush() {
      final key = currentKey;
      if (key == null) return;
      values[key] = _unquote(buffer.toString().trim());
      buffer.clear();
    }

    for (final line in header.split('\n')) {
      if (line.trim().isEmpty) continue;
      // 只解析一层 key: value；嵌套 metadata 不参与提示词。
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        final match = RegExp(r'^([A-Za-z0-9_-]+)\s*:\s*(.*)$').firstMatch(line);
        if (match == null) continue;
        flush();
        currentKey = match.group(1)!.toLowerCase();
        buffer.write(match.group(2) ?? '');
      } else if (currentKey != null) {
        buffer.write(' ${line.trim()}');
      }
    }
    flush();
    return values;
  }

  static String _unquote(String value) {
    if (value.length >= 2) {
      final first = value[0];
      final last = value[value.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        return value.substring(1, value.length - 1).trim();
      }
    }
    return value;
  }

  static String _stripExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) return fileName;
    return fileName.substring(0, dot);
  }
}

/// 导入后的技能。`id` 是目录名，重启后保持稳定。
class LocalSkill {
  const LocalSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.body,
    this.license = '',
    this.version = '',
    this.source = '',
    this.importedAt = 0,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String description;
  final String body;
  final String license;
  final String version;

  /// 导入来源（原文件名），仅用于展示。
  final String source;
  final int importedAt;
  final bool enabled;

  LocalSkill copyWith({bool? enabled}) => LocalSkill(
    id: id,
    name: name,
    description: description,
    body: body,
    license: license,
    version: version,
    source: source,
    importedAt: importedAt,
    enabled: enabled ?? this.enabled,
  );
}
