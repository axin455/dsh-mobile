import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 设备凭证的唯一落盘位置。
///
/// flutter_secure_storage 11.x 在 Android 端走 Keystore 支持的 AES 加密存储，
/// `AndroidOptions.encryptedSharedPreferences` 已被移除，不能再传该参数。
/// 这里存两类凭证：
///   1. 自建 Host 配对得到的设备 token（origin 绑定）；
///   2. DeepSeek 账号登录得到的账号 token + 网关地址 + 昵称/余额。
/// 账号 token 与设备 token 互不覆盖，退出登录不会破坏已配对的自建 Host。
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
    : _storage =
          storage ?? const FlutterSecureStorage(aOptions: AndroidOptions());

  static const _keyDeviceId = 'dsh.device.id';
  static const _keyToken = 'dsh.device.token';
  static const _keyOrigin = 'dsh.device.token.origin';
  static const _keyEndpoint = 'dsh.gateway.endpoint';
  static const _keyCandidates = 'dsh.gateway.candidates';
  static const _keyOrigins = 'dsh.device.token.origins';
  static const _keyDeviceName = 'dsh.device.name';

  static const _keyAccountToken = 'dsh.account.token';
  static const _keyAccountGateway = 'dsh.account.gateway';
  static const _keyAccountNickname = 'dsh.account.nickname';
  static const _keyAccountBalance = 'dsh.account.balance';

  /// 电脑端 DSH 的账号资料缓存：断网/重启后仍能显示是谁在登录。
  static const _keyHostNickname = 'dsh.host.nickname';
  static const _keyHostAvatar = 'dsh.host.avatar';
  static const _keyHostBalance = 'dsh.host.balance';

  /// 供应商 API Key：按供应商 id 分开存，切换供应商不会互相覆盖。
  static String _providerKey(String providerId) =>
      'dsh.provider.$providerId.key';

  final FlutterSecureStorage _storage;

  Future<String> readDeviceId() async {
    final existing = await _storage.read(key: _keyDeviceId);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final id = _randomHex(16);
    await _storage.write(key: _keyDeviceId, value: id);
    return id;
  }

  Future<String?> readDeviceName() => _storage.read(key: _keyDeviceName);

  Future<void> writeDeviceName(String name) =>
      _storage.write(key: _keyDeviceName, value: name);

  Future<String?> readEndpoint() => _storage.read(key: _keyEndpoint);

  /// 读取与 [origin] 绑定的 token。Origin 不匹配时返回 null：
  /// 设备令牌只发往精确 Origin，禁止跨 Origin 复用。
  Future<String?> readTokenFor(String origin) async {
    final token = await _storage.read(key: _keyToken);
    if (token == null || token.isEmpty) return null;
    final raw = await _storage.read(key: _keyOrigins);
    if (raw != null && raw.isNotEmpty) {
      final list = (jsonDecode(raw) as List).cast<String>();
      if (list.contains(origin)) return token;
    }
    // 兼容旧版本：只存过一个 origin 的情况。
    final storedOrigin = await _storage.read(key: _keyOrigin);
    if (storedOrigin != origin) return null;
    return token;
  }

  Future<void> saveToken({
    required String token,
    required String origin,
    required String endpoint,
    List<String>? origins,
  }) async {
    await _storage.write(key: _keyToken, value: token);
    await _storage.write(key: _keyOrigin, value: origin);
    await _storage.write(key: _keyEndpoint, value: endpoint);
    // 同一台电脑的局域网 / 隧道地址共享同一个设备令牌：
    // 这样隧道失效时可以立刻换局域网地址，不用重新扫码。
    final all = <String>{origin, ...?origins};
    await _storage.write(key: _keyOrigins, value: jsonEncode(all.toList()));
  }

  Future<void> saveCandidates(List<String> candidates) async {
    await _storage.write(key: _keyCandidates, value: jsonEncode(candidates));
  }

  Future<List<String>> readCandidates() async {
    final raw = await _storage.read(key: _keyCandidates);
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.cast<String>();
    } catch (_) {
      // 兼容旧格式：单个地址字符串。
    }
    return <String>[raw];
  }

  Future<void> clearToken() async {
    await _storage.delete(key: _keyToken);
    await _storage.delete(key: _keyOrigin);
    await _storage.delete(key: _keyEndpoint);
    await _storage.delete(key: _keyOrigins);
    await _storage.delete(key: _keyCandidates);
  }

  /// 账号令牌只发往登录时下发的网关地址，换网关即视为需要重新登录。
  Future<AccountSession?> readAccountSession() async {
    final token = await _storage.read(key: _keyAccountToken);
    final gatewayUrl = await _storage.read(key: _keyAccountGateway);
    if (token == null ||
        token.isEmpty ||
        gatewayUrl == null ||
        gatewayUrl.isEmpty) {
      return null;
    }
    return AccountSession(token: token, gatewayUrl: gatewayUrl);
  }

  Future<void> saveAccountSession({
    required String token,
    required String gatewayUrl,
    required String nickname,
    required double balance,
  }) async {
    await _storage.write(key: _keyAccountToken, value: token);
    await _storage.write(key: _keyAccountGateway, value: gatewayUrl);
    await _storage.write(key: _keyAccountNickname, value: nickname);
    await _storage.write(key: _keyAccountBalance, value: balance.toString());
  }

  Future<AccountProfile?> readAccountProfile() async {
    final nickname = await _storage.read(key: _keyAccountNickname);
    if (nickname == null || nickname.isEmpty) return null;
    final balance = double.tryParse(
      await _storage.read(key: _keyAccountBalance) ?? '',
    );
    return AccountProfile(nickname: nickname, balance: balance ?? 0);
  }

  Future<void> updateAccountProfile({
    required String nickname,
    required double balance,
  }) async {
    await _storage.write(key: _keyAccountNickname, value: nickname);
    await _storage.write(key: _keyAccountBalance, value: balance.toString());
  }

  Future<void> clearAccountSession() async {
    await _storage.delete(key: _keyAccountToken);
    await _storage.delete(key: _keyAccountGateway);
    await _storage.delete(key: _keyAccountNickname);
    await _storage.delete(key: _keyAccountBalance);
  }

  Future<HostProfile?> readHostProfile() async {
    final nickname = await _storage.read(key: _keyHostNickname);
    if (nickname == null || nickname.isEmpty) return null;
    return HostProfile(
      nickname: nickname,
      avatarUrl: await _storage.read(key: _keyHostAvatar) ?? '',
      balance: double.tryParse(
            await _storage.read(key: _keyHostBalance) ?? '',
          ) ??
          0,
    );
  }

  Future<void> saveHostProfile({
    required String nickname,
    required String avatarUrl,
    required double balance,
  }) async {
    await _storage.write(key: _keyHostNickname, value: nickname);
    await _storage.write(key: _keyHostAvatar, value: avatarUrl);
    await _storage.write(key: _keyHostBalance, value: balance.toString());
  }

  Future<void> clearHostProfile() async {
    await _storage.delete(key: _keyHostNickname);
    await _storage.delete(key: _keyHostAvatar);
    await _storage.delete(key: _keyHostBalance);
  }

  Future<String?> readProviderKey(String providerId) =>
      _storage.read(key: _providerKey(providerId));

  Future<void> saveProviderKey({
    required String providerId,
    required String apiKey,
  }) => _storage.write(key: _providerKey(providerId), value: apiKey);

  Future<void> clearProviderKey(String providerId) =>
      _storage.delete(key: _providerKey(providerId));

  static String originOf(Uri uri) =>
      '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';

  static String _randomHex(int bytes) {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

class AccountSession {
  const AccountSession({required this.token, required this.gatewayUrl});

  final String token;
  final String gatewayUrl;
}

class AccountProfile {
  const AccountProfile({required this.nickname, required this.balance});

  final String nickname;
  final double balance;
}

/// 电脑端 DSH（DeepSeek 账号）的资料缓存。
class HostProfile {
  const HostProfile({
    required this.nickname,
    required this.avatarUrl,
    required this.balance,
  });

  final String nickname;
  final String avatarUrl;
  final double balance;
}
