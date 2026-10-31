class_name PlayRecords
extends RefCounted
## 每谱面游玩记录（user://records.json）：评级图/分数/Acc 的数据源。
## 键 = 本地 "local:目录" / PZ "pzc:谱id"（与收藏键同族但精确到谱面难度）。
## 只保留最好成绩；由 chart_stage 在歌曲自然结束时写入（Esc 退出不记）。
## Rank.png = PhiTogether respack shared 256×1792 竖排 7 格：Φ,V,S,A,B,C,F。

const REC_FILE := "user://records.json"
const RANK_IMG := "res://assets/ranks/Rank.png"
# PhiZone 评级档（分数制满分 1,000,000）：Φ=AP；下标即 Rank.png 格号
const THRESHOLDS := [1000000, 980000, 950000, 900000, 850000, 800000]
const RANK_NAMES := ["Phi", "V", "S", "A", "B", "C", "F"]

static var _data := {}
static var _loaded := false
static var _atlas: Texture2D = null

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(REC_FILE):
		return
	var fa := FileAccess.open(REC_FILE, FileAccess.READ)
	if fa == null:
		return
	var j: Variant = JSON.parse_string(fa.get_buffer(fa.get_length()).get_string_from_utf8())
	fa.close()
	if typeof(j) == TYPE_DICTIONARY:
		_data = j

static func get_record(key: String) -> Dictionary:
	if key == "":
		return {}
	_ensure()
	var r: Variant = _data.get(key, {})
	return r if typeof(r) == TYPE_DICTIONARY else {}

## 写入成绩，仅当刷新最好分。返回 true=产生了新纪录。
static func save_record(key: String, score: int, acc: float, combo: int) -> bool:
	if key == "":
		return false
	_ensure()
	var old := get_record(key)
	if not old.is_empty() and int(old.get("score", 0)) >= score:
		return false
	_data[key] = {"score": score, "acc": acc, "combo": combo, "ts": Time.get_unix_time_from_system()}
	var fa := FileAccess.open(REC_FILE, FileAccess.WRITE)
	if fa != null:
		fa.store_string(JSON.stringify(_data))
		fa.flush()
		fa.close()
	return true

static func rank_index(score: int) -> int:
	for i in THRESHOLDS.size():
		if score >= int(THRESHOLDS[i]):
			return i
	return THRESHOLDS.size()  # F

## 删一条记录（QA 用：不残留测试成绩）
static func erase(key: String) -> void:
	_ensure()
	if not _data.has(key):
		return
	_data.erase(key)
	var fa := FileAccess.open(REC_FILE, FileAccess.WRITE)
	if fa != null:
		fa.store_string(JSON.stringify(_data))
		fa.flush()
		fa.close()

## Rank.png 第 i 格（256×256 竖排）→ AtlasTexture，共享同一底图。
## 每格按"墨迹 bbox"裁方：徽章透明边距大（用户报"评级空/截太大"），裁掉后显示盒里被撑满
static var _regions: Array = []

static func rank_texture(i: int) -> Texture2D:
	if _atlas == null:
		_atlas = load(RANK_IMG) as Texture2D
	if _atlas == null:
		return null
	if _regions.is_empty():
		_regions = _trim_regions()
	var at := AtlasTexture.new()
	at.atlas = _atlas
	at.region = _regions[i] if i < _regions.size() else Rect2(0, i * 256, 256, 256)
	return at

## 未裁墨迹的原始 256×256 格：PT 结算页的徽章是整格缩放（ResultPage.ts:124-138 把
## 256 格画成 492 见方）。用裁过的墨迹方框会让字比 PT 大一号（实跑截图实证）。
static func rank_cell(i: int) -> Texture2D:
	if _atlas == null:
		_atlas = load(RANK_IMG) as Texture2D
	if _atlas == null:
		return null
	var at := AtlasTexture.new()
	at.atlas = _atlas
	at.region = Rect2(0, i * 256, 256, 256)
	return at

static func _trim_regions() -> Array:
	var out: Array = []
	var img := _atlas.get_image()
	if img == null:
		return out
	img.convert(Image.FORMAT_RGBA8)
	var cell := 256
	var n := maxi(img.get_height() / cell, 1)
	for c in n:
		var x0 := cell
		var y0 := cell
		var x1 := -1
		var y1 := -1
		for y in cell:
			for x in cell:
				if img.get_pixel(x, c * cell + y).a > 0.04:
					x0 = mini(x0, x)
					x1 = maxi(x1, x)
					y0 = mini(y0, y)
					y1 = maxi(y1, y)
		if x1 < 0:
			out.append(Rect2(0, c * cell, cell, cell))
			continue
		var side := float(maxi(x1 - x0 + 1, y1 - y0 + 1))
		var cx := x0 + (x1 - x0 + 1) * 0.5
		var cy := c * cell + y0 + (y1 - y0 + 1) * 0.5
		var rx: float = clampf(cx - side * 0.5, 0.0, c * cell + cell - side)
		var ry: float = clampf(cy - side * 0.5, c * cell, c * cell + cell - side)
		out.append(Rect2(rx, ry, side, side))
	return out
