@tool
class_name WechatUpdateManager
extends Node

signal state_changed
signal update_available(version: String)
signal update_installed(version: String)

const RELEASE_PATH := "res://addons/wechat_exporter/release.json"
const PUBLIC_KEY_PATH := "res://addons/wechat_exporter/release_public.pem"
const SOURCE_SETTING := "wechat_exporter/update_manifest_url"
const AUTO_CHECK_SETTING := "wechat_exporter/auto_check_updates"
const LAST_CHECK_SETTING := "wechat_exporter/last_update_check_unix"
const CHECK_INTERVAL_SECONDS := 24 * 60 * 60
const PLUGIN_PATH := "res://addons/wechat_exporter"
const MAX_EXTRACT_BYTES := 128 * 1024 * 1024

var _editor_interface: EditorInterface
var _request: HTTPRequest
var _request_stage := ""
var _source := ""
var _manifest_bytes := PackedByteArray()
var _remote_manifest: Dictionary = {}
var _downloaded_package := ""

var state := "idle"
var message := "尚未检查更新"


func setup(editor_interface: EditorInterface) -> void:
    _editor_interface = editor_interface
    _request = HTTPRequest.new()
    _request.request_completed.connect(_on_request_completed)
    add_child(_request)
func current_release() -> Dictionary:
    if not FileAccess.file_exists(RELEASE_PATH):
        return {}
    var parsed: Variant = JSON.parse_string(
        FileAccess.get_file_as_string(RELEASE_PATH))
    return parsed if parsed is Dictionary else {}


func current_version() -> String:
    return str(current_release().get("plugin_version", "0.0.0"))


func update_source() -> String:
    var settings := _editor_settings()
    if settings != null and settings.has_setting(SOURCE_SETTING):
        return str(settings.get_setting(SOURCE_SETTING)).strip_edges()
    return str(
        current_release().get("default_update_manifest", "")
    ).strip_edges()


func set_update_source(value: String) -> void:
    var settings := _editor_settings()
    if settings == null:
        return
    settings.set_setting(SOURCE_SETTING, value.strip_edges())
    settings.mark_setting_changed(SOURCE_SETTING)


func auto_check_enabled() -> bool:
    var settings := _editor_settings()
    if settings == null or not settings.has_setting(AUTO_CHECK_SETTING):
        return true
    return bool(settings.get_setting(AUTO_CHECK_SETTING))
func set_auto_check_enabled(enabled: bool) -> void:
    var settings := _editor_settings()
    if settings == null:
        return
    settings.set_setting(AUTO_CHECK_SETTING, enabled)
    settings.mark_setting_changed(AUTO_CHECK_SETTING)


func auto_check_if_due() -> void:
    if not auto_check_enabled():
        return
    var source := update_source()
    if source.is_empty():
        return
    var settings := _editor_settings()
    if settings == null:
        return
    var now := int(Time.get_unix_time_from_system())
    var last := 0
    if settings.has_setting(LAST_CHECK_SETTING):
        last = int(settings.get_setting(LAST_CHECK_SETTING))
    if now - last < CHECK_INTERVAL_SECONDS:
        return
    check_for_updates()


func check_for_updates(source_override: String = "") -> void:
    if _request_stage != "":
        return
    _source = source_override.strip_edges()
    if _source.is_empty():
        _source = update_source()
    if _source.is_empty():
        _set_state("not_configured", "未配置自动更新源")
        return
    _record_check_time()
    _set_state("checking", "正在检查更新...")
    if _is_local_source(_source):
        _check_local_manifest(_source)
    else:
        _request_stage = "manifest"
        _start_http_request(_source)
func download_update() -> void:
    if state != "available" or _remote_manifest.is_empty():
        return
    var package: Dictionary = _remote_manifest.get("package", {})
    var package_url := str(package.get("url", "")).strip_edges()
    if package_url.is_empty():
        _set_state("error", "更新 manifest 缺少 package.url")
        return
    var resolved := _resolve_relative_source(_source, package_url)
    if _is_local_source(resolved):
        var local_path := _local_path(resolved)
        if not FileAccess.file_exists(local_path):
            _set_state("error", "更新包不存在：" + local_path)
            return
        _downloaded_package = local_path
        _verify_downloaded_package()
        return

    var update_dir := ProjectSettings.globalize_path(
        "user://wechat_exporter/updates")
    var error := DirAccess.make_dir_recursive_absolute(update_dir)
    if error != OK:
        _set_state("error", "创建更新缓存目录失败")
        return
    var version := str(_remote_manifest.get("version", "update"))
    _downloaded_package = update_dir.path_join(
        "godot-wechat-exporter-%s.zip" % version)
    _request.download_file = _downloaded_package
    _request_stage = "package"
    _set_state("downloading", "正在下载更新 %s..." % version)
    _start_http_request(resolved)
func install_downloaded_update(restart_editor: bool = true) -> Error:
    if state != "downloaded" or _downloaded_package.is_empty():
        return ERR_UNAVAILABLE
    var expected_version := str(_remote_manifest.get("version", ""))
    var staging := ProjectSettings.globalize_path(
        "res://addons/.wechat_exporter_staging")
    var backup := ProjectSettings.globalize_path(
        "res://addons/.wechat_exporter_backup")
    var current := ProjectSettings.globalize_path(PLUGIN_PATH)

    _remove_tree(staging)
    var extract_error := _extract_package(_downloaded_package, staging)
    if extract_error != OK:
        _remove_tree(staging)
        return extract_error
    var release_path := staging.path_join("release.json")
    var candidate := _read_json_file(release_path)
    if str(candidate.get("plugin_version", "")) != expected_version:
        _set_state("error", "更新包版本与 manifest 不一致")
        _remove_tree(staging)
        return ERR_FILE_CORRUPT
    if not FileAccess.file_exists(staging.path_join("plugin.cfg")):
        _set_state("error", "更新包缺少 plugin.cfg")
        _remove_tree(staging)
        return ERR_FILE_CORRUPT

    var previous_version := current_version()
    _remove_tree(backup)
    var error := DirAccess.rename_absolute(current, backup)
    if error != OK:
        _set_state("error", "备份当前插件失败：%s" % error_string(error))
        _remove_tree(staging)
        return error
    error = DirAccess.rename_absolute(staging, current)
    if error != OK:
        DirAccess.rename_absolute(backup, current)
        _set_state("error", "安装新插件失败，已恢复当前版本")
        return error

    _write_install_marker(previous_version, expected_version)
    _set_state("installed", "已安装 %s，等待重启编辑器" % expected_version)
    update_installed.emit(expected_version)
    if restart_editor and _editor_interface != null:
        _editor_interface.restart_editor(true)
    return OK


func rollback_previous(restart_editor: bool = true) -> Error:
    var current := ProjectSettings.globalize_path(PLUGIN_PATH)
    var backup := ProjectSettings.globalize_path(
        "res://addons/.wechat_exporter_backup")
    var failed := ProjectSettings.globalize_path(
        "res://addons/.wechat_exporter_failed")
    if not DirAccess.dir_exists_absolute(backup):
        _set_state("error", "没有可回滚的上一版本")
        return ERR_DOES_NOT_EXIST
    _remove_tree(failed)
    var error := DirAccess.rename_absolute(current, failed)
    if error != OK:
        return error
    error = DirAccess.rename_absolute(backup, current)
    if error != OK:
        DirAccess.rename_absolute(failed, current)
        return error
    _remove_tree(failed)
    _set_state("installed", "已恢复上一版本，等待重启编辑器")
    if restart_editor and _editor_interface != null:
        _editor_interface.restart_editor(true)
    return OK


func has_rollback() -> bool:
    return DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(
        "res://addons/.wechat_exporter_backup"))
func snapshot() -> Dictionary:
    return {
        "state": state,
        "message": message,
        "current_version": current_version(),
        "remote_version": str(_remote_manifest.get("version", "")),
        "source": update_source(),
        "auto_check": auto_check_enabled(),
        "downloaded_package": _downloaded_package,
        "has_rollback": has_rollback(),
    }


func _check_local_manifest(source: String) -> void:
    var path := _local_path(source)
    var sig_path := path + ".sig"
    if not FileAccess.file_exists(path) or not FileAccess.file_exists(sig_path):
        _set_state("error", "本地更新 manifest 或签名不存在")
        return
    _manifest_bytes = FileAccess.get_file_as_bytes(path)
    var signature := FileAccess.get_file_as_bytes(sig_path)
    _accept_verified_manifest(_manifest_bytes, signature)


func _start_http_request(url: String) -> void:
    if not _request.is_inside_tree():
        call_deferred("_start_http_request", url)
        return
    _request.download_file = (
        _downloaded_package if _request_stage == "package" else "")
    var error := _request.request(url)
    if error != OK:
        _request_stage = ""
        _set_state("error", "启动更新请求失败：%s" % error_string(error))


func _on_request_completed(
        result: int, response_code: int, _headers: PackedStringArray,
        body: PackedByteArray) -> void:
    var stage := _request_stage
    _request_stage = ""
    if result != HTTPRequest.RESULT_SUCCESS or response_code < 200             or response_code >= 300:
        _request.download_file = ""
        _set_state("error", "更新请求失败：HTTP %d" % response_code)
        return
    if stage == "manifest":
        _manifest_bytes = body
        _request_stage = "signature"
        _start_http_request(_source + ".sig")
        return
    if stage == "signature":
        _accept_verified_manifest(_manifest_bytes, body)
        return
    if stage == "package":
        _request.download_file = ""
        _verify_downloaded_package()


func _accept_verified_manifest(
        manifest_bytes: PackedByteArray,
        signature: PackedByteArray) -> void:
    if not _verify_signature(manifest_bytes, signature):
        _set_state("error", "更新 manifest 签名验证失败")
        return
    var text := manifest_bytes.get_string_from_utf8()
    var parsed: Variant = JSON.parse_string(text)
    if not (parsed is Dictionary):
        _set_state("error", "更新 manifest 不是有效 JSON object")
        return
    var manifest: Dictionary = parsed
    if int(manifest.get("schema", 0)) != 1:
        _set_state("error", "不支持的更新 manifest schema")
        return
    var compatibility_error := _validate_compatibility(manifest)
    if not compatibility_error.is_empty():
        _set_state("incompatible", compatibility_error)
        return
    _remote_manifest = manifest
    var remote_version := str(manifest.get("version", "0.0.0"))
    if _compare_versions(remote_version, current_version()) <= 0:
        _set_state("up_to_date", "当前已是最新版本 %s" % current_version())
        return
    _set_state("available", "发现新版本 %s" % remote_version)
    update_available.emit(remote_version)
func current_godot_compatibility_error() -> String:
    var release := current_release()
    var godot: Dictionary = release.get("godot", {})
    return _validate_godot_requirement(godot)


func _validate_compatibility(manifest: Dictionary) -> String:
    var godot: Dictionary = manifest.get("godot", {})
    return _validate_godot_requirement(godot)


func _validate_godot_requirement(godot: Dictionary) -> String:
    var required_version := str(godot.get("version", ""))
    var required_commit := str(godot.get("commit", ""))
    var info := Engine.get_version_info()
    var current := "%d.%d.%d" % [
        int(info.get("major", 0)),
        int(info.get("minor", 0)),
        int(info.get("patch", 0)),
    ]
    if not required_version.is_empty() and current != required_version:
        return "更新仅支持 Godot %s；当前为 %s" % [
            required_version, current]
    var hash := str(info.get("hash", ""))
    if not required_commit.is_empty() and not hash.begins_with(required_commit):
        return "Godot 4.7.2 commit 不匹配更新要求"
    return ""


func _verify_signature(
        content: PackedByteArray, signature: PackedByteArray) -> bool:
    if signature.is_empty() or not FileAccess.file_exists(PUBLIC_KEY_PATH):
        return false
    var key := CryptoKey.new()
    var pem := FileAccess.get_file_as_string(PUBLIC_KEY_PATH)
    if key.load_from_string(pem, true) != OK:
        return false
    var hashing := HashingContext.new()
    if hashing.start(HashingContext.HASH_SHA256) != OK:
        return false
    if hashing.update(content) != OK:
        return false
    var digest := hashing.finish()
    return Crypto.new().verify(
        HashingContext.HASH_SHA256, digest, signature, key)
func _verify_downloaded_package() -> void:
    if not FileAccess.file_exists(_downloaded_package):
        _set_state("error", "下载的更新包不存在")
        return
    var package: Dictionary = _remote_manifest.get("package", {})
    var expected_sha := str(package.get("sha256", "")).to_lower()
    var actual_sha := FileAccess.get_sha256(_downloaded_package).to_lower()
    if expected_sha.is_empty() or actual_sha != expected_sha:
        _set_state("error", "更新包 SHA-256 校验失败")
        return
    var expected_size := int(package.get("size", -1))
    var actual_size := FileAccess.get_file_as_bytes(
        _downloaded_package).size()
    if expected_size >= 0 and actual_size != expected_size:
        _set_state("error", "更新包大小校验失败")
        return
    _set_state(
        "downloaded",
        "更新 %s 已下载并校验" % str(_remote_manifest.get("version", "")),
    )


func _extract_package(zip_path: String, staging: String) -> Error:
    var zip := ZIPReader.new()
    var error := zip.open(zip_path)
    if error != OK:
        _set_state("error", "无法打开更新 ZIP")
        return error
    var total := 0
    error = DirAccess.make_dir_recursive_absolute(staging)
    if error != OK:
        zip.close()
        return error
    for entry: String in zip.get_files():
        var normalized := entry.replace("\\", "/")
        var parts := normalized.split("/", false)
        if normalized.begins_with("/") or ".." in parts:
            zip.close()
            _set_state("error", "更新 ZIP 包含不安全路径")
            return ERR_FILE_CORRUPT
        var prefix := "addons/wechat_exporter/"
        if not normalized.begins_with(prefix):
            zip.close()
            _set_state("error", "更新 ZIP 只能写入 addons/wechat_exporter")
            return ERR_FILE_CORRUPT
        var relative := normalized.trim_prefix(prefix)
        if relative.is_empty():
            continue
        var target := staging.path_join(relative)
        if normalized.ends_with("/"):
            error = DirAccess.make_dir_recursive_absolute(target)
            if error != OK:
                zip.close()
                return error
            continue
        var bytes := zip.read_file(entry)
        total += bytes.size()
        if total > MAX_EXTRACT_BYTES:
            zip.close()
            _set_state("error", "更新包解压后大小超过安全限制")
            return ERR_OUT_OF_MEMORY
        error = DirAccess.make_dir_recursive_absolute(target.get_base_dir())
        if error != OK:
            zip.close()
            return error
        var file := FileAccess.open(target, FileAccess.WRITE)
        if file == null:
            zip.close()
            return FileAccess.get_open_error()
        file.store_buffer(bytes)
        file.close()
    zip.close()
    return OK


func _compare_versions(left: String, right: String) -> int:
    var a := left.split("-", true, 1)[0].split(".")
    var b := right.split("-", true, 1)[0].split(".")
    var count := maxi(a.size(), b.size())
    for index: int in range(count):
        var av := int(a[index]) if index < a.size() else 0
        var bv := int(b[index]) if index < b.size() else 0
        if av != bv:
            return 1 if av > bv else -1
    return 0
func _resolve_relative_source(base: String, value: String) -> String:
    if value.begins_with("https://") or value.begins_with("http://")             or _is_local_source(value):
        return value
    if _is_local_source(base):
        return _local_path(base).get_base_dir().path_join(value)
    return base.get_base_dir().path_join(value)


func _is_local_source(value: String) -> bool:
    return (
        value.begins_with("/")
        or value.begins_with("file://")
        or value.begins_with("res://")
        or value.begins_with("user://")
    )


func _local_path(value: String) -> String:
    if value.begins_with("file://"):
        return value.trim_prefix("file://")
    if value.begins_with("res://") or value.begins_with("user://"):
        return ProjectSettings.globalize_path(value)
    return value


func _read_json_file(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {}
    var parsed: Variant = JSON.parse_string(
        FileAccess.get_file_as_string(path))
    return parsed if parsed is Dictionary else {}


func _remove_tree(path: String) -> Error:
    if not DirAccess.dir_exists_absolute(path):
        return OK
    var dir := DirAccess.open(path)
    if dir == null:
        return DirAccess.get_open_error()
    dir.list_dir_begin()
    while true:
        var name := dir.get_next()
        if name.is_empty():
            break
        if name in [".", ".."]:
            continue
        var child := path.path_join(name)
        var error := OK
        if dir.current_is_dir():
            error = _remove_tree(child)
        else:
            error = DirAccess.remove_absolute(child)
        if error != OK:
            dir.list_dir_end()
            return error
    dir.list_dir_end()
    return DirAccess.remove_absolute(path)


func _write_install_marker(
        previous_version: String, installed_version: String) -> void:
    var dir := ProjectSettings.globalize_path("user://wechat_exporter")
    if DirAccess.make_dir_recursive_absolute(dir) != OK:
        return
    var path := dir.path_join("last_update.json")
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string(JSON.stringify({
        "previous_version": previous_version,
        "installed_version": installed_version,
        "installed_at": int(Time.get_unix_time_from_system()),
    }, "  ") + "\n")
    file.close()


func _record_check_time() -> void:
    var settings := _editor_settings()
    if settings == null:
        return
    settings.set_setting(
        LAST_CHECK_SETTING, int(Time.get_unix_time_from_system()))
    settings.mark_setting_changed(LAST_CHECK_SETTING)


func _editor_settings() -> EditorSettings:
    if _editor_interface == null:
        return null
    return _editor_interface.get_editor_settings()


func _set_state(next_state: String, next_message: String) -> void:
    state = next_state
    message = next_message
    state_changed.emit()
