import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../protocol/pairing.dart';
import '../state/app_providers.dart';
import '../state/auth_provider.dart';
import '../state/chat_provider.dart';
import '../ui/colors.dart';
import '../ui/glyphs.dart';
import '../ui/tokens.dart';
import '../ui/typography.dart';
import '../ui/widgets.dart';

/// 扫一扫：扫描电脑端 DSH 移动网关生成的配对二维码。
///
/// 扫码 → 解析配对载荷 → 先探测电脑是否在线（TCP 可达）→ 再用一次性配对码建连。
/// 电脑离线时直接提示「设备离线」，不会把超时伪装成配对失败。
class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});

  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _busy = false;
  bool _paired = false;
  String? _error;
  String _stage = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy || _paired) return;
    final raw = capture.barcodes.isEmpty
        ? null
        : capture.barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await _controller.stop();
    await _handleText(raw);
  }

  /// 二维码与手动粘贴都走这一条链路。
  Future<void> _handleText(String raw) async {
    try {
      final payload = PairingPayload.decode(raw);
      await _handlePayload(payload);
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _handlePayload(PairingPayload payload) async {
    try {
      if (payload.isExpired) {
        throw const PairingException('二维码已过期，请在电脑上重新生成');
      }
      // 协议只给「候选地址」，publicUrl 可能是电脑本机回环或一条不可用的隧道。
      // 逐个真正尝试建连：握手失败（例如端口上跑的不是移动网关）直接换下一个，
      // 这样局域网可用时不会被排在前面的地址挡住。
      final candidates = payload.candidates;
      if (candidates.isEmpty) {
        throw const PairingException('配对内容里没有可用地址，请在电脑上重新生成二维码');
      }
      final tried = <String>[];
      String? chosen;
      PairingException? lastError;
      for (final candidate in candidates) {
        final uri = Uri.parse(candidate);
        final host = uri.host;
        tried.add(host);
        if (mounted) setState(() => _stage = '正在连接 $host…');
        // 先做一次 TCP 探测：电脑关机、端口没开或不在同一网络时，
        // WebSocket 握手可能挂很久；探测失败就直接换下一个候选地址。
        if (!await _reachable(uri)) {
          lastError = PairingException('$host 没有响应');
          continue;
        }
        try {
          await ref
              .read(linkProvider.notifier)
              .pair(payload.withUrl(candidate));
          chosen = candidate;
          break;
        } catch (error) {
          lastError = error is PairingException
              ? error
              : PairingException('$error');
        }
      }
      if (chosen == null) {
        throw lastError ??
            PairingException(
              '连不上电脑：${tried.join('、')} 都没有响应，请确认电脑已开机、DSH 正在运行，且与平板在同一局域网',
            );
      }
      // 电脑上的 DSH 已登录，扫码即视为登录成功，对话直接复用那台电脑。
      await ref
          .read(authProvider.notifier)
          .signInWithHost(name: payload.gatewayName);
      // 扫码的目的就是操作电脑端：直接切到「电脑端」，避免用户还要多点一次。
      ref.read(chatScopeProvider.notifier).select(ChatScope.pc);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _paired = true;
        _stage = '';
      });
      Navigator.of(context).pop(true);
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _stage = '';
      _error = error.toString();
    });
    unawaited(_controller.start());
  }

  /// 只验证 TCP 可达，不发送任何凭证；真正的鉴权仍由 WebSocket 子协议完成。
  static Future<bool> _reachable(Uri uri) async {
    final port = uri.hasPort ? uri.port : (uri.scheme == 'wss' ? 443 : 80);
    try {
      final socket = await Socket.connect(
        uri.host,
        port,
        timeout: const Duration(milliseconds: 1500),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _retry() async {
    setState(() => _error = null);
    await _controller.start();
  }

  /// 手电筒：平板摄像头在室内光线不足时经常识别不到密集二维码。
  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
    } catch (_) {
      _fail('这台设备不支持手电筒');
    }
  }

  /// 相册兜底：拍一张电脑屏幕上的二维码再识别，比实时取景更容易扫上。
  Future<void> _pickFromGallery() async {
    if (_busy) return;
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _stage = '正在识别图片…';
    });
    await _controller.stop();
    try {
      final capture = await _controller.analyzeImage(image.path);
      final raw = capture == null || capture.barcodes.isEmpty
          ? null
          : capture.barcodes.first.rawValue;
      if (raw == null || raw.isEmpty) {
        setState(() {
          _busy = false;
          _stage = '';
          _error = '图片里没有识别到二维码，换一张更清晰、正对的照片试试';
        });
        unawaited(_controller.start());
        return;
      }
      await _handleText(raw);
    } catch (error) {
      _fail(error);
    }
  }

  /// 相机不可用时的兜底：直接粘贴地址与配对码。
  Future<void> _manualInput() async {
    final urlController = TextEditingController();
    final codeController = TextEditingController();
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动填写'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'WebSocket 地址',
                hintText: 'wss://192.168.1.5:3081/ws/mobile',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeController,
              decoration: const InputDecoration(labelText: '配对码'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context)
                .pop((urlController.text.trim(), codeController.text.trim())),
            child: const Text('连接'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    try {
      final payload = PairingPayload.manual(
        publicUrl: result.$1,
        pairingCode: result.$2,
      );
      setState(() {
        _busy = true;
        _error = null;
      });
      await _controller.stop();
      await _handlePayload(payload);
    } on PairingException catch (error) {
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColors.of(context);
    final secondary = AppTextStyle.footnote
        .of(context)
        .copyWith(color: Colors.white70);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: MobileScanner(controller: _controller, onDetect: _onDetect),
          ),
          // 取景框
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                borderRadius: AppRadius.all(AppCorner.lg),
                border: Border.all(color: Colors.white24, width: 2),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        AppGlyphs.close,
                        size: 22,
                        color: Colors.white,
                      ),
                      tooltip: '关闭',
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      '扫一扫连接电脑',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: _toggleTorch,
                      icon: const Icon(
                        Icons.flash_on_rounded,
                        size: 22,
                        color: Colors.white,
                      ),
                      tooltip: '手电筒',
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_busy)
            const Positioned.fill(child: ColoredBox(color: Color(0x66000000))),
          if (_busy)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  if (_stage.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      _stage,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),

          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_error != null) ...[
                      AppCard(
                        radius: AppCorner.lg,
                        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                        child: Row(
                          children: [
                            GlyphIcon(
                              AppGlyphs.warning,
                              size: 18,
                              color: scheme.error,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _error!,
                                style: AppTextStyle.footnote
                                    .of(context)
                                    .copyWith(color: scheme.error),
                              ),
                            ),
                            TextButton(
                              onPressed: _retry,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      '把电脑上生成的一次性二维码放进框内',
                      textAlign: TextAlign.center,
                      style: secondary,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '二维码 5 分钟内有效，仅能使用一次',
                      textAlign: TextAlign.center,
                      style: secondary.copyWith(fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton.icon(
                          onPressed: _busy ? null : _pickFromGallery,
                          icon: const Icon(
                            Icons.photo_library_outlined,
                            size: 18,
                            color: Colors.white,
                          ),
                          label: const Text(
                            '从相册识别',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _busy ? null : _manualInput,
                          child: const Text(
                            '手动填写',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
