import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 用供应商 API Key 直连 OpenAI 兼容接口。
///
/// 与网关模式无关：这个客户端不依赖 Host，也不经过设备码登录，
/// 只把 `messages` 发到 `${baseUrl}/chat/completions` 并逐块读取 SSE 增量。
class DirectChatClient {
  DirectChatClient({HttpClient? httpClient})
    : _client = httpClient ?? HttpClient();

  final HttpClient _client;
  static const _timeout = Duration(seconds: 20);

  bool _cancelled = false;

  /// 最近一次 `stream` 结束后供应商回传的用量；没有返回时为 null。
  ChatUsage? usage;

  void cancel() => _cancelled = true;

  /// 校验 Key：先用 `/models` 探测，401 视为 Key 无效；
  /// 供应商没有 `/models`（404/405）时视为可用，交给真正的对话请求兜底。
  Future<String?> validate({
    required String baseUrl,
    required String apiKey,
  }) async {
    final uri = Uri.parse('${_trim(baseUrl)}/models');
    try {
      final request = await _client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      final response = await request.close().timeout(_timeout);
      await response.drain<void>();
      if (response.statusCode == 401 || response.statusCode == 403) {
        return 'API Key 无效或没有权限';
      }
      if (response.statusCode == 404 || response.statusCode == 405) return null;
      if (response.statusCode >= 400) {
        return '${uri.origin} 返回 ${response.statusCode}';
      }
      return null;
    } on TimeoutException {
      return '连接 ${uri.origin} 超时';
    } catch (error) {
      return '无法连接 ${uri.origin}：$error';
    }
  }

  /// 逐块返回模型输出。调用方负责把增量拼进消息气泡。
  Stream<String> stream({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    String? reasoningEffort,
  }) async* {
    final uri = Uri.parse('${_trim(baseUrl)}/chat/completions');
    usage = null;

    Future<HttpClientResponse> post({required bool withUsage}) async {
      final request = await _client.postUrl(uri).timeout(_timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      request.write(
        jsonEncode({
          'model': model,
          'stream': true,
          'messages': messages,
          'reasoning_effort': ?reasoningEffort,
          if (withUsage) 'stream_options': {'include_usage': true},
        }),
      );
      return request.close().timeout(_timeout);
    }

    var response = await post(withUsage: true);
    if (response.statusCode == 400) {
      // 少数兼容接口不认 stream_options，去掉后再试一次。
      final body = await response.transform(utf8.decoder).join();
      if (!body.contains('stream_options')) {
        throw DirectChatException(_errorText(response.statusCode, body));
      }
      response = await post(withUsage: false);
    }
    if (response.statusCode != 200) {
      final body = await response.transform(utf8.decoder).join();
      throw DirectChatException(_errorText(response.statusCode, body));
    }

    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (_cancelled) return;
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } on FormatException {
        continue;
      }
      if (decoded is Map) {
        usage = _usageOf(decoded) ?? usage;
      }
      final delta = _deltaOf(payload);
      if (delta != null && delta.isNotEmpty) yield delta;
    }
  }

  void dispose() => _client.close(force: true);

  static ChatUsage? _usageOf(Map<dynamic, dynamic> decoded) {
    final raw = decoded['usage'];
    if (raw is! Map) return null;
    int? asInt(Object? value) => value is num ? value.toInt() : null;
    final prompt = asInt(raw['prompt_tokens']);
    final completion = asInt(raw['completion_tokens']);
    final details = raw['prompt_tokens_details'];
    final cached =
        asInt(raw['prompt_cache_hit_tokens']) ??
        asInt(raw['cached_tokens']) ??
        (details is Map ? asInt(details['cached_tokens']) : null);
    if (prompt == null && completion == null && cached == null) return null;
    return ChatUsage(
      promptTokens: prompt,
      completionTokens: completion,
      cachedTokens: cached,
    );
  }

  static String? _deltaOf(String payload) {
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map) return null;
    final delta = first['delta'] ?? first['message'];
    if (delta is! Map) return null;
    final content = delta['content'];
    return content is String ? content : null;
  }

  static String _errorText(int status, String body) {
    var text = body.trim();
    if (text.isEmpty) return '请求失败（HTTP $status）';
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          text = error['message'] as String;
        } else if (decoded['message'] is String) {
          text = decoded['message'] as String;
        }
      }
    } on FormatException {
      // 保留原始文本。
    }
    if (text.length > 160) text = '${text.substring(0, 160)}…';
    final unsupported = RegExp(
      r'The supported API model names are ([^,]+), but you passed',
    ).firstMatch(text);
    if (unsupported != null) {
      return '模型名不受支持，可用：${unsupported.group(1)}';
    }
    return 'HTTP $status：$text';
  }

  static String _trim(String baseUrl) =>
      baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
}

class DirectChatException implements Exception {
  const DirectChatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 供应商回传的用量（OpenAI 兼容 `usage` 字段）。
class ChatUsage {
  const ChatUsage({
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
  });

  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;

  bool get isEmpty =>
      promptTokens == null && completionTokens == null && cachedTokens == null;
}
