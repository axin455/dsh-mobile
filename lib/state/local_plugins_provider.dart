import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../plugins/local/local_plugin_store.dart';
import '../plugins/local/manifest.dart';

@immutable
class LocalPluginsState {
  const LocalPluginsState({
    this.plugins = const <LocalPlugin>[],
    this.settings = const <String, Map<String, bool>>{},
    this.loading = false,
    this.error,
  });

  final List<LocalPlugin> plugins;

  /// pluginId → settingKey → value
  final Map<String, Map<String, bool>> settings;
  final bool loading;
  final String? error;

  List<LocalPluginCapability> get composerActions => [
    for (final plugin in plugins)
      if (plugin.enabled)
        for (final capability in plugin.composerActions) capability,
  ];

  /// 本地纯文本对话要注入的系统提示（启用中的 chatTemplate 拼接）。
  List<LocalPluginCapability> get chatTemplates => [
    for (final plugin in plugins)
      if (plugin.enabled)
        for (final capability in plugin.chatTemplates) capability,
  ];

  bool settingValue(String pluginId, String key, {bool fallback = false}) =>
      settings[pluginId]?[key] ?? fallback;

  LocalPluginsState copyWith({
    List<LocalPlugin>? plugins,
    Map<String, Map<String, bool>>? settings,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => LocalPluginsState(
    plugins: plugins ?? this.plugins,
    settings: settings ?? this.settings,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

final localPluginStoreProvider = Provider<LocalPluginStore>(
  (ref) => LocalPluginStore(),
);

final localPluginsProvider =
    NotifierProvider<LocalPluginsNotifier, LocalPluginsState>(
      LocalPluginsNotifier.new,
    );

class LocalPluginsNotifier extends Notifier<LocalPluginsState> {
  @override
  LocalPluginsState build() {
    unawaited(Future.microtask(refresh));
    return const LocalPluginsState(loading: true);
  }

  Future<void> refresh() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final store = ref.read(localPluginStoreProvider);
      final plugins = await store.scan();
      final settings = <String, Map<String, bool>>{};
      for (final plugin in plugins) {
        for (final section in plugin.settingsSections) {
          for (final row in section.rows.where((item) => item.isSwitch)) {
            settings.putIfAbsent(plugin.id, () => <String, bool>{})[row.key] =
                await store.readSetting(plugin.id, row.key, row.defaultValue);
          }
        }
      }
      state = LocalPluginsState(plugins: plugins, settings: settings);
    } catch (error) {
      state = state.copyWith(
        loading: false,
        error: '读取本地插件失败：$error',
      );
    }
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await ref.read(localPluginStoreProvider).setEnabled(id, enabled);
    state = state.copyWith(
      plugins: [
        for (final plugin in state.plugins)
          if (plugin.id == id) plugin.copyWith(enabled: enabled) else plugin,
      ],
    );
  }

  Future<void> setSetting(
    String pluginId,
    String key,
    bool value,
  ) async {
    await ref
        .read(localPluginStoreProvider)
        .writeSetting(pluginId, key, value);
    final settings = <String, Map<String, bool>>{
      for (final entry in state.settings.entries)
        entry.key: Map<String, bool>.from(entry.value),
    };
    settings.putIfAbsent(pluginId, () => <String, bool>{})[key] = value;
    state = state.copyWith(settings: settings);
  }
}
