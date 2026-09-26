# Changelog

## 0.6.1

Public release preparation.

- Added MIT license for the exporter/plugin code.
- Included Godot and Emscripten license notices inside the distributable addon.
- Configured the signed GitHub `latest/download/stable.json` update channel by default.
- Kept exact Godot 4.7.2 compatibility and runtime ID `godot-4.7.2-wx-r1`.
- Release ZIP remains restricted to `addons/wechat_exporter/**`.

## 0.6.0

Initial standalone release.

- Self-contained `addons/wechat_exporter/` distribution.
- Godot 4.7.2 official compatibility gate.
- Bundled patched Godot Web runtime and WeChat host templates.
- Doctor, Build, Preview, QR display, and developer-version Upload workflow.
- Safe cooperative cancellation and staging builds.
- Sidecar build manifest with stale-build detection.
- Signed updater with RSA/SHA-256 verification, staging install, backup, and
  rollback.
- Responsive publishing UI with configurable 100%–200% interface scaling.
- Standalone clean-project acceptance tests.
- Runtime adapter resize and diagnostic persistence hardening.

## Earlier development

Versions 0.4.x–0.5.x were developed inside the original consumer project
before the exporter was extracted into this standalone repository.
