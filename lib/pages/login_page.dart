import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_providers.dart';
import '../state/auth_provider.dart';
import '../ui/colors.dart';
import '../ui/glyphs.dart';
import '../ui/typography.dart';
import '../ui/widgets.dart';
import 'api_key_page.dart';
import 'scan_page.dart';

/// DeepSeek 账号登录页（设备码流程，与 Hermes 同构）。
///
/// App 只负责拿到一条登录链接并交给系统浏览器：扫码、手机号确认都在网页里完成，
/// 回来后本机轮询到令牌即可直接用账号余额对话。界面上只保留三个动作：
/// 浏览器登录 / 手机号登录 / 稍后登录。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(authProvider.notifier).ensureStarted();
    });
  }

  void _popIfPossible() {
    if (_popped || !mounted) return;
    // 登录页可能同时存在两个实例：HomePage 的 body（根路由）与「我的」push 出来的
    // 路由。只有处在栈顶的那个实例才能 pop，否则两个实例会各弹一次，把根路由也
    // 弹掉，Navigator 变空后整屏全黑。
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    if (!Navigator.of(context).canPop()) return;
    _popped = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  /// 扫一扫优先：电脑端 DSH 已经登录，扫码后手机直接复用那台电脑。
  static Future<void> _openScan(BuildContext context) async {
    // 扫码成功后登录态会通知根页面自动切到主界面；这里绝不能 pop，
    // 登录页本身可能就在根路由上，pop 掉最后一层会触发 Navigator 断言。
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const ScanPage()),
    );
  }

  /// 连不上登录服务时，允许就地改地址（真机需要指向电脑的局域网地址）。
  static bool _canEditService(String error) =>
      error.contains('无法连接') ||
      error.contains('超时') ||
      error.contains('SocketException') ||
      error.contains('No route to host');

  Future<void> _editAuthBaseUrl(BuildContext context) async {
    final controller = TextEditingController(
      text: ref.read(settingsProvider).authBaseUrl,
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('登录服务地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'http://192.168.1.5:3081',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '模拟器用 10.0.2.2；真机请填电脑的局域网地址。',
              style: AppTextStyle.caption1
                  .of(context)
                  .copyWith(color: AppColors.textSecondaryOf(context)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    final url = value.trim().replaceAll(RegExp(r'/+$'), '');
    if (url.isEmpty) return;
    await ref.read(settingsProvider.notifier).setAuthBaseUrl(url);
    await ref.read(authProvider.notifier).begin();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final scheme = AppColors.of(context);
    final secondary = AppTextStyle.footnote
        .of(context)
        .copyWith(color: AppColors.textSecondaryOf(context));
    final canClose = Navigator.of(context).canPop();

    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.authorized) _popIfPossible();
    });

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 32, 28, 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: AppMark(size: 56)),
                      const SizedBox(height: 24),
                      Text(
                        '登录 DSH',
                        textAlign: TextAlign.center,
                        style: AppTextStyle.title1.of(context),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '扫码连接电脑，或用 DeepSeek 账号登录',
                        textAlign: TextAlign.center,
                        style: secondary,
                      ),
                      const SizedBox(height: 36),

                      if (auth.error != null) ...[
                        InlineBanner(
                          text: auth.error!,
                          tone: BannerTone.error,
                          margin: EdgeInsets.zero,
                          action: TextButton(
                            onPressed: _canEditService(auth.error!)
                                ? () => _editAuthBaseUrl(context)
                                : () => ref.read(authProvider.notifier).begin(),
                            child: Text(
                              _canEditService(auth.error!) ? '设置地址' : '重试',
                              style: AppTextStyle.footnote
                                  .of(context)
                                  .copyWith(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      PrimaryButton(
                        label: '扫一扫连接电脑',
                        icon: AppGlyphs.scan,
                        onPressed: () => _openScan(context),
                      ),
                      const SizedBox(height: 10),
                      SecondaryButton(
                        label: '在浏览器中打开登录页',
                        icon: AppGlyphs.link,
                        onPressed: auth.phase == AuthPhase.starting
                            ? null
                            : () => ref
                                  .read(authProvider.notifier)
                                  .openInBrowser(),
                      ),
                      const SizedBox(height: 10),
                      SecondaryButton(
                        label: '手机号登录',
                        icon: AppGlyphs.profile,
                        onPressed: auth.phase == AuthPhase.starting
                            ? null
                            : () => ref
                                  .read(authProvider.notifier)
                                  .openInBrowser(phone: true),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton(
                            onPressed: () async {
                              await ref
                                  .read(authProvider.notifier)
                                  .continueAsGuest();
                            },
                            child: Text(
                              '稍后登录',
                              style: AppTextStyle.callout
                                  .of(context)
                                  .copyWith(
                                    color: AppColors.textSecondaryOf(context),
                                  ),
                            ),
                          ),
                          Text(
                            '·',
                            style: AppTextStyle.callout
                                .of(context)
                                .copyWith(
                                  color: AppColors.textSecondaryOf(context),
                                ),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ApiKeyPage(),
                              ),
                            ),
                            child: Text(
                              '使用 API Key 登录',
                              style: AppTextStyle.callout
                                  .of(context)
                                  .copyWith(color: scheme.primary),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (auth.phase == AuthPhase.starting)
                        Text(
                          '正在准备登录链接…',
                          textAlign: TextAlign.center,
                          style: AppTextStyle.caption1
                              .of(context)
                              .copyWith(
                                color: AppColors.textSecondaryOf(context),
                              ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (canClose)
              Positioned(
                left: 8,
                top: 4,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(
                    AppGlyphs.close,
                    size: 22,
                    color: AppColors.textSecondaryOf(context),
                  ),
                  tooltip: '关闭',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
