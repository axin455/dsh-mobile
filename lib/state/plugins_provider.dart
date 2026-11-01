import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../protocol/models.dart';
import 'app_providers.dart';

@immutable
class PluginsState {
  const PluginsState({
    this.catalog = const PluginCatalog(),
    this.loading = false,
    this.error,
  });

  final PluginCatalog catalog;
  final bool loading;
  final String? error;

  PluginsState copyWith({
    PluginCatalog? catalog,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => PluginsState(
    catalog: catalog ?? this.catalog,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

final pluginsProvider = NotifierProvider<PluginsNotifier, PluginsState>(
  PluginsNotifier.new,
);

class PluginsNotifier extends Notifier<PluginsState> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  String? _requestId;

  @override
  PluginsState build() {
    final client = ref.watch(gatewayProvider);
    _subscription = client.frames.listen(_onFrame);
    ref.onDispose(() => _subscription?.cancel());
    return const PluginsState();
  }

  void _onFrame(Map<String, dynamic> frame) {
    switch (frame['kind']) {
      case 'hello':
        refresh();
      case 'plugin-catalog':
        if (_requestId != null && frame['requestId'] != _requestId) return;
        state = PluginsState(
          catalog: PluginCatalog.fromJson(frame),
          loading: false,
        );
      case 'plugin-bundle-set-enabled':
      case 'plugin-entry-set-enabled':
        // 以 Host 返回的 ChangeResult 为准，刷新目录而不是本地猜测。
        refresh();
      case 'error':
        final requestType = (frame['requestType'] ?? '').toString();
        if (requestType.startsWith('plugin')) {
          state = state.copyWith(
            loading: false,
            error: (frame['message'] ?? '插件操作失败').toString(),
          );
        }
    }
  }

  void refresh() {
    if (state.loading) return;
    state = state.copyWith(loading: true, clearError: true);
    _requestId = 'catalog-${DateTime.now().microsecondsSinceEpoch}';
    ref.read(gatewayProvider).send({
      'type': 'plugin-catalog',
      'requestId': _requestId,
    });
  }

  void setBundleEnabled(String name, bool enabled) {
    ref.read(gatewayProvider).send({
      'type': 'plugin-bundle-set-enabled',
      'requestId': 'bundle-${DateTime.now().microsecondsSinceEpoch}',
      'name': name,
      'enabled': enabled,
    });
  }

  void setEntryEnabled(String entryId, bool enabled) {
    ref.read(gatewayProvider).send({
      'type': 'plugin-entry-set-enabled',
      'requestId': 'entry-${DateTime.now().microsecondsSinceEpoch}',
      'entryId': entryId,
      'enabled': enabled,
    });
  }
}
