# Third-Party Notices

This repository bundles a patched Godot Web runtime so consumer projects can
export to WeChat Mini Games without rebuilding the engine.

## Godot Engine

- Project: Godot Engine
- Version: 4.7.2 stable
- Commit: `ed1daf0bf`
- Source: https://github.com/godotengine/godot
- Bundled artifacts:
  - `addons/wechat_exporter/toolchain/runtime/godot-4.7.2/godot.js`
  - `addons/wechat_exporter/toolchain/runtime/godot-4.7.2/godot.wasm.br`
- Local modifications are represented by:
  `tools/wechat/patches/godot-4.7.2-wechat.patch`

Godot Engine is distributed under the MIT license. The complete license text
used for this bundled runtime is in `LICENSES/Godot.txt`.

## Emscripten

The bundled Godot Web runtime was built with Emscripten 4.0.11. Generated
JavaScript glue includes Emscripten runtime code.

Emscripten is available under the MIT license and the University of
Illinois/NCSA Open Source License. The upstream license text is reproduced in
`LICENSES/Emscripten.txt`.

This notice covers third-party components bundled in the standalone addon. It
does not select a license for the original exporter/plugin code in this
repository.
