# WeChat Mini Game Exporter for Godot

Standalone Godot editor addon for building Godot projects as WeChat Mini Games.

## Supported engine

This release supports exactly:

- Godot 4.7.2 stable official
- commit `ed1daf0bf`
- GL Compatibility renderer
- GDScript / single-threaded Web export

The publishing actions are disabled when the running editor does not match
that engine/runtime pair.

## Install

Download the latest `godot-wechat-exporter-<version>.zip` from GitHub
Releases and extract it into the project root. The installed path must be:

```text
addons/wechat_exporter/
```

Then enable **WeChat Mini Game** in **Project Settings → Plugins** and open
**Tools → 微信小游戏...**.
The addon is self-contained. It includes:

- the editor publishing UI,
- the Python exporter,
- WeChat host templates,
- the patched Godot 4.7.2 Web runtime.

A consumer project does not need a separate `tools/wechat/` directory.

## Project configuration

The plugin stores project publishing settings in:

```text
wechat_export.json
```

Typical fields include AppID, Quick Adapt declaration, orientation,
base-library version, diagnostics, optional exclude patterns, and autoloads
that should be stripped only during publishing.

The exporter itself always excludes the editor plugin from the game PCK.
Other addons are preserved by default.
## Publishing

The editor window supports:

- compatibility Doctor,
- Build,
- device Preview with QR code,
- WeChat developer-version Upload,
- package-size dashboard,
- safe cooperative cancellation,
- build staleness detection.

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

The **高级 → 插件更新** panel can override this with another HTTP(S) or
local manifest source. The updater:

1. verifies the manifest with the bundled public key,
2. checks Godot compatibility,
3. downloads the release ZIP,
4. verifies package SHA-256 and size,
5. extracts only `addons/wechat_exporter/**`,
6. keeps the previous plugin as a rollback backup,
7. installs the new addon and restarts the editor.

Automatic checks run at most once per 24 hours when an update source is
configured. Installation is explicit; updates are not silently installed.

The source URL is a local EditorSettings preference and is not written into
the game project's `wechat_export.json`.
## WeChat Developer Tools

On macOS the addon auto-detects:

```text
/Applications/wechatwebdevtools.app
```

The WeChat Developer Tools service port must be enabled once under
**Settings → Security Settings → Service Port**.

Other operating systems can use a manually configured CLI path, but the
current end-to-end acceptance coverage is macOS-first.

## Runtime limitations

Not fully supported: pthread/Threads, GDExtension, C#/.NET, Forward+/Mobile
renderer, WebSocket, and IME/keyboard text input.

HTTP requests are bridged through `wx.request`; the mini game still needs
the appropriate WeChat request-domain configuration.

## License

The exporter/plugin code is available under the MIT License. The bundled
patched Godot runtime and Emscripten-generated glue retain their upstream
licenses; see `THIRD_PARTY_NOTICES.md` and `LICENSES/`.
