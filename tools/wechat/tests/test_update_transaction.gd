extends SceneTree

const UpdateManager = preload(
    "res://addons/wechat_exporter/wechat_update_manager.gd"
)

var failures: Array[String] = []


func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures.append(message)


func _read_version(path: String) -> String:
    if not FileAccess.file_exists(path):
        return ""
    var parsed: Variant = JSON.parse_string(
        FileAccess.get_file_as_string(path))
    if not (parsed is Dictionary):
        return ""
    return str(parsed.get("plugin_version", ""))


func _init() -> void:
    call_deferred("_run")
func _run() -> void:
    var fixture := OS.get_environment("WX_UPDATE_FIXTURE")
    _expect(not fixture.is_empty(), "WX_UPDATE_FIXTURE is required")

    var updater := UpdateManager.new()
    root.add_child(updater)
    updater.setup(null)
    var original := updater.current_version()

    updater.check_for_updates(fixture)
    _expect(updater.state == "available", "signed update must be available")

    updater.download_update()
    _expect(updater.state == "downloaded", "fixture package must verify")

    var install_error: int = int(
        updater.install_downloaded_update(false))
    _expect(install_error == OK, "fixture install must succeed")
    _expect(
        _read_version("res://addons/wechat_exporter/release.json")
        == "99.0.0",
        "candidate version must become current",
    )
    var backup := ProjectSettings.globalize_path(
        "res://addons/.wechat_exporter_backup/release.json")
    _expect(FileAccess.file_exists(backup), "previous version must be backed up")
    _expect(
        _read_version(backup) == original,
        "backup version must match the original plugin",
    )
    _expect(updater.has_rollback(), "rollback must be available")

    var rollback_error: int = int(updater.rollback_previous(false))
    _expect(rollback_error == OK, "rollback must succeed")
    _expect(
        _read_version("res://addons/wechat_exporter/release.json")
        == original,
        "rollback must restore original version",
    )
    _expect(not updater.has_rollback(), "backup must be consumed after rollback")

    updater.queue_free()
    if failures.is_empty():
        print("UPDATE_TRANSACTION_TESTS_OK")
        quit(0)
        return
    for failure: String in failures:
        push_error(failure)
    quit(1)
