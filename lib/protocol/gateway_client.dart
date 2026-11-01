import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/secure_store.dart';
import 'pairing.dart';

enum GatewayPhase {
  idle,
  pairing,
  connecting,
  connected,
  reconnecting,
  unauthorized,
  gatewayDisabled,
  failed,
}

@immutable
class GatewayStatus {
  const GatewayStatus(this.phase, {this.message, this.detail});

  final GatewayPhase phase;
  final String? message;
  final String? detail;

  bool get isConnected => phase == GatewayPhase.connected;

  String get label => switch (phase) {
    GatewayPhase.idle => '未连接',
    GatewayPhase.pairing => '正在连接',
    GatewayPhase.connecting => '正在连接',
    GatewayPhase.connected => '已连接',
    GatewayPhase.reconnecting => '正在重连',
    GatewayPhase.unauthorized => '凭证失效',
    GatewayPhase.gatewayDisabled => '网关未开启',
    GatewayPhase.failed => '连接失败',
  };

  @override
  bool operator ==(Object other) =>
      other is GatewayStatus &&
      other.phase == phase &&
      other.message == message &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(phase, message, detail);
}

/// 单一 WebSocket 连接：UTF-8 JSON 文本帧，帧内 `type` / `kind` 区分方向。
///
/// 配对与鉴权都只用子协议传递凭证（token 不进 URL query）：
/// 配对：`dsh-mobile-v1, dsh-pair.<code>, dsh-device.<id>, dsh-device-name.<b64url(name)>`
/// 重连：`dsh-mobile-v1, dsh-auth.<token>, dsh-device.<id>`
class GatewayClient {
  GatewayClient(this._store);

  final SecureStore _store;

  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  final _statuses = StreamController<GatewayStatus>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retryTimer;
  Timer? _pingTimer;
  Timer? _pongWatchdog;

  String? _endpoint;
  String? _token;
  String? _pairingCode;
  String? _deviceName;

  /// 同一台电脑的候选地址（局域网优先），断线时轮换尝试。
  List<String> _candidates = const <String>[];

  /// 当前凭证来自 DeepSeek 账号登录，而不是自建 Host 配对。
  bool _accountSession = false;
  bool _closedByUser = false;
  int _retryAttempt = 0;
  bool autoReconnect = true;

  /// 断线自动重连的时间预算：只抢 10 秒，过了就停下来等用户手动点连接。
  static const autoRetryWindow = Duration(seconds: 10);
  DateTime? _retryWindowStart;
  Timer? _windowTimer;
  bool _autoRetryExhausted = false;

  GatewayStatus _status = const GatewayStatus(GatewayPhase.idle);

  Stream<Map<String, dynamic>> get frames => _frames.stream;
  Stream<GatewayStatus> get statuses => _statuses.stream;
  GatewayStatus get status => _status;
  String? get endpoint => _endpoint;

  bool get hasCredentials => _token != null && _token!.isNotEmpty;

  void _emitStatus(GatewayStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_statuses.isClosed) _statuses.add(status);
  }

  /// 启动时调用：若 secure storage 里已有 token，直接尝试连接。
  Future<bool> restoreCredentials() async {
    final endpoint = await _store.readEndpoint();
    if (endpoint == null || endpoint.isEmpty) return false;
    final stored = await _store.readCandidates();
    // 二维码里带的候选地址会一起存下来；优先用局域网地址，
    // 避免重启电脑后旧的隧道地址失效还一直重连。
    final list = stored.isEmpty ? <String>[endpoint] : stored;
    for (final candidate in list) {
      final uri = Uri.tryParse(candidate);
      if (uri == null) continue;
      final token = await _store.readTokenFor(SecureStore.originOf(uri));
      if (token == null) continue;
      _endpoint = candidate;
      _token = token;
      _candidates = list;
      return true;
    }
    return false;
  }

  /// 账号登录成功后调用：用登录服务下发的令牌与网关地址直接建连。
  Future<void> connectWithAccount({
    required String gatewayUrl,
    required String token,
  }) async {
    _closedByUser = false;
    _autoRetryExhausted = false;
    _windowTimer?.cancel();
    _windowTimer = null;
    _endpoint = gatewayUrl;
    _token = token;
    _pairingCode = null;
    _accountSession = true;
    await _open(pairing: false);
  }

  /// 启动时优先恢复账号登录；没有账号会话再回落到自建 Host 的设备令牌。
  Future<bool> restoreAccountSession() async {
    final session = await _store.readAccountSession();
    if (session == null) return false;
    final uri = Uri.tryParse(session.gatewayUrl);
    if (uri == null) return false;
    _endpoint = session.gatewayUrl;
    _token = session.token;
    _accountSession = true;
    return true;
  }

  Future<void> signOutAccount() async {
    _closedByUser = true;
    _retryTimer?.cancel();
    await _teardown();
    _token = null;
    _endpoint = null;
    _accountSession = false;
    await _store.clearAccountSession();
    _emitStatus(const GatewayStatus(GatewayPhase.idle));
  }

  Future<void> pair(PairingPayload payload) async {
    if (payload.isExpired) {
      throw const PairingException('配对码已过期，请在 Host 上重新生成二维码');
    }
    _closedByUser = false;
    _autoRetryExhausted = false;
    _windowTimer?.cancel();
    _windowTimer = null;
    _endpoint = payload.publicUrl;
    _pairingCode = payload.pairingCode;
    _token = null;
    _accountSession = false;
    _candidates = payload.candidates;
    await _store.saveCandidates(_candidates);
    await _open(pairing: true);
  }

  /// 等待真正连上（收到 hello）而不是只等 WebSocket 握手成功。
  Future<bool> waitForConnected({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (_status.isConnected) return true;
    final completer = Completer<bool>();
    late StreamSubscription<GatewayStatus> subscription;
    subscription = _statuses.stream.listen((status) {
      if (completer.isCompleted) return;
      if (status.isConnected) {
        completer.complete(true);
      } else if (status.phase == GatewayPhase.failed ||
          status.phase == GatewayPhase.unauthorized ||
          status.phase == GatewayPhase.gatewayDisabled) {
        completer.complete(false);
      }
    });
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    final connected = await completer.future;
    timer.cancel();
    await subscription.cancel();
    return connected;
  }

  Future<void> connectSaved() async {
    if (!hasCredentials) {
      throw const PairingException('尚未配对，请先扫码');
    }
    _closedByUser = false;
    _autoRetryExhausted = false;
    _windowTimer?.cancel();
    _windowTimer = null;
    await _open(pairing: false);
  }

  Future<void> _open({required bool pairing}) async {
    await _teardown();
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw const PairingException('缺少网关地址');
    }
    final uri = Uri.parse(endpoint);
    final deviceId = await _store.readDeviceId();
    _deviceName ??= await _store.readDeviceName();

    final name = _deviceName ?? 'Android';
    final protocols = <String>[
      'dsh-mobile-v1',
      if (pairing)
        'dsh-pair.${_pairingCode ?? ''}'
      else
        'dsh-auth.${_token ?? ''}',
      'dsh-device.$deviceId',
      if (pairing) 'dsh-device-name.${_b64Url(name)}',
    ];

    _emitStatus(
      GatewayStatus(
        pairing ? GatewayPhase.pairing : GatewayPhase.connecting,
        message: uri.host,
      ),
    );

    try {
      final channel = WebSocketChannel.connect(uri, protocols: protocols);
      _channel = channel;
      // 连不上的地址不能一直挂着：握手最多等 6 秒，交给上层换下一个候选地址。
      await channel.ready.timeout(const Duration(seconds: 6));
      debugPrint(
        '[gateway] ready ${uri.toString()} protocol=${channel.protocol} '
        'pairing=$pairing token=${_token == null ? 'none' : 'set'}',
      );
      _retryAttempt = 0;
      _retryWindowStart = null;
      _autoRetryExhausted = false;
      _windowTimer?.cancel();
      _windowTimer = null;
      _subscription = channel.stream.listen(
        _onFrame,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
      _startPing();
      if (!pairing) {
        _emitStatus(GatewayStatus(GatewayPhase.connected, message: uri.host));
      }
    } catch (error) {
      debugPrint('[gateway] open failed: $error');
      unawaited(_teardown());
      _handleFailure(error);
    }
  }

  void _onFrame(dynamic raw) {
    if (raw is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final frame = decoded.cast<String, dynamic>();

    final kind = frame['kind'];
    switch (kind) {
      case 'paired':
        final token = frame['token'];
        if (token is String && token.isNotEmpty) {
          _token = token;
          _pairingCode = null;
          final endpoint = _endpoint;
          if (endpoint != null) {
            _store.saveToken(
              token: token,
              origin: SecureStore.originOf(Uri.parse(endpoint)),
              endpoint: endpoint,
              origins: [
                for (final candidate in _candidates)
                  if (Uri.tryParse(candidate) != null)
                    SecureStore.originOf(Uri.parse(candidate)),
              ],
            );
          }
        }
      case 'hello':
        _emitStatus(GatewayStatus(GatewayPhase.connected, message: _endpoint));
        send(const {'type': 'sessions'});
      case 'pong':
        _pongWatchdog?.cancel();
    }
    if (!_frames.isClosed) _frames.add(frame);
  }

  void _onError(Object error) => _handleFailure(error);

  void _onDone() {
    final channel = _channel;
    final closeCode = channel?.closeCode;
    debugPrint(
      '[gateway] closed code=$closeCode reason=${channel?.closeReason} '
      'byUser=$_closedByUser token=${_token == null ? 'none' : 'set'}',
    );
    _pongWatchdog?.cancel();
    _pingTimer?.cancel();
    if (_closedByUser) return;
    if (closeCode == 4004) {
      _emitStatus(
        const GatewayStatus(
          GatewayPhase.gatewayDisabled,
          message: '移动网关已关闭，停止自动重连',
        ),
      );
      return;
    }
    if (closeCode == 4003) {
      _emitStatus(
        const GatewayStatus(GatewayPhase.unauthorized, message: '服务端重新开启了设备鉴权'),
      );
      return;
    }
    _scheduleRetry();
  }

  void _handleFailure(Object error) {
    final text = error.toString();
    debugPrint('[gateway] failure: $text');
    if (_closedByUser) return;

    if (text.contains('not upgraded') || text.contains('was not upgraded')) {
      // Upgrade 被拒 = 服务端返回了非 101：扫码时多半是配对码已失效，
      // 已配对时则是插件重装后旧令牌失效。两种情况都只能重新扫码。
      if (_status.phase == GatewayPhase.pairing) {
        _emitStatus(
          GatewayStatus(
            GatewayPhase.failed,
            message: '电脑端拒绝了这次配对',
            detail: '配对码可能已经失效，请在电脑上重新生成二维码再扫',
          ),
        );
        return;
      }
      _token = null;
      unawaited(_store.clearToken());
      _emitStatus(
        GatewayStatus(
          GatewayPhase.unauthorized,
          message: '设备令牌已失效，请重新扫码配对',
          detail: '电脑端拒绝了旧连接',
        ),
      );
      return;
    }
    if (text.contains('401')) {
      final wasAccount = _accountSession;
      _token = null;
      unawaited(
        wasAccount ? _store.clearAccountSession() : _store.clearToken(),
      );
      _emitStatus(
        GatewayStatus(
          GatewayPhase.unauthorized,
          message: wasAccount ? '登录已失效，请重新登录' : '设备令牌已失效，请重新扫码配对',
          detail: '401 Unauthorized',
        ),
      );
      return;
    }
    if (text.contains('503')) {
      _emitStatus(
        const GatewayStatus(
          GatewayPhase.gatewayDisabled,
          message: 'Host 上的移动网关未开启',
          detail: '503 Service Unavailable',
        ),
      );
      return;
    }
    if (_status.phase == GatewayPhase.pairing) {
      _emitStatus(
        GatewayStatus(
          GatewayPhase.failed,
          message: '无法连接 ${_endpoint ?? ''}',
          detail: text,
        ),
      );
      return;
    }
    _scheduleRetry(detail: text);
  }

  void _scheduleRetry({String? detail}) {
    if (!autoReconnect ||
        _closedByUser ||
        !hasCredentials ||
        _autoRetryExhausted) {
      _retryWindowStart = null;
      _emitStatus(
        _autoRetryExhausted
            ? const GatewayStatus(
                GatewayPhase.failed,
                message: '自动重连已停止',
                detail: '点「连接」重新连接电脑',
              )
            : GatewayStatus(
                GatewayPhase.failed,
                message: '连接已断开',
                detail: detail,
              ),
      );
      return;
    }
    // 自动重连只抢一段时间，过了就停下等用户手动点「连接」。
    final start = _retryWindowStart ??= DateTime.now();
    final elapsed = DateTime.now().difference(start);
    if (elapsed >= autoRetryWindow) {
      _exhaustAutoRetry();
      return;
    }
    // 硬截止：即使正在等握手，也到点就停，不再无限拖下去。
    _windowTimer ??= Timer(autoRetryWindow - elapsed, _exhaustAutoRetry);
    // 有上限的指数退避：1, 2, 4, 8, 16, 30 ...
    const delays = [1, 2, 4, 8, 16, 30];
    final seconds = delays[_retryAttempt.clamp(0, delays.length - 1)];
    _retryAttempt++;
    final remaining = autoRetryWindow - elapsed;
    final wait = Duration(
      milliseconds: math.min(seconds * 1000, remaining.inMilliseconds),
    );
    _emitStatus(
      GatewayStatus(
        GatewayPhase.reconnecting,
        message: '已断开，${math.max(wait.inMilliseconds ~/ 1000, 1)}s 后重连',
        detail: detail,
      ),
    );
    _retryTimer?.cancel();
    _retryTimer = Timer(wait, () {
      if (_closedByUser) return;
      _rotateEndpoint();
      unawaited(_open(pairing: false));
    });
  }

  /// 预算用完：停掉退避、放弃正在等握手的连接，交给用户手动点「连接」。
  void _exhaustAutoRetry() {
    if (_status.isConnected) return;
    _autoRetryExhausted = true;
    _retryTimer?.cancel();
    _windowTimer?.cancel();
    _windowTimer = null;
    _retryWindowStart = null;
    _retryAttempt = 0;
    unawaited(_teardown());
    _emitStatus(
      const GatewayStatus(
        GatewayPhase.failed,
        message: '自动重连已停止',
        detail: '点「连接」重新连接电脑',
      ),
    );
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_status.phase != GatewayPhase.connected) return;
      send(const {'type': 'ping'});
      _pongWatchdog?.cancel();
      _pongWatchdog = Timer(const Duration(seconds: 45), () {
        _channel?.sink.close();
      });
    });
  }

  void send(Map<String, dynamic> frame) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode(frame));
    } catch (_) {
      // 连接已坏，交给 close/error 回调处理重连。
    }
  }

  Future<void> disconnect({bool forget = false}) async {
    _closedByUser = true;
    _retryTimer?.cancel();
    _windowTimer?.cancel();
    _windowTimer = null;
    _retryWindowStart = null;
    _retryAttempt = 0;
    _autoRetryExhausted = false;
    await _teardown();
    if (forget) {
      _token = null;
      _endpoint = null;
      _accountSession = false;
      await _store.clearToken();
      _emitStatus(const GatewayStatus(GatewayPhase.idle));
    } else {
      _emitStatus(const GatewayStatus(GatewayPhase.idle, message: '已断开连接'));
    }
  }

  /// 换到下一个候选地址（局域网 ↔ 隧道）。返回是否真的换了。
  bool _rotateEndpoint() {
    if (_candidates.length <= 1 || _endpoint == null) return false;
    final index = _candidates.indexOf(_endpoint!);
    _endpoint = _candidates[(index + 1) % _candidates.length];
    return true;
  }

  Future<void> retryNow() async {
    _retryTimer?.cancel();
    _windowTimer?.cancel();
    _windowTimer = null;
    _retryAttempt = 0;
    _retryWindowStart = null;
    _autoRetryExhausted = false;
    _closedByUser = false;
    _rotateEndpoint();
    await connectSaved();
  }

  Future<void> _teardown() async {
    _pingTimer?.cancel();
    _pongWatchdog?.cancel();
    _pingTimer = null;
    _retryTimer?.cancel();
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    await subscription?.cancel();
    // 已断开的 socket 上 close() 可能迟迟不完成，不能阻塞重连流程。
    unawaited(channel?.sink.close().catchError((_) {}));
  }

  void dispose() {
    _closedByUser = true;
    _windowTimer?.cancel();
    _teardown();
    _frames.close();
    _statuses.close();
  }

  static String _b64Url(String text) =>
      base64Url.encode(utf8.encode(text)).replaceAll('=', '');
}
