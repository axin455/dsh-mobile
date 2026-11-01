import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// DeepSeek 账号登录（设备码流程）。
///
/// 与 Hermes 客户端一致：App 只负责展示二维码并轮询，真正的扫码 / 手机号确认
/// 发生在浏览器网页里。登录成功后拿到的是账号令牌，直接走 DeepSeek 余额，
/// 不需要用户填 API Key。
///
/// 端点（预览版由 `tool/mock_gateway` 模拟，可整体替换为线上实现）：
///   POST /auth/device           → {deviceCode,userCode,verifyUrl,expiresIn}
///   GET  /auth/device/<code>    → {status:pending|authorized|expired,...}
///   GET  /auth/me?token=...     → {nickname,balance}
class CloudAuthApi {
  CloudAuthApi({required String baseUrl, HttpClient? httpClient})
    : _baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
      _client = httpClient ?? HttpClient();

  final String _baseUrl;
  final HttpClient _client;
  static const _timeout = Duration(seconds: 12);

  String get baseUrl => _baseUrl;

  Future<DeviceTicket> startDeviceLogin() async {
    final json = await _postJson('/auth/device', const {});
    final deviceCode = json['deviceCode'];
    final userCode = json['userCode'];
    final verifyUrl = json['verifyUrl'];
    final expiresIn = json['expiresIn'];
    if (deviceCode is! String || verifyUrl is! String) {
      throw const CloudAuthException('登录服务返回的数据不完整');
    }
    return DeviceTicket(
      deviceCode: deviceCode,
      userCode: userCode is String ? userCode : '',
      verifyUrl: verifyUrl,
      expiresAt: DateTime.now().add(
        Duration(seconds: expiresIn is int ? expiresIn : 300),
      ),
    );
  }

  Future<DevicePoll> pollDevice(String deviceCode) async {
    final json = await _getJson('/auth/device/$deviceCode');
    final status = json['status'];
    if (status == 'authorized') {
      final token = json['token'];
      if (token is! String || token.isEmpty) {
        throw const CloudAuthException('登录成功但未返回令牌');
      }
      final account = json['account'] is Map
          ? (json['account'] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      final gateway = json['gateway'] is Map
          ? (json['gateway'] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      final wsUrl = gateway['wsUrl'];
      if (wsUrl is! String || wsUrl.isEmpty) {
        throw const CloudAuthException('登录成功但未返回网关地址');
      }
      return DevicePoll.authorized(
        token: token,
        nickname: (account['nickname'] ?? 'DeepSeek 用户').toString(),
        balance: _toDouble(account['balance']),
        gatewayUrl: wsUrl,
      );
    }
    if (status == 'expired') return const DevicePoll.expired();
    return const DevicePoll.pending();
  }

  Future<AccountSnapshot> fetchAccount(String token) async {
    final json = await _getJson(
      '/auth/me?token=${Uri.encodeQueryComponent(token)}',
    );
    return AccountSnapshot(
      nickname: (json['nickname'] ?? 'DeepSeek 用户').toString(),
      balance: _toDouble(json['balance']),
    );
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final uri = Uri.parse('$_baseUrl$path');
    try {
      final request = await _client.postUrl(uri).timeout(_timeout);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().timeout(_timeout);
      return await _decode(response, uri);
    } on CloudAuthException {
      rethrow;
    } on TimeoutException {
      throw CloudAuthException('连接登录服务超时：${uri.origin}');
    } catch (error) {
      throw CloudAuthException('无法连接登录服务 ${uri.origin}：$error');
    }
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final uri = Uri.parse('$_baseUrl$path');
    try {
      final request = await _client.getUrl(uri).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      return await _decode(response, uri);
    } on CloudAuthException {
      rethrow;
    } on TimeoutException {
      throw CloudAuthException('连接登录服务超时：${uri.origin}');
    } catch (error) {
      throw CloudAuthException('无法连接登录服务 ${uri.origin}：$error');
    }
  }

  Future<Map<String, dynamic>> _decode(
    HttpClientResponse response,
    Uri uri,
  ) async {
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw CloudAuthException('登录服务 ${uri.origin} 返回 ${response.statusCode}');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const CloudAuthException('登录服务返回的不是 JSON 对象');
    }
    return decoded.cast<String, dynamic>();
  }

  void dispose() => _client.close(force: true);

  static double _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }
}

class DeviceTicket {
  const DeviceTicket({
    required this.deviceCode,
    required this.userCode,
    required this.verifyUrl,
    required this.expiresAt,
  });

  final String deviceCode;
  final String userCode;
  final String verifyUrl;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  int get secondsLeft {
    final left = expiresAt.difference(DateTime.now()).inSeconds;
    return left < 0 ? 0 : left;
  }
}

class DevicePoll {
  const DevicePoll.pending()
    : status = DevicePollStatus.pending,
      token = null,
      nickname = null,
      balance = null,
      gatewayUrl = null;
  const DevicePoll.expired()
    : status = DevicePollStatus.expired,
      token = null,
      nickname = null,
      balance = null,
      gatewayUrl = null;
  DevicePoll.authorized({
    required this.token,
    required this.nickname,
    required this.balance,
    required this.gatewayUrl,
  }) : status = DevicePollStatus.authorized;

  final DevicePollStatus status;
  final String? token;
  final String? nickname;
  final double? balance;
  final String? gatewayUrl;
}

enum DevicePollStatus { pending, authorized, expired }

class AccountSnapshot {
  const AccountSnapshot({
    required this.nickname,
    required this.balance,
    this.avatarUrl = '',
  });

  final String nickname;
  final double balance;
  final String avatarUrl;
}

class CloudAuthException implements Exception {
  const CloudAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
