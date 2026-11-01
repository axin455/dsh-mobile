import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/secure_store.dart';
import '../data/settings.dart';
import '../protocol/cloud_auth.dart';
import 'app_providers.dart';

enum AuthPhase { restoring, signedOut, starting, pending, authorized, error }

@immutable
class AuthState {
  const AuthState({
    this.phase = AuthPhase.restoring,
    this.profile,
    this.ticket,
    this.error,
    this.hostMode = false,
  });

  final AuthPhase phase;
  final AccountSnapshot? profile;
  final DeviceTicket? ticket;
  final String? error;

  /// 「已登录」来自扫一扫配对的电脑，而不是 DeepSeek 账号或 API Key。
  final bool hostMode;

  bool get authorized => phase == AuthPhase.authorized;

  bool get waiting => phase == AuthPhase.starting || phase == AuthPhase.pending;

  AuthState copyWith({
    AuthPhase? phase,
    AccountSnapshot? profile,
    DeviceTicket? ticket,
    String? error,
    bool clearError = false,
    bool? hostMode,
  }) => AuthState(
    phase: phase ?? this.phase,
    profile: profile ?? this.profile,
    ticket: ticket ?? this.ticket,
    error: clearError ? null : (error ?? this.error),
    hostMode: hostMode ?? this.hostMode,
  );
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);

/// 设备码登录的客户端状态机。
///
/// 二维码与「在浏览器中打开」指向同一个登录网页：用户在网页里扫码或输入手机号
/// 确认后，本机每 2 秒轮询一次结果，拿到账号令牌即可直接用余额对话。
class AuthNotifier extends Notifier<AuthState> {
  Timer? _pollTimer;
  bool _polling = false;

  @override
  AuthState build() {
    ref.onDispose(() {
      _pollTimer?.cancel();
      _pollTimer = null;
    });
    unawaited(Future.microtask(_restore));
    return const AuthState();
  }

  CloudAuthApi _api() =>
      CloudAuthApi(baseUrl: ref.read(settingsProvider).authBaseUrl);

  /// 恢复登录态时任何安全存储异常都按「未登录」处理，避免直接闪退。
  Future<void> _restore() async {
    try {
      await _restoreInner();
    } catch (_) {
      state = const AuthState(phase: AuthPhase.signedOut);
    }
  }

  Future<void> _restoreInner() async {
    final settings = ref.read(settingsProvider);
    final store = ref.read(secureStoreProvider);
    final endpoint = await store.readEndpoint();
    final token = endpoint == null || Uri.tryParse(endpoint) == null
        ? null
        : await store.readTokenFor(SecureStore.originOf(Uri.parse(endpoint)));
    final hostProfile = await store.readHostProfile();

    // 扫码配对的优先级高于 API Key：同步过来的凭据只负责「本地直连」，
    // 登录身份仍然应该是电脑上的 DeepSeek 账号。
    if (settings.hostMode && token != null && token.isNotEmpty) {
      if (!settings.pcLinkPluginEnabled) {
        await ref.read(settingsProvider.notifier).setPcLinkPluginEnabled(true);
      }
      state = AuthState(
        phase: AuthPhase.authorized,
        hostMode: true,
        profile: AccountSnapshot(
          nickname: hostProfile?.nickname ?? '电脑上的 DSH',
          balance: hostProfile?.balance ?? 0,
          avatarUrl: hostProfile?.avatarUrl ?? '',
        ),
      );
      return;
    }
    if (settings.apiKeyModeEnabled) {
      final credential = settings.activeCredential;
      state = AuthState(
        phase: AuthPhase.authorized,
        profile: AccountSnapshot(
          nickname: credential?.name ?? 'API Key',
          balance: 0,
        ),
      );
      return;
    }
    final profile = await store.readAccountProfile();
    final session = await store.readAccountSession();
    if (profile != null && session != null) {
      state = AuthState(
        phase: AuthPhase.authorized,
        profile: AccountSnapshot(
          nickname: profile.nickname,
          balance: profile.balance,
        ),
      );
      return;
    }
    // 旧版本可能只配对了设备但没打开「电脑端互联」；恢复登录态时补开，
    // 否则对话页不会显示电脑端入口，看起来像「扫码成功但什么都看不到」。
    if (endpoint != null && token != null && token.isNotEmpty) {
      if (!settings.pcLinkPluginEnabled) {
        await ref.read(settingsProvider.notifier).setPcLinkPluginEnabled(true);
      }
      await ref.read(settingsProvider.notifier).setHostMode(true);
      state = AuthState(
        phase: AuthPhase.authorized,
        hostMode: true,
        profile: AccountSnapshot(
          nickname: hostProfile?.nickname ?? '电脑上的 DSH',
          balance: hostProfile?.balance ?? 0,
          avatarUrl: hostProfile?.avatarUrl ?? '',
        ),
      );
      return;
    }
    state = const AuthState(phase: AuthPhase.signedOut);
  }

  /// 已登录的 API Key 增删后重新判断登录态（例如移除最后一家供应商）。
  Future<void> reload() => _restore();

  /// 登录页首帧调用：只在未登录状态下发起新的设备码。
  Future<void> ensureStarted() async {
    if (state.phase == AuthPhase.restoring ||
        state.phase == AuthPhase.starting ||
        state.phase == AuthPhase.pending ||
        state.phase == AuthPhase.authorized) {
      return;
    }
    await begin();
  }

  /// 生成（或刷新）一张新二维码。
  Future<void> begin() async {
    _pollTimer?.cancel();
    state = AuthState(phase: AuthPhase.starting, ticket: state.ticket);
    final api = _api();
    try {
      final ticket = await api.startDeviceLogin();
      state = AuthState(phase: AuthPhase.pending, ticket: ticket);
      _startPolling();
    } on CloudAuthException catch (error) {
      state = AuthState(phase: AuthPhase.error, error: error.message);
    } catch (error) {
      state = AuthState(phase: AuthPhase.error, error: '登录服务异常：$error');
    } finally {
      api.dispose();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_poll()),
    );
  }

  Future<void> _poll() async {
    final ticket = state.ticket;
    if (ticket == null || _polling) return;
    if (ticket.isExpired) {
      unawaited(begin());
      return;
    }
    _polling = true;
    final api = _api();
    try {
      final result = await api.pollDevice(ticket.deviceCode);
      switch (result.status) {
        case DevicePollStatus.authorized:
          await _onAuthorized(result);
        case DevicePollStatus.expired:
          unawaited(begin());
        case DevicePollStatus.pending:
          if (state.error != null) {
            state = state.copyWith(clearError: true);
          }
      }
    } on CloudAuthException catch (error) {
      // 轮询中的网络抖动不中断登录，下一次轮询自动恢复。
      if (state.phase == AuthPhase.pending) {
        state = state.copyWith(error: error.message);
      }
    } finally {
      _polling = false;
      api.dispose();
    }
  }

  Future<void> _onAuthorized(DevicePoll result) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final token = result.token;
    final gatewayUrl = result.gatewayUrl;
    if (token == null || gatewayUrl == null) return;
    final nickname = result.nickname ?? 'DeepSeek 用户';
    final balance = result.balance ?? 0;

    await ref
        .read(secureStoreProvider)
        .saveAccountSession(
          token: token,
          gatewayUrl: gatewayUrl,
          nickname: nickname,
          balance: balance,
        );
    await ref.read(settingsProvider.notifier).setGuestMode(false);
    await ref.read(settingsProvider.notifier).setHostMode(false);
    state = AuthState(
      phase: AuthPhase.authorized,
      profile: AccountSnapshot(nickname: nickname, balance: balance),
    );
    unawaited(
      ref
          .read(linkProvider.notifier)
          .signIn(gatewayUrl: gatewayUrl, token: token),
    );
  }

  /// 用供应商 API Key 登录：Key 本体已由页面写进 secure storage，
  /// 这里只落设置并切到「已登录」，对话改走该供应商直连。
  /// 多次调用会把不同供应商叠加在已登录列表里，不再覆盖上一家。
  Future<void> signInWithApiKey({required ApiCredential credential}) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await ref
        .read(settingsProvider.notifier)
        .upsertApiCredential(credential);
    await ref.read(settingsProvider.notifier).setHostMode(false);
    state = AuthState(
      phase: AuthPhase.authorized,
      profile: AccountSnapshot(nickname: credential.name, balance: 0),
    );
  }

  /// 扫码配对成功：电脑上的 DSH 已经登录过，本机直接复用那台电脑的会话。
  Future<void> signInWithHost({String? name}) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final settings = ref.read(settingsProvider.notifier);
    await settings.setGuestMode(false);
    // 扫码就是为了用电脑端，必须同时打开「电脑端互联」，否则入口会被隐藏。
    await settings.setPcLinkPluginEnabled(true);
    await settings.setHostMode(true);
    final cached = await ref.read(secureStoreProvider).readHostProfile();
    state = AuthState(
      phase: AuthPhase.authorized,
      hostMode: true,
      profile: AccountSnapshot(
        nickname: cached?.nickname ?? name ?? '电脑上的 DSH',
        balance: cached?.balance ?? 0,
        avatarUrl: cached?.avatarUrl ?? '',
      ),
    );
  }

  /// 登录页「稍后登录」：跳过登录直接进主界面（只能浏览，不能对话）。
  Future<void> continueAsGuest() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await ref.read(settingsProvider.notifier).setGuestMode(true);
    await ref.read(settingsProvider.notifier).setHostMode(false);
    state = const AuthState(phase: AuthPhase.signedOut);
  }

  /// 打开登录网页（扫码与手机号是同一个页面，`phone=1` 只是聚焦手机号表单）。
  ///
  /// 没有拿到登录链接时先现取一张，避免按钮点了「没反应」。
  Future<void> openInBrowser({bool phone = false}) async {
    var ticket = state.ticket;
    if (ticket == null || ticket.isExpired) {
      await begin();
      ticket = state.ticket;
    }
    if (ticket == null) return;
    final base = Uri.parse(ticket.verifyUrl);
    final uri = phone
        ? base.replace(queryParameters: {...base.queryParameters, 'phone': '1'})
        : base;
    try {
      var opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        opened = await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
      if (!opened && !state.authorized) {
        state = state.copyWith(error: '无法打开浏览器，请检查系统默认浏览器');
      }
    } catch (error) {
      state = state.copyWith(error: '无法打开浏览器：$error');
    }
  }

  Future<void> refreshBalance() async {
    if (state.hostMode) {
      await ref.read(linkProvider.notifier).refreshHostState();
      return;
    }
    final session = await ref.read(secureStoreProvider).readAccountSession();
    final profile = state.profile;
    if (session == null || profile == null) return;
    final api = _api();
    try {
      final snapshot = await api.fetchAccount(session.token);
      await ref
          .read(secureStoreProvider)
          .updateAccountProfile(
            nickname: snapshot.nickname,
            balance: snapshot.balance,
          );
      state = state.copyWith(profile: snapshot, clearError: true);
    } on CloudAuthException catch (error) {
      state = state.copyWith(error: error.message);
    } finally {
      api.dispose();
    }
  }

  Future<void> signOut() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final settings = ref.read(settingsProvider);
    if (settings.credentials.isNotEmpty) {
      for (final credential in settings.credentials) {
        await ref
            .read(secureStoreProvider)
            .clearProviderKey(credential.providerId);
      }
      await ref.read(settingsProvider.notifier).clearApiKeyAccount();
    }
    await ref.read(settingsProvider.notifier).removeHostSyncedCredentials(
      ref.read(secureStoreProvider),
    );
    if (state.hostMode) {
      await ref.read(linkProvider.notifier).unpair();
    }
    await ref.read(linkProvider.notifier).signOut();
    await ref.read(secureStoreProvider).clearAccountSession();
    await ref.read(secureStoreProvider).clearHostProfile();
    await ref.read(settingsProvider.notifier).setHostMode(false);
    await ref.read(settingsProvider.notifier).setGuestMode(false);
    state = const AuthState(phase: AuthPhase.signedOut, ticket: null);
  }
}
