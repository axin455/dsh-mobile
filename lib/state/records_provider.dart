import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../protocol/models.dart';
import 'app_providers.dart';

@immutable
class RecordsState {
  const RecordsState({
    this.items = const <SessionSummary>[],
    this.loading = false,
    this.error,
  });

  final List<SessionSummary> items;
  final bool loading;
  final String? error;

  RecordsState copyWith({
    List<SessionSummary>? items,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => RecordsState(
    items: items ?? this.items,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

final recordsProvider = NotifierProvider<RecordsNotifier, RecordsState>(
  RecordsNotifier.new,
);

class RecordsNotifier extends Notifier<RecordsState> {
  StreamSubscription<Map<String, dynamic>>? _subscription;

  @override
  RecordsState build() {
    final client = ref.watch(gatewayProvider);
    _subscription = client.frames.listen(_onFrame);
    ref.onDispose(() => _subscription?.cancel());
    unawaited(Future.microtask(_loadLocal));
    // 页面可能在 hello 之后才被创建，这里补一次拉取，避免错过 sessions 帧。
    unawaited(
      Future.microtask(() {
        if (ref.read(gatewayProvider).status.isConnected) refresh();
      }),
    );
    return const RecordsState();
  }

  Future<void> _loadLocal() async {
    final local = await ref.read(sessionStoreProvider).listSessions();
    state = state.copyWith(items: local);
  }

  void _onFrame(Map<String, dynamic> frame) {
    switch (frame['kind']) {
      case 'hello':
        refresh();
      case 'sessions':
        final items = frame['items'];
        if (items is! List) return;
        final parsed = items
            .whereType<Map>()
            .map((e) => SessionSummary.fromJson(e.cast<String, dynamic>()))
            .where((s) => s.sessionId.isNotEmpty)
            .toList(growable: false);
        unawaited(_mergeHost(parsed));
      case 'session-title-changed':
        final sessionId = frame['sessionId'];
        final title = frame['title'];
        if (sessionId is! String || title is! String) return;
        state = state.copyWith(
          items: [
            for (final item in state.items)
              if (item.sessionId == sessionId)
                item.copyWith(title: title)
              else
                item,
          ],
        );
        unawaited(
          ref.read(sessionStoreProvider).renameSession(sessionId, title),
        );
      case 'session-archives':
        final archived = frame['archivedSessionIds'];
        if (archived is! List) return;
        final ids = archived.whereType<String>().toSet();
        state = state.copyWith(
          items: state.items
              .where((item) => !ids.contains(item.sessionId))
              .toList(growable: false),
        );
    }
  }

  /// 电脑下发的会话只做「导入」：写进本地库后，记录页仍以本地列表为准。
  /// 这样本地新建、还没同步到电脑的会话不会被远端列表覆盖掉。
  Future<void> _mergeHost(List<SessionSummary> host) async {
    final store = ref.read(sessionStoreProvider);
    await store.replaceSessions(host);
    final local = await store.listSessions();
    state = state.copyWith(items: local, loading: false, clearError: true);
  }

  /// 本地新建 / 更新时间后刷新记录列表，保证记录页立刻能看到新会话。
  Future<void> reloadLocal() async {
    final local = await ref.read(sessionStoreProvider).listSessions();
    state = state.copyWith(items: local);
  }

  /// 会话改名（本地命名）后同步到记录页，不依赖电脑回帧。
  Future<void> applyTitle(String sessionId, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    state = state.copyWith(
      items: [
        for (final item in state.items)
          if (item.sessionId == sessionId)
            item.copyWith(title: trimmed)
          else
            item,
      ],
    );
    await ref.read(sessionStoreProvider).renameSession(sessionId, trimmed);
  }

  static int _compare(SessionSummary a, SessionSummary b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    return b.updatedAt.compareTo(a.updatedAt);
  }

  void refresh() {
    // 访客/断线时没有连接，直接回读本地缓存，避免 loading 一直转圈。
    if (!ref.read(gatewayProvider).status.isConnected) {
      unawaited(_loadLocal());
      return;
    }
    state = state.copyWith(loading: true);
    ref.read(gatewayProvider).send(const {'type': 'sessions'});
  }

  Future<void> rename(String sessionId, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    state = state.copyWith(
      items: [
        for (final item in state.items)
          if (item.sessionId == sessionId)
            item.copyWith(title: trimmed)
          else
            item,
      ],
    );
    await ref.read(sessionStoreProvider).renameSession(sessionId, trimmed);
    ref.read(gatewayProvider).send({
      'type': 'session-rename',
      'sessionId': sessionId,
      'title': trimmed,
    });
  }

  Future<void> setPinned(String sessionId, bool pinned) async {
    final items = [
      for (final item in state.items)
        if (item.sessionId == sessionId)
          item.copyWith(pinned: pinned)
        else
          item,
    ]..sort(_compare);
    state = state.copyWith(items: items);
    await ref.read(sessionStoreProvider).setPinned(sessionId, pinned);
  }

  /// 归档：Host 侧只隐藏不删除，本地同步移除。返回被移除项供 Snackbar 撤销。
  Future<SessionSummary?> archive(String sessionId) async {
    final matches = state.items
        .where((item) => item.sessionId == sessionId)
        .toList(growable: false);
    if (matches.isEmpty) return null;
    final removed = matches.first;
    state = state.copyWith(
      items: state.items
          .where((item) => item.sessionId != sessionId)
          .toList(growable: false),
    );
    await ref.read(sessionStoreProvider).deleteSession(sessionId);
    ref.read(gatewayProvider).send({
      'type': 'session-archive',
      'sessionId': sessionId,
    });
    return removed;
  }

  Future<void> restore(SessionSummary session) async {
    final items = [...state.items, session]..sort(_compare);
    state = state.copyWith(items: items);
    await ref.read(sessionStoreProvider).upsertSession(session);
  }
}
