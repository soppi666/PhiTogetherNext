class_name ChartMetaCache
extends RefCounted
## 本地谱目录 → 选曲卡片元数据的持久缓存（user://chart_meta.json）。
##
## 为什么要它：列一张本地卡原本要把整份 chart.json（RPE 谱 1–8MB）读进来 JSON.parse 一遍，
## 本机 21 张实测 **2118ms**，全砸在「点单人游戏」那一帧上——动画做得再顺，
## 前面挡着 2.7 秒冻结也只会看成"卡一下然后瞬间到位"。
## 键=目录，指纹=chart.json 的 修改时间|大小（official 目录=目录内 json 数|最新修改时间），
## 谱被替换/重下自动失效；命中缓存=零 IO。
## 未命中时不再同步解析：先给占位条目（目录名 / info.txt），真解析排进 BakePump 一帧一份。

const FILE := "user://chart_meta.json"
## 条目字段语义变更时递增：整份旧缓存作废（键带版本前缀，旧键自然永不命中）。
## v2 = official 条目的 local_json 统一为"带后缀文件名"（此前占位条目存去后缀名 → 开谱失败）。
const SCHEMA := "v2"

static var _data := {}
static var _dirty := false
static var _loaded := false

static func _k(dir: String) -> String:
	return SCHEMA + "|" + dir

static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var fa := FileAccess.open(FILE, FileAccess.READ)
	if fa == null:
		return
	var j: Variant = JSON.parse_string(fa.get_as_text())
	fa.close()
	if typeof(j) == TYPE_DICTIONARY:
		_data = j

## 命中返回条目数组（可能直接交给 UI 用），未命中返回空数组
static func get_entries(dir: String, fp: String) -> Array:
	_load()
	var v: Variant = _data.get(_k(dir), null)
	if typeof(v) != TYPE_DICTIONARY:
		return []
	if String((v as Dictionary).get("fp", "")) != fp:
		return []
	var e: Variant = (v as Dictionary).get("entries", [])
	if typeof(e) != TYPE_ARRAY:
		return []
	return e as Array

static func put_entries(dir: String, fp: String, entries: Array) -> void:
	_load()
	_data[_k(dir)] = {"fp": fp, "entries": entries}
	_dirty = true

## 让某个目录的缓存条目作废（info.txt 的 Level 被修复覆盖后必须走这条：
## 指纹只看 chart.json，改了 info.txt 指纹不变，否则卡片永远显示旧难度码）。
static func drop(dir: String) -> void:
	_load()
	if _data.erase(_k(dir)):
		_dirty = true

## 节流落盘：一件解析完就整份 stringify + 写盘，会在"回填窗口"里连打 20 次
## （实测贡献 20–50ms 的帧）。1.2s 内只写一次，队列排空时由 force_save 收尾。
const SAVE_GAP_MS := 1200
static var _last_save := 0

static func save_if_dirty() -> void:
	if not _dirty:
		return
	if Time.get_ticks_msec() - _last_save < SAVE_GAP_MS:
		return
	force_save()

static func force_save() -> void:
	if not _dirty:
		return
	_dirty = false
	_last_save = Time.get_ticks_msec()
	var fa := FileAccess.open(FILE, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify(_data))
	fa.close()
