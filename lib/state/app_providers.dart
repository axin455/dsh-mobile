import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/secure_store.dart';
import '../data/session_store.dart';
import '../data/settings.dart';
import '../protocol/gateway_client.dart';
import '../protocol/host_state.dart';
import '../protocol/pairing.dart';

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore());

final sessionStoreProvider = Provider<SessionStore>((ref) {
  final store = SessionStore();
  ref.onDispose(store.close);
  return store;
});

/// 由 `main()` 在 `runApp` 前同步注入，避免首帧闪烁。
final initialSettingsProvider = Provider<AppSettings>(
  (ref) => const AppSettings(),
);

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

final gatewayProvider = Provider<GatewayClient>((ref) {
  final client = GatewayClient(ref.watch(secureStoreProvider));
  ref.onDispose(client.dispose);
  return client;
});

/// 展开输入时隐藏 dock，把整块下 2/3 让给编辑区。
final inputExpandedProvider = NotifierProvider<InputExpandedNotifier, bool>(
  InputExpandedNotifier.new,
);

class InputExpandedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setExpanded(bool value) => state = value;
}

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(initialSettingsProvider);

  Future<void> _commit(AppSettings next) async {
    state = next;
    await ref.read(settingsStoreProvider).save(next);
  }

  Future<void> setThemeMode(ThemeMode mode) =>
      _commit(state.copyWith(themeMode: mode));

  Future<void> setStartStrategy(StartStrategy strategy) =>
      _commit(state.copyWith(startStrategy: strategy));

  Future<void> setStreaming(bool value) =>
      _commit(state.copyWith(streaming: value));

  Future<void> setAutoScroll(bool value) =>
      _commit(state.copyWith(autoScroll: value));

  Future<void> setAutoReconnect(bool value) async {
    ref.read(gatewayProvider).autoReconnect = value;
    await _commit(state.copyWith(autoReconnect: value));
  }

  Future<void> setKeepDays(int days) =>
      _commit(state.copyWith(keepDays: days.clamp(1, 365)));

  Future<void> setModelNaming(bool value) =>
      _commit(state.copyWith(modelNaming: value));

  Future<void> setPcLinkPluginEnabled(bool value) =>
      _commit(state.copyWith(pcLinkPluginEnabled: value));

  Future<void> setContextLimit(int tokens) =>
      _commit(state.copyWith(contextLimit: tokens));

  Future<void> setThinking(ThinkingLevel level) =>
      _commit(state.copyWith(thinking: level));

  Future<void> setModel(String model) => _commit(state.copyWith(model: model));

  Future<void> setBaseUrl(String url) => _commit(state.copyWith(baseUrl: url));

  Future<void> setGuestMode(bool value) =>
      _commit(state.copyWith(guestMode: value));

  Future<void> setHostMode(bool value) =>
      _commit(state.copyWith(hostMode: value));

  Future<void> setChatScope(String scope) =>
      _commit(state.copyWith(chatScope: scope));

  /// 本地模式选用电脑 DeepSeek 账号的模型；清空则回到本机 API Key。
  Future<void> setLocalHostModel({
    required String provider,
    required String model,
    required String name,
  }) => _commit(
    state.copyWith(
      localHostModelProvider: provider,
      localHostModelId: model,
      localHostModelName: name,
    ),
  );

  Future<void> clearLocalHostModel() => _commit(
    state.copyWith(
      localHostModelProvider: '',
      localHostModelId: '',
      localHostModelName: '',
    ),
  );

  /// 缓存电脑下发的账号模型目录；断连后仍能在模型面板里看到并置灰展示。
  Future<void> cacheHostModels(List<HostModelOption> models) {
    if (models.isEmpty) return Future<void>.value();
    return _commit(state.copyWith(hostModelsCache: models));
  }

  Future<void> clearHostModelsCache() =>
      _commit(state.copyWith(hostModelsCache: const <HostModelOption>[]));

  Future<void> setAuthBaseUrl(String url) =>
      _commit(state.copyWith(authBaseUrl: url));

  /// 保存一家供应商的 API Key 选择（Key 本体已在 secure storage），并设为当前使用。
  Future<void> upsertApiCredential(
    ApiCredential credential, {
    bool makeActive = true,
  }) {
    final existingIndex = state.credentials.indexWhere(
      (item) => item.providerId == credential.providerId,
    );
    final credentials = [...state.credentials];
    if (existingIndex >= 0) {
      credentials[existingIndex] = credential;
    } else {
      credentials.add(credential);
    }
    return _commit(
      state.copyWith(
        credentials: credentials,
        activeProviderId: makeActive
            ? credential.providerId
            : state.activeProviderId,
        localHostModelProvider: makeActive
            ? ''
            : state.localHostModelProvider,
        localHostModelId: makeActive ? '' : state.localHostModelId,
        localHostModelName: makeActive ? '' : state.localHostModelName,
        guestMode: false,
      ),
    );
  }

  /// 只切换当前使用哪一家，不改变已登录列表。
  Future<void> selectApiCredential({
    required String providerId,
    String? model,
  }) {
    final credentials = [
      for (final item in state.credentials)
        if (item.providerId == providerId && model != null)
          item.copyWith(model: model)
        else
          item,
    ];
    return _commit(
      state.copyWith(
        credentials: credentials,
        activeProviderId: providerId,
        localHostModelProvider: '',
        localHostModelId: '',
        localHostModelName: '',
      ),
    );
  }

  /// 电脑端下发的供应商凭据：按 providerId 合并，保留用户已选模型；
  /// 本机还没有任何凭据时自动设为当前供应商。
  Future<void> syncHostCredentials(List<ApiCredential> incoming) async {
    if (incoming.isEmpty) return;
    final merged = <String, ApiCredential>{
      for (final item in state.credentials) item.providerId: item,
    };
    for (final item in incoming) {
      final existing = merged[item.providerId];
      merged[item.providerId] = existing == null
          ? item
          : item.copyWith(
              model: (existing.model.isEmpty ? item.model : existing.model),
            );
    }
    final credentials = merged.values.toList(growable: false);
    var activeProviderId = state.activeProviderId;
    if (activeProviderId.isEmpty ||
        !credentials.any((item) => item.providerId == activeProviderId)) {
      activeProviderId = incoming.first.providerId;
    }
    await _commit(
      state.copyWith(
        credentials: credentials,
        activeProviderId: activeProviderId,
        guestMode: false,
      ),
    );
  }

  /// 退出电脑端登录时清理同步过来的凭据（含 Keystore 中的 Key）。
  Future<void> removeHostSyncedCredentials(SecureStore store) async {
    final synced = state.credentials
        .where((item) => item.providerId.startsWith('pc:'))
        .toList(growable: false);
    if (synced.isEmpty) {
      if (state.localHostModelEnabled) await clearLocalHostModel();
      return;
    }
    for (final item in synced) {
      await store.clearProviderKey(item.providerId);
    }
    final credentials = state.credentials
        .where((item) => !item.providerId.startsWith('pc:'))
        .toList(growable: false);
    final activeProviderId = credentials.isEmpty
        ? ''
        : (credentials.any((item) => item.providerId == state.activeProviderId)
              ? state.activeProviderId
              : credentials.first.providerId);
    await _commit(
      state.copyWith(
        credentials: credentials,
        activeProviderId: activeProviderId,
        localHostModelProvider: '',
        localHostModelId: '',
        localHostModelName: '',
      ),
    );
  }

  Future<void> removeApiCredential(String providerId) {
    final credentials = state.credentials
        .where((item) => item.providerId != providerId)
        .toList(growable: false);
    final activeProviderId = state.activeProviderId == providerId
        ? (credentials.isEmpty ? '' : credentials.first.providerId)
        : state.activeProviderId;
    return _commit(
      state.copyWith(
        credentials: credentials,
        activeProviderId: activeProviderId,
      ),
    );
  }

  Future<void> clearApiKeyAccount() => _commit(
    state.copyWith(credentials: const <ApiCredential>[], activeProviderId: ''),
  );

  Future<void> setPinnedSession(String? sessionId) => sessionId == null
      ? _commit(state.copyWith(clearPinnedSession: true))
      : _commit(state.copyWith(pinnedSessionId: sessionId));

  Future<void> rememberSession(String sessionId) async {
    if (state.startStrategy != StartStrategy.restoreLast) return;
    if (state.pinnedSessionId == sessionId) return;
    await _commit(state.copyWith(pinnedSessionId: sessionId));
  }
}

@immutable
class LinkState {
  const LinkState({
    this.status = const GatewayStatus(GatewayPhase.idle),
    this.paired = false,
    this.endpoint,
    this.deviceName,
    this.account,
    this.credentials = const <SyncedCredential>[],
    this.accountModels = const <HostModelOption>[],
  });

  final GatewayStatus status;
  final bool paired;
  final String? endpoint;
  final String? deviceName;

  /// 电脑上 DSH 登录的 DeepSeek 账号资料。
  final HostAccount? account;

  /// 电脑下发并可直连的供应商凭据（Key 本体不在这里）。
  final List<SyncedCredential> credentials;

  /// 电脑上 DeepSeek 账号自带的模型（deepseek-flash / deepseek-v4-pro）。
  final List<HostModelOption> accountModels;

  LinkState copyWith({
    GatewayStatus? status,
    bool? paired,
    String? endpoint,
    String? deviceName,
    HostAccount? account,
    List<SyncedCredential>? credentials,
    List<HostModelOption>? accountModels,
  }) => LinkState(
    status: status ?? this.status,
    paired: paired ?? this.paired,
    endpoint: endpoint ?? this.endpoint,
    deviceName: deviceName ?? this.deviceName,
    account: account ?? this.account,
    credentials: credentials ?? this.credentials,
    accountModels: accountModels ?? this.accountModels,
  );
}

final linkProvider = NotifierProvider<LinkNotifier, LinkState>(
  LinkNotifier.new,
);

class LinkNotifier extends Notifier<LinkState> {
  @override
  LinkState build() {
    final client = ref.watch(gatewayProvider);
    final subscription = client.statuses.listen((status) {
      state = state.copyWith(status: status, paired: client.hasCredentials);
    });
    final frames = client.frames.listen(_onFrame);
    ref.onDispose(subscription.cancel);
    ref.onDispose(frames.cancel);

    unawaited(
      Future.microtask(() async {
        try {
          await _restore();
        } catch (_) {
          // 配对凭证读取失败时保持未连接，不影响应用启动。
        }
      }),
    );
    return LinkState(
      status: client.status,
      accountModels: ref.read(settingsProvider).hostModelsCache,
    );
  }

  void _onFrame(Map<String, dynamic> frame) {
    final kind = frame['kind'];
    if (kind == 'account-profile') {
      final account = HostAccount.fromFrame(frame);
      state = state.copyWith(account: account);
      final nickname = account.name.trim();
      if (nickname.isEmpty) return;
      unawaited(
        ref
            .read(secureStoreProvider)
            .saveHostProfile(
              nickname: nickname,
              avatarUrl: account.avatarUrl,
              balance: account.primaryBalance?.balance ?? 0,
            ),
      );
      return;
    }
    if (kind == 'account-models') {
      final models = HostModelOption.listFromGroups(frame['groups']);
      state = state.copyWith(accountModels: models);
      if (models.isNotEmpty) {
        unawaited(ref.read(settingsProvider.notifier).cacheHostModels(models));
      }
      return;
    }
    if (kind == 'api-credential') {
      unawaited(_applySyncedCredentials(frame));
    }
  }

  Future<void> _applySyncedCredentials(Map<String, dynamic> frame) async {
    final credentials = SyncedCredential.listFromFrame(frame);
    state = state.copyWith(credentials: credentials);
    if (credentials.isEmpty) return;
    final store = ref.read(secureStoreProvider);
    final settings = ref.read(settingsProvider);
    final incoming = <ApiCredential>[];
    for (final credential in credentials) {
      final providerId = 'pc:${credential.provider}';
      ApiCredential? existing;
      for (final item in settings.credentials) {
        if (item.providerId == providerId) {
          existing = item;
          break;
        }
      }
      // Key 本体只在变化时写 Keystore，重连不会反复擦写安全存储。
      if (existing == null ||
          existing.last4 != credential.last4 ||
          existing.baseUrl != credential.baseUrl) {
        await store.saveProviderKey(
          providerId: providerId,
          apiKey: credential.apiKey,
        );
      }
      final models = <String>[...credential.models];
      if (credential.defaultModel.isNotEmpty &&
          !models.contains(credential.defaultModel)) {
        models.insert(0, credential.defaultModel);
      }
      final model = existing != null && existing.model.isNotEmpty
          ? existing.model
          : (credential.defaultModel.isNotEmpty
                ? credential.defaultModel
                : (models.isEmpty ? '' : models.first));
      incoming.add(
        ApiCredential(
          providerId: providerId,
          name: '${credential.displayName} · 电脑',
          baseUrl: credential.baseUrl,
          last4: credential.last4,
          model: model,
          models: models,
        ),
      );
    }
    await ref
        .read(settingsProvider.notifier)
        .syncHostCredentials(incoming);
  }

  /// 重新向电脑请求账号资料与凭据（「刷新余额」）。
  Future<void> refreshHostState() async {
    ref.read(gatewayProvider).send(const {'type': 'host-state'});
  }

  /// 清掉模型目录缓存（模型面板里不再展示上次同步的列表）。
  void dropCachedModels() {
    state = state.copyWith(accountModels: const <HostModelOption>[]);
  }

  Future<void> _restore() async {
    final client = ref.read(gatewayProvider);
    client.autoReconnect = ref.read(settingsProvider).autoReconnect;
    final store = ref.read(secureStoreProvider);
    final deviceName = await store.readDeviceName();
    if (deviceName != null) {
      state = state.copyWith(deviceName: deviceName);
    }
    final cachedProfile = await store.readHostProfile();
    if (cachedProfile != null) {
      state = state.copyWith(
        account: HostAccount(
          signedIn: true,
          name: cachedProfile.nickname,
          avatarUrl: cachedProfile.avatarUrl,
          balances: [
            HostBalance(currency: 'CNY', balance: cachedProfile.balance),
          ],
        ),
      );
    }
    // 账号登录优先：有账号会话就直接连登录服务下发的网关。
    final accountRestored = await client.restoreAccountSession();
    if (accountRestored) {
      state = state.copyWith(paired: true, endpoint: client.endpoint);
      await client.connectSaved();
      return;
    }
    // 扫一扫配对的电脑与 API Key 登录可以并存：Key 用来直连供应商，
    // 配对用来读写电脑上的会话，所以这里不因 API Key 模式而跳过恢复。
    final restored = await client.restoreCredentials();
    if (!restored) return;
    state = state.copyWith(paired: true, endpoint: client.endpoint);
    // 未登录：不自动连匿名网关，避免在未登录状态下同步/写入远端数据。
    if (ref.read(settingsProvider).guestMode) return;
    await client.connectSaved();
  }

  /// 登录成功：用账号令牌连网关，并记录端点。
  Future<void> signIn({
    required String gatewayUrl,
    required String token,
  }) async {
    state = state.copyWith(paired: true, endpoint: gatewayUrl);
    await ref
        .read(gatewayProvider)
        .connectWithAccount(gatewayUrl: gatewayUrl, token: token);
  }

  /// 退出登录：断开账号连接并清除账号令牌（不影响自建 Host 的配对）。
  Future<void> signOut() async {
    final cached = ref.read(settingsProvider).hostModelsCache;
    await ref.read(gatewayProvider).signOutAccount();
    // 缓存的电脑模型保留：下次连上电脑还能直接选回来。
    state = LinkState(accountModels: cached);
  }

  /// 配对失败时抛出 [PairingException]/[Exception]，由页面显示可操作提示。
  Future<void> pair(PairingPayload payload) async {
    final client = ref.read(gatewayProvider);
    final store = ref.read(secureStoreProvider);
    final name = state.deviceName ?? 'Android';
    if (state.deviceName == null) {
      await store.writeDeviceName(name);
      state = state.copyWith(deviceName: name);
    }
    await client.pair(payload);
    // 握手成功不等于真的连上：必须等到 hello，否则扫码后会出现「假成功」。
    if (!await client.waitForConnected()) {
      final status = client.status;
      final detail = status.detail ?? '';
      if (detail.contains('not upgraded')) {
        throw const PairingException(
          '电脑端拒绝了这次配对：二维码可能已经失效，请在电脑上重新生成二维码再扫',
        );
      }
      throw PairingException(
        status.detail == null || status.detail!.isEmpty
            ? '电脑端连接没有建立（${status.message ?? '未知原因'}）'
            : '电脑端连接没有建立：${status.message ?? ''}（${status.detail}）',
      );
    }
    state = state.copyWith(paired: true, endpoint: client.endpoint);
  }

  Future<void> reconnect() async {
    final client = ref.read(gatewayProvider);
    await client.retryNow();
  }

  /// 手动断开但保留配对与令牌：下次点「连接」直接回来。
  Future<void> disconnect() async {
    await ref.read(gatewayProvider).disconnect();
  }

  Future<void> unpair() async {
    final client = ref.read(gatewayProvider);
    final cached = ref.read(settingsProvider).hostModelsCache;
    await client.disconnect(forget: true);
    await ref.read(secureStoreProvider).clearHostProfile();
    state = LinkState(accountModels: cached);
  }
}
