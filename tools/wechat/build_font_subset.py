#!/usr/bin/env python3
import argparse
from pathlib import Path
import sys

TEXT_SUFFIXES = {
    ".gd", ".tscn", ".tres", ".godot", ".cfg", ".json",
    ".md", ".txt", ".csv",
}


def parse_args():
    parser = argparse.ArgumentParser(description="Build a release font subset from project text.")
    parser.add_argument("--font", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scan", type=Path, action="append", required=True)
    return parser.parse_args()


def text_files(path):
    if path.is_file():
        yield path
        return
    for item in path.rglob("*"):
        if item.is_file() and item.suffix.lower() in TEXT_SUFFIXES:
            yield item


def collect_codepoints(paths):
    codepoints = set(range(0x20, 0x100))
    codepoints.update({0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026, 0xFFFD})
    scanned = 0
    for root in paths:
        for path in text_files(root):
            scanned += 1
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            codepoints.update(ord(char) for char in text if ord(char) >= 0x20)
    return codepoints, scanned


def main():
    args = parse_args()
    try:
        from fontTools import subset
    except ImportError:
        print("ERROR: FontTools is required: python -m pip install fonttools", file=sys.stderr)
        return 1

    font_path = args.font.resolve()
    output = args.output.resolve()
    scan_paths = [path.resolve() for path in args.scan]
    codepoints, scanned = collect_codepoints(scan_paths)

    options = subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6]
    options.name_legacy = True
    options.name_languages = [0x409]
    font = subset.load_font(str(font_path), options, lazy=False)
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=sorted(codepoints))
    subsetter.subset(font)
    output.parent.mkdir(parents=True, exist_ok=True)
    subset.save_font(font, str(output), options)
    original_size = font_path.stat().st_size
    subset_size = output.stat().st_size
    print(f"scanned files: {scanned}")
    print(f"requested codepoints: {len(codepoints)}")
    print(f"original font: {original_size} bytes")
    print(f"subset font: {subset_size} bytes")
    print(f"reduction: {(1.0 - subset_size / original_size) * 100:.1f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
