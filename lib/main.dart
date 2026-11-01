import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/settings.dart';
import 'pages/home_page.dart';
import 'state/app_providers.dart';
import 'ui/colors.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 读设置失败不能拖垮启动：部分机型升级系统后 SharedPreferences
  // 文件可能损坏，这里回落到默认设置，保证应用能进主界面。
  AppSettings settings;
  try {
    settings = await SettingsStore().load();
  } catch (_) {
    settings = const AppSettings();
  }
  runApp(
    ProviderScope(
      overrides: [initialSettingsProvider.overrideWithValue(settings)],
      child: const DshApp(),
    ),
  );
}

class DshApp extends ConsumerWidget {
  const DshApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      title: 'DSH',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(AppColors.light),
      darkTheme: buildAppTheme(AppColors.dark),
      themeMode: settings.themeMode,
      // 平板屏幕大、观看距离远：整体字号略放大；手机保持系统原始比例。
      // 系统字体缩放仍会叠加，不覆盖用户的辅助功能设置。
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final shortest = media.size.shortestSide;
        final extra = shortest >= 600 ? 1.08 : 1.0;
        final system = media.textScaler.scale(1.0);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(system * extra),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const HomePage(),
    );
  }
}
