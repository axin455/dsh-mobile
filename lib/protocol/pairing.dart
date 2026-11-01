import 'dart:convert';

/// 配对载荷。
///
/// 协议唯一受支持的格式：二维码/手动复制内容是**无 padding 的 Base64URL**，
/// 解码后为 UTF-8 JSON：
/// `{"version":2,"publicUrl":"...","pairingCode":"...","expiresAt":<ms>}`
/// 见 PROTOCOL.md「首次配对」。
class PairingPayload {
  const PairingPayload({
    required this.publicUrl,
    required this.pairingCode,
    required this.expiresAt,
    this.version = 2,
    this.endpoints = const <String>[],
    this.gatewayId,
    this.gatewayName,
  });

  final int version;
  final String publicUrl;
  final String pairingCode;
  final int expiresAt;
  final List<String> endpoints;
  final String? gatewayId;
  final String? gatewayName;

  static final RegExp _strictBase64Url = RegExp(r'^[A-Za-z0-9_-]+$');

  bool get isExpired =>
      expiresAt > 0 && DateTime.now().millisecondsSinceEpoch > expiresAt;

  /// 候选连接地址：过滤 loopback 后，局域网私有地址优先，公网 TLS 地址兜底。
  ///
  /// 协议只保证 `endpoints` 是「同一网关的候选地址」，明确提示候选里可能
  /// 包含手机不可达的 loopback；因此不能用 `publicUrl` 直接建连。
  List<String> get candidates {
    final seen = <String>{};
    final lan = <String>[];
    final remote = <String>[];
    for (final raw in <String>[publicUrl, ...endpoints]) {
      final uri = Uri.tryParse(raw);
      if (uri == null) continue;
      if (uri.scheme != 'ws' && uri.scheme != 'wss') continue;
      final host = uri.host.toLowerCase();
      if (host.isEmpty || _isLoopback(host)) continue;
      if (!seen.add(raw)) continue;
      (uri.scheme == 'ws' && _isPrivateHost(host) ? lan : remote).add(raw);
    }
    return <String>[...lan, ...remote];
  }

  /// 复制一份载荷，只替换首选地址（用于选定可达端点后重新配对）。
  PairingPayload withUrl(String url) => PairingPayload(
    version: version,
    publicUrl: url,
    pairingCode: pairingCode,
    expiresAt: expiresAt,
    endpoints: endpoints,
    gatewayId: gatewayId,
    gatewayName: gatewayName,
  );

  static bool _isLoopback(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '0.0.0.0' ||
      host == '10.0.2.1'; // Android 模拟器宿主回环

  static bool _isPrivateHost(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final first = int.tryParse(parts[0]);
    final second = int.tryParse(parts[1]);
    if (first == null || second == null) return false;
    if (first == 10) return true;
    if (first == 172 && second >= 16 && second <= 31) return true;
    if (first == 192 && second == 168) return true;
    return false;
  }

  /// 二维码 / 粘贴内容的解码入口。任何不合规输入都抛出 [PairingException]，
  /// 由页面转成人类可读提示。
  factory PairingPayload.decode(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const PairingException('配对内容为空');
    }
    if (text.startsWith('{')) {
      throw const PairingException('不支持原始 JSON，请扫描 Host 生成的二维码');
    }
    if (text.contains('=')) {
      throw const PairingException('配对内容不能包含 Base64 padding「=」，请用网关生成的原文');
    }
    if (!_strictBase64Url.hasMatch(text)) {
      throw const PairingException('配对内容含非法字符，只允许 A-Z a-z 0-9 - _');
    }

    late final String decoded;
    try {
      decoded = utf8.decode(base64Url.decode(base64Url.normalize(text)));
    } on FormatException {
      throw const PairingException('配对内容不是合法的 Base64URL');
    }

    late final Object? json;
    try {
      json = jsonDecode(decoded);
    } on FormatException {
      throw const PairingException('配对内容解码后不是 JSON');
    }
    if (json is! Map) {
      throw const PairingException('配对内容解码后不是 JSON 对象');
    }
    return PairingPayload.fromJson(json.cast<String, dynamic>());
  }

  factory PairingPayload.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version != 2) {
      throw PairingException('不支持的配对版本：$version（当前只支持 version 2）');
    }
    final url = json['publicUrl'];
    if (url is! String || url.isEmpty) {
      throw const PairingException('配对内容缺少 publicUrl');
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasScheme ||
        !(uri.scheme == 'ws' || uri.scheme == 'wss')) {
      throw const PairingException('publicUrl 必须是 ws:// 或 wss:// 地址');
    }
    final code = json['pairingCode'];
    if (code is! String || code.isEmpty) {
      throw const PairingException('配对内容缺少 pairingCode');
    }
    final expiresAt = json['expiresAt'];
    if (expiresAt is! int) {
      throw const PairingException('配对内容缺少 expiresAt');
    }
    final rawEndpoints = json['endpoints'];
    final endpoints = rawEndpoints is List
        ? rawEndpoints.whereType<String>().toList(growable: false)
        : const <String>[];
    return PairingPayload(
      version: 2,
      publicUrl: url,
      pairingCode: code,
      expiresAt: expiresAt,
      endpoints: endpoints,
      gatewayId: json['gatewayId'] as String?,
      gatewayName: json['gatewayName'] as String?,
    );
  }

  /// 手动兜底输入（相机不可用、或用户直接粘贴三个字段）。
  factory PairingPayload.manual({
    required String publicUrl,
    required String pairingCode,
  }) {
    final uri = Uri.tryParse(publicUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        !(uri.scheme == 'ws' || uri.scheme == 'wss')) {
      throw const PairingException('地址必须以 ws:// 或 wss:// 开头');
    }
    final code = pairingCode.trim();
    if (code.isEmpty) {
      throw const PairingException('配对码不能为空');
    }
    return PairingPayload(
      publicUrl: publicUrl.trim(),
      pairingCode: code,
      expiresAt: 0,
    );
  }
}

class PairingException implements Exception {
  const PairingException(this.message);

  final String message;

  @override
  String toString() => message;
}
