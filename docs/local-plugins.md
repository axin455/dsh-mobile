# 本地插件开发规范（手机端）

> 状态：**v1 已实现**（声明式插件：`composerAction`、`settingsSection`、`chatTemplate`）。
> 适用版本：DSH Mobile 0.1.x（Flutter / Android 首发）。
> 插件只影响手机端，不改变电脑端 DSH 的插件目录、会话与工具。
>
> 未实现、但已预留的扩展：`theme`、`.dshplugin` 打包导入、在线索引与更新、
> WebView 沙箱插件、JS/WASM 沙箱。见第 10 节路线图。

---

## 1. 定位

手机端与电脑端是两套插件体系：

| | 电脑端 DSH 插件 | 手机端本地插件 |
|---|---|---|
| 形态 | Node ESM 包（`lib/index.mjs`） | 目录 + `manifest.json` |
| 运行位置 | 电脑上的 DSH 进程 | Flutter App 内，不执行外部代码 |
| 能力 | tool / systemPrompt / agent / llm | 输入框动作、设置区、对话模板 |
| 生效范围 | 电脑端「对话」与「工作」 | 本地纯文本对话与手机界面 |
| 安装方式 | DSH 插件市场 / 本地 bundle | 放入 App 私有 `plugins/` 目录 |

两套体系互不越界：

- 电脑端「工作」和「对话」只使用**电脑上的插件**；
- 本地纯文本对话只使用**手机上的插件**；
- 手机插件不会上传到电脑，电脑插件也不会自动出现在手机功能里。

## 2. 目录与安装

```
<App 私有数据目录>/plugins/
  com.dsh.example.quick-note/
    manifest.json          # 必须，≤ 64 KB
    assets/                # 可选，图标等静态资源
  com.dsh.example.roleplay/
    manifest.json
```

- App 只读取每个目录下的 `manifest.json`，**不读取、不执行**其他文件。
- 目录名必须与 manifest 的 `id` 完全一致，否则该插件会被忽略。
- 单个插件损坏（JSON 语法错误、字段缺失）只会跳过它，不影响其他插件。
- 卸载 = 删除插件目录；开关状态保存在 App 偏好设置里，不会写回插件目录。
- App 首次运行会放入两个示例插件：
  - `com.dsh.example.quick-note`（快捷便签，输入框动作）
  - `com.dsh.example.roleplay`（角色扮演，对话模板；默认关闭）

当前版本没有内置的「安装压缩包」入口。安装方式：

1. 用文件管理器 / `adb push` 把插件目录放进上述路径；
2. 回到 App「插件 → 本地插件 → 重新扫描本地插件」。

`minAppVersion` 目前只做展示，不做强制拦截；后续版本会与 `version` 一起用于
升级、降级与兼容性提示。

## 3. manifest 规范

### 3.1 最小示例

```json
{
  "id": "com.example.prompt-library",
  "version": "1.0.0",
  "name": "提示词库",
  "description": "把常用提示词插进输入框",
  "author": "example",
  "minAppVersion": "0.1.0",
  "capabilities": [
    {
      "type": "composerAction",
      "label": "插入审阅提示",
      "icon": "note",
      "action": { "kind": "insertText", "text": "请逐条审阅下面的代码，指出风险：" }
    }
  ]
}
```

### 3.2 字段表

| 字段 | 类型 | 必填 | 约束与说明 |
|---|---|---|---|
| `id` | string | 是 | 反域名格式，`^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$`，且等于目录名 |
| `version` | string | 是 | 语义化版本，如 `1.2.0` |
| `name` | string | 是 | 展示名，建议 ≤ 12 个汉字 |
| `description` | string | 否 | 一句话说明，展示在插件卡片副标题 |
| `icon` | string | 否 | 保留字段，当前版本不加载外部图片 |
| `author` | string | 否 | 作者署名 |
| `minAppVersion` | string | 否 | 预留兼容性字段 |
| `defaultEnabled` | bool | 否 | 首次安装默认开关，默认 `true`；模板类插件建议 `false` |
| `capabilities` | array | 是 | 最多 8 项；未知 `type` 忽略 |

安全约束：

- manifest 总量 ≤ 64 KB；
- 所有字符串字段按需截断，单个模板提示词上限 8000 字符；
- 解析失败、字段类型不符的条目直接丢弃，不抛异常到界面；
- 不解析 HTML，不加载插件目录内的脚本或可执行文件。

## 4. 能力白名单（v1）

### 4.1 `composerAction` — 输入框动作

在对话输入框左侧的 `+` 面板里增加一个快捷动作。

```json
{
  "type": "composerAction",
  "label": "插入便签",
  "icon": "note",
  "action": { "kind": "insertText", "text": "【便签】" }
}
```

| 字段 | 说明 |
|---|---|
| `label` | 面板里的按钮文案 |
| `icon` | 图标名；未知值回落到默认图标 |
| `action.kind` | v1 仅支持 `insertText` |
| `action.text` | 插入到草稿末尾的文本，非空 |

行为：

- 点击后把 `action.text` 追加到当前草稿末尾，不自动发送；
- 若插件同时声明了设置项，动作可以读取设置（见 4.2 的示例开关）；
- 输入框已存在草稿时不会覆盖，只在末尾拼接。

### 4.2 `settingsSection` — 插件设置区

在插件卡片下方渲染开关列表。

```json
{
  "type": "settingsSection",
  "title": "快捷便签",
  "rows": [
    { "kind": "switch", "key": "autoAppendTime", "title": "插入时附加当前时间", "default": true }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `title` | 分区标题，同时作为开关的副标题 |
| `rows[].kind` | v1 仅支持 `switch` |
| `rows[].key` | 设置键，同一插件内唯一 |
| `rows[].title` | 开关标题 |
| `rows[].default` | 默认值（bool，缺省 `false`） |

- 设置按 `pluginId + key` 存在 App 偏好设置里；
- 同一插件可以声明多个 `settingsSection`；
- 示例：`autoAppendTime` 为真时，「插入便签」会追加 `HH:MM`。

### 4.3 `chatTemplate` — 对话模板 / 角色扮演

这是本地纯文本对话的**系统提示注入**能力：启用后，本地对话的每次请求都会在
历史前插入一条 `system` 消息。

```json
{
  "type": "chatTemplate",
  "title": "古风客栈掌柜",
  "prompt": "你正在扮演「阿岚」……保持第一人称与人设，不提及自己是 AI。"
}
```

| 字段 | 说明 |
|---|---|
| `title` | 展示名，出现在插件卡片 |
| `prompt` | 系统提示词，也接受别名 `systemPrompt`；≤ 8000 字符 |

行为与边界：

- 只在**本地**纯文本对话生效（本机 API Key 直连、电脑账号模型两种通道都支持）；
- 电脑端「对话」「工作」不会注入手机模板；
- 多个启用中的 `chatTemplate` 按插件扫描顺序（插件名排序）拼接，用空行分隔；
- 模板不会改写用户消息，也不会上传到电脑的会话历史；
- 插件整体关闭时模板立即失效，正在进行的请求不受影响；
- 如只想偶尔使用，建议把插件 `defaultEnabled` 设为 `false`，在插件页手动开。

> 角色扮演只是模板的一种用法。任何「固定人设 / 输出格式 / 语气约束 / 领域
> 提示词」都可以用同一个能力实现，不需要执行代码。

## 5. 生命周期

1. **扫描**：进入插件页或点「重新扫描」时，遍历 `plugins/` 子目录；
2. **解析**：校验 `manifest.json`，构建能力列表，读取开关与设置；
3. **启用/停用**：只影响能力是否参与渲染与请求，不修改插件目录；
4. **升级**：用新目录替换旧目录后重新扫描；设置按 `key` 保留；
5. **卸载**：删除目录后重新扫描；App 不保留其设置（键值仍留在偏好设置里，
   重新安装同名插件会沿用旧设置）。

失败处理：

- 目录名与 `id` 不一致 → 忽略；
- JSON 解析失败 → 跳过该插件并在界面静默忽略（不弹错误）；
- 能力数量超过 8 项 → 只取前 8 项；
- 未知能力 → 忽略，不影响其余能力。

## 6. 权限模型

v1 是「零执行」模型：插件不能读写文件、不能发起网络请求、不能访问剪贴板或
相册、不能读取会话内容。它只能做两件事：

1. 向输入框**追加**一段声明好的文本；
2. 向本地对话**注入**一段声明好的系统提示。

由此不需要运行时权限弹窗。manifest 里的 `permissions` 字段当前仅作展示与未来
兼容保留，App 不据此授予任何能力。

需要更强能力时，必须走后续的沙箱档位（第 10 节），并按档位单独授权。

## 7. 安全边界

- 插件目录位于 App 私有存储，其他应用无法直接读写；
- App 不加载插件目录内的图片、字体、脚本、二进制；
- 提示词按纯文本处理，不拼接 HTML / Markdown 指令；
- 本地对话把提示词作为 `system` 消息发给模型，不写入电脑端会话记录；
- 电脑端「工作」不加载手机插件，避免手机模板影响工具调用；
- 本地插件列表与电脑插件列表完全隔离，互不导入。

## 8. 打包与命名约定

建议的发布结构（`.dshplugin` 规划中，当前用普通目录）：

```
com.example.my-plugin/
  manifest.json
  assets/
    icon.png          # 预留给后续版本
  README.md           # 可选，App 不读取
```

约定：

- 目录名 = `id`，大小写敏感；
- 版本号递增用语义化版本；
- 插件名、描述、提示词使用 UTF-8；
- 不要把密钥、令牌写进 manifest（插件目录可能被导出或分享）。

## 9. 自测清单

新增 / 修改插件后，至少验证：

- [ ] App 能扫描到插件，名称、版本、描述正确；
- [ ] 停用后：输入框动作消失、设置区隐藏、模板不再注入；
- [ ] 启用后：动作插入位置正确，不会覆盖已有草稿；
- [ ] 设置开关重启 App 后保持；
- [ ] 模板在本地对话生效，在电脑端「对话」「工作」不生效；
- [ ] 删除目录后重新扫描，插件消失且不影响其他插件；
- [ ] manifest 写错一个字段时，插件被忽略而 App 不崩溃。

## 10. 路线图

| 阶段 | 内容 | 边界 |
|---|---|---|
| v1（已实现） | 声明式：输入框动作、设置区、对话模板 | 不执行代码 |
| v1.1 | `.dshplugin` 压缩包导入/导出、在线索引、更新与签名校验 | 只解压白名单文件 |
| v2 | WebView 面板插件：设置页内嵌入 `index.html`，下载后离线可用 | 独立 WebView、无 JSBridge 默认权限 |
| v2.1 | `theme`：颜色、圆角、字体档位 | 只覆盖设计令牌，不改布局 |
| v3 | JS/WASM 沙箱：有限 API（读设置、追加草稿、调用本地模型） | 独立 isolate + 超时 + 消息白名单 |
| v3.1 | 手机插件代理电脑插件能力 | 必须由电脑端显式授权、按次授予 |

优先级原则：**能不执行代码就不执行**。每增加一档能力，都必须同时补齐权限、
超时、资源上限与失败隔离，再进入文档。

## 11. 参考实现

- 声明式模型：[`lib/plugins/local/manifest.dart`](../lib/plugins/local/manifest.dart)
- 目录扫描与示例：[`lib/plugins/local/local_plugin_store.dart`](../lib/plugins/local/local_plugin_store.dart)
- 插件页渲染：[`lib/pages/plugins_page.dart`](../lib/pages/plugins_page.dart)
- 模板注入点：`ChatNotifier._localSystemPrompt()`（`lib/state/chat_provider.dart`）
- 输入框动作：`localPluginsProvider.composerActions`
