---
name: dsh-mobile-motion
description: DSH 移动端的动效与视觉节奏规范。修改导航 dock、页面转场、底部输入条、卡片/列表切换、本地-电脑端切换时使用，确保不破坏 FlClash 风格的既有观感，只做性能与 bug 修复，不重做动画语言。
---

# DSH 移动端动效规范

这个项目的动效基准是 **FlClash v0.9.2**（`lib/ui/navigation_dock.dart`）以及本项目 2026-10-31 17:00 左右的版本。用户认可的观感来自那一版：整块选中框随切换滑动、图标有轻微回弹、页面切换干净迅速。

## 硬性规则

1. **不要重做基础动画。** 优化代码、修 bug、提性能，但不要更换动画语言、不要改缓动曲线、不要缩短/延长既有动画时长。
2. **不要顺便改视觉设计。** 尺寸、圆角、间距、阴影、颜色透明度都属于设计；除非任务明确要求，否则保持现状。
3. **允许的优化**：RepaintBoundary、避免 build 里 debugPrint、避免整页重建、避免重复订阅、把逐帧 layout 动画换成合成层动画（但保留同样的视觉轨迹与时长）。
4. **改完必须截图对比**：手机竖屏 + 平板横屏各一张，确认 dock/转场没有观感退化。

## 动效参数（改前先对照）

| 元素 | 时长 | 曲线 | 说明 |
| --- | --- | --- | --- |
| 底部 dock 选中框滑动 | 320ms | `Curves.easeOutQuint` | 整块高亮框平移，不是每个图标各自变色 |
| 竖排 dock 选中框 | 320ms | `Curves.easeOutQuint` | 80×64 圆角片，随选中项上下滑动；禁止铺满整格（会变成巨大的圆） |
| dock 图标填充/回弹 | 350ms | `Curves.easeInOutCubic` + 10% pop | `AnimatedGlyph`，不要缩短到 200ms 左右 |
| dock 文字 | 200ms | 默认 | `AnimatedDefaultTextStyle` |
| 四个 Tab 内容切换 | 180ms | `Curves.easeOutCubic` | 透明度 0.7→1，位移 6px |
| 本地/电脑端切换 | 280ms | `Curves.easeOutQuint` | 带玻璃感的选中框整块滑过去；标签颜色 180ms 交叉淡变；不要整页淡入/位移 |
| 页面 push | 平台默认 | — | 用 `MaterialPageRoute`，不要替换成自定义 fade 转场 |
| 底部 sheet | 平台默认 | — | `showModalBottomSheet` 默认节奏 |

## Dock 结构

- 底部横排：`Stack` + `AnimatedPositioned` 的选中框（`left = itemWidth * index`, `width = itemWidth`, `padding: 4`, `borderRadius: full`），下面叠 `Row` 的四个按钮。选中框要带一层很轻的阴影，让整块“阴影框”跟着滑动。
- 平板左竖排：同一个 `AnimatedPositioned`，但高亮片固定为 `80×64`、圆角 20、左右各留 8，`top = itemHeight * index + (itemHeight - 64) / 2`。每个 `SizedBox(width: double.infinity)` 铺满整格，图标/文字才会落在高亮片中心，点击区域也覆盖整格。
- 外层保持 `ClipRRect + BackdropFilter + RepaintBoundary`；不要在滚动时重建模糊层。
- 禁止用 `AnimatedContainer` 改 `width/left/top` 来做跨项滑动（逐帧 layout，大屏掉帧明显）；`AnimatedPositioned` 只在这个 4 项的小 `Stack` 里用，成本可接受。

## 玻璃磁贴

- 卡片（`AppCard`）、助手消息气泡用 `AppColors.glassOf`：亮色约 79% 的灰白、暗色约 72% 的近黑，外加 0.5px 高光描边和轻阴影；不要改成纯白实心。
- 不在滚动列表的每一张卡片上放 `BackdropFilter`：成本高且背景是纯色时看不出效果。毛玻璃只留给 dock、scope 切换这种悬浮层。
- 页面底纹用 `AppColors.canvasGradientOf` 的极轻灰阶渐变；不要加彩色光斑。

## 代码位置

- `lib/ui/dock.dart`：dock 与选中框
- `lib/ui/segmented.dart`：本地/电脑端玻璃滑块
- `lib/ui/colors.dart`：`glassOf` / `glassBorderOf` / `canvasGradientOf`
- `lib/ui/glyphs.dart`：`AnimatedGlyph` 的填充与回弹参数
- `lib/pages/home_page.dart`：四个 Tab 的 180ms 过渡与页面底纹
- `lib/pages/chat_page.dart`：scope 切换、输入条、消息区
- `lib/ui/tokens.dart`：`AppDockMetrics` 尺寸常量

## 回归检查清单

- [ ] 手机竖屏：对话→记录→插件→我的，选中框整块滑过去，不闪、不跳。
- [ ] 平板横屏：左侧 rail 的选中框是圆角片，不是大圆；图标/文字居中，点整格任意位置都能切换。
- [ ] 本地↔电脑端：整块玻璃选中框从左滑到右（280ms），页面内容不整体淡入/位移。
- [ ] 打开/返回二级页面：平台默认转场，没有自定义 fade。
- [ ] 滚动长对话时不掉帧；dock 毛玻璃不随列表重绘。
