# Godot 4.7.2 → 微信小游戏 Exporter

当前版本：0.6.0。

这套工具把 **Godot 4.7.2 + GL Compatibility + GDScript + 单线程** 项目导出为微信小游戏工程。它不是浏览器模拟器，而是 Godot Web runtime 的微信宿主适配层。

当前已验证能力：

- `WXWebAssembly` 加载 Godot WASM。
- WebGL2 / Compatibility renderer。
- 微信 Canvas 与触摸输入。
- WebAudio；微信环境使用 ScriptProcessor fallback。
- Android 真机 `AudioNode.connect()` 差异处理。
- `user://` → `wx.env.USER_DATA_PATH` 持久化。
- `wx.onHide/onShow` 音频生命周期。
- Godot `HTTPRequest` / `HTTPClient` → `wx.request`。
- ETC2 移动端纹理导出。
- PCK ZIP 压缩、微信启动时解包。
- `engine` / `data` 分包。
- 可配置上传体积预检查：默认 20 MiB；已开通并验证“快适配”的 AppID 可配置为 30 MiB。
- runtime SHA-256 和 JS/WASM import 配对校验。
- 微信开发者工具 Preview 已验证。

当前不支持或未完整适配：Threads/pthread、GDExtension、C#/.NET、Forward+/Mobile renderer、WebSocket、微信键盘/IME。HTTP 已支持，但当前 `wx.request` bridge 会整包缓冲响应，真机还需要配置合法 request 域名。
## 在任意项目中使用

0.6.0 起插件是 self-contained addon。普通项目只需要复制或安装：

```text
addons/wechat_exporter/
```

然后在 **项目 → 项目设置 → 插件** 中启用 **WeChat Mini Game**，从顶部 **工具 → 微信小游戏...** 使用发布窗口。项目不需要复制 `tools/wechat/`。

如需直接使用 CLI，Exporter 位于 addon 内：

```bash
python3 addons/wechat_exporter/toolchain/export_wechat.py --project /path/to/game
```

`--project` 默认就是当前工作目录。Godot 可执行文件按以下顺序自动寻找：

1. `--godot /path/to/godot`
2. 环境变量 `GODOT_BIN`
3. `godot` / `godot4` PATH
4. macOS `/Applications/Godot.app/Contents/MacOS/Godot`

先建议运行兼容性检查：

```bash
python3 addons/wechat_exporter/toolchain/export_wechat.py \
  --project /path/to/game --doctor
```

`doctor` 会检查 renderer、GDExtension、C#、Thread、网络、文本输入、JavaScriptBridge，以及被排除路径中的 autoload。
## 项目配置

项目根目录可创建 `wechat_export.json`。插件首次保存配置时也会自动生成。维护者示例见 `tools/wechat/wechat_export.example.json`：

```json
{
  "project_name": "My Godot Game",
  "appid": "touristappid",
  "quick_adapt": false,
  "orientation": "portrait",
  "lib_version": "latest",
  "prepare_mobile_textures": true,
  "diagnostics": false,
  "exclude_patterns": [],
  "strip_autoloads": []
}
```

字段说明：

- `project_name`：微信开发者工具项目名。
- `appid`：微信小游戏 AppID；没有时可先用 `touristappid`。
- `quick_adapt`：声明此 AppID 已在微信公众平台开启“快适配”。`false` 默认按 20 MiB 校验，`true` 默认按已实测的 30 MiB 校验。该字段是项目声明，不等于服务端能力验证结果。
- `orientation`：`portrait` 或 `landscape`。
- `lib_version`：写入微信 `project.config.json` 的基础库版本，可用 `latest` 或固定版本。
- `prepare_mobile_textures`：默认 `true`。导出期间临时启用 Godot ETC2/ASTC 导入并执行 `--import`，结束后恢复原 `project.godot`。
- `diagnostics`：默认 `false`。开启时把启动 trace、console warn/error、`wx.onError` 和 unhandled rejection 写到微信 storage。
- `exclude_patterns`：发布包排除的编辑器、测试或开发资源。
- `strip_autoloads`：仅在发布过程中临时移除的开发期 autoload。
## 日常导出

```bash
python3 addons/wechat_exporter/toolchain/export_wechat.py \
  --project /path/to/game
```

输出默认为：

```text
<game>/build/wechat/
```

导出过程会执行：兼容性检查 → ETC2 import → 临时 Web export preset → `project.pck` → staging 组装 → `project.zip` → 分包 → `eval/new Function` 扫描 → 包体校验 → 原子替换上一版成功构建。构建元数据写到本地 sidecar `build/wechat-build-manifest.json`，不会进入微信上传源码包。

不要优先使用 `release_scenes` / `--scene` 做正式包。Godot scene-only 导出可能漏掉 GDScript 全局类、动态 shader/texture 等依赖。默认的 `all_resources + exclude_patterns` 更稳。

微信开发者工具直接打开 `build/wechat/`。CLI Preview 示例：

```bash
HOME=/Users/<user> /Applications/wechatwebdevtools.app/Contents/MacOS/cli preview \
  --project /path/to/game/build/wechat \
  --qr-format terminal
```

如果只想临时开启诊断，不改 JSON：

```bash
python3 addons/wechat_exporter/toolchain/export_wechat.py \
  --project /path/to/game --diagnostics
```

## Godot 编辑器插件

项目内置 `addons/wechat_exporter/`。启用后可从 Godot 顶部 **工具 → 微信小游戏...** 打开发布窗口。

当前窗口可直接编辑并保存：项目名称、AppID、快适配声明、屏幕方向、基础库、ETC2/ASTC、Diagnostics、排除路径和发布时移除的 Autoload。快适配开启时默认使用 30 MiB 目标额度，关闭时默认 20 MiB；checkbox 只是项目声明，实际服务端 entitlement 仍以微信 Preview/Upload 返回结果为准。

编辑器插件已经接入异步 **检查**、**构建**、**真机预览** 和 **上传开发版本**。它们调用 addon 内同一份 `toolchain/export_wechat.py` 与微信开发者工具 CLI，编辑器不会另实现一套导出逻辑。0.6.0 起 exporter、template 和 4.7.2 runtime 全部随 `addons/wechat_exporter/` 发布，不再依赖项目根目录的 `tools/wechat/`。插件只允许官方 Godot 4.7.2 commit `ed1daf0bf` 执行 Build/Preview/Upload。

**真机预览** 会强制重新构建，再调用微信 CLI Preview，并把生成的二维码直接显示在 Godot 窗口内。**上传开发版本** 也会强制重新构建，并要求填写版本号和版本说明后确认上传；插件不会自动执行微信后台的提交审核/正式发布。

微信 CLI 需要在开发者工具 **设置 → 安全设置 → 服务端口** 中一次性开启。插件会检测服务端口关闭、登录状态和 CLI 路径，并给出可操作提示。本机 CLI 路径保存在 Godot EditorSettings，不进入项目仓库。当前自动发现 CLI、自动打开微信开发者工具和完整端到端验证以 macOS 为主；其他平台可手动填写 CLI 路径，但尚未完成同等级验证。

给编辑器前端使用时可增加 `--json-events`。Exporter 会在普通日志中穿插 `@@WXEVENT@@{...}` JSON 行，供插件稳定解析阶段、兼容性和构建结果。编辑器取消 Build/Doctor 时使用 cooperative cancel：先终止 exporter 的 Godot process group，再正常恢复临时 `project.godot` / `export_presets.cfg`。

## 回归测试

```bash
tools/wechat/tests/run_tests.sh
```

测试覆盖 output 删除保护、cooperative cancel、配置额度迁移、sidecar manifest、坏 JSON、微信 CLI false-success、runtime resize、签名 updater 安装/回滚，以及“干净 Godot 4.7.2 项目只复制 addon 即可 Doctor/Build”的 standalone acceptance。

## 自动更新与 Release

0.6.0 的 addon 内置签名 updater。更新源使用 `stable.json` + `stable.json.sig`，manifest 描述版本、Godot 兼容条件、ZIP URL、size 和 SHA-256。公钥随 addon 发布，release 私钥必须保存在仓库外或 CI Secret 中。

生成独立 Release ZIP：

```bash
python3 tools/wechat/package_plugin.py \
  --base-url https://example.invalid/releases/v0.6.0
```

需要同时签名时：

```bash
export WECHAT_EXPORTER_SIGNING_KEY=/secure/release_private.pem
python3 tools/wechat/package_plugin.py \
  --base-url https://downloads.example.com/godot-wechat
```

发行目录会生成：

```text
godot-wechat-exporter-<version>.zip
stable.json
stable.json.sig   # 提供签名 key 时
```

Release ZIP 的根目录只包含 `addons/wechat_exporter/**`。Updater 只允许从 ZIP 中解压这一前缀，安装时使用 staging + backup，随后重启 Godot Editor；高级页可执行上一版本回滚。当前仓库没有配置线上 remote，因此 `release.json` 的 `default_update_manifest` 暂为空；发布独立仓库后只需填入稳定 manifest URL。

## runtime 维护者操作

普通游戏项目不需要重编 Godot runtime。维护 runtime 时必须使用 Godot `ed1daf0bf` 和 Emscripten 4.0.11，并先把 `patches/godot-4.7.2-wechat.patch` 应用到干净源码树：

```bash
git -C /path/to/godot-4.7.2 checkout ed1daf0bf
git -C /path/to/godot-4.7.2 apply /path/to/tools/wechat/patches/godot-4.7.2-wechat.patch

python3 tools/wechat/build_runtime.py \
  --godot-source /path/to/godot-4.7.2 \
  --emsdk /path/to/emsdk \
  --python /path/to/venv/bin/python
```

脚本会先验证 Godot HEAD、Emscripten 版本和 patch 已应用状态，然后等 SCons 完整退出后才复制最终 wrapper。产物还会验证 `_glGenTextures` 的 JS/WASM ABI，以及 `WXWebAssembly`、微信音频、`wx.request`、userfs 等 patch 特征，避免把错误源码或错误 toolchain 伪装成正确 runtime。

`addons/wechat_exporter/toolchain/runtime/godot-4.7.2/runtime.json` 保存 runtime 版本和 SHA-256。addon 内的 `toolchain/export_wechat.py` 每次发布都会校验它。

## 可选：字体子集

大型 CJK 字体经常是小游戏包体的主要来源。通用子集工具：

```bash
python3 -m pip install fonttools
python3 tools/wechat/build_font_subset.py \
  --font /path/to/original.ttf \
  --output /path/to/release.ttf \
  --scan /path/to/game
```

字体替换由项目自己决定，Exporter 不会自动改资源引用。

## 当前边界

如果项目依赖 WebSocket、文本输入、Threads、GDExtension、C#，`doctor` 会报错或警告。HTTP 已通过 `wx.request` 支持；当前响应为整包缓冲，不提供浏览器 ReadableStream 式增量下载。大于项目配置上传限制的项目还需要继续减包或采用远程内容包/CDN 方案。
