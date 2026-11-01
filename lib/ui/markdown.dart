import 'package:flutter/material.dart';

import 'colors.dart';
import 'typography.dart';

/// 轻量 Markdown 文本：把 `**`、`#`、反引号等模型常带的符号渲染成排版，
/// 而不是让符号原样出现在气泡里。流式输出中未闭合的标记直接丢弃，
/// 避免半截 `**` 先露出来再消失。
///
/// 只支持聊天里真正会出现的子集：标题、列表、代码块、加粗、斜体、
/// 行内代码、链接（只留文字）。不引入第三方 Markdown 依赖。
class AppMarkdown extends StatelessWidget {
  const AppMarkdown({super.key, required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? AppTextStyle.callout.of(context);
    return SelectableText.rich(
      TextSpan(
        style: base,
        children: _MarkdownParser(context, base).parse(text),
      ),
    );
  }
}

class _MarkdownParser {
  _MarkdownParser(this.context, this.base)
    : scheme = AppColors.of(context),
      secondary = AppColors.textSecondaryOf(context);

  final BuildContext context;
  final TextStyle base;
  final ColorScheme scheme;
  final Color secondary;

  static final RegExp _heading = RegExp(r'^(#{1,6})\s+(.*)$');
  static final RegExp _bullet = RegExp(r'^(?:-|\*|\+)\s+');
  static final RegExp _ordered = RegExp(r'^(\d+\.)\s+');
  static final RegExp _quote = RegExp(r'^>\s+');
  static final RegExp _divider = RegExp(r'^---+$');

  List<TextSpan> parse(String source) {
    final spans = <TextSpan>[];
    final lines = source.split('\n');
    var inCode = false;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trimLeft();
      final newline = i == lines.length - 1 ? '' : '\n';

      if (trimmed.startsWith('```')) {
        inCode = !inCode;
        continue;
      }
      if (inCode) {
        spans.add(
          TextSpan(
            text: '$raw$newline',
            style: base.copyWith(
              fontFamily: 'monospace',
              fontSize: (base.fontSize ?? 16) - 1,
              backgroundColor: scheme.surfaceContainerHigh,
              color: scheme.onSurface,
            ),
          ),
        );
        continue;
      }
      if (trimmed.isEmpty) {
        spans.add(TextSpan(text: newline));
        continue;
      }
      if (_divider.hasMatch(trimmed)) {
        spans.add(
          TextSpan(
            text: '────────────────$newline',
            style: base.copyWith(color: secondary),
          ),
        );
        continue;
      }

      final heading = _heading.firstMatch(trimmed);
      if (heading != null) {
        final level = heading.group(1)!.length;
        final scale = switch (level) {
          1 => 1.3,
          2 => 1.15,
          _ => 1.02,
        };
        spans.add(
          TextSpan(
            text: '${heading.group(2)}$newline',
            style: base.copyWith(
              fontSize: (base.fontSize ?? 16) * scale,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
        continue;
      }

      var body = trimmed;
      String prefix = '';
      if (_bullet.hasMatch(body)) {
        body = body.replaceFirst(_bullet, '');
        prefix = '· ';
      } else {
        final ordered = _ordered.firstMatch(body);
        if (ordered != null) {
          body = body.replaceFirst(_ordered, '');
          prefix = '${ordered.group(1)} ';
        } else if (_quote.hasMatch(body)) {
          body = body.replaceFirst(_quote, '');
          prefix = '│ ';
        }
      }

      if (prefix.isNotEmpty) {
        spans.add(
          TextSpan(
            text: prefix,
            style: base.copyWith(color: secondary),
          ),
        );
      }
      spans.addAll(_inline('$body$newline'));
    }
    return spans;
  }

  /// 行内标记：**加粗**、*斜体*、`代码`、[文字](链接)。
  List<TextSpan> _inline(String text) {
    final spans = <TextSpan>[];
    final buffer = StringBuffer();
    var i = 0;

    void flush() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(text: buffer.toString()));
      buffer.clear();
    }

    while (i < text.length) {
      if (text.startsWith('**', i)) {
        final end = text.indexOf('**', i + 2);
        // 未闭合（流式输出中常见）：丢掉标记，文字照常显示。
        if (end <= i + 2) {
          i += 2;
          continue;
        }
        flush();
        spans.add(
          TextSpan(
            text: text.substring(i + 2, end),
            style: base.copyWith(fontWeight: FontWeight.w600),
          ),
        );
        i = end + 2;
        continue;
      }
      if (text[i] == '`') {
        final end = text.indexOf('`', i + 1);
        if (end < 0) {
          i++;
          continue;
        }
        flush();
        spans.add(
          TextSpan(
            text: text.substring(i + 1, end),
            style: base.copyWith(
              fontFamily: 'monospace',
              backgroundColor: scheme.surfaceContainerHigh,
            ),
          ),
        );
        i = end + 1;
        continue;
      }
      if (text[i] == '*') {
        final end = text.indexOf('*', i + 1);
        if (end < 0 || end == i + 1) {
          i++;
          continue;
        }
        flush();
        spans.add(
          TextSpan(
            text: text.substring(i + 1, end),
            style: base.copyWith(fontStyle: FontStyle.italic),
          ),
        );
        i = end + 1;
        continue;
      }
      if (text[i] == '[') {
        final close = text.indexOf(']', i);
        if (close > i && close + 1 < text.length && text[close + 1] == '(') {
          final paren = text.indexOf(')', close + 2);
          if (paren > 0) {
            flush();
            spans.add(TextSpan(text: text.substring(i + 1, close)));
            i = paren + 1;
            continue;
          }
        }
      }
      buffer.write(text[i]);
      i++;
    }
    flush();
    return spans;
  }
}
