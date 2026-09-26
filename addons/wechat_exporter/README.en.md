# WeChat Mini Game Exporter for Godot

Standalone Godot editor addon for WeChat Mini Games.

<p>
  <a href="./README.md"><img src="https://img.shields.io/badge/%E8%AF%AD%E8%A8%80-%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-d0d7de" alt="简体中文"></a>
  <a href="./README.en.md"><img src="https://img.shields.io/badge/Language-English-2ea44f" alt="English"></a>
</p>

This is a standalone Godot editor addon for building, previewing, and uploading Godot projects as WeChat Mini Games.

## Supported engine

The current release supports exactly:

- Godot 4.7.2 stable official
- commit `ed1daf0bf`
- GL Compatibility renderer
- GDScript
- single-threaded Web/WASM export

Build, Preview, and Upload are disabled when the running Godot version or commit does not match this supported pair.

## Install

Download the latest `godot-wechat-exporter-<version>.zip` from GitHub Releases and extract it into the project root.

The installed path must be:

```text
addons/wechat_exporter/
```

Then enable **WeChat Mini Game** under **Project → Project Settings → Plugins** and open **Tools → 微信小游戏...**.

The addon is self-contained and includes:

- the editor publishing UI
- the Python exporter
- WeChat Mini Game host templates
- the patched Godot 4.7.2 Web runtime

Consumer projects do not need a separate `tools/wechat/` directory.

## Project configuration

Publishing settings are stored in:

```text
wechat_export.json
```

Typical fields include AppID, Quick Adapt declaration, orientation, base-library version, diagnostics, optional exclude patterns, and Autoloads that should be stripped only during publishing.

The exporter always excludes the editor plugin itself from the game PCK. Other addons are preserved by default.

## Publishing

The editor window supports:

- compatibility Doctor
- Build
- device Preview with QR code
- WeChat developer-version Upload
- package-size reporting
- safe cooperative cancellation
- stale-build detection

Generated WeChat project:

```text
build/wechat/
```

Local build metadata:

```text
build/wechat-build-manifest.json
```

The sidecar manifest is not uploaded to WeChat.

## Updates

Version 0.6.1 and later use the signed GitHub stable channel by default:

```text
https://github.com/niu-row/godot-wechat-exporter/releases/latest/download/stable.json
```

The source can be overridden under **高级 → 插件更新** with another HTTP(S) URL or a local manifest.

The updater:

1. verifies `stable.json.sig` with the bundled public key
2. checks Godot compatibility
3. downloads the Release ZIP
4. verifies package SHA-256 and size
5. extracts only `addons/wechat_exporter/**`
6. keeps the previous plugin as a rollback backup
7. installs the new version and lets the user restart the editor

Automatic checks run at most once every 24 hours. Updates are never installed silently.

The update source is stored in local EditorSettings and is not written to the game's `wechat_export.json`.

## WeChat Developer Tools

On macOS the addon auto-detects:

```text
/Applications/wechatwebdevtools.app
```

Enable the service port once in:

**Settings → Security Settings → Service Port**

Other operating systems can use a manually configured CLI path, but current end-to-end acceptance coverage is macOS-first.

## Runtime / platform boundaries

The current release does not support the following capabilities. These are primarily constrained by the Godot Web/WASM architecture or the WeChat Mini Game runtime rather than being simple plugin-adaptation gaps:

- pthread / Godot Thread APIs
- general-purpose dynamic GDExtension loading
- C# / .NET
- Forward+ / Mobile renderer

## WeChat adaptations not yet implemented

The platform provides related capabilities, but the current runtime does not yet bridge them to Godot:

- WebSocket: WeChat provides Socket APIs, but the `WebSocketPeer` bridge is not implemented yet
- text input / virtual keyboard: WeChat provides keyboard APIs, so normal text input can be adapted; full IME composition behavior still requires device validation

HTTP requests are already bridged through `wx.request`; the Mini Game still needs the appropriate WeChat request-domain configuration.

## License

The exporter/plugin code is licensed under the MIT License.

The bundled patched Godot runtime and Emscripten-generated code retain their upstream licenses. See:

- `THIRD_PARTY_NOTICES.md`
- `LICENSES/`
