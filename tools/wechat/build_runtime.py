#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = ROOT.parents[1]
DEFAULT_OUTPUT = (
    PROJECT_ROOT / "addons" / "wechat_exporter" / "toolchain"
    / "runtime" / "godot-4.7.2"
)
PATCH_FILE = ROOT / "patches" / "godot-4.7.2-wechat.patch"
GODOT_COMMIT = "ed1daf0bf"
EMSCRIPTEN_VERSION = "4.0.11"


def parse_args():
    p = argparse.ArgumentParser(description="Build the patched Godot 4.7.2 WeChat runtime.")
    p.add_argument("--godot-source", type=Path, required=True)
    p.add_argument("--emsdk", type=Path, required=True)
    p.add_argument("--python", default=sys.executable, help="Python used to locate a sibling scons executable.")
    p.add_argument("--scons", default=None, help="Explicit SCons executable.")
    p.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return p.parse_args()


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_scons(python, explicit=None):
    candidates = []
    if explicit:
        candidates.append(explicit)
    candidates.append(str(Path(python).expanduser().parent / "scons"))
    discovered = shutil.which("scons")
    if discovered:
        candidates.append(discovered)
    for candidate in candidates:
        path = Path(candidate).expanduser()
        if path.is_file():
            return str(path)
    raise RuntimeError("SCons executable not found. Pass --scons or install it next to --python.")


def verify_toolchain(source, emsdk):
    head = subprocess.run(
        ["git", "-C", str(source), "rev-parse", "HEAD"],
        check=True, text=True, capture_output=True,
    ).stdout.strip()
    if not head.startswith(GODOT_COMMIT):
        raise RuntimeError(
            f"Expected Godot commit {GODOT_COMMIT}, got {head}"
        )

    patch_check = subprocess.run(
        ["git", "-C", str(source), "apply", "--reverse", "--check", str(PATCH_FILE)],
        text=True, capture_output=True,
    )
    if patch_check.returncode != 0:
        raise RuntimeError(
            "WeChat Godot patch is not applied cleanly to the source tree."
        )

    emcc = emsdk / "upstream/emscripten/emcc"
    if not emcc.is_file():
        raise RuntimeError(f"Emscripten compiler not found: {emcc}")
    version = subprocess.run(
        [str(emcc), "--version"], check=True, text=True, capture_output=True
    ).stdout.splitlines()[0]
    if EMSCRIPTEN_VERSION not in version:
        raise RuntimeError(
            f"Expected Emscripten {EMSCRIPTEN_VERSION}, got: {version}"
        )
    return head, version


def run_build(source, emsdk, scons):
    cmd = f'''\nset -e\nsource "{emsdk / "emsdk_env.sh"}" >/dev/null\ncd "{source}"\n"{scons}" platform=web target=template_release arch=wasm32 threads=no javascript_eval=no lto=none optimize=size use_closure_compiler=no debug_symbols=no linkflags='-sDISABLE_DEPRECATED_FIND_EVENT_TARGET_BEHAVIOR=0' -j4\n'''
    subprocess.run(["/bin/zsh", "-lc", cmd], check=True)


def validate_pair(js_path, wasm_path, wasm_dis):
    js = js_path.read_text(encoding="utf-8", errors="ignore")
    required_markers = [
        "WXWebAssembly.instantiate",
        "wx.createWebAudioContext",
        "wx.request",
        "wxFSSync",
        "wxAudioResume",
        "wx.env.USER_DATA_PATH",
    ]
    missing = [marker for marker in required_markers if marker not in js]
    if missing:
        raise RuntimeError(
            "Patched runtime markers missing from godot.js: " + ", ".join(missing)
        )
    if "_gainNode.connect(this._soloNode).connect" in js:
        raise RuntimeError("AudioNode.connect chaining is still present in runtime.")
    match = re.search(r'([A-Za-z_$][A-Za-z0-9_$]*):_glGenTextures\b', js)
    if not match:
        raise RuntimeError("Could not find _glGenTextures import binding in godot.js.")
    import_name = match.group(1)

    with tempfile.TemporaryDirectory(prefix="wx-godot-wasm-") as td:
        wast = Path(td) / "godot.wast"
        subprocess.run([str(wasm_dis), str(wasm_path), "-o", str(wast)], check=True)
        expected = None
        with wast.open("r", encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                if f'(import "a" "{import_name}" ' in line:
                    expected = line.strip()
                    break
        if expected is None:
            raise RuntimeError(f"WASM does not import JS symbol {import_name!r}.")
        if "(param i32 i32)" not in expected or "(result" in expected:
            raise RuntimeError(
                f"godot.js/WASM import mismatch for _glGenTextures: {expected}"
            )
    return import_name


def main():
    args = parse_args()
    source = args.godot_source.resolve()
    emsdk = args.emsdk.resolve()
    output = args.output.resolve()
    wrapper = source / "bin/godot.web.template_release.wasm32.nothreads.wrapped.js"
    wasm = source / "bin/godot.web.template_release.wasm32.nothreads.wasm"
    wasm_dis = emsdk / "upstream/bin/wasm-dis"

    scons = resolve_scons(args.python, args.scons)
    source_head, emcc_version = verify_toolchain(source, emsdk)
    run_build(source, emsdk, scons)

    if not wrapper.is_file() or not wasm.is_file():
        raise RuntimeError("Godot web build did not produce final JS/WASM outputs.")

    import_name = validate_pair(wrapper, wasm, wasm_dis)

    try:
        import brotli
    except ImportError as exc:
        raise RuntimeError("brotli Python module is required: pip install brotli") from exc

    output.mkdir(parents=True, exist_ok=True)
    js_out = output / "godot.js"
    wasm_out = output / "godot.wasm.br"
    js_out.write_bytes(wrapper.read_bytes())
    wasm_out.write_bytes(brotli.compress(wasm.read_bytes(), quality=11))

    manifest = {
        "godot_version": "4.7.2.stable",
        "godot_commit": source_head,
        "emscripten_version": EMSCRIPTEN_VERSION,
        "emscripten_version_text": emcc_version,
        "threads": False,
        "javascript_eval": False,
        "gl_gen_textures_import": import_name,
        "capabilities": {
            "webgl2": True,
            "touch": True,
            "audio": True,
            "userfs": True,
            "http_request": True,
            "websocket": False,
            "ime": False,
            "threads": False,
            "gdextension": False,
            "dotnet": False,
        },
        "files": {
            "godot.js": {"size": js_out.stat().st_size, "sha256": sha256(js_out)},
            "godot.wasm.br": {"size": wasm_out.stat().st_size, "sha256": sha256(wasm_out)},
        },
    }
    (output / "runtime.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
