class_name ChartInfo
extends RefCounted
## 谱包元数据的统一读取口：info.txt / info.yml / info.csv 三种都在这归成一整套键，
## 选曲卡片、占位条目、游玩内 HUD 三条链共用一份实现（以前各自只认 info.txt，
## 于是 "测试.json + 测试.mp3 + info.csv" 那种包进来既没曲名也没伴奏）。
##
## 键名取现实包里真实出现过的写法（qa-official/IN.txt、qa-rpe/info.txt、
## bad apple/info.txt、RTX 20000 的 info.csv）：
##   Name / Song / Picture / Level / Composer / Illustrator / Charter / By / Chart
## 归一化输出键：name composer illustrator level charter song picture chart bpm

## 一个目录里的候选文件，按优先级排：先出现的键赢（同 info.txt 内部的"先到先得"一致）
const FILES := ["info.txt", "info.yml", "info.yaml", "info.csv"]

## 别名 → 规范键。小写比对，允许各打包工具的不同叫法。
const ALIAS := {
	"name": "name",
	"title": "name",
	"song": "song",          # 乐曲文件名
	"music": "song",         # info.csv 里 Music=测试.mp3 同样是文件，不是作曲家
	"musicfile": "song",
	"audio": "song",
	"picture": "picture",    # 封面文件名
	"image": "picture",
	"imagefile": "picture",
	"level": "level",
	"diff": "level",
	"difficulty": "level",
	"composer": "composer",
	"artist": "composer",
	"charter": "charter",
	"designer": "charter",   # info.csv 的 Designer=谱师
	"by": "charter",         # rpe 包习惯写 By:
	"illustrator": "illustrator",
	"chart": "chart",        # 谱面文件名（.json/.pec/.pe）
	"previewtime": "preview_time",
	"bpm": "bpm",
}

## 目录级：把三种 info 依次读进来合并（已有值的键不被后面格式覆盖）
static func read_dir(dir: String) -> Dictionary:
	var out := {}
	for f in FILES:
		var d := read_file(dir.path_join(f))
		for k in d:
			if String(out.get(k, "")) == "" and String(d[k]) != "":
				out[k] = d[k]
	return out

static func read_file(path: String) -> Dictionary:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return {}
	var txt := fa.get_as_text()
	fa.close()
	return parse_text(txt, path.get_file())

## 已经有文本了（zip 里的成员、下载到的字符串）就走这里，别先落盘再读一遍
static func parse_text(txt: String, fname: String = "info.txt") -> Dictionary:
	var t := txt.strip_edges()
	if t == "":
		return {}
	if t.begins_with("{"):
		return _from_json(t)          # 少数包把 info 写成 JSON
	if fname.get_extension().to_lower() == "csv":
		return parse_csv(t)
	return parse_kv(t)

## 规范键 → info.txt 写法（导入时把 csv/yml 的元数据固化成 info.txt 用这一份表）
const OUT_KEYS := {
	"name": "Name", "level": "Level", "song": "Song", "picture": "Picture",
	"composer": "Composer", "illustrator": "Illustrator", "charter": "Charter",
	"chart": "Chart", "bpm": "Bpm", "preview_time": "PreviewTime",
}

static func to_info_txt(im: Dictionary) -> String:
	var lines := []
	for k in OUT_KEYS:
		var v := String(im.get(k, ""))
		if v != "":
			lines.append(String(OUT_KEYS[k]) + ": " + v)
	return "\n".join(lines) + ("\n" if not lines.is_empty() else "")

## info.txt / info.yml 共用：扁平 "Key: Value"。
## yml 的 `key: "value"` 与注释行（# 开头）在这里一并处理；真正的嵌套 yml
## 打包工具没见过，若出现会退化成"取第一个标量"，不会崩。
static func parse_kv(txt: String) -> Dictionary:
	var out := {}
	for ln in txt.split("\n"):
		var s := ln.strip_edges()
		if s == "" or s.begins_with("#") or s == "---":
			continue
		var i := s.find(":")
		if i <= 0:
			continue
		var k := canon(s.substr(0, i))
		var v := s.substr(i + 1).strip_edges()
		if v.begins_with("#"):
			v = ""  # 空注释占位行（bad apple 的 info.txt 首行就是 "#"）
		v = _unquote(v)
		if k == "" or v == "":
			continue
		if String(out.get(k, "")) == "":
			out[k] = v
	return out

## info.csv：首行是英文表头，次行常是中文名，末行才是取值。
## 按表头列名下标取值（不写死列序），并跳过"整行都是表头中文翻译"的那种行。
static func parse_csv(txt: String) -> Dictionary:
	var rows: Array = []
	for ln in txt.split("\n"):
		var s := ln.strip_edges()
		if s != "":
			rows.append(s.split(","))
	if rows.size() < 2:
		return {}
	var keys: PackedStringArray = rows[0]
	var out := {}
	var header_hit := false
	for r in range(1, rows.size()):
		var rowv: PackedStringArray = rows[r]
		# 认数据行：至少有一列能按表头映射出非空值，且这行不等于表头本身
		var cand := {}
		for c in range(mini(keys.size(), rowv.size())):
			var k := canon(String(keys[c]))
			var v := _unquote(String(rowv[c]).strip_edges())
			if k != "" and v != "":
				cand[k] = v
		if cand.is_empty():
			continue
		# 中文名行：每列都正好是该列键的翻译，长度与表头一致且没有任何文件扩展名/数字
		if not header_hit:
			header_hit = true
			if _looks_like_label_row(rowv, keys):
				header_hit = true
				continue
		for k in cand:
			if String(out.get(k, "")) == "":
				out[k] = cand[k]
	return out

static func _looks_like_label_row(rowv: Array, keys: Array) -> bool:
	# 判定"第二行是中文列名"的依据：这一行的每个单元都只有 1~4 字符、不含 '.'，
	# 且列数与表头一致。数据行几乎必然含文件名（带点）或 "EZ Lv.0" 这类串。
	if rowv.size() != keys.size():
		return false
	for c in rowv.size():
		var s := String(rowv[c]).strip_edges()
		if s == "" or s.length() > 4 or s.contains("."):
			return false
	return true

static func _from_json(txt: String) -> Dictionary:
	var j: Variant = JSON.parse_string(txt)
	if typeof(j) != TYPE_DICTIONARY:
		return {}
	var out := {}
	for k in (j as Dictionary):
		var ck := canon(String(k))
		var v := String((j as Dictionary)[k])
		if ck != "" and v != "":
			out[ck] = v
	return out

static func canon(k: String) -> String:
	var key := k.strip_edges().to_lower().replace(" ", "").replace("_", "")
	return String(ALIAS.get(key, ""))

static func _unquote(v: String) -> String:
	var s := v.strip_edges()
	if s.length() >= 2 and ((s.begins_with("\"") and s.ends_with("\""))
			or (s.begins_with("'") and s.ends_with("'"))):
		return s.substr(1, s.length() - 2)
	return s
