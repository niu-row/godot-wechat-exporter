@tool
class_name WechatCLI
extends RefCounted

const EDITOR_SETTING := "wechat_exporter/wechat_cli_path"
const MAC_APP := "/Applications/wechatwebdevtools.app"
const MAC_CLI := (
    "/Applications/wechatwebdevtools.app/Contents/MacOS/cli")


static func resolve_cli(editor_interface: EditorInterface) -> String:
    if editor_interface != null:
        var settings := editor_interface.get_editor_settings()
        if settings != null and settings.has_setting(EDITOR_SETTING):
            var configured := str(settings.get_setting(EDITOR_SETTING))
            if not configured.is_empty() and FileAccess.file_exists(configured):
                return configured
    return auto_detect_cli()


static func auto_detect_cli() -> String:
    if OS.get_name() == "macOS" and FileAccess.file_exists(MAC_CLI):
        return MAC_CLI
    return ""


static func save_cli_path(
        editor_interface: EditorInterface, path: String) -> void:
    if editor_interface == null:
        return
    var settings := editor_interface.get_editor_settings()
    if settings == null:
        return
    settings.set_setting(EDITOR_SETTING, path.strip_edges())
    settings.mark_setting_changed(EDITOR_SETTING)


static func open_devtools() -> Error:
    if OS.get_name() != "macOS" or not FileAccess.file_exists(MAC_CLI):
        return ERR_UNAVAILABLE
    var pid := OS.create_process(
        "/usr/bin/open", PackedStringArray([MAC_APP]))
    return OK if pid > 0 else ERR_CANT_FORK


static func service_port_hint() -> String:
    return "微信开发者工具 → 设置 → 安全设置 → 服务端口：开启"


static func user_home() -> String:
    if OS.get_name() == "macOS":
        var documents := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
        if not documents.is_empty():
            return documents.get_base_dir()
    return OS.get_environment("HOME")


static func wrap_command(
        cli_path: String, arguments: PackedStringArray) -> Dictionary:
    if OS.get_name() != "macOS":
        return {"path": cli_path, "arguments": arguments}

    var home := user_home()
    if home.is_empty():
        return {"path": cli_path, "arguments": arguments}

    var wrapped := PackedStringArray(["HOME=" + home, cli_path])
    for argument: String in arguments:
        wrapped.append(argument)
    return {
        "path": "/usr/bin/env",
        "arguments": wrapped,
    }
