@tool
class_name WechatProcessRunner
extends RefCounted

signal started(pid: int)
signal output_received(text: String, is_stderr: bool)
signal finished(exit_code: int, was_cancelled: bool)

var _pid: int = -1
var _stdout: FileAccess
var _stderr: FileAccess
var _running := false
var _cancelled := false


func start(path: String, arguments: PackedStringArray) -> Error:
    if _running:
        return ERR_ALREADY_IN_USE

    var result := OS.execute_with_pipe(path, arguments, false)
    if result.is_empty():
        return ERR_CANT_FORK

    _pid = int(result.get("pid", -1))
    _stdout = result.get("stdio") as FileAccess
    _stderr = result.get("stderr") as FileAccess
    if _pid <= 0:
        _reset()
        return ERR_CANT_FORK

    _running = true
    _cancelled = false
    started.emit(_pid)
    return OK


func poll() -> void:
    if not _running:
        return

    _drain_pipe(_stdout, false)
    _drain_pipe(_stderr, true)

    if OS.is_process_running(_pid):
        return

    _drain_pipe(_stdout, false)
    _drain_pipe(_stderr, true)
    var exit_code := OS.get_process_exit_code(_pid)
    var was_cancelled := _cancelled
    _close_pipes()
    _pid = -1
    _running = false
    _cancelled = false
    finished.emit(exit_code, was_cancelled)


func cancel() -> Error:
    if not _running or _pid <= 0:
        return ERR_DOES_NOT_EXIST

    _cancelled = true
    return OS.kill(_pid)


func is_running() -> bool:
    return _running


func get_pid() -> int:
    return _pid


func _drain_pipe(pipe: FileAccess, is_stderr: bool) -> void:
    if pipe == null:
        return
    var available := pipe.get_length() - pipe.get_position()
    if available <= 0:
        return
    var bytes := pipe.get_buffer(available)
    if bytes.is_empty():
        return
    output_received.emit(bytes.get_string_from_utf8(), is_stderr)


func _close_pipes() -> void:
    if _stdout != null:
        _stdout.close()
    if _stderr != null:
        _stderr.close()
    _stdout = null
    _stderr = null


func _reset() -> void:
    _close_pipes()
    _pid = -1
    _running = false
    _cancelled = false
