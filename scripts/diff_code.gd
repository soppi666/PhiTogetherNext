class_name DiffCode
extends RefCounted
## 难度名 → 显示码：**只有表里认得的英文难度词**才压成两字母码；其余一律原样显示。
## （旧规则"未收录就取前两字母大写"把自定义难度名 Pixel 变成了 PI —— PhiZone 的 level
## 允许是任意名字，截断等于改名。含非拉丁字符的名字本来就原样显示。）纯逻辑，无节点依赖。

const TABLE := {
	"easy": "EZ",
	"normal": "NM",
	"hard": "HD",
	"extreme": "EX",
	"exhard": "EX",
	"insane": "IN",
	"inferno": "IF",
	"hell": "HL",
	"master": "MS",
	"another": "AT",
	"legacy": "LG",
	"present": "PR",
}

## 归一化：小写、只保留字母和数字（"Ex Hard" / "ex_hard" / "EXHARD" 同一键）
static func normalize(v: String) -> String:
	var out := ""
	for c in v.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
	return out

## 难度名部分："キメラ Lv.17" → "キメラ"；"AT Lv.15" → "AT"；无 " Lv" 分隔则原样返回
static func _name_part(t: String) -> String:
	var low := t.to_lower()
	var i := low.find("lv")
	while i != -1:
		# 只认词首的 lv（"Slayer"/"Evilvein" 内嵌 lv 不切）
		if i == 0 or t[i - 1] == " " or t[i - 1] == "." or t[i - 1] == "_":
			return t.substr(0, i).strip_edges()
		i = low.find("lv", i + 2)
	return t.strip_edges()

static func to_code(display_name: String) -> String:
	var t := display_name.strip_edges()
	if t == "":
		return t
	var name := _name_part(t)
	# 纯 ASCII 字母（可含空格/数字/符号分隔）→ 两字母码
	var only_ascii := true
	for c in name:
		var o := c.unicode_at(0)  # String 无 unicode_scalar()；单字符码点=unicode_at(0)
		if o > 127:
			only_ascii = false
			break
	if not only_ascii:
		return name  # 非英文难度名：显示原本的名字
	var key := normalize(name)
	if TABLE.has(key):
		var code: String = TABLE[key]
		return code
	return name  # 表里没有的就是自定义难度名（Pixel / Napthusiasm / +∞…）：原名显示，不截断

## 两字母码是否"查无此名"：TABLE 的码值 + PZ levelType 兜底名表（FA/LV）都在这里，
## 再加实测确认过的真难度名（SP=服务器回来的也是 SP，不是截断）。
## 用途=回填过滤：已知码（IN/AT/HD…）大概率就是真难度名，不必为它发一次服务器请求；
## 未知码（旧规则把 Pixel 截成的 PI、Chimera 截成的 CH）才可能是截断残留，值得核对。
## "EZ+" 这类三字符是 levelType 真名，长度!=2 → 直接判已知。
const KNOWN_CODES := ["EZ", "NM", "HD", "EX", "IN", "IF", "HL", "MS", "AT", "LG", "PR", "FA", "LV", "SP"]

static func is_unknown_code(level_text: String) -> bool:
	var np := _name_part(level_text)
	if np.length() != 2 or np != np.to_upper():
		return false
	return not KNOWN_CODES.has(np)

## 截断残留判据：cached 是"旧规则"（未收录就取前两字母大写）写进 info.txt /
## chart_meta.json 的值，fresh 是修好后从服务器重新算出来的值。
## 判据收得很窄，三条都成立才认为是同一难度的修复前后两版：
## ① cached 的难度名部分是两字母全大写码 ② fresh 的名字更长 ③ fresh 以它开头（忽略大小写）。
## 其余情况一律不动（真两字母难度如 IN/AT 不会被误改：服务器返回的同名不"更长"）。
static func is_truncation_of(cached: String, fresh: String) -> bool:
	var c := _name_part(cached)
	var f := _name_part(fresh)
	if c.length() != 2 or c != c.to_upper():
		return false
	if f.length() <= 2:
		return false
	return f.to_lower().begins_with(c.to_lower())
