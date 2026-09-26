#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
PYTHON_BIN=${PYTHON_BIN:-python3}

if [ -n "${GODOT_BIN:-}" ]; then
    GODOT="$GODOT_BIN"
elif command -v godot >/dev/null 2>&1; then
    GODOT=$(command -v godot)
elif command -v godot4 >/dev/null 2>&1; then
    GODOT=$(command -v godot4)
elif [ -x /Applications/Godot.app/Contents/MacOS/Godot ]; then
    GODOT=/Applications/Godot.app/Contents/MacOS/Godot
else
    echo "Godot executable not found; set GODOT_BIN." >&2
    exit 1
fi

cd "$PROJECT_ROOT"
"$PYTHON_BIN" -m unittest discover \
    -s tools/wechat/tests -p 'test_*.py' -v
"$GODOT" --headless --path "$PROJECT_ROOT" \
    --script tools/wechat/tests/test_editor_window.gd

if command -v node >/dev/null 2>&1; then
    node tools/wechat/tests/test_runtime_adapter.mjs
fi

TMP_PROJECT=$(mktemp -d "${TMPDIR:-/tmp}/wx-addon-update-test.XXXXXX")
trap 'rm -rf "$TMP_PROJECT"' EXIT INT TERM
mkdir -p "$TMP_PROJECT/addons"
cp -R "$PROJECT_ROOT/addons/wechat_exporter" "$TMP_PROJECT/addons/wechat_exporter"
cat > "$TMP_PROJECT/project.godot" <<'EOF'
[application]
config/name="WeChat Updater Transaction Test"

[rendering]
renderer/rendering_method="gl_compatibility"
EOF
WX_UPDATE_FIXTURE="$PROJECT_ROOT/tools/wechat/tests/fixtures/update/stable.json" \
    "$GODOT" --headless --path "$TMP_PROJECT" \
    --script "$PROJECT_ROOT/tools/wechat/tests/test_update_transaction.gd"

GODOT_BIN="$GODOT" PYTHON_BIN="$PYTHON_BIN" \
    tools/wechat/tests/test_standalone_addon.sh
