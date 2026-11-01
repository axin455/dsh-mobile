import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_mobile/skills/local/local_skill.dart';
import 'package:dsh_mobile/skills/local/skill_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('解析 frontmatter 与正文', () {
    final parsed = SkillParser.parse('''
---
name: code-reviewer
description: "按团队规范审阅代码"
license: MIT
version: 1.2.0
---

你是一名严格的代码审阅者。
''', fileName: 'code-reviewer.md');
    expect(parsed.name, 'code-reviewer');
    expect(parsed.description, '按团队规范审阅代码');
    expect(parsed.license, 'MIT');
    expect(parsed.version, '1.2.0');
    expect(parsed.body.contains('严格的代码审阅者'), isTrue);
  });

  test('没有 frontmatter 时用一级标题与首段兜底', () {
    final parsed = SkillParser.parse('''
# 咖啡品鉴师
先用香气描述，再给建议。
''', fileName: 'coffee.md');
    expect(parsed.name, '咖啡品鉴师');
    expect(parsed.description, '先用香气描述，再给建议。');
  });

  test('空文件与只有元数据的文件会报错', () {
    expect(
      () => SkillParser.parse('   ', fileName: 'empty.md'),
      throwsA(isA<SkillParseException>()),
    );
    expect(
      () => SkillParser.parse('---\nname: x\ndescription: y\n---\n',
          fileName: 'meta.md'),
      throwsA(isA<SkillParseException>()),
    );
  });

  test('zip 里取最浅的 SKILL.md，忽略其他文件', () {
    final archive = Archive();
    final skill = utf8.encode('''
---
name: zip-skill
description: 来自压缩包
---
正文内容。
''');
    archive.add(ArchiveFile('pkg/references/notes.md', 4, utf8.encode('1234')));
    archive.add(ArchiveFile('pkg/a/b/SKILL.md', skill.length, skill));
    final bytes = ZipEncoder().encodeBytes(archive);
    final parsed = SkillStore.preview(
      fileName: 'pkg.zip',
      bytes: Uint8List.fromList(bytes),
    );
    expect(parsed.name, 'zip-skill');
    expect(parsed.body.contains('正文内容'), isTrue);
  });

  test('zip 缺少 SKILL.md 时报可读错误', () {
    final archive = Archive();
    archive.add(ArchiveFile('README.md', 3, utf8.encode('abc')));
    final bytes = ZipEncoder().encodeBytes(archive);
    expect(
      () => SkillStore.preview(
        fileName: 'pkg.zip',
        bytes: Uint8List.fromList(bytes),
      ),
      throwsA(isA<SkillParseException>()),
    );
  });
}
