# WeChat Mini Game Exporter for Godot

Godot 微信小游戏导出插件。

<p>
  <a href="./README.md"><img src="https://img.shields.io/badge/%E8%AF%AD%E8%A8%80-%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-2ea44f" alt="简体中文"></a>
  <a href="./README.en.md"><img src="https://img.shields.io/badge/Language-English-d0d7de" alt="English"></a>
</p>

这是一个独立的 Godot 编辑器插件，用于把 Godot 项目构建、预览并上传为微信小游戏。

## 支持环境

当前版本严格支持：

- Godot 4.7.2 stable official
- commit `ed1daf0bf`
- GL Compatibility renderer
- GDScript
- 单线程 Web/WASM 导出

如果当前 Godot 版本或 commit 不匹配，插件会禁用 Build、Preview 和 Upload。

## 安装

从 GitHub Releases 下载最新的 `godot-wechat-exporter-<version>.zip`，解压到项目根目录。安装后目录必须是：

```text
addons/wechat_exporter/
```

然后在 **项目 → 项目设置 → 插件** 中启用 **WeChat Mini Game**，从顶部菜单打开 **工具 → 微信小游戏...**。

插件是 self-contained 的，发行包已经包含：

- 编辑器发布界面
- Python exporter
- 微信小游戏宿主模板
- 修改后的 Godot 4.7.2 Web runtime

普通游戏项目不需要复制 `tools/wechat/`。

## 项目配置

插件把项目发布配置保存在：

```text
wechat_export.json
```

常用配置包括 AppID、快速适配声明、屏幕方向、基础库版本、诊断开关、可选排除规则，以及只在发布时移除的 Autoload。

Exporter 始终会把编辑器插件自身从游戏 PCK 中排除；其他 addon 默认保留。

## 发布能力

编辑器窗口支持：

- Doctor 兼容性检查
- Build
- 二维码真机 Preview
- 上传微信后台开发版本
- 包体积统计
- 安全协作式取消
- 构建过期检测

生成的微信小游戏工程：

```text
build/wechat/
```

本地构建元数据：

```text
build/wechat-build-manifest.json
```

该 sidecar manifest 不会上传到微信后台。

## 自动更新

从 0.6.1 起，插件默认使用经过签名的 GitHub stable 更新通道：

```text
https://github.com/niu-row/godot-wechat-exporter/releases/latest/download/stable.json
```

也可以在 **高级 → 插件更新** 中覆盖为其他 HTTP(S) 地址或本地 manifest。

Updater 会：

1. 使用内置公钥验证 `stable.json.sig`
2. 检查 Godot 版本兼容性
3. 下载 Release ZIP
4. 校验 ZIP 的 SHA-256 和 size
5. 只允许解压 `addons/wechat_exporter/**`
6. 保存上一版本作为 rollback backup
7. 安装新版本，并由用户确认后重启编辑器

自动检查最多每 24 小时一次。插件不会静默安装更新。

更新源保存在本机 EditorSettings，不会写入游戏项目的 `wechat_export.json`。

## 微信开发者工具

macOS 下会自动检测：

```text
/Applications/wechatwebdevtools.app
```

需要在微信开发者工具中开启一次：

**设置 → 安全设置 → 服务端口**

其他操作系统可以手动配置 CLI 路径，但目前端到端验收以 macOS 为主。

## Runtime / 平台边界

当前发行版不支持以下能力。这些限制主要来自 Godot Web/WASM 架构或微信小游戏运行环境，不是简单的插件适配项：

- pthread / Godot Thread API
- 通用 GDExtension 动态加载
- C# / .NET
- Forward+ / Mobile renderer

## 尚未完成的微信适配

以下能力平台本身具备，但当前 runtime 尚未完成对应桥接：

- WebSocket：微信提供 Socket API，当前尚未完成 Godot `WebSocketPeer` 到微信 Socket 的适配
- 文本输入 / 虚拟键盘：微信提供键盘 API，普通文本输入具备适配条件；完整 IME composition 行为仍需进一步真机验证

HTTP 请求已经通过 `wx.request` 桥接；小游戏仍需要在微信后台配置合法 request 域名。

## 许可证

Exporter / 插件代码使用 MIT License。

发行包中包含的修改版 Godot runtime 和 Emscripten 生成代码继续遵循各自上游许可证，详见：

- `THIRD_PARTY_NOTICES.md`
- `LICENSES/`
