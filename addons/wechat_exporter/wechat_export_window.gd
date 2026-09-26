@tool
extends Window

const Config = preload("res://addons/wechat_exporter/wechat_config.gd")
const ProcessRunner = preload(
    "res://addons/wechat_exporter/wechat_process_runner.gd")
const WechatTool = preload("res://addons/wechat_exporter/wechat_cli.gd")
const EVENT_PREFIX := "@@WXEVENT@@"
const UI_SCALE_SETTING := "wechat_exporter/ui_scale_percent"
const UI_SCALE_PRESETS := [100, 125, 150, 175, 200]
const DEFAULT_UI_SCALE_PERCENT := 125
const UPLOAD_DIALOG_BASE_SIZE := Vector2i(560, 360)
const UPLOAD_DIALOG_BASE_MIN_SIZE := Vector2i(500, 320)
const BUILD_MANIFEST_PATH := "res://build/wechat-build-manifest.json"
const LEGACY_BUILD_MANIFEST_PATH := "res://build/wechat/build-manifest.json"

var _editor_interface: EditorInterface
var _update_manager: Node
var _runner: RefCounted
var _config: Dictionary = {}
var _loading := false
var _dirty := false
var _action := ""
var _event_buffer := ""
var _pending_after_build := ""
var _cancel_file_path := ""
var _preview_qr_path := ""
var _preview_info_path := ""

var _project_name: LineEdit
var _appid: LineEdit
var _appid_status: Label
var _quick_adapt: CheckBox
var _limit_status: Label
var _orientation: OptionButton
var _lib_version: LineEdit
var _mobile_textures: CheckBox
var _diagnostics: CheckBox
var _exclude_patterns: TextEdit
var _strip_autoloads: TextEdit
var _wechat_cli_path: LineEdit
var _wechat_status: Label
var _upload_version: LineEdit
var _upload_desc: LineEdit

var _status: Label
var _header_project: Label
var _header_meta: Label
var _ui_scale_option: OptionButton
var _ui_scale_percent := DEFAULT_UI_SCALE_PERCENT
var _dashboard_grid: GridContainer
var _dashboard_left: VBoxContainer
var _dashboard_right: VBoxContainer
var _compatibility: Label
var _runtime_status: Label
var _package_progress: ProgressBar
var _package_summary: Label
var _stat_main: Label
var _stat_engine: Label
var _stat_data: Label
var _stat_remaining: Label
var _largest_tree: Tree
var _qr_card: PanelContainer
var _log: TextEdit
var _save_button: Button
var _doctor_button: Button
var _build_button: Button
var _environment_button: Button
var _open_devtools_button: Button
var _preview_button: Button
var _upload_button: Button
var _cancel_button: Button
var _qr_texture: TextureRect
var _qr_status: Label
var _upload_confirm: Window
var _upload_dialog_summary: Label
var _upload_confirm_button: Button
var _upload_cancel_button: Button
var _update_source: LineEdit
var _auto_update_check: CheckBox
var _update_status: Label
var _check_update_button: Button
var _update_action_button: Button
var _rollback_update_button: Button


func setup(
        editor_interface: EditorInterface,
        update_manager: Node = null) -> void:
    if _editor_interface != null:
        return
    _editor_interface = editor_interface
    _update_manager = update_manager
    _runner = ProcessRunner.new()
    _runner.output_received.connect(_on_process_output)
    _runner.finished.connect(_on_process_finished)
    _build_ui()
    _apply_editor_icons()
    _bind_update_manager()
    _load_ui_scale_setting()
    _load_config()
    _refresh_manifest()
    _update_godot_compatibility_status()
    size_changed.connect(_update_responsive_layout)
    _update_responsive_layout()
    set_process(true)


func _process(_delta: float) -> void:
    if _runner != null:
        _runner.poll()


func _load_ui_scale_setting() -> void:
    var percent := DEFAULT_UI_SCALE_PERCENT
    if _editor_interface != null:
        var settings := _editor_interface.get_editor_settings()
        if settings != null and settings.has_setting(UI_SCALE_SETTING):
            percent = int(settings.get_setting(UI_SCALE_SETTING))
    if not UI_SCALE_PRESETS.has(percent):
        percent = DEFAULT_UI_SCALE_PERCENT

    _ui_scale_percent = percent
    for index: int in range(_ui_scale_option.item_count):
        if int(_ui_scale_option.get_item_metadata(index)) == percent:
            _ui_scale_option.select(index)
            break
    _apply_ui_scale(percent, false)


func _on_ui_scale_selected(index: int) -> void:
    var percent := int(_ui_scale_option.get_item_metadata(index))
    _apply_ui_scale(percent, true)


func _apply_ui_scale(percent: int, persist: bool) -> void:
    _ui_scale_percent = clampi(percent, 100, 200)
    if _ui_scale_option != null:
        for index: int in range(_ui_scale_option.item_count):
            if int(_ui_scale_option.get_item_metadata(index)) == _ui_scale_percent:
                _ui_scale_option.select(index)
                break
    var factor := float(_ui_scale_percent) / 100.0

    content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
    content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
    content_scale_factor = factor

    if _upload_confirm != null:
        _upload_confirm.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
        _upload_confirm.content_scale_stretch = (
            Window.CONTENT_SCALE_STRETCH_FRACTIONAL)
        _upload_confirm.content_scale_factor = factor
        _upload_confirm.min_size = _scaled_upload_size(
            UPLOAD_DIALOG_BASE_MIN_SIZE)

    if persist and _editor_interface != null:
        var settings := _editor_interface.get_editor_settings()
        if settings != null:
            settings.set_setting(UI_SCALE_SETTING, _ui_scale_percent)
            settings.mark_setting_changed(UI_SCALE_SETTING)

    call_deferred("_update_responsive_layout")


func _scaled_upload_size(base_size: Vector2i) -> Vector2i:
    var factor := float(_ui_scale_percent) / 100.0
    return Vector2i(
        ceili(float(base_size.x) * factor),
        ceili(float(base_size.y) * factor),
    )


func _build_ui() -> void:
    var shell := MarginContainer.new()
    shell.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    shell.add_theme_constant_override("margin_left", 18)
    shell.add_theme_constant_override("margin_top", 16)
    shell.add_theme_constant_override("margin_right", 18)
    shell.add_theme_constant_override("margin_bottom", 16)
    add_child(shell)

    var root := VBoxContainer.new()
    root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    root.size_flags_vertical = Control.SIZE_EXPAND_FILL
    root.add_theme_constant_override("separation", 12)
    shell.add_child(root)

    _build_header(root)

    var tabs := TabContainer.new()
    tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
    tabs.get_tab_bar().add_theme_font_size_override("font_size", 17)
    root.add_child(tabs)

    _build_dashboard_tab(tabs)
    _build_project_tab(tabs)
    _build_advanced_tab(tabs)
    _build_log_tab(tabs)
    _build_upload_dialog()
    _connect_config_signals()
func _build_header(root: VBoxContainer) -> void:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 16)
    root.add_child(row)

    var left := VBoxContainer.new()
    left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(left)

    var title_label := Label.new()
    title_label.text = "微信小游戏"
    title_label.add_theme_font_size_override("font_size", 28)
    left.add_child(title_label)

    _header_project = Label.new()
    _header_project.text = "Godot Project"
    _header_project.add_theme_font_size_override("font_size", 17)
    left.add_child(_header_project)

    var header_right := HBoxContainer.new()
    header_right.size_flags_horizontal = Control.SIZE_SHRINK_END
    header_right.alignment = BoxContainer.ALIGNMENT_END
    header_right.add_theme_constant_override("separation", 8)
    row.add_child(header_right)

    _header_meta = Label.new()
    _header_meta.custom_minimum_size = Vector2(260, 0)
    _header_meta.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    _header_meta.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _header_meta.add_theme_font_size_override("font_size", 17)
    _header_meta.autowrap_mode = TextServer.AUTOWRAP_OFF
    _header_meta.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    header_right.add_child(_header_meta)

    var scale_label := Label.new()
    scale_label.text = "缩放"
    scale_label.add_theme_font_size_override("font_size", 17)
    header_right.add_child(scale_label)

    _ui_scale_option = OptionButton.new()
    _ui_scale_option.custom_minimum_size = Vector2(96, 0)
    _ui_scale_option.add_theme_font_size_override("font_size", 17)
    for percent: int in UI_SCALE_PRESETS:
        _ui_scale_option.add_item("%d%%" % percent)
        _ui_scale_option.set_item_metadata(
            _ui_scale_option.item_count - 1, percent)
    _ui_scale_option.item_selected.connect(_on_ui_scale_selected)
    _ui_scale_option.tooltip_text = "仅调整微信发布窗口的界面缩放"
    header_right.add_child(_ui_scale_option)

    _status = Label.new()
    _status.text = "● 就绪"
    _status.add_theme_font_size_override("font_size", 17)
    _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    root.add_child(_status)


func _build_dashboard_tab(tabs: TabContainer) -> void:
    var page := _make_scroll_tab(tabs, "发布")
    _dashboard_grid = GridContainer.new()
    _dashboard_grid.columns = 2
    _dashboard_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _dashboard_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _dashboard_grid.add_theme_constant_override("h_separation", 12)
    _dashboard_grid.add_theme_constant_override("v_separation", 12)
    page.add_child(_dashboard_grid)

    _dashboard_left = VBoxContainer.new()
    _dashboard_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _dashboard_left.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _dashboard_left.add_theme_constant_override("separation", 12)
    _dashboard_grid.add_child(_dashboard_left)

    _dashboard_right = VBoxContainer.new()
    _dashboard_right.custom_minimum_size = Vector2(280, 0)
    _dashboard_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _dashboard_right.add_theme_constant_override("separation", 12)
    _dashboard_grid.add_child(_dashboard_right)

    _build_status_card(_dashboard_left)
    _build_package_card(_dashboard_left)
    _build_largest_resources_card(_dashboard_left)
    _build_action_card(_dashboard_right)
    _build_qr_card(_dashboard_right)


func _update_responsive_layout() -> void:
    if (
        _dashboard_grid == null
        or _dashboard_left == null
        or _dashboard_right == null
    ):
        return
    var logical_width := get_visible_rect().size.x
    var compact := logical_width < 900.0
    var very_narrow := logical_width < 620.0
    _dashboard_grid.columns = 1 if compact else 2
    _dashboard_right.custom_minimum_size = Vector2(0 if compact else 280, 0)
    _header_meta.visible = not very_narrow
    _header_meta.custom_minimum_size = Vector2(
        180 if compact else 260, 0)

    if compact:
        if _dashboard_right.get_index() != 0:
            _dashboard_grid.move_child(_dashboard_right, 0)
    elif _dashboard_left.get_index() != 0:
        _dashboard_grid.move_child(_dashboard_left, 0)
func _build_status_card(parent: VBoxContainer) -> void:
    var card := _make_card(parent, "发布状态")
    var body := card["body"] as VBoxContainer

    _compatibility = Label.new()
    _compatibility.text = "○ 兼容性尚未检查"
    _compatibility.add_theme_font_size_override("font_size", 17)
    body.add_child(_compatibility)

    _runtime_status = Label.new()
    _runtime_status.text = "○ Runtime 等待构建信息"
    _runtime_status.add_theme_font_size_override("font_size", 17)
    body.add_child(_runtime_status)

    _wechat_status = Label.new()
    _wechat_status.text = "○ 微信环境尚未检查"
    _wechat_status.add_theme_font_size_override("font_size", 17)
    _wechat_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    body.add_child(_wechat_status)

    _appid_status = Label.new()
    _appid_status.add_theme_font_size_override("font_size", 17)
    body.add_child(_appid_status)

    _limit_status = Label.new()
    _limit_status.add_theme_font_size_override("font_size", 17)
    body.add_child(_limit_status)


func _build_package_card(parent: VBoxContainer) -> void:
    var card := _make_card(parent, "包体")
    var body := card["body"] as VBoxContainer

    _package_summary = Label.new()
    _package_summary.text = "暂无构建"
    _package_summary.add_theme_font_size_override("font_size", 24)
    body.add_child(_package_summary)

    _package_progress = ProgressBar.new()
    _package_progress.min_value = 0.0
    _package_progress.max_value = 30.0
    _package_progress.show_percentage = false
    _package_progress.custom_minimum_size = Vector2(0, 18)
    body.add_child(_package_progress)

    var stats := GridContainer.new()
    stats.columns = 4
    stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    body.add_child(stats)

    _stat_main = _make_stat(stats, "Main")
    _stat_engine = _make_stat(stats, "Engine")
    _stat_data = _make_stat(stats, "Data")
    _stat_remaining = _make_stat(stats, "Remaining")
func _build_largest_resources_card(parent: VBoxContainer) -> void:
    var card := _make_card(parent, "最大资源")
    var panel := card["panel"] as PanelContainer
    var body := card["body"] as VBoxContainer
    panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
    body.size_flags_vertical = Control.SIZE_EXPAND_FILL

    _largest_tree = Tree.new()
    _largest_tree.columns = 2
    _largest_tree.hide_root = true
    _largest_tree.set_column_title(0, "Size")
    _largest_tree.set_column_title(1, "Resource")
    _largest_tree.column_titles_visible = true
    _largest_tree.set_column_custom_minimum_width(0, 90)
    _largest_tree.set_column_expand(0, false)
    _largest_tree.set_column_expand(1, true)
    _largest_tree.custom_minimum_size = Vector2(0, 96)
    _largest_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _largest_tree.add_theme_font_size_override("font_size", 17)
    _largest_tree.item_activated.connect(_on_largest_resource_activated)
    body.add_child(_largest_tree)


func _build_action_card(parent: VBoxContainer) -> void:
    var card := _make_card(parent, "操作")
    var body := card["body"] as VBoxContainer

    _preview_button = Button.new()
    _preview_button.text = "真机预览"
    _preview_button.tooltip_text = "重新构建后生成微信真机 Preview 二维码"
    _preview_button.custom_minimum_size = Vector2(0, 54)
    _preview_button.add_theme_font_size_override("font_size", 20)
    _preview_button.pressed.connect(_run_preview)
    body.add_child(_preview_button)

    var secondary := HBoxContainer.new()
    secondary.add_theme_constant_override("separation", 8)
    body.add_child(secondary)

    _build_button = Button.new()
    _build_button.text = "构建"
    _build_button.tooltip_text = "生成 build/wechat，不调用微信 CLI"
    _build_button.add_theme_font_size_override("font_size", 17)
    _build_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _build_button.pressed.connect(_run_build)
    secondary.add_child(_build_button)

    _doctor_button = Button.new()
    _doctor_button.text = "检查"
    _doctor_button.tooltip_text = "运行兼容性 Doctor，不生成构建"
    _doctor_button.add_theme_font_size_override("font_size", 17)
    _doctor_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _doctor_button.pressed.connect(_run_doctor)
    secondary.add_child(_doctor_button)

    _upload_button = Button.new()
    _upload_button.text = "上传开发版本"
    _upload_button.tooltip_text = "重新构建并上传到微信后台开发版本"
    _upload_button.add_theme_font_size_override("font_size", 17)
    _upload_button.pressed.connect(_request_upload)
    body.add_child(_upload_button)

    _cancel_button = Button.new()
    _cancel_button.text = "取消当前任务"
    _cancel_button.add_theme_font_size_override("font_size", 17)
    _cancel_button.visible = false
    _cancel_button.pressed.connect(_cancel_process)
    body.add_child(_cancel_button)
func _build_qr_card(parent: VBoxContainer) -> void:
    var card := _make_card(parent, "最近 Preview")
    _qr_card = card["panel"] as PanelContainer
    _qr_card.visible = false
    var body := card["body"] as VBoxContainer

    _qr_status = Label.new()
    _qr_status.text = "尚未生成 Preview 二维码"
    _qr_status.add_theme_font_size_override("font_size", 17)
    _qr_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    body.add_child(_qr_status)

    _qr_texture = TextureRect.new()
    _qr_texture.custom_minimum_size = Vector2(0, 240)
    _qr_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    _qr_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    body.add_child(_qr_texture)


func _build_project_tab(tabs: TabContainer) -> void:
    var page := _make_scroll_tab(tabs, "项目设置")
    var app_card := _make_card(page, "微信应用")
    var app_body := app_card["body"] as VBoxContainer
    var grid := GridContainer.new()
    grid.columns = 2
    grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    app_body.add_child(grid)

    _project_name = LineEdit.new()
    _add_grid_row(grid, "项目名称", _project_name)

    _appid = LineEdit.new()
    _appid.placeholder_text = "wx..."
    _add_grid_row(grid, "AppID", _appid)

    _quick_adapt = CheckBox.new()
    _quick_adapt.text = "此 AppID 已在微信公众平台开启快适配"
    _add_grid_row(grid, "快适配", _quick_adapt)

    _orientation = OptionButton.new()
    _orientation.add_item("Portrait", 0)
    _orientation.add_item("Landscape", 1)
    _add_grid_row(grid, "屏幕方向", _orientation)

    _lib_version = LineEdit.new()
    _lib_version.placeholder_text = "latest"
    _add_grid_row(grid, "基础库", _lib_version)

    var build_card := _make_card(page, "构建选项")
    var build_body := build_card["body"] as VBoxContainer
    var build_grid := GridContainer.new()
    build_grid.columns = 2
    build_body.add_child(build_grid)

    _mobile_textures = CheckBox.new()
    _mobile_textures.text = "ETC2 / ASTC"
    _add_grid_row(build_grid, "移动纹理", _mobile_textures)

    _diagnostics = CheckBox.new()
    _diagnostics.text = "写入 runtime trace / error storage"
    _add_grid_row(build_grid, "Diagnostics", _diagnostics)

    _save_button = Button.new()
    _save_button.text = "保存项目配置"
    _save_button.add_theme_font_size_override("font_size", 17)
    _save_button.custom_minimum_size = Vector2(180, 40)
    _save_button.pressed.connect(_on_save_pressed)
    page.add_child(_save_button)
func _build_advanced_tab(tabs: TabContainer) -> void:
    var page := _make_scroll_tab(tabs, "高级")
    var tool_card := _make_card(page, "本机微信工具")
    var tool_body := tool_card["body"] as VBoxContainer

    var cli_grid := GridContainer.new()
    cli_grid.columns = 2
    tool_body.add_child(cli_grid)

    _wechat_cli_path = LineEdit.new()
    _wechat_cli_path.placeholder_text = "微信开发者工具 CLI 路径"
    _add_grid_row(cli_grid, "CLI Path", _wechat_cli_path)

    var tool_buttons := HBoxContainer.new()
    tool_buttons.add_theme_constant_override("separation", 8)
    tool_body.add_child(tool_buttons)

    _environment_button = Button.new()
    _environment_button.text = "检查微信环境"
    _environment_button.add_theme_font_size_override("font_size", 17)
    _environment_button.pressed.connect(_check_wechat_environment)
    tool_buttons.add_child(_environment_button)

    _open_devtools_button = Button.new()
    _open_devtools_button.text = "打开开发者工具"
    _open_devtools_button.add_theme_font_size_override("font_size", 17)
    _open_devtools_button.pressed.connect(_open_wechat_devtools)
    tool_buttons.add_child(_open_devtools_button)

    var update_card := _make_card(page, "插件更新")
    var update_body := update_card["body"] as VBoxContainer

    _update_status = Label.new()
    _update_status.add_theme_font_size_override("font_size", 17)
    _update_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _update_status.text = "当前版本 0.6.0 · 尚未检查更新"
    update_body.add_child(_update_status)

    _update_source = LineEdit.new()
    _update_source.placeholder_text = (
        "https://.../stable.json 或本地 stable.json")
    _update_source.add_theme_font_size_override("font_size", 17)
    _update_source.text_submitted.connect(_on_update_source_submitted)
    _update_source.focus_exited.connect(_save_update_source)
    update_body.add_child(_update_source)

    _auto_update_check = CheckBox.new()
    _auto_update_check.text = "每天自动检查更新"
    _auto_update_check.add_theme_font_size_override("font_size", 17)
    _auto_update_check.toggled.connect(_on_auto_update_toggled)
    update_body.add_child(_auto_update_check)

    var update_buttons := HBoxContainer.new()
    update_buttons.add_theme_constant_override("separation", 8)
    update_body.add_child(update_buttons)

    _check_update_button = Button.new()
    _check_update_button.text = "检查更新"
    _check_update_button.add_theme_font_size_override("font_size", 17)
    _check_update_button.pressed.connect(_check_for_updates)
    update_buttons.add_child(_check_update_button)

    _update_action_button = Button.new()
    _update_action_button.text = "下载更新"
    _update_action_button.add_theme_font_size_override("font_size", 17)
    _update_action_button.disabled = true
    _update_action_button.pressed.connect(_run_update_action)
    update_buttons.add_child(_update_action_button)

    _rollback_update_button = Button.new()
    _rollback_update_button.text = "回滚上一版本"
    _rollback_update_button.add_theme_font_size_override("font_size", 17)
    _rollback_update_button.visible = false
    _rollback_update_button.pressed.connect(_rollback_update)
    update_buttons.add_child(_rollback_update_button)

    var content_card := _make_card(page, "发布内容")
    var content_body := content_card["body"] as VBoxContainer

    var exclude_label := Label.new()
    exclude_label.text = "排除路径（每行一个 glob）"
    exclude_label.add_theme_font_size_override("font_size", 17)
    content_body.add_child(exclude_label)
    _exclude_patterns = TextEdit.new()
    _exclude_patterns.add_theme_font_size_override("font_size", 17)
    _exclude_patterns.custom_minimum_size = Vector2(0, 120)
    content_body.add_child(_exclude_patterns)

    var autoload_label := Label.new()
    autoload_label.text = "发布时移除 Autoload（每行一个名称）"
    autoload_label.add_theme_font_size_override("font_size", 17)
    content_body.add_child(autoload_label)
    _strip_autoloads = TextEdit.new()
    _strip_autoloads.add_theme_font_size_override("font_size", 17)
    _strip_autoloads.custom_minimum_size = Vector2(0, 90)
    content_body.add_child(_strip_autoloads)


func _bind_update_manager() -> void:
    if _update_manager == null:
        _update_status.text = "自动更新管理器不可用"
        _update_source.editable = false
        _auto_update_check.disabled = true
        _check_update_button.disabled = true
        _update_action_button.disabled = true
        return
    _update_manager.state_changed.connect(_refresh_update_ui)
    _update_source.text = str(_update_manager.update_source())
    _auto_update_check.set_pressed_no_signal(
        bool(_update_manager.auto_check_enabled()))
    _refresh_update_ui()


func _save_update_source() -> void:
    if _update_manager == null:
        return
    _update_manager.set_update_source(_update_source.text)


func _on_update_source_submitted(_value: String) -> void:
    _save_update_source()
    _check_for_updates()


func _on_auto_update_toggled(enabled: bool) -> void:
    if _update_manager != null:
        _update_manager.set_auto_check_enabled(enabled)


func _check_for_updates() -> void:
    if _update_manager == null:
        return
    _save_update_source()
    _update_manager.check_for_updates()


func _run_update_action() -> void:
    if _update_manager == null:
        return
    match str(_update_manager.state):
        "available":
            _update_manager.download_update()
        "downloaded":
            _update_manager.install_downloaded_update(true)


func _rollback_update() -> void:
    if _update_manager == null:
        return
    _update_manager.rollback_previous(true)


func _refresh_update_ui() -> void:
    if _update_manager == null:
        return
    var data: Dictionary = _update_manager.snapshot()
    _update_status.text = "当前版本 %s · %s" % [
        str(data.get("current_version", "?")),
        str(data.get("message", "")),
    ]
    var update_state := str(data.get("state", "idle"))
    _check_update_button.disabled = update_state in [
        "checking", "downloading"]
    _update_action_button.disabled = true
    _update_action_button.text = "下载更新"
    if update_state == "available":
        _update_action_button.text = "下载更新"
        _update_action_button.disabled = false
    elif update_state == "downloading":
        _update_action_button.text = "正在下载..."
    elif update_state == "downloaded":
        _update_action_button.text = "安装并重启"
        _update_action_button.disabled = false
    _rollback_update_button.visible = bool(data.get("has_rollback", false))


func _build_log_tab(tabs: TabContainer) -> void:
    var page := MarginContainer.new()
    page.name = "日志"
    page.add_theme_constant_override("margin_left", 8)
    page.add_theme_constant_override("margin_top", 8)
    page.add_theme_constant_override("margin_right", 8)
    page.add_theme_constant_override("margin_bottom", 8)
    tabs.add_child(page)

    _log = TextEdit.new()
    _log.editable = false
    _log.add_theme_font_size_override("font_size", 17)
    _log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _log.size_flags_vertical = Control.SIZE_EXPAND_FILL
    page.add_child(_log)


func _build_upload_dialog() -> void:
    _upload_confirm = Window.new()
    _upload_confirm.title = "上传微信小游戏开发版本"
    _upload_confirm.size = UPLOAD_DIALOG_BASE_SIZE
    _upload_confirm.min_size = UPLOAD_DIALOG_BASE_MIN_SIZE
    _upload_confirm.transient = true
    _upload_confirm.exclusive = true
    _upload_confirm.wrap_controls = false
    _upload_confirm.close_requested.connect(_upload_confirm.hide)
    _upload_confirm.visible = false
    add_child(_upload_confirm)

    var margin := MarginContainer.new()
    margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    margin.add_theme_constant_override("margin_left", 18)
    margin.add_theme_constant_override("margin_top", 16)
    margin.add_theme_constant_override("margin_right", 18)
    margin.add_theme_constant_override("margin_bottom", 16)
    _upload_confirm.add_child(margin)

    var body := VBoxContainer.new()
    body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    body.size_flags_vertical = Control.SIZE_EXPAND_FILL
    body.add_theme_constant_override("separation", 12)
    margin.add_child(body)

    _upload_dialog_summary = Label.new()
    _upload_dialog_summary.add_theme_font_size_override("font_size", 17)
    _upload_dialog_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    body.add_child(_upload_dialog_summary)

    var grid := GridContainer.new()
    grid.columns = 2
    grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    body.add_child(grid)

    _upload_version = LineEdit.new()
    _upload_version.placeholder_text = "例如 2026.09.26.1"
    _add_grid_row(grid, "版本号", _upload_version)

    _upload_desc = LineEdit.new()
    _upload_desc.placeholder_text = "版本说明"
    _add_grid_row(grid, "版本说明", _upload_desc)

    var spacer := Control.new()
    spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
    body.add_child(spacer)

    var buttons := HBoxContainer.new()
    buttons.alignment = BoxContainer.ALIGNMENT_END
    buttons.add_theme_constant_override("separation", 8)
    body.add_child(buttons)

    _upload_cancel_button = Button.new()
    _upload_cancel_button.text = "取消"
    _upload_cancel_button.add_theme_font_size_override("font_size", 17)
    _upload_cancel_button.pressed.connect(_upload_confirm.hide)
    buttons.add_child(_upload_cancel_button)

    _upload_confirm_button = Button.new()
    _upload_confirm_button.text = "构建并上传"
    _upload_confirm_button.add_theme_font_size_override("font_size", 17)
    _upload_confirm_button.pressed.connect(_confirm_upload)
    buttons.add_child(_upload_confirm_button)


func _make_scroll_tab(tabs: TabContainer, title_text: String) -> VBoxContainer:
    var scroll := ScrollContainer.new()
    scroll.name = title_text
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    tabs.add_child(scroll)

    var margin := MarginContainer.new()
    margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
    margin.add_theme_constant_override("margin_left", 8)
    margin.add_theme_constant_override("margin_top", 10)
    margin.add_theme_constant_override("margin_right", 8)
    margin.add_theme_constant_override("margin_bottom", 10)
    scroll.add_child(margin)

    var body := VBoxContainer.new()
    body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    body.size_flags_vertical = Control.SIZE_EXPAND_FILL
    body.add_theme_constant_override("separation", 12)
    margin.add_child(body)
    return body
func _make_card(parent: Control, title_text: String) -> Dictionary:
    var panel := PanelContainer.new()
    panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    parent.add_child(panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 14)
    margin.add_theme_constant_override("margin_top", 12)
    margin.add_theme_constant_override("margin_right", 14)
    margin.add_theme_constant_override("margin_bottom", 14)
    panel.add_child(margin)

    var body := VBoxContainer.new()
    body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    body.add_theme_constant_override("separation", 8)
    margin.add_child(body)

    var title_label := Label.new()
    title_label.text = title_text
    title_label.add_theme_font_size_override("font_size", 20)
    body.add_child(title_label)
    return {"panel": panel, "body": body}


func _make_stat(parent: GridContainer, title_text: String) -> Label:
    var box := VBoxContainer.new()
    box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    parent.add_child(box)

    var title_label := Label.new()
    title_label.text = title_text
    title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title_label.add_theme_font_size_override("font_size", 17)
    box.add_child(title_label)

    var value := Label.new()
    value.text = "—"
    value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    value.add_theme_font_size_override("font_size", 20)
    box.add_child(value)
    return value


func _apply_editor_icons() -> void:
    if _editor_interface == null:
        return
    var base := _editor_interface.get_base_control()
    if base == null:
        return

    _set_button_icon(_preview_button, base, "MainPlay")
    _set_button_icon(_build_button, base, "Tools")
    _set_button_icon(_doctor_button, base, "Search")
    _set_button_icon(_upload_button, base, "MoveUp")
    _set_button_icon(_cancel_button, base, "Stop")
    _set_button_icon(_save_button, base, "Save")
    _set_button_icon(_environment_button, base, "Reload")
    _set_button_icon(_open_devtools_button, base, "Folder")
    _set_button_icon(_upload_confirm_button, base, "MoveUp")
    _set_button_icon(_upload_cancel_button, base, "Stop")
    _set_button_icon(_check_update_button, base, "Reload")
    _set_button_icon(_update_action_button, base, "MoveUp")
    _set_button_icon(_rollback_update_button, base, "Reload")


func _set_button_icon(button: Button, base: Control, icon_name: String) -> void:
    if button == null or not base.has_theme_icon(icon_name, "EditorIcons"):
        return
    button.icon = base.get_theme_icon(icon_name, "EditorIcons")


func _add_section(root: VBoxContainer, text: String) -> void:
    var label := Label.new()
    label.text = text
    label.add_theme_font_size_override("font_size", 20)
    root.add_child(label)


func _add_grid_row(
        grid: GridContainer, label_text: String, control: Control) -> void:
    var label := Label.new()
    label.text = label_text
    label.add_theme_font_size_override("font_size", 17)
    grid.add_child(label)
    control.add_theme_font_size_override("font_size", 17)
    control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    grid.add_child(control)


func _connect_config_signals() -> void:
    _project_name.text_changed.connect(_on_config_changed_text)
    _appid.text_changed.connect(_on_appid_changed)
    _quick_adapt.toggled.connect(_on_quick_adapt_toggled)
    _orientation.item_selected.connect(_on_config_changed_index)
    _lib_version.text_changed.connect(_on_config_changed_text)
    _mobile_textures.toggled.connect(_on_config_changed_bool)
    _diagnostics.toggled.connect(_on_config_changed_bool)
    _wechat_cli_path.text_changed.connect(_on_cli_path_changed)
    _exclude_patterns.text_changed.connect(_on_config_changed)
    _strip_autoloads.text_changed.connect(_on_config_changed)


func _load_config() -> void:
    _loading = true
    _config = Config.load_config()
    _project_name.text = str(_config.get("project_name", ""))
    _appid.text = str(_config.get("appid", "touristappid"))
    _quick_adapt.button_pressed = bool(_config.get("quick_adapt", false))

    var orientation := str(_config.get("orientation", "portrait"))
    _orientation.select(1 if orientation == "landscape" else 0)
    _lib_version.text = str(_config.get("lib_version", "latest"))
    _mobile_textures.button_pressed = bool(
        _config.get("prepare_mobile_textures", true))
    _diagnostics.button_pressed = bool(_config.get("diagnostics", false))
    _exclude_patterns.text = _array_to_lines(
        _config.get("exclude_patterns", Config.DEFAULT_EXCLUDES))
    _strip_autoloads.text = _array_to_lines(
        _config.get("strip_autoloads", []))
    _wechat_cli_path.text = WechatTool.resolve_cli(_editor_interface)
    _upload_version.text = _suggest_upload_version()
    _upload_desc.text = "%s dev build" % _project_name.text
    _loading = false
    _dirty = false
    _update_title()
    _update_header_summary()
    _update_capability_status()
    _update_wechat_status_initial()
    if _config.has("_load_error"):
        _status.text = "配置错误：" + str(_config["_load_error"])


func _on_save_pressed() -> void:
    _save_config()


func _save_config() -> bool:
    if _config.has("_load_error"):
        _status.text = (
            "配置文件损坏，为避免覆盖已阻止保存/构建；请先修复或删除 "
            + "wechat_export.json"
        )
        return false

    var appid_error := Config.validate_appid(_appid.text)
    if not appid_error.is_empty():
        _status.text = "配置未保存：" + appid_error
        _update_capability_status()
        return false

    _config["project_name"] = _project_name.text.strip_edges()
    _config["appid"] = _appid.text.strip_edges()
    _config["quick_adapt"] = _quick_adapt.button_pressed
    _config["orientation"] = (
        "landscape" if _orientation.selected == 1 else "portrait")
    _config["lib_version"] = _lib_version.text.strip_edges()
    if str(_config["lib_version"]).is_empty():
        _config["lib_version"] = "latest"
    _config["prepare_mobile_textures"] = _mobile_textures.button_pressed
    _config["diagnostics"] = _diagnostics.button_pressed
    _config["exclude_patterns"] = _lines_to_array(_exclude_patterns.text)
    _config["strip_autoloads"] = _lines_to_array(_strip_autoloads.text)

    WechatTool.save_cli_path(_editor_interface, _wechat_cli_path.text)
    var error := Config.save_config(_config)
    if error != OK:
        _status.text = "保存配置失败：%s" % error_string(error)
        return false
    _config.erase("package_limit_mib")
    _dirty = false
    _update_title()
    _update_capability_status()
    _status.text = "配置已保存"
    return true


func _on_appid_changed(_value: String) -> void:
    _on_config_changed()
    _update_capability_status()


func _on_quick_adapt_toggled(_value: bool) -> void:
    _on_config_changed()
    _update_capability_status()


func _on_config_changed_text(_value: String) -> void:
    _on_config_changed()


func _on_cli_path_changed(value: String) -> void:
    if _loading:
        return
    WechatTool.save_cli_path(_editor_interface, value)
    _update_wechat_status_initial()


func _on_config_changed_bool(_value: bool) -> void:
    _on_config_changed()


func _on_config_changed_index(_value: int) -> void:
    _on_config_changed()


func _on_config_changed() -> void:
    if _loading:
        return
    _dirty = true
    _update_title()
    _update_header_summary()
    _refresh_manifest()


func _update_title() -> void:
    title = "微信小游戏发布" + (" *" if _dirty else "")


func _update_header_summary() -> void:
    if _header_project == null or _header_meta == null:
        return
    var project_name := _project_name.text.strip_edges()
    _header_project.text = project_name if not project_name.is_empty() else "Godot Project"
    var appid := _appid.text.strip_edges()
    var capability := "快适配" if _quick_adapt.button_pressed else "普通额度"
    _header_meta.text = "%s  ·  %s" % [appid, capability]


func _update_capability_status() -> void:
    if _appid_status == null:
        return
    var error := Config.validate_appid(_appid.text)

    if not error.is_empty():
        _appid_status.text = "✕ AppID：" + error
    elif _appid.text.strip_edges() == "touristappid":
        _appid_status.text = "○ AppID：Tourist（正式上传需真实 AppID）"
    else:
        _appid_status.text = "✓ AppID：" + _appid.text.strip_edges()

    var limit := 30 if _quick_adapt.button_pressed else 20
    if _quick_adapt.button_pressed:
        _limit_status.text = "○ 快适配已配置 · %d MiB 目标额度" % limit
    else:
        _limit_status.text = "○ 普通小游戏 · %d MiB 默认额度" % limit
    _update_header_summary()
    _update_action_buttons()


func _update_wechat_status_initial() -> void:
    if _wechat_status == null:
        return
    var cli := _resolved_wechat_cli()
    if cli.is_empty():
        _wechat_status.text = "✕ 微信环境：未找到 CLI"
    else:
        _wechat_status.text = "○ 微信环境：CLI 已找到，等待检查服务端口 / 登录"


func _suggest_upload_version() -> String:
    var now := Time.get_datetime_dict_from_system()
    return "%04d.%02d.%02d.1" % [
        int(now.get("year", 0)),
        int(now.get("month", 0)),
        int(now.get("day", 0)),
    ]


func _run_doctor() -> void:
    _pending_after_build = ""
    _run_exporter("doctor")


func _run_build() -> void:
    _pending_after_build = ""
    _run_exporter("build")


func _run_preview() -> void:
    _pending_after_build = "preview"
    _run_exporter("build_preview")


func _request_upload() -> void:
    var appid := _appid.text.strip_edges()
    var appid_error := Config.validate_appid(appid)
    if not appid_error.is_empty() or appid == "touristappid":
        _status.text = "上传需要有效的正式 AppID"
        return

    if _upload_version.text.strip_edges().is_empty():
        _upload_version.text = _suggest_upload_version()
    if _upload_desc.text.strip_edges().is_empty():
        _upload_desc.text = "%s dev build" % _project_name.text.strip_edges()

    _upload_dialog_summary.text = (
        "AppID  %s\n"
        + "当前构建  %s\n\n"
        + "确认后会重新构建，再上传到微信后台的开发版本。"
    ) % [appid, _package_summary.text]
    _upload_confirm.popup_centered(
        _scaled_upload_size(UPLOAD_DIALOG_BASE_SIZE))


func _confirm_upload() -> void:
    var version := _upload_version.text.strip_edges()
    var description := _upload_desc.text.strip_edges()
    if version.is_empty() or description.is_empty():
        _status.text = "上传版本号和版本说明不能为空"
        return
    _upload_confirm.hide()
    _pending_after_build = "upload"
    _run_exporter("build_upload")


func _run_exporter(action: String) -> void:
    if _runner == null or _runner.is_running():
        return
    if not _save_config():
        return

    var python := _resolve_python()
    var exporter := ProjectSettings.globalize_path(
        "res://addons/wechat_exporter/toolchain/export_wechat.py")

    var project := ProjectSettings.globalize_path("res://").trim_suffix("/")
    if not _prepare_cancel_request():
        return
    var arguments := PackedStringArray([
        exporter,
        "--project", project,
        "--cancel-file", _cancel_file_path,
        "--json-events",
    ])
    if action == "doctor":
        arguments.append("--doctor")

    _action = action
    _event_buffer = ""
    _log.text = ""
    _append_log("$ %s %s\n" % [python, " ".join(arguments)], false)
    _set_busy(true)
    _status.text = "正在%s..." % ("检查" if action == "doctor" else "构建")
    var error: int = int(_runner.start(python, arguments))
    if error != OK:
        _clear_cancel_request()
        _set_busy(false)
        _status.text = "启动 exporter 失败：%s" % error_string(error)


func _prepare_cancel_request() -> bool:
    var user_dir := ProjectSettings.globalize_path("user://wechat_exporter")
    var error := DirAccess.make_dir_recursive_absolute(user_dir)
    if error != OK:
        _status.text = "创建取消请求目录失败：%s" % error_string(error)
        return false
    _cancel_file_path = user_dir.path_join("cancel.request")
    if FileAccess.file_exists(_cancel_file_path):
        DirAccess.remove_absolute(_cancel_file_path)
    return true


func _clear_cancel_request() -> void:
    if not _cancel_file_path.is_empty() and FileAccess.file_exists(
            _cancel_file_path):
        DirAccess.remove_absolute(_cancel_file_path)


func _resolve_python() -> String:
    for candidate: String in [
        "/usr/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
    ]:
        if FileAccess.file_exists(candidate):
            return candidate
    return "python3"


func _resolved_wechat_cli() -> String:
    if _wechat_cli_path != null:
        var configured := _wechat_cli_path.text.strip_edges()
        if not configured.is_empty() and FileAccess.file_exists(configured):
            return configured
    return WechatTool.resolve_cli(_editor_interface)


func _check_wechat_environment() -> void:
    if _runner == null or _runner.is_running():
        return
    var cli := _resolved_wechat_cli()
    if cli.is_empty():
        _wechat_status.text = "微信工具：✕ 未找到 CLI"
        _status.text = "请填写微信开发者工具 CLI 路径"
        return
    WechatTool.save_cli_path(_editor_interface, cli)
    _action = "wechat_env"
    _log.text = ""
    _append_log("$ %s islogin --lang en\n" % cli, false)
    _set_busy(true)
    _status.text = "正在检查微信开发者工具..."
    var error: int = _start_wechat_cli(
        cli, PackedStringArray(["islogin", "--lang", "en"]))
    if error != OK:
        _set_busy(false)
        _status.text = "启动微信 CLI 失败：%s" % error_string(error)


func _open_wechat_devtools() -> void:
    var error: int = int(WechatTool.open_devtools())
    if error != OK:
        _status.text = "无法自动打开微信开发者工具：%s" % error_string(error)


func _start_wechat_preview() -> void:
    var cli := _resolved_wechat_cli()
    if cli.is_empty():
        _status.text = "未找到微信开发者工具 CLI"
        return
    var preview_dir := ProjectSettings.globalize_path(
        "res://build/.wechat-preview")
    var dir_error := DirAccess.make_dir_recursive_absolute(preview_dir)
    if dir_error != OK:
        _status.text = "创建 Preview 缓存目录失败：%s" % error_string(dir_error)
        return

    _preview_qr_path = preview_dir.path_join("preview-qr.jpg")
    _preview_info_path = preview_dir.path_join("preview-info.json")
    if FileAccess.file_exists(_preview_qr_path):
        DirAccess.remove_absolute(_preview_qr_path)
    if FileAccess.file_exists(_preview_info_path):
        DirAccess.remove_absolute(_preview_info_path)

    var build_path := ProjectSettings.globalize_path("res://build/wechat")
    var arguments := PackedStringArray([
        "preview",
        "--project", build_path,
        "--qr-format", "image",
        "--qr-output", _preview_qr_path,
        "--info-output", _preview_info_path,
        "--lang", "en",
    ])
    _action = "preview"
    _append_log("\n--- WeChat Preview ---\n", false)
    _append_log("$ %s %s\n" % [cli, " ".join(arguments)], false)
    _set_busy(true)
    _status.text = "正在生成微信真机 Preview..."
    var error: int = _start_wechat_cli(cli, arguments)
    if error != OK:
        _set_busy(false)
        _status.text = "启动 Preview 失败：%s" % error_string(error)


func _start_wechat_upload() -> void:
    var cli := _resolved_wechat_cli()
    if cli.is_empty():
        _status.text = "未找到微信开发者工具 CLI"
        return
    var version := _upload_version.text.strip_edges()
    var description := _upload_desc.text.strip_edges()
    var build_path := ProjectSettings.globalize_path("res://build/wechat")
    var arguments := PackedStringArray([
        "upload",
        "--project", build_path,
        "--version", version,
        "--desc", description,
        "--lang", "en",
    ])
    _action = "upload"
    _append_log("\n--- WeChat Upload ---\n", false)
    _append_log("$ %s %s\n" % [cli, " ".join(arguments)], false)
    _set_busy(true)
    _status.text = "正在上传微信小游戏开发版本..."
    var error: int = _start_wechat_cli(cli, arguments)
    if error != OK:
        _set_busy(false)
        _status.text = "启动 Upload 失败：%s" % error_string(error)


func _start_wechat_cli(
        cli: String, arguments: PackedStringArray) -> int:
    var command: Dictionary = WechatTool.wrap_command(cli, arguments)
    return int(_runner.start(
        str(command.get("path", cli)),
        command.get("arguments", arguments) as PackedStringArray,
    ))


func _write_export_cancel_request() -> bool:
    if _cancel_file_path.is_empty():
        return false
    var file := FileAccess.open(_cancel_file_path, FileAccess.WRITE)
    if file == null:
        return false
    file.store_string("cancel\n")
    file.close()
    return true


func shutdown() -> void:
    if _runner == null or not _runner.is_running():
        return
    if _action in ["doctor", "build", "build_preview", "build_upload"]:
        _write_export_cancel_request()
    else:
        _runner.cancel()


func _cancel_process() -> void:
    if _runner == null or not _runner.is_running():
        return
    if _action in ["doctor", "build", "build_preview", "build_upload"]:
        if not _write_export_cancel_request():
            _status.text = "无法创建安全取消请求"
            return
        _cancel_button.disabled = true
        _status.text = "正在安全取消并恢复项目文件..."
        return

    var error: int = int(_runner.cancel())
    if error == OK:
        _status.text = "正在取消微信 CLI..."
    else:
        _status.text = "取消失败：%s" % error_string(error)


func _set_busy(busy: bool) -> void:
    var supported := _godot_compatibility_error().is_empty()
    _save_button.disabled = busy
    _doctor_button.disabled = busy or not supported
    _build_button.disabled = busy or not supported
    _environment_button.disabled = busy
    _preview_button.disabled = busy or not supported
    _upload_button.disabled = busy or not supported or not _can_upload()
    _cancel_button.disabled = not busy
    _cancel_button.visible = busy


func _godot_compatibility_error() -> String:
    if _update_manager == null:
        return ""
    if not _update_manager.has_method("current_godot_compatibility_error"):
        return ""
    return str(_update_manager.current_godot_compatibility_error())


func _update_godot_compatibility_status() -> void:
    var error := _godot_compatibility_error()
    if not error.is_empty():
        _runtime_status.text = "✕ " + error
        _status.text = "当前 Godot 版本不受此插件版本支持"
        return
    if _runtime_status.text.begins_with("○ Runtime"):
        var info := Engine.get_version_info()
        _runtime_status.text = "✓ Godot %d.%d.%d official · %s" % [
            int(info.get("major", 0)),
            int(info.get("minor", 0)),
            int(info.get("patch", 0)),
            str(info.get("hash", "")).left(10),
        ]


func _update_action_buttons() -> void:
    if _save_button == null:
        return
    var busy: bool = _runner != null and bool(_runner.is_running())
    _set_busy(busy)
    _update_godot_compatibility_status()


func _can_upload() -> bool:
    var appid := _appid.text.strip_edges() if _appid != null else ""
    return (
        not appid.is_empty()
        and appid != "touristappid"
        and Config.validate_appid(appid).is_empty()
    )


func _on_process_output(text: String, is_stderr: bool) -> void:
    _append_log(text, is_stderr)
    if not is_stderr:
        _consume_event_text(text)


func _append_log(text: String, is_stderr: bool) -> void:
    if _log == null or text.is_empty():
        return
    var value := text
    if is_stderr:
        value = "[stderr] " + value
    _log.text += value
    _log.set_caret_line(maxi(0, _log.get_line_count() - 1))


func _consume_event_text(text: String) -> void:
    _event_buffer += text
    while true:
        var newline := _event_buffer.find("\n")
        if newline < 0:
            break
        var line := _event_buffer.substr(0, newline).strip_edges()
        _event_buffer = _event_buffer.substr(newline + 1)
        if not line.begins_with(EVENT_PREFIX):
            continue
        var payload_text := line.substr(EVENT_PREFIX.length())
        var parsed: Variant = JSON.parse_string(payload_text)
        if parsed is Dictionary:
            _handle_event(parsed)


func _handle_event(event: Dictionary) -> void:
    match str(event.get("event", "")):
        "config":
            _status.text = "配置：%s | %s MiB" % [
                str(event.get("appid", "")),
                str(event.get("package_limit_mib", "")),
            ]
        "compatibility":
            var errors: Array = event.get("errors", [])
            var warnings: Array = event.get("warnings", [])
            _compatibility.text = (
                "✓ 兼容性通过" if errors.is_empty() and warnings.is_empty()
                else "⚠ 兼容性：%d error / %d warning" % [
                    errors.size(), warnings.size()]
            )
        "phase":
            _status.text = _phase_label(str(event.get("name", "")))

        "error":
            _status.text = "失败：" + str(event.get("message", ""))
        "complete":
            if str(event.get("mode", "")) == "doctor":
                _status.text = "检查完成"
            else:
                _status.text = "构建完成"


func _phase_label(phase: String) -> String:
    match phase:
        "import":
            return "正在导入 ETC2 / ASTC 资源..."
        "export_pack":
            return "正在生成 Godot PCK..."
        "assemble":
            return "正在组装微信小游戏包..."
        _:
            return "正在处理：" + phase


func _on_process_finished(exit_code: int, was_cancelled: bool) -> void:
    var completed_action := _action
    _clear_cancel_request()
    _set_busy(false)
    if was_cancelled:
        _pending_after_build = ""
        _status.text = "任务已取消"
        return

    if (
        exit_code == 130
        and completed_action in ["doctor", "build", "build_preview", "build_upload"]
    ):
        _pending_after_build = ""
        _status.text = "任务已安全取消，项目文件已恢复"
        return

    if exit_code != 0:
        if completed_action in ["wechat_env", "preview", "upload"]:
            _handle_wechat_failure(completed_action, exit_code)
        else:
            _status.text = "%s失败，退出码 %d" % [
                "检查" if completed_action == "doctor" else "构建",
                exit_code,
            ]
        _pending_after_build = ""
        return

    if completed_action in ["preview", "upload"]:
        if not _wechat_action_confirmed(completed_action):
            var label := "Preview" if completed_action == "preview" else "Upload"
            _wechat_status.text = "微信工具：✕ %s 未确认成功" % label
            _status.text = "%s 未确认成功，请查看日志" % label
            return

    match completed_action:
        "doctor":
            _status.text = "检查通过"
        "build":
            _status.text = "构建完成"
            _refresh_manifest()
        "build_preview", "build_upload":
            _refresh_manifest()
            var next_action := _pending_after_build
            _pending_after_build = ""
            _status.text = "构建完成，准备微信操作..."
            if next_action == "preview":
                call_deferred("_start_wechat_preview")
            elif next_action == "upload":
                call_deferred("_start_wechat_upload")
        "wechat_env":
            if _log.text.contains("\"login\":true"):
                _status.text = "微信环境检查通过"
                _wechat_status.text = "✓ 微信环境：CLI · 服务端口 · 已登录"
            else:
                _status.text = "微信开发者工具尚未登录"
                _wechat_status.text = "⚠ 微信环境：CLI 可用，但当前未登录"
        "preview":
            _status.text = "微信真机 Preview 已生成"
            _wechat_status.text = "微信工具：✓ Preview 成功"
            _load_preview_qr()
        "upload":
            _status.text = "微信小游戏开发版本上传成功"
            _wechat_status.text = "微信工具：✓ Upload 成功"
        _:
            _status.text = "任务完成"


func _wechat_log_has_error() -> bool:
    var output := _log.text.to_lower()
    for marker: String in [
        "[error]",
        "error:",
        "compile failed",
        "preview failed",
        "upload failed",
        "exceed max limit",
        "源码包超出最大限制",
    ]:
        if output.contains(marker):
            return true
    return false


func _wechat_action_confirmed(action: String) -> bool:
    if _wechat_log_has_error():
        return false
    match action:
        "preview":
            return (
                _log.text.contains("✔ preview")
                and FileAccess.file_exists(_preview_qr_path)
                and FileAccess.file_exists(_preview_info_path)
            )
        "upload":
            return _log.text.contains("✔ upload")
        _:
            return false


func _handle_wechat_failure(action: String, exit_code: int) -> void:
    var output := _log.text.to_lower()
    if (
        output.contains("service port disabled")
        or output.contains("服务端口已关闭")
    ):
        var hint := WechatTool.service_port_hint()
        _wechat_status.text = "微信工具：✕ 服务端口关闭；" + hint
        _status.text = "微信 CLI 不可用：请先开启服务端口"
        return
    if (
        output.contains("not login")
        or output.contains("login=false")
        or output.contains("未登录")
    ):
        _wechat_status.text = "微信工具：✕ 当前未登录"
        _status.text = "请先在微信开发者工具中登录"
        return

    var label := {
        "wechat_env": "微信环境检查",
        "preview": "Preview",
        "upload": "Upload",
    }.get(action, "微信 CLI")
    _wechat_status.text = "微信工具：✕ %s 失败" % label
    _status.text = "%s失败，退出码 %d" % [label, exit_code]


func _load_preview_qr() -> void:
    if _preview_qr_path.is_empty() or not FileAccess.file_exists(
            _preview_qr_path):
        _qr_status.text = "Preview 成功，但未找到二维码文件"
        _qr_texture.visible = false
        _qr_card.visible = true
        return

    var image := Image.load_from_file(_preview_qr_path)
    if image == null or image.is_empty():
        _qr_status.text = "Preview 二维码无法加载"
        _qr_texture.visible = false
        _qr_card.visible = true
        return

    _qr_texture.texture = ImageTexture.create_from_image(image)
    _qr_texture.visible = true
    _qr_card.visible = true
    var summary := "Preview 二维码已生成"
    if FileAccess.file_exists(_preview_info_path):
        var parsed: Variant = JSON.parse_string(
            FileAccess.get_file_as_string(_preview_info_path))
        if parsed is Dictionary:
            var size_info: Dictionary = parsed.get("size", {})
            var total := int(size_info.get("total", 0))
            if total > 0:
                summary += " | %.2f MiB" % _mib(total)
    _qr_status.text = summary


func _current_build_config_snapshot() -> Dictionary:
    var lib_version := _lib_version.text.strip_edges()
    if lib_version.is_empty():
        lib_version = "latest"
    return {
        "project_name": _project_name.text.strip_edges(),
        "appid": _appid.text.strip_edges(),
        "quick_adapt": _quick_adapt.button_pressed,
        "package_limit_mib": 30 if _quick_adapt.button_pressed else 20,
        "orientation": "landscape" if _orientation.selected == 1 else "portrait",
        "lib_version": lib_version,
        "prepare_mobile_textures": _mobile_textures.button_pressed,
        "diagnostics": _diagnostics.button_pressed,
        "exclude_patterns": _lines_to_array(_exclude_patterns.text),
        "strip_autoloads": _lines_to_array(_strip_autoloads.text),
        "release_scenes": _config.get("release_scenes", []),
    }


func _manifest_matches_current_config(manifest: Dictionary) -> bool:
    var built: Variant = manifest.get("config", {})
    if not (built is Dictionary):
        return false
    var current := _current_build_config_snapshot()
    for key: Variant in current.keys():
        if not built.has(key) or built[key] != current[key]:
            return false
    return true


func _refresh_manifest() -> void:
    if _package_summary == null:
        return
    var path := BUILD_MANIFEST_PATH
    if not FileAccess.file_exists(path) and FileAccess.file_exists(
            LEGACY_BUILD_MANIFEST_PATH):
        path = LEGACY_BUILD_MANIFEST_PATH
    if not FileAccess.file_exists(path):
        _package_progress.value = 0.0
        _package_summary.text = "暂无构建"
        _stat_main.text = "—"
        _stat_engine.text = "—"
        _stat_data.text = "—"
        _stat_remaining.text = "—"
        _runtime_status.text = "○ Runtime 等待构建信息"
        _largest_tree.clear()
        return

    var parsed: Variant = JSON.parse_string(
        FileAccess.get_file_as_string(path))
    if not (parsed is Dictionary):
        _package_summary.text = "build-manifest.json 无法解析"
        return

    var manifest: Dictionary = parsed
    var sizes: Dictionary = manifest.get("package_sizes", {})
    var total := int(sizes.get("total", 0))
    var main := int(sizes.get("main", 0))
    var engine := int(sizes.get("engine", 0))
    var data := int(sizes.get("data", 0))
    var limit := int(manifest.get("package_limit_mib", 20))
    var headroom := int(manifest.get(
        "package_headroom_bytes", limit * 1024 * 1024 - total))

    _package_progress.max_value = float(limit)
    _package_progress.value = _mib(total)
    _package_summary.text = "%.2f / %d MiB   ·   %.1f%%" % [
        _mib(total), limit, 100.0 * float(total) / float(limit * 1024 * 1024),
    ]
    if not _manifest_matches_current_config(manifest):
        _package_summary.text += "   ·   ⚠ 构建已过期"
    _stat_main.text = "%.2f MiB" % _mib(main)
    _stat_engine.text = "%.2f MiB" % _mib(engine)
    _stat_data.text = "%.2f MiB" % _mib(data)
    _stat_remaining.text = "%.2f MiB" % _mib(headroom)

    var compatibility: Dictionary = manifest.get("compatibility", {})
    var errors: Array = compatibility.get("errors", [])
    var warnings: Array = compatibility.get("warnings", [])
    _compatibility.text = (
        "✓ 兼容性通过" if errors.is_empty() and warnings.is_empty()
        else "⚠ 兼容性：%d error / %d warning" % [
            errors.size(), warnings.size()]
    )
    _runtime_status.text = "✓ Godot %s   ·   Exporter %s" % [
        str(manifest.get("godot_version", "?")),
        str(manifest.get("exporter_version", "?")),
    ]

    _largest_tree.clear()
    var root := _largest_tree.create_item()
    var rows: Array = manifest.get("largest_project_files", [])
    for index: int in range(rows.size()):
        var row: Dictionary = rows[index]
        var item := _largest_tree.create_item(root)
        var resource_path := str(row.get("path", ""))
        item.set_text(0, "%.2f MiB" % _mib(int(row.get("size", 0))))
        item.set_text(1, resource_path)
        item.set_tooltip_text(1, resource_path)
        item.set_metadata(1, resource_path)


func _on_largest_resource_activated() -> void:
    if _largest_tree == null or _editor_interface == null:
        return
    var item := _largest_tree.get_selected()
    if item == null:
        return
    var resource_path := str(item.get_metadata(1))
    if resource_path.is_empty():
        return
    if resource_path.begins_with(".godot/"):
        _status.text = "该条目是 Godot 导出缓存，无法在项目资源中直接定位"
        return
    var res_path := (
        resource_path if resource_path.begins_with("res://")
        else "res://" + resource_path
    )
    _editor_interface.get_file_system_dock().navigate_to_path(res_path)
    _status.text = "已定位资源：" + resource_path


func _mib(value: int) -> float:
    return float(value) / (1024.0 * 1024.0)


func _array_to_lines(value: Variant) -> String:
    if not (value is Array):
        return ""
    var lines := PackedStringArray()
    for item: Variant in value:
        lines.append(str(item))
    return "\n".join(lines)


func _lines_to_array(text: String) -> Array:
    var result: Array = []
    for raw_line: String in text.split("\n"):
        var line := raw_line.strip_edges()
        if not line.is_empty():
            result.append(line)
    return result
