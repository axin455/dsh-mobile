import 'dart:convert';
import 'dart:io';

/// 用户在加号菜单里选中的附件。
///
/// 图片走 OpenAI 兼容的 `image_url`（base64 data URL）；
/// 文本类文件直接读成文字拼进消息；其余类型明确提示不支持。
class ChatAttachment {
  const ChatAttachment({
    required this.name,
    required this.file,
    this.isImage = false,
    this.textContent,
  });

  final String name;
  final File file;
  final bool isImage;

  /// 文本文件的内容（仅文本文件存在）。
  final String? textContent;

  static const _textExtensions = {
    '.txt',
    '.md',
    '.markdown',
    '.json',
    '.yaml',
    '.yml',
    '.csv',
    '.log',
    '.dart',
    '.js',
    '.ts',
    '.py',
    '.java',
    '.kt',
    '.swift',
    '.html',
    '.css',
    '.xml',
    '.sh',
  };

  static bool _isText(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _textExtensions.contains(name.substring(dot).toLowerCase());
  }

  /// 读出图片的 base64 data URL。
  Future<String?> toDataUrl() async {
    if (!isImage) return null;
    final bytes = await file.readAsBytes();
    final lower = name.toLowerCase();
    final mime = lower.endsWith('.png')
        ? 'image/png'
        : lower.endsWith('.webp')
        ? 'image/webp'
        : 'image/jpeg';
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }

  /// 只接受图片或文本文件；其它类型返回 null，由界面提示。
  static ChatAttachment? fromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final name = file.uri.pathSegments.last;
    final lower = name.toLowerCase();
    final isImage =
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic');
    String? text;
    if (!isImage && _isText(name)) {
      try {
        final raw = file.readAsStringSync();
        text = raw.length > 200000 ? raw.substring(0, 200000) : raw;
      } catch (_) {
        return null;
      }
    }
    if (!isImage && text == null) return null;
    return ChatAttachment(
      name: name,
      file: file,
      isImage: isImage,
      textContent: text,
    );
  }
}
