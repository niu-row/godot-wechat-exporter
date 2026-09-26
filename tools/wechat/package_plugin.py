#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile

PROJECT_ROOT = Path(__file__).resolve().parents[2]
ADDON_DIR = PROJECT_ROOT / "addons" / "wechat_exporter"
DEFAULT_DIST = PROJECT_ROOT / "dist" / "wechat_exporter"
RELEASE_FILE = ADDON_DIR / "release.json"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Package the standalone Godot WeChat Exporter addon."
    )
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_DIST)
    parser.add_argument("--base-url", default="")
    parser.add_argument(
        "--private-key",
        type=Path,
        default=Path(os.environ["WECHAT_EXPORTER_SIGNING_KEY"])
        if os.environ.get("WECHAT_EXPORTER_SIGNING_KEY")
        else None,
    )
    return parser.parse_args()
def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def release_metadata():
    data = json.loads(RELEASE_FILE.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise RuntimeError("release.json must be a JSON object")
    return data


def addon_files():
    for path in sorted(ADDON_DIR.rglob("*")):
        if not path.is_file():
            continue
        if path.name in {".DS_Store"} or "__pycache__" in path.parts:
            continue
        yield path


def write_zip(path):
    with zipfile.ZipFile(
        path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as archive:
        for source in addon_files():
            relative = source.relative_to(PROJECT_ROOT).as_posix()
            info = zipfile.ZipInfo(relative)
            info.date_time = (2026, 1, 1, 0, 0, 0)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, source.read_bytes())


def sign_manifest(manifest_path, private_key):
    if private_key is None:
        return None
    private_key = private_key.expanduser().resolve()
    if not private_key.is_file():
        raise RuntimeError(f"Signing key not found: {private_key}")
    signature = manifest_path.with_suffix(manifest_path.suffix + ".sig")
    subprocess.run(
        [
            "openssl", "dgst", "-sha256", "-sign", str(private_key),
            "-out", str(signature), str(manifest_path),
        ],
        check=True,
    )
    return signature


def main():
    args = parse_args()
    release = release_metadata()
    version = str(release["plugin_version"])
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    package_name = f"godot-wechat-exporter-{version}.zip"
    package_path = output_dir / package_name
    write_zip(package_path)

    base_url = args.base_url.rstrip("/")
    package_url = (
        f"{base_url}/{package_name}" if base_url else package_name
    )
    manifest = {
        "schema": 1,
        "channel": "stable",
        "version": version,
        "runtime_id": release["runtime_id"],
        "godot": release["godot"],
        "package": {
            "url": package_url,
            "size": package_path.stat().st_size,
            "sha256": sha256(package_path),
        },
    }
    manifest_path = output_dir / "stable.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    signature = sign_manifest(manifest_path, args.private_key)

    print(f"package: {package_path}")
    print(f"size: {package_path.stat().st_size}")
    print(f"sha256: {manifest['package']['sha256']}")
    print(f"manifest: {manifest_path}")
    if signature:
        print(f"signature: {signature}")


if __name__ == "__main__":
    main()
