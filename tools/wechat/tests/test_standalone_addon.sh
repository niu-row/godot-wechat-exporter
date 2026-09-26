#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
PYTHON_BIN=${PYTHON_BIN:-python3}
GODOT=${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}

TMP_PROJECT=$(mktemp -d "${TMPDIR:-/tmp}/wx-addon-standalone.XXXXXX")
trap 'rm -rf "$TMP_PROJECT"' EXIT INT TERM
mkdir -p "$TMP_PROJECT/addons/runtime_dependency"
cp -R "$PROJECT_ROOT/addons/wechat_exporter"     "$TMP_PROJECT/addons/wechat_exporter"

cat > "$TMP_PROJECT/project.godot" <<'EOF'
[application]
config/name="WeChat Standalone Acceptance"
run/main_scene="res://main.tscn"

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
textures/vram_compression/import_etc2_astc=true

[editor_plugins]
enabled=PackedStringArray("res://addons/wechat_exporter/plugin.cfg")
EOF
cat > "$TMP_PROJECT/addons/runtime_dependency/helper.gd" <<'EOF'
extends RefCounted
class_name RuntimeDependencyHelper

static func value() -> String:
    return "third-party-addon-kept"
EOF

cat > "$TMP_PROJECT/main.gd" <<'EOF'
extends Node

func _ready() -> void:
    print(RuntimeDependencyHelper.value())
EOF

cat > "$TMP_PROJECT/main.tscn" <<'EOF'
[gd_scene load_steps=2 format=3]

[ext_resource path="res://main.gd" type="Script" id="1"]

[node name="Main" type="Node"]
script = ExtResource("1")
EOF
"$GODOT" --headless --editor --path "$TMP_PROJECT" --quit     >/tmp/wx-standalone-editor.log 2>&1

EXPORTER="$TMP_PROJECT/addons/wechat_exporter/toolchain/export_wechat.py"
"$PYTHON_BIN" "$EXPORTER" --project "$TMP_PROJECT" --doctor     >/tmp/wx-standalone-doctor.log 2>&1
"$PYTHON_BIN" "$EXPORTER" --project "$TMP_PROJECT"     >/tmp/wx-standalone-build.log 2>&1

WX_STANDALONE_PROJECT="$TMP_PROJECT" "$PYTHON_BIN" - <<'PY'
import importlib.util
import os
from pathlib import Path
import tempfile
import zipfile

root = Path(os.environ["WX_STANDALONE_PROJECT"])
module_path = root / "addons/wechat_exporter/toolchain/export_wechat.py"
spec = importlib.util.spec_from_file_location("wx_export", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with zipfile.ZipFile(root / "build/wechat/data/project.zip") as archive:
    with tempfile.TemporaryDirectory() as td:
        pck = Path(td) / "project.bin"
        pck.write_bytes(archive.read("project.bin"))
        rows = module.pck_top_files(pck, limit=1000)

names = [row["path"] for row in rows]
assert any(
    "addons/runtime_dependency/helper.gd" in name
    or "addons/runtime_dependency/helper.gdc" in name
    for name in names
), "third-party runtime addon was excluded"
assert not any(
    "addons/wechat_exporter/" in name for name in names
), "WeChat editor plugin leaked into the game PCK"
print("STANDALONE_ADDON_TESTS_OK")
PY
