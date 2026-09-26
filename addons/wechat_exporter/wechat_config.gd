@tool
class_name WechatExportConfig
extends RefCounted

const CONFIG_PATH := "res://wechat_export.json"
const DEFAULT_EXCLUDES: Array[String] = []
static func defaults() -> Dictionary:
    return {
        "project_name": str(ProjectSettings.get_setting(
            "application/config/name", "Godot Project")),
        "appid": "touristappid",
        "quick_adapt": false,
        "orientation": "portrait",
        "lib_version": "latest",
        "prepare_mobile_textures": true,
        "diagnostics": false,
        "exclude_patterns": DEFAULT_EXCLUDES.duplicate(),
        "strip_autoloads": [],
    }


static func load_config() -> Dictionary:
    var result := defaults()
    if not FileAccess.file_exists(CONFIG_PATH):
        return result

    var text := FileAccess.get_file_as_string(CONFIG_PATH)
    var parser := JSON.new()
    var parse_error := parser.parse(text)
    if parse_error != OK:
        result["_load_error"] = (
            "wechat_export.json JSON 错误（第 %d 行）：%s"
            % [parser.get_error_line() + 1, parser.get_error_message()]
        )
        return result
    var parsed: Variant = parser.data
    if not (parsed is Dictionary):
        result["_load_error"] = "wechat_export.json 不是有效 JSON object"
        return result

    var loaded: Dictionary = parsed
    for key: Variant in loaded.keys():
        result[key] = loaded[key]

    if not loaded.has("quick_adapt"):
        var legacy_limit := int(loaded.get("package_limit_mib", 20))
        result["quick_adapt"] = legacy_limit >= 30
    result.erase("package_limit_mib")
    return result


static func save_config(config: Dictionary) -> Error:
    var output := config.duplicate(true)
    output.erase("_load_error")
    output.erase("package_limit_mib")

    var file := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
    if file == null:
        return FileAccess.get_open_error()
    file.store_string(JSON.stringify(output, "  ", false) + "\n")
    file.close()
    return OK


static func effective_package_limit_mib(config: Dictionary) -> int:
    return 30 if bool(config.get("quick_adapt", false)) else 20


static func validate_appid(appid: String) -> String:
    var value := appid.strip_edges()
    if value == "touristappid":
        return ""
    var regex := RegEx.new()
    if regex.compile("^wx[0-9A-Fa-f]{16}$") != OK:
        return "AppID 校验器初始化失败"
    if regex.search(value) == null:
        return "AppID 应为 wx + 16 位十六进制字符"
    return ""
