@tool
extends EditorPlugin

const TOOL_MENU_LABEL := "微信小游戏..."
const ExportWindow = preload(
    "res://addons/wechat_exporter/wechat_export_window.gd")
const UpdateManager = preload(
    "res://addons/wechat_exporter/wechat_update_manager.gd")

var _window: Window
var _update_manager: Node


func _enter_tree() -> void:
    _update_manager = UpdateManager.new()
    add_child(_update_manager)
    _update_manager.setup(get_editor_interface())
    _update_manager.call_deferred("auto_check_if_due")
    add_tool_menu_item(TOOL_MENU_LABEL, Callable(self, "_show_window"))


func _exit_tree() -> void:
    remove_tool_menu_item(TOOL_MENU_LABEL)
    if _window != null:
        if _window.has_method("shutdown"):
            _window.shutdown()
        if _window.get_parent() != null:
            _window.get_parent().remove_child(_window)
        _window.queue_free()
        _window = null
    if _update_manager != null:
        _update_manager.queue_free()
        _update_manager = null


func _show_window() -> void:
    if _window == null:
        _create_window()
    if _window == null:
        return
    if _window.visible:
        _window.grab_focus()
    else:
        _window.popup_centered()


func _create_window() -> void:
    _window = ExportWindow.new()
    _window.name = "WechatExportWindow"
    _window.title = "微信小游戏发布"
    _window.size = Vector2i(1200, 800)
    _window.min_size = Vector2i(700, 520)
    _window.transient = true
    _window.exclusive = false
    _window.wrap_controls = false
    _window.close_requested.connect(_window.hide)
    get_editor_interface().get_base_control().add_child(_window)
    _window.setup(get_editor_interface(), _update_manager)
