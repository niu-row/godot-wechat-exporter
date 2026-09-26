extends SceneTree

const ExportWindow = preload(
    "res://addons/wechat_exporter/wechat_export_window.gd"
)

var failures: Array[String] = []


func _init() -> void:
    call_deferred("_run")


func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures.append(message)


func _run() -> void:
    var window := ExportWindow.new()
    root.add_child(window)
    window.setup(null)

    window.set("_action", "preview")
    window.get("_log").text = "✔ preview\n[error] compile failed\n"
    window.call("_on_process_finished", 0, false)
    _expect(
        "未确认成功" in window.get("_status").text,
        "Preview exit 0 + error marker must not be reported as success",
    )

    window.set("_action", "upload")
    window.get("_log").text = "[error] upload failed\n"
    window.call("_on_process_finished", 0, false)
    _expect(
        "未确认成功" in window.get("_status").text,
        "Upload exit 0 + error marker must not be reported as success",
    )

    window.get("_quick_adapt").button_pressed = true
    var snapshot: Dictionary = window.call("_current_build_config_snapshot")
    _expect(
        int(snapshot.get("package_limit_mib", 0)) == 30,
        "Quick Adapt snapshot must use 30 MiB",
    )

    window.queue_free()
    if failures.is_empty():
        print("EDITOR_WINDOW_TESTS_OK")
        quit(0)
        return
    for failure: String in failures:
        push_error(failure)
    quit(1)
