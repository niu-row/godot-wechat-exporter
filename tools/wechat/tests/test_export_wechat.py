import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest

PROJECT_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = (
    PROJECT_ROOT / "addons" / "wechat_exporter" / "toolchain"
    / "export_wechat.py"
)
SPEC = importlib.util.spec_from_file_location("wechat_export", MODULE_PATH)
wx = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wx)


class ExportWechatTests(unittest.TestCase):
    def tearDown(self):
        wx.CANCEL_FILE = None

    def test_package_limit_resolution(self):
        self.assertEqual(wx.resolve_package_limit_mib(None, False), 20)
        self.assertEqual(wx.resolve_package_limit_mib(None, True), 30)
        self.assertEqual(wx.resolve_package_limit_mib(25, True), 25)

    def test_existing_custom_output_is_not_deleted(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            project = root / "game"
            project.mkdir()
            victim = root / "victim"
            victim.mkdir()
            sentinel = victim / "sentinel.txt"
            sentinel.write_text("keep", encoding="utf-8")
            with self.assertRaises(RuntimeError):
                wx.validate_output_path(project, victim)
            self.assertTrue(sentinel.is_file())

            default_output = project / "build" / "wechat"
            default_output.mkdir(parents=True)
            self.assertEqual(
                wx.validate_output_path(project, default_output),
                default_output.resolve(),
            )

    def test_cooperative_cancel_restores_and_kills_group(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            project_file = root / "project.godot"
            original = (
                '[application]\nconfig/name="Probe"\n\n'
                '[autoload]\nProbe="*res://probe.gd"\n'
            )
            project_file.write_text(original, encoding="utf-8")
            cancel = root / "cancel.request"
            child_pid_file = root / "child.pid"
            wx.CANCEL_FILE = cancel
            def request_cancel():
                time.sleep(0.3)
                cancel.write_text("cancel\n", encoding="utf-8")

            threading.Thread(target=request_cancel, daemon=True).start()
            command = [
                "/bin/sh",
                "-c",
                f"sleep 30 & echo $! > {child_pid_file}; wait",
            ]
            with self.assertRaises(wx.ExportCancelled):
                with wx.temporary_project_settings(
                    project_file,
                    mobile_textures=True,
                    strip_autoloads=["Probe"],
                ):
                    wx.run(command)

            self.assertEqual(project_file.read_text(encoding="utf-8"), original)
            child_pid = int(child_pid_file.read_text(encoding="utf-8"))
            time.sleep(0.1)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)

    def test_manifest_is_sidecar(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            output = root / "wechat"
            output.mkdir()
            (output / "game.js").write_text("export {};", encoding="utf-8")
            manifest_path = root / "wechat-build-manifest.json"
            sizes = wx.package_sizes(output)
            snapshot = {
                "appid": "touristappid",
                "quick_adapt": False,
                "package_limit_mib": 20,
            }
            wx.write_build_manifest(
                manifest_path,
                output,
                root,
                "Probe",
                "touristappid",
                "4.7.2.test",
                {"files": {}},
                sizes,
                [],
                [],
                {"errors": [], "warnings": [], "notes": []},
                20,
                20 * 1024 * 1024,
                False,
                snapshot,
            )
            self.assertTrue(manifest_path.is_file())
            self.assertFalse((output / "build-manifest.json").exists())
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(data["format"], 3)
            self.assertEqual(data["appid"], "touristappid")

    def test_commit_preserves_output_directory_inodes(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            output = root / "wechat"
            engine = output / "engine"
            engine.mkdir(parents=True)
            (engine / "godot.js").write_text("old", encoding="utf-8")
            (output / "stale.js").write_text("stale", encoding="utf-8")
            root_inode = output.stat().st_ino
            engine_inode = engine.stat().st_ino

            staging_root = root / "staging"
            staging = staging_root / "wechat"
            (staging / "engine").mkdir(parents=True)
            (staging / "engine" / "godot.js").write_text(
                "new", encoding="utf-8"
            )
            (staging / "game.js").write_text("game", encoding="utf-8")

            wx.commit_staging_output(staging, output)

            self.assertEqual(output.stat().st_ino, root_inode)
            self.assertEqual((output / "engine").stat().st_ino, engine_inode)
            self.assertEqual(
                (output / "engine" / "godot.js").read_text(encoding="utf-8"),
                "new",
            )
            self.assertEqual(
                (output / "game.js").read_text(encoding="utf-8"), "game"
            )
            self.assertFalse((output / "stale.js").exists())

    def test_invalid_json_is_structured_error(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "wechat_export.json").write_text(
                "{ invalid json\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(RuntimeError, "Invalid JSON"):
                wx.load_config(root)


if __name__ == "__main__":
    unittest.main()
