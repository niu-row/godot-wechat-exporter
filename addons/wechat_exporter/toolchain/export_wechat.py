#!/usr/bin/env python3
import argparse
import contextlib
from fnmatch import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zipfile

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_TEMPLATE = SCRIPT_DIR / "template"
DEFAULT_RUNTIME = SCRIPT_DIR / "runtime" / "godot-4.7.2"
MAIN_PACKAGE_LIMIT = 4_000_000
DEFAULT_PACKAGE_LIMIT_MIB = 20
MAX_VERIFIED_PACKAGE_LIMIT_MIB = 30
PACKAGE_HEADROOM_WARNING = 4 * 1024 * 1024
PACKAGE_HEADROOM_CRITICAL = 2 * 1024 * 1024
ALLOWED_SUFFIXES = {".js", ".json", ".br", ".bin", ".zip"}
TOOL_VERSION = "0.6.1"
EVENT_PREFIX = "@@WXEVENT@@"
JSON_EVENTS = False
CANCEL_FILE = None
DEFAULT_EXCLUDES = [
    ".git/**", ".godot/**", "build/**",
    "addons/wechat_exporter/**", "wechat_export.json",
]
DEFAULT_EXPORT_EXCLUDES = [
    "build/**", ".git/**", "addons/wechat_exporter/**", "wechat_export.json",
]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Export a Godot 4.7.2 project as a WeChat Mini Game project."
    )
    parser.add_argument("--project", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--godot", default=None, help="Godot executable; defaults to GODOT_BIN/PATH/macOS app.")
    parser.add_argument("--runtime", type=Path, default=DEFAULT_RUNTIME)
    parser.add_argument("--template", type=Path, default=DEFAULT_TEMPLATE)
    parser.add_argument("--config", type=Path, default=None)
    parser.add_argument("--appid", default=None)
    parser.add_argument("--project-name", default=None)
    parser.add_argument("--orientation", choices=("portrait", "landscape"), default=None)
    parser.add_argument("--lib-version", default=None, help="WeChat base library version for project.config.json.")
    parser.add_argument(
        "--package-limit-mib",
        type=int,
        default=None,
        help="Total upload limit in MiB. Defaults to 20; use 30 only for AppIDs with verified Quick Adapt entitlement.",
    )
    parser.add_argument("--scene", action="append", default=None)
    parser.add_argument("--preset", default="Web")
    parser.add_argument("--keep-temp", action="store_true")
    parser.add_argument("--allow-oversize", action="store_true")
    parser.add_argument(
        "--cancel-file", type=Path, default=None,
        help="Cooperative cancellation sentinel used by the Godot editor plugin.",
    )
    parser.add_argument("--doctor", action="store_true", help="Check project compatibility and exit.")
    parser.add_argument("--skip-import", action="store_true", help="Skip the Godot resource import pass.")
    parser.add_argument("--skip-compat-check", action="store_true", help="Skip project capability checks.")
    parser.add_argument("--diagnostics", action="store_true", help="Enable persistent runtime trace/error capture.")
    parser.add_argument(
        "--json-events", action="store_true",
        help="Emit machine-readable JSON event lines prefixed with @@WXEVENT@@.",
    )
    parser.add_argument("--version", action="version", version=f"godot-wechat-exporter {TOOL_VERSION}")
    return parser.parse_args()


class ExportCancelled(RuntimeError):
    pass


def fail(message):
    raise RuntimeError(message)


def cancellation_requested():
    return CANCEL_FILE is not None and CANCEL_FILE.exists()


def check_cancelled():
    if cancellation_requested():
        raise ExportCancelled("Export cancelled")


def terminate_child(process):
    if process.poll() is not None:
        return
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except ProcessLookupError:
            pass
        process.wait()


def emit_event(event, **payload):
    if not JSON_EVENTS:
        return
    record = {"event": event}
    record.update(payload)
    print(EVENT_PREFIX + json.dumps(record, ensure_ascii=True), flush=True)


def run(command, **kwargs):
    check_cancelled()
    print("+", " ".join(map(str, command)))
    process = subprocess.Popen(
        command,
        text=True,
        start_new_session=(os.name == "posix"),
        **kwargs,
    )
    try:
        while True:
            exit_code = process.poll()
            if exit_code is not None:
                break
            if cancellation_requested():
                terminate_child(process)
                raise ExportCancelled("Export cancelled")
            time.sleep(0.1)
    except BaseException:
        terminate_child(process)
        raise
    if exit_code != 0:
        raise subprocess.CalledProcessError(exit_code, command)
    return subprocess.CompletedProcess(command, exit_code)


def resolve_godot_binary(value=None):
    candidates = []
    if value:
        candidates.append(value)
    env_value = os.environ.get("GODOT_BIN")
    if env_value:
        candidates.append(env_value)
    for name in ("godot", "godot4"):
        resolved = shutil.which(name)
        if resolved:
            candidates.append(resolved)
    candidates.append("/Applications/Godot.app/Contents/MacOS/Godot")

    for candidate in candidates:
        if not candidate:
            continue
        expanded = Path(candidate).expanduser()
        if expanded.is_file():
            return str(expanded)
        resolved = shutil.which(str(candidate))
        if resolved:
            return resolved
    fail("Godot executable not found. Pass --godot or set GODOT_BIN.")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_project_name(project_file):
    text = project_file.read_text(encoding="utf-8")
    match = re.search(r'^config/name="([^"]+)"', text, re.MULTILINE)
    return match.group(1) if match else project_file.parent.name


def load_config(project, explicit_path=None):
    path = explicit_path.resolve() if explicit_path else project / "wechat_export.json"
    if not path.exists():
        return {}, path
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        fail(
            f"Invalid JSON in {path} at line {error.lineno}, "
            f"column {error.colno}: {error.msg}"
        )
    if not isinstance(data, dict):
        fail(f"WeChat export config must be an object: {path}")
    return data, path


def resolve_package_limit_mib(value, quick_adapt=False):
    if value is None:
        limit = MAX_VERIFIED_PACKAGE_LIMIT_MIB if quick_adapt else DEFAULT_PACKAGE_LIMIT_MIB
    else:
        if isinstance(value, bool):
            fail("package_limit_mib must be an integer, not a boolean")
        try:
            limit = int(value)
        except (TypeError, ValueError):
            fail(f"package_limit_mib must be an integer; got {value!r}")
    if limit <= 0 or limit > MAX_VERIFIED_PACKAGE_LIMIT_MIB:
        fail(
            f"package_limit_mib must be between 1 and {MAX_VERIFIED_PACKAGE_LIMIT_MIB}; got {limit}"
        )
    return limit


def validate_output_path(project, output):
    project = project.resolve()
    output = output.resolve()
    default_output = (project / "build" / "wechat").resolve()
    build_root = (project / "build").resolve()

    if output == project or output == build_root:
        fail(f"Refusing destructive output path: {output}")
    try:
        project.relative_to(output)
    except ValueError:
        pass
    else:
        fail(f"Output path must not contain the project directory: {output}")

    if output.exists() and not output.is_dir():
        fail(f"Output path exists and is not a directory: {output}")
    if output.exists() and output != default_output:
        fail(
            "Refusing to replace an existing custom output directory. "
            f"Remove it explicitly first: {output}"
        )
    return output


def normalize_scenes(scenes):
    result = []
    for scene in scenes or []:
        value = str(scene)
        if not value.startswith("res://"):
            value = "res://" + value.lstrip("/")
        result.append(value)
    return result


def is_excluded(relative_path, patterns):
    value = relative_path.as_posix()
    return any(fnmatch(value, pattern) for pattern in patterns)


def scan_project_compatibility(project, project_file, exclude_patterns, strip_autoloads=None):
    errors = []
    warnings = []
    notes = []
    text = project_file.read_text(encoding="utf-8", errors="ignore")

    compatibility = (
        'renderer/rendering_method="gl_compatibility"' in text
        or '"GL Compatibility"' in text
    )
    if not compatibility:
        errors.append("Renderer must be GL Compatibility for the current WeChat runtime.")

    patterns = DEFAULT_EXCLUDES + list(exclude_patterns or [])
    strip_autoloads = set(strip_autoloads or [])
    autoload_section = re.search(r"(?ms)^\[autoload\]\s*\n(.*?)(?=^\[|\Z)", text)
    if autoload_section:
        uid_cache = {}
        for uid_file in project.rglob("*.uid"):
            try:
                uid_value = uid_file.read_text(encoding="utf-8").strip()
            except OSError:
                continue
            if uid_value:
                uid_cache[uid_value] = Path(str(uid_file.relative_to(project))[:-4])
        for line in autoload_section.group(1).splitlines():
            match = re.match(r'^([^=]+)="\*?([^"]+)"$', line.strip())
            if not match:
                continue
            name, target = match.groups()
            if name in strip_autoloads:
                notes.append(f"Autoload {name} will be stripped for WeChat export.")
                continue
            rel = None
            if target.startswith("res://"):
                rel = Path(target.removeprefix("res://"))
            elif target.startswith("uid://"):
                rel = uid_cache.get(target)
            if rel is not None and is_excluded(rel, patterns):
                errors.append(
                    f"Autoload {name} resolves to excluded path: {rel.as_posix()}"
                )

    source_files = []
    gdextensions = []
    csharp_files = []
    for path in project.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(project)
        if is_excluded(rel, patterns):
            continue
        if path.suffix == ".gdextension":
            gdextensions.append(rel.as_posix())
        if path.suffix == ".cs":
            csharp_files.append(rel.as_posix())
        if path.suffix in {".gd", ".tscn", ".tres"}:
            source_files.append((path, rel.as_posix()))

    if gdextensions:
        errors.append(f"GDExtension is not supported yet: {gdextensions[0]}")
    if csharp_files or '"C#"' in text or "dotnet" in text.lower():
        sample = csharp_files[0] if csharp_files else "project.godot"
        errors.append(f"C#/.NET projects are not supported yet: {sample}")

    probes = [
        ("threads", ("Thread.new", "WorkerThreadPool", "Semaphore", "Mutex"),
         "Thread APIs detected; this runtime is built with threads=no."),
        ("websocket", ("WebSocketPeer", "WebSocketMultiplayerPeer"),
         "WebSocket APIs detected; wx.connectSocket adaptation is not complete."),
        ("keyboard", ("LineEdit", "TextEdit", "virtual_keyboard_show"),
         "Text input detected; wx.showKeyboard/IME adaptation is not complete."),
        ("javascript", ("JavaScriptBridge",),
         "JavaScriptBridge usage may depend on browser APIs unavailable in WeChat."),
    ]
    seen = set()
    http_seen = False
    for path, rel in source_files:
        try:
            body = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if not http_seen and any(token in body for token in ("HTTPRequest", "HTTPClient")):
            notes.append(
                f"HTTP APIs use wx.request (buffered response). Configure a legal request domain on real devices. First match: {rel}"
            )
            http_seen = True
        for key, tokens, message in probes:
            if key in seen:
                continue
            if any(token in body for token in tokens):
                warnings.append(f"{message} First match: {rel}")
                seen.add(key)

    etc2_enabled = "textures/vram_compression/import_etc2_astc=true" in text
    if etc2_enabled:
        notes.append("ETC2/ASTC import is enabled in project.godot.")
    else:
        notes.append("ETC2/ASTC import will be enabled temporarily during export.")
    return {"errors": errors, "warnings": warnings, "notes": notes}


def print_compatibility_report(report):
    print("\nCompatibility check")
    for item in report["errors"]:
        print(f"  ERROR: {item}")
    for item in report["warnings"]:
        print(f"  WARN:  {item}")
    for item in report["notes"]:
        print(f"  INFO:  {item}")
    if not report["errors"] and not report["warnings"]:
        print("  OK:    No unsupported project features detected.")


def set_ini_setting(text, section, key, value):
    section_re = re.compile(
        rf"(?ms)^\[{re.escape(section)}\]\s*\n(.*?)(?=^\[|\Z)"
    )
    match = section_re.search(text)
    line = f"{key}={value}"
    if not match:
        suffix = "" if text.endswith("\n") else "\n"
        return f"{text}{suffix}\n[{section}]\n\n{line}\n"

    body = match.group(1)
    key_re = re.compile(rf"(?m)^{re.escape(key)}=.*$")
    if key_re.search(body):
        new_body = key_re.sub(line, body, count=1)
    else:
        new_body = body + ("" if body.endswith("\n") else "\n") + line + "\n"
    return text[:match.start(1)] + new_body + text[match.end(1):]


def strip_autoload_entries(text, names):
    names = set(names or [])
    if not names:
        return text
    section_re = re.compile(r"(?ms)^\[autoload\]\s*\n(.*?)(?=^\[|\Z)")
    match = section_re.search(text)
    if not match:
        return text
    body_lines = match.group(1).splitlines(keepends=True)
    filtered = []
    for line in body_lines:
        key_match = re.match(r"^([^=]+)=", line.strip())
        if key_match and key_match.group(1) in names:
            continue
        filtered.append(line)
    new_body = "".join(filtered)
    return text[:match.start(1)] + new_body + text[match.end(1):]


@contextlib.contextmanager
def temporary_project_settings(project_file, mobile_textures=True, strip_autoloads=None):
    original = project_file.read_bytes()
    text = original.decode("utf-8")
    updated = text
    if mobile_textures:
        updated = set_ini_setting(
            updated, "rendering", "textures/vram_compression/import_etc2_astc", "true"
        )
    updated = strip_autoload_entries(updated, strip_autoloads)
    changed = updated != text
    if changed:
        project_file.write_text(updated, encoding="utf-8")
    try:
        yield changed
    finally:
        if changed:
            project_file.write_bytes(original)


def import_project_resources(project, godot):
    run([godot, "--headless", "--recovery-mode", "--path", str(project), "--import"])


def validate_project(project):
    project_file = project / "project.godot"
    if not project_file.is_file():
        fail(f"Godot project not found: {project_file}")
    text = project_file.read_text(encoding="utf-8")
    if "GL Compatibility" not in text and 'renderer/rendering_method="gl_compatibility"' not in text:
        print("WARNING: project does not explicitly use GL Compatibility.")
    return project_file


def validate_runtime(runtime):
    manifest_path = runtime / "runtime.json"
    if not manifest_path.is_file():
        fail(f"Runtime manifest missing: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for filename, expected in manifest["files"].items():
        path = runtime / filename
        if not path.is_file():
            fail(f"Runtime file missing: {path}")
        actual = sha256(path)
        if actual != expected["sha256"]:
            fail(f"Runtime checksum mismatch: {filename}")
    return manifest


def validate_godot(
    godot, expected="4.7.2", expected_commit="ed1daf0bf"
):
    result = subprocess.run(
        [godot, "--version"], check=True, text=True, capture_output=True
    )
    version = result.stdout.strip()
    if not version.startswith(expected):
        fail(f"Expected Godot {expected}, got {version}")
    if expected_commit and f".{expected_commit}" not in version:
        fail(
            f"Expected official Godot {expected} commit {expected_commit}, "
            f"got {version}"
        )
    return version


@contextlib.contextmanager
def ensure_export_preset(project, preset_name, scenes=None, exclude_patterns=None):
    path = project / "export_presets.cfg"
    original = path.read_bytes() if path.exists() else None
    if scenes:
        scene_values = ", ".join(json.dumps(scene) for scene in scenes)
        export_filter = "scenes"
        export_files = f"export_files=PackedStringArray({scene_values})\n"
    else:
        export_filter = "all_resources"
        export_files = ""
    export_excludes = DEFAULT_EXPORT_EXCLUDES + list(exclude_patterns or [])
    exclude_filter = ",".join(dict.fromkeys(export_excludes))
    content = (
        f'[preset.0]\n\nname="{preset_name}"\nplatform="Web"\n'
        'runnable=true\ndedicated_server=false\ncustom_features=""\n'
        f'export_filter="{export_filter}"\n{export_files}'
        f'include_filter=""\nexclude_filter="{exclude_filter}"\nexport_path=""\n'
        'encrypt_pck=false\nencrypt_directory=false\n\n'
        '[preset.0.options]\n'
        'variant/extensions_support=false\n'
        'variant/thread_support=false\n'
        'vram_texture_compression/for_desktop=false\n'
        'vram_texture_compression/for_mobile=true\n'
    )
    path.write_text(content, encoding="utf-8")
    try:
        yield
    finally:
        if original is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(original)


def export_pack(project, godot, preset, destination, scenes=None, exclude_patterns=None):
    with ensure_export_preset(project, preset, scenes, exclude_patterns):
        run([
            godot, "--headless", "--recovery-mode", "--path", str(project),
            "--export-pack", preset, str(destination),
        ])
    if not destination.is_file() or destination.stat().st_size == 0:
        fail("Godot export did not produce a PCK file")


def write_game_json(output, orientation):
    data = {
        "deviceOrientation": orientation,
        "subpackages": [
            {"name": "engine", "root": "engine/"},
            {"name": "data", "root": "data/"},
        ],
    }
    (output / "game.json").write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def write_project_config(output, appid, project_name, lib_version="latest"):
    config = {
        "description": "Godot WeChat Mini Game export",
        "compileType": "game",
        "libVersion": lib_version,
        "appid": appid,
        "projectname": project_name,
        "setting": {
            "urlCheck": False,
            "es6": True,
            "minified": True,
            "compileWorklet": False,
            "enhance": False,
            "disableSWC": True,
        },
        "packOptions": {"ignore": [], "include": []},
    }
    (output / "project.config.json").write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def _hardlink_or_copy(source, destination):
    try:
        os.link(source, destination)
    except OSError:
        shutil.copy2(source, destination)


def _sync_files_preserving_directories(source, target):
    source_files = {
        path.relative_to(source)
        for path in source.rglob("*")
        if path.is_file()
    }
    target_files = {
        path.relative_to(target)
        for path in target.rglob("*")
        if path.is_file()
    }

    for directory in sorted(
        (path for path in source.rglob("*") if path.is_dir()),
        key=lambda path: len(path.parts),
    ):
        (target / directory.relative_to(source)).mkdir(
            parents=True, exist_ok=True
        )

    for relative in sorted(source_files):
        source_file = source / relative
        target_file = target / relative
        target_file.parent.mkdir(parents=True, exist_ok=True)
        os.replace(source_file, target_file)

    for relative in sorted(target_files - source_files):
        stale = target / relative
        if stale.is_file() or stale.is_symlink():
            stale.unlink()


def commit_staging_output(staging_output, output):
    if not output.exists():
        staging_output.replace(output)
        return

    if not output.is_dir():
        fail(f"Output path is not a directory: {output}")

    backup = staging_output.parent / "previous-output"
    if backup.exists():
        shutil.rmtree(backup)
    shutil.copytree(
        output, backup, copy_function=_hardlink_or_copy
    )
    try:
        _sync_files_preserving_directories(staging_output, output)
    except BaseException:
        _sync_files_preserving_directories(backup, output)
        raise
    finally:
        shutil.rmtree(backup, ignore_errors=True)


def assemble_output(template, runtime, pck, output, appid, project_name, orientation, diagnostics=False, lib_version="latest"):
    if output.exists():
        fail(f"Assembly target already exists: {output}")
    shutil.copytree(template, output)
    shutil.copy2(runtime / "godot.js", output / "engine" / "godot.js")
    shutil.copy2(runtime / "godot.wasm.br", output / "engine" / "godot.wasm.br")
    shutil.copy2(runtime / "runtime.json", output / "engine" / "runtime.json")
    (output / "runtime" / "build_config.js").write_text(
        "export const runtimeConfig = {\n"
        f"  diagnostics: {str(bool(diagnostics)).lower()},\n"
        "};\n",
        encoding="utf-8",
    )
    archive = output / "data" / "project.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as handle:
        handle.write(pck, arcname="project.bin")
    write_game_json(output, orientation)
    write_project_config(output, appid, project_name, lib_version=lib_version)


def iter_files(root):
    return sorted(path for path in root.rglob("*") if path.is_file())


def package_sizes(output):
    main = 0
    engine = 0
    data = 0
    for path in iter_files(output):
        rel = path.relative_to(output)
        size = path.stat().st_size
        if rel.parts[0] == "engine":
            engine += size
        elif rel.parts[0] == "data":
            data += size
        else:
            main += size
    return {"main": main, "engine": engine, "data": data, "total": main + engine + data}


def validate_output(output, package_limit, allow_oversize=False):
    errors = []
    for path in iter_files(output):
        rel = path.relative_to(output)
        if path.suffix.lower() not in ALLOWED_SUFFIXES:
            errors.append(f"unsupported package extension: {rel}")
        if path.suffix.lower() == ".pck":
            errors.append(f"PCK must not be shipped directly: {rel}")
        if path.suffix.lower() == ".js":
            text = path.read_text(encoding="utf-8", errors="ignore")
            if re.search(r"\beval\s*\(", text):
                errors.append(f"eval() found in {rel}")
            if re.search(r"\bnew\s+Function\b", text):
                errors.append(f"new Function found in {rel}")

    sizes = package_sizes(output)
    if sizes["main"] > MAIN_PACKAGE_LIMIT:
        errors.append(
            f"main package is {sizes['main']} bytes, limit is {MAIN_PACKAGE_LIMIT}"
        )
    if sizes["total"] > package_limit and not allow_oversize:
        errors.append(
            f"total local package is {sizes['total']} bytes, limit is {package_limit}"
        )
    if errors:
        fail("WeChat package validation failed:\n  - " + "\n  - ".join(errors))
    return sizes


def file_manifest(output):
    result = {}
    for path in iter_files(output):
        rel = path.relative_to(output).as_posix()
        if rel == "build-manifest.json":
            continue
        result[rel] = {"size": path.stat().st_size, "sha256": sha256(path)}
    return result


def pck_top_files(path, limit=15):
    rows = []
    with path.open("rb") as handle:
        header = handle.read(40)
        if len(header) < 40:
            return rows
        magic, version, _maj, _min, _patch, flags = struct.unpack("<6I", header[:24])
        if magic != 0x43504447 or version not in (3, 4) or (flags & 1):
            return rows
        _file_base, directory_offset = struct.unpack("<QQ", header[24:40])
        handle.seek(directory_offset)
        count_data = handle.read(4)
        if len(count_data) != 4:
            return rows
        count = struct.unpack("<I", count_data)[0]
        for _ in range(count):
            length = struct.unpack("<I", handle.read(4))[0]
            name = handle.read(length).decode("utf-8", "replace").rstrip("\x00")
            _offset, size = struct.unpack("<QQ", handle.read(16))
            handle.read(16)
            handle.read(4)
            rows.append({"path": name, "size": size})
    return sorted(rows, key=lambda row: row["size"], reverse=True)[:limit]


def write_build_manifest(
    manifest_path, output, project, project_name, appid, godot_version,
    runtime_manifest, sizes, scenes, pck_top, compatibility_report,
    package_limit_mib, package_limit, quick_adapt, config_snapshot
):
    manifest = {
        "format": 3,
        "exporter_version": TOOL_VERSION,
        "project": str(project),
        "project_name": project_name,
        "appid": appid,
        "godot_version": godot_version,
        "release_scenes": scenes,
        "config": config_snapshot,
        "runtime": runtime_manifest,
        "package_sizes": sizes,
        "quick_adapt": quick_adapt,
        "package_limit_mib": package_limit_mib,
        "package_limit_bytes": package_limit,
        "package_headroom_bytes": package_limit - sizes["total"],
        "largest_project_files": pck_top,
        "compatibility": compatibility_report,
        "files": file_manifest(output),
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def mib(value):
    return value / (1024 * 1024)


def print_summary(output, pck_size, sizes, package_limit_mib, package_limit):
    print("\nWeChat Mini Game export complete")
    print(f"  output: {output}")
    print(f"  project.bin: {mib(pck_size):.2f} MiB")
    print(f"  main package: {mib(sizes['main']):.2f} MiB")
    print(f"  engine package: {mib(sizes['engine']):.2f} MiB")
    print(f"  data package: {mib(sizes['data']):.2f} MiB")
    print(f"  total local package: {mib(sizes['total']):.2f} MiB")
    print(f"  configured upload limit: {package_limit_mib} MiB")
    headroom = package_limit - sizes["total"]
    if headroom >= 0:
        print(f"  package headroom: {mib(headroom):.2f} MiB")
    if 0 <= headroom < PACKAGE_HEADROOM_CRITICAL:
        print(f"  CRITICAL: less than {mib(PACKAGE_HEADROOM_CRITICAL):.0f} MiB upload headroom remains")
    elif 0 <= headroom < PACKAGE_HEADROOM_WARNING:
        print(f"  WARNING: less than {mib(PACKAGE_HEADROOM_WARNING):.0f} MiB upload headroom remains")


def main():
    global JSON_EVENTS, CANCEL_FILE
    args = parse_args()
    JSON_EVENTS = bool(args.json_events)
    CANCEL_FILE = args.cancel_file.resolve() if args.cancel_file else None
    project = args.project.resolve()
    output = (args.output or (project / "build" / "wechat")).resolve()
    if not args.doctor:
        output = validate_output_path(project, output)
    runtime = args.runtime.resolve()
    template = args.template.resolve()
    manifest_path = output.parent / f"{output.name}-build-manifest.json"

    project_file = validate_project(project)
    runtime_manifest = validate_runtime(runtime)
    godot = resolve_godot_binary(args.godot)
    godot_version = validate_godot(godot)
    config, config_path = load_config(project, args.config)
    project_name = args.project_name or config.get("project_name") or parse_project_name(project_file)
    appid = args.appid or config.get("appid") or os.environ.get("WX_APPID") or "touristappid"
    orientation = args.orientation or config.get("orientation") or "portrait"
    lib_version = args.lib_version or config.get("lib_version") or "latest"
    quick_adapt = config.get("quick_adapt", False)
    if not isinstance(quick_adapt, bool):
        fail(f"quick_adapt must be a boolean; got {quick_adapt!r}")
    package_limit_mib = resolve_package_limit_mib(
        args.package_limit_mib, quick_adapt=quick_adapt
    )
    package_limit = package_limit_mib * 1024 * 1024
    scenes = normalize_scenes(args.scene or config.get("release_scenes") or [])
    exclude_patterns = [str(item) for item in (config.get("exclude_patterns") or [])]
    strip_autoloads = [str(item) for item in (config.get("strip_autoloads") or [])]
    prepare_mobile_textures = bool(config.get("prepare_mobile_textures", True))
    diagnostics = bool(args.diagnostics or config.get("diagnostics", False))
    config_snapshot = {
        "project_name": project_name,
        "appid": appid,
        "quick_adapt": quick_adapt,
        "package_limit_mib": package_limit_mib,
        "orientation": orientation,
        "lib_version": lib_version,
        "prepare_mobile_textures": prepare_mobile_textures,
        "diagnostics": diagnostics,
        "exclude_patterns": exclude_patterns,
        "strip_autoloads": strip_autoloads,
        "release_scenes": scenes,
    }
    emit_event(
        "config", appid=appid, project_name=project_name,
        quick_adapt=quick_adapt, package_limit_mib=package_limit_mib,
        output=str(output),
    )
    compatibility_report = scan_project_compatibility(
        project, project_file, exclude_patterns, strip_autoloads=strip_autoloads
    )
    emit_event("compatibility", **compatibility_report)
    if not args.skip_compat_check:
        print_compatibility_report(compatibility_report)
        if compatibility_report["errors"]:
            fail("Project is outside the supported runtime profile.")
    if args.doctor:
        emit_event(
            "complete", mode="doctor",
            errors=len(compatibility_report["errors"]),
            warnings=len(compatibility_report["warnings"]),
        )
        return
    for scene in scenes:
        scene_path = project / scene.removeprefix("res://")
        if not scene_path.is_file():
            fail(f"Release scene does not exist: {scene}")
    if config_path.exists():
        print(f"Using WeChat export config: {config_path}")

    temp_root = Path(tempfile.mkdtemp(prefix="wx-godot-export-"))
    try:
        pck = temp_root / "project.pck"
        with temporary_project_settings(
            project_file,
            mobile_textures=prepare_mobile_textures,
            strip_autoloads=strip_autoloads,
        ):
            if prepare_mobile_textures and not args.skip_import:
                emit_event("phase", name="import")
                import_project_resources(project, godot)
            emit_event("phase", name="export_pack")
            export_pack(
                project, godot, args.preset, pck,
                scenes=scenes, exclude_patterns=exclude_patterns,
            )
        pck_top = pck_top_files(pck)
        emit_event("phase", name="assemble")
        output.parent.mkdir(parents=True, exist_ok=True)
        staging_root = Path(tempfile.mkdtemp(
            prefix=f".{output.name}-staging-", dir=output.parent
        ))
        staging_output = staging_root / output.name
        try:
            assemble_output(
                template, runtime, pck, staging_output,
                appid, project_name, orientation,
                diagnostics=diagnostics, lib_version=lib_version,
            )
            sizes = validate_output(
                staging_output, package_limit,
                allow_oversize=args.allow_oversize,
            )
            check_cancelled()
            commit_staging_output(staging_output, output)
        finally:
            shutil.rmtree(staging_root, ignore_errors=True)

        write_build_manifest(
            manifest_path, output, project, project_name, appid, godot_version,
            runtime_manifest, sizes, scenes, pck_top, compatibility_report,
            package_limit_mib, package_limit, quick_adapt, config_snapshot,
        )
        print_summary(
            output, pck.stat().st_size, sizes, package_limit_mib, package_limit
        )
        emit_event(
            "complete", mode="build", output=str(output),
            package_sizes=sizes, package_limit_mib=package_limit_mib,
            package_headroom_bytes=package_limit - sizes["total"],
            quick_adapt=quick_adapt,
        )
        if pck_top:
            print("  largest project files:")
            for row in pck_top[:8]:
                print(f"    {mib(row['size']):6.2f} MiB  {row['path']}")
    finally:
        if args.keep_temp:
            print(f"temporary export retained at: {temp_root}")
        else:
            shutil.rmtree(temp_root, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except ExportCancelled as error:
        emit_event("cancelled", message=str(error))
        print(f"CANCELLED: {error}", file=sys.stderr)
        sys.exit(130)
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        emit_event("error", message=str(error))
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
    finally:
        if CANCEL_FILE is not None and CANCEL_FILE.exists():
            CANCEL_FILE.unlink(missing_ok=True)
