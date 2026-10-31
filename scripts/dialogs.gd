class_name Dialogs
extends RefCounted
## 原生文件/目录选择器的统一入口。
##
## 为什么包一层：4.7 Windows 的 file_dialog_show 回调**实传 3 个参数**
## (status, PackedStringArray, filter_index)，目录模式还会传第 4 个；每个页面自己写回调
## 迟早有人写 2 参版本，运行时报 "Method expected 2 argument(s), but called with 3"，
## 而且失败是静默的（选了文件也没反应）。这里把参数形状归一成两个干净信号。
## 原生对话框不可用时（无显示服务/平台不支持）退到内置 FileDialog，行为一致。

static func pick_file(filter: PackedStringArray, cb: Callable) -> void:
	_open("选择资源包（zip）", filter, DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, false, cb, "file")


static func pick_dir(cb: Callable) -> void:
	_open("选择资源包目录", PackedStringArray(), DisplayServer.FILE_DIALOG_MODE_OPEN_DIR, false, cb, "file")


static func pick_save(suggested: String, filter: PackedStringArray, cb: Callable) -> void:
	_open("导出位置", filter, DisplayServer.FILE_DIALOG_MODE_SAVE_FILE, false, cb, "save")


static func _open(title: String, filter: PackedStringArray, mode: int, _multi: bool, cb: Callable, kind: String) -> void:
	var start := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if start == "":
		start = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	var err := DisplayServer.file_dialog_show(title, start, "", false, mode, filter,
			func(confirmed: bool = false, a: Variant = null, b: Variant = null, _c: Variant = null) -> void:
				_reply(cb, confirmed, a, kind))
	if err != OK:
		_fallback(title, filter, mode, cb, kind)


static func _reply(cb: Callable, confirmed: bool, a: Variant, kind: String) -> void:
	var paths := PackedStringArray()
	if a is PackedStringArray:
		paths = a
	elif a is String:
		paths = PackedStringArray([String(a)])
	if kind == "save":
		cb.call(confirmed and not paths.is_empty(), paths[0] if not paths.is_empty() else "")
	else:
		cb.call(confirmed and not paths.is_empty(), paths)


## 退路：内置 FileDialog（原生对话框不可用时；song_select 导入谱面也留了这条）
static func _fallback(title: String, filter: PackedStringArray, mode: int, cb: Callable, kind: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		cb.call(false, "" if kind == "save" else PackedStringArray())
		return
	var fd := FileDialog.new()
	fd.title = title
	fd.access = FileDialog.ACCESS_FILESYSTEM
	match mode:
		DisplayServer.FILE_DIALOG_MODE_SAVE_FILE:
			fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		DisplayServer.FILE_DIALOG_MODE_OPEN_DIR:
			fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_:
			fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	for f in filter:
		var pat := String(f).split(";")[0].strip_edges()
		if pat != "":
			fd.add_filter(pat + " ; 资源包")
	fd.use_native_dialog = false
	fd.file_selected.connect(func(path: String) -> void:
			_reply(cb, path != "", PackedStringArray([path]), kind)
			fd.queue_free())
	fd.dir_selected.connect(func(path: String) -> void:
			_reply(cb, path != "", PackedStringArray([path]), kind)
			fd.queue_free())
	fd.files_selected.connect(func(paths: PackedStringArray) -> void:
			_reply(cb, paths.size() > 0, paths, kind)
			fd.queue_free())
	fd.cancelled.connect(func() -> void:
			_reply(cb, false, PackedStringArray(), kind)
			fd.queue_free())
	tree.root.add_child(fd)
	fd.popup_centered(Vector2i(920, 620))
