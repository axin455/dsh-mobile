# DSH Mobile 预览版

DeepSeek Harness 的 Android 客户端。手机和电脑在同一局域网时，扫码连接电脑上的 DSH，查看并继续电脑端会话。不连接电脑时，也可以用本机 API Key 或电脑 DeepSeek 账号模型进行本地纯文本对话。

这是预览版，仅支持 Android 15 及以上、arm64 设备。协议和界面还会调整，升级时请保持手机端和电脑端插件版本接近。

电脑端需要安装 dsh-plugin-mobile-link：
https://github.com/axin455/dsh-plugin-mobile-link

## 主要功能

扫码配对。手机扫描电脑端“移动设备”里的二维码，自动配对并连接。

电脑端会话。支持历史快照、流式输出、发送消息、切换模型和重命名。

电脑端对话和工作两档模式。对话是纯文本，只走电脑上的模型，不建 Agent 会话，不跑工具。工作是完整 Agent 会话，会调工具、读写工作区，思考和工具步骤默认折叠，点开可以看细节。

断线处理。断开后只自动重连约十秒，之后停在“连接”按钮，由你手动恢复。

离线可用。打开过的会话和消息缓存在手机本地。DeepSeek 账号模型目录会缓存，离线时置灰显示。

本地对话。支持本机 API Key 直连，也支持经电脑使用 DeepSeek 账号模型，按账号余额计费。

本地插件。支持声明式输入框动作、设置区和对话模板。

技能导入。可以导入 SKILL.md 或包含 SKILL.md 的压缩包，作为本地对话的系统提示，不执行脚本。

平板适配。横屏左侧 dock，竖屏底部 dock，支持浅色和深色。

## 工作方式

手机 App 通过局域网 WebSocket 连接电脑上的移动网关插件，插件再通过 DSH 的 Typert 和 Connection 服务访问会话。手机端不运行电脑上的 Node 插件，手机插件只在本地对话里生效。

## 快速开始

1. 在电脑端安装并启用 dsh-plugin-mobile-link，在 DSH 左下角“移动设备”生成二维码。

2. 在手机端安装 release/DSH-Mobile-0.1.0-preview-arm64.apk，或者按下面的构建步骤自行编译。

3. 打开 App，点“扫一扫连接电脑”，扫描二维码。

连接后可以在“对话”里切换本地和电脑端。在“记录”里长按会话，可以置顶、重命名或删除。

## 构建

环境需要 Flutter 3.47 以上、Dart 3.13 以上和 Android SDK 35。

```
flutter pub get
flutter build apk --release --target-platform android-arm64 --split-per-abi --obfuscate --split-debug-info=build/symbols
```

产物在 build/app/outputs/flutter-apk/app-arm64-v8a-release.apk。

## 安全与隐私

设备 token 和 API Key 存在 Android Keystore 里，token 按 origin 隔离。电脑端只保存设备 token 的哈希。配对码一次性使用，五分钟过期。

API Key 只在你主动配对时由电脑经局域网下发。请只在自己的电脑、自己的手机和可信局域网里配对。

本地插件和技能只作为提示词使用，不执行脚本，也不读取插件目录里的其他文件。

没有遥测和第三方统计。需要联网时，只连接你配置的电脑或模型供应商。

## 已知限制

目前只支持 Android 和 arm64，没有上架应用商店。

只支持局域网直连。跨公网需要 Tailscale、Cloudflare Tunnel 之类的隧道方案。

电脑端“对话”暂不调用电脑插件，“工作”才使用完整 Agent 能力。

旧版本缓存的消息没有 token 用量，统计会显示零。新消息会正常记录。

技能目前只支持本地导入，暂不内置技能目录浏览。

## 文档

本地插件规范：docs/local-plugins.md

技能导入说明：docs/skills.md

动效规范：docs/motion.md

## 相关项目

dsh-plugin-mobile-link：
https://github.com/axin455/dsh-plugin-mobile-link

## License

MIT
