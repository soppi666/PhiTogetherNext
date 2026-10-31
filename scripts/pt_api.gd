class_name PtApi
extends Node
## PhiTogether 社区谱面库（PTC）只读客户端。
## 数据源 = https://ptc.realtvop.top/pt_songs.json（结构 {count,next,previous,results}；
## 每条 = 歌曲 + charts[]，URL 都是直链）。主站 chart.phitogether.fun 是同一份数据的别名，
## 这里用 ptc.realtvop.top（PT 客户端自己也是把 chart.phitogether.fun 换成它）。
## 本类只做列表/映射；下载与落盘由 game.gd 走 PzApi.download_raw 的既有队列。

signal songs_loaded(items: Array)
signal net_error(msg: String)

const BASE := "https://ptc.realtvop.top"
const UA := "User-Agent: PhiTogetherNext"

var items: Array = []
var loading := false
var last_error := ""
var _main_items: Array = []
var _want_special := false
var _is_special := false

const SPECIAL_URL := BASE + "/chapters/special.json"

func load_songs() -> void:
	# 特殊章节不是独立页：拉完普通列表后再拉 chapters/special.json，
	# 给这些条目打 #特殊 标并与普通列表合并（搜索 #特殊 即可）。
	_want_special = true
	load_list(BASE + "/pt_songs.json")

## 章节列表：chapters.json → [{id,name:{zh-cn},songsListUrls:[...]}]；
## 普通页 = pt_songs.json，特殊页 = chapters/special.json（故事版）。
func load_list(url: String) -> void:
	if loading:
		return
	loading = true
	var r := HTTPRequest.new()
	add_child(r)
	r.request_completed.connect(_on_done.bind(r), CONNECT_ONE_SHOT)
	var e := r.request(url, [UA])
	if e != OK:
		loading = false
		last_error = "PT 谱面库请求发不出去 err=%d" % int(e)
		net_error.emit(last_error)
		r.queue_free()

func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray,
		r: HTTPRequest) -> void:
	loading = false
	r.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		if _is_special:
			# 特殊章节挂了不该拖垮主列表：主列表已经拿到就先用主列表
			_is_special = false
			last_error = "PT 特殊章节拉取失败（http=%d）" % code
			push_warning(last_error)
			songs_loaded.emit(_main_items)
			return
		last_error = "PT 谱面库连接失败（http=%d result=%d）" % [code, result]
		net_error.emit(last_error)
		return
	var txt := body.get_string_from_utf8()
	var j: Variant = JSON.parse_string(txt)
	if j is not Dictionary:
		last_error = "PT 谱面库返回的不是对象"
		net_error.emit(last_error)
		return
	items = map_songs(j.get("results", []))
	if _want_special:
		_want_special = false
		_main_items = items
		_is_special = true
		loading = false
		load_list(SPECIAL_URL)
		return
	if _is_special:
		_is_special = false
		var by_id := {}
		var out: Array = []
		for dv in _main_items:
			var d: Dictionary = dv
			by_id[String(d.get("pt_id", ""))] = d
			out.append(d)
		for dv2 in items:
			var sp: Dictionary = dv2
			var pid := String(sp.get("pt_id", ""))
			if by_id.has(pid):
				var ex: Dictionary = by_id[pid]
				# 特殊章节的 URL 走 chart.phitogether.fun（主线镜像 ptc 上缺 mp4/曲绘）；
				# 同 ID 时以特殊章节的直链为准，否则故事版条目会下到 404 页。
				ex["song_file"] = sp.get("song_file", ex.get("song_file", ""))
				ex["cover_url"] = sp.get("cover_url", ex.get("cover_url", ""))
				# 难度取**并集**：原来直接拿特殊章节那份整份替换，主线列了 4 档而
				# 故事版只带 3 档时，卡片就凭空少一个难度（用户 2026-10-28："明明有 4 个
				# 难度，结果只显示了 3 个"）。同档以特殊章节的条目为准（直链更可信）。
				var merged: Array = []
				var at := {}
				for md in (ex.get("diffs", []) as Array):
					at[_diff_key(md)] = merged.size()
					merged.append(md)
				for sd in (sp.get("diffs", []) as Array):
					var k := _diff_key(sd)
					if at.has(k):
						merged[int(at[k])] = sd   # 同档：特殊章节的直链覆盖主线
					else:
						at[k] = merged.size()
						merged.append(sd)
				ex["diffs"] = merged
				ex["pt_song"] = sp.get("pt_song", ex.get("pt_song", {}))
				var ts: Array = ex.get("tags", [])
				if not ts.has("#特殊"):
					ts.append("#特殊")
				ex["tags"] = ts
			else:
				sp["tags"] = ["#特殊"]
				out.append(sp)
				by_id[pid] = sp
		print("QA-PT songs=", out.size(), " special tagged")
		songs_loaded.emit(out)
		return
	print("QA-PT songs=", items.size())
	songs_loaded.emit(items)

## 同一难度的判据：难度名 + 等级（PT 的 diffs 里就这两个字段稳定）
static func _diff_key(d: Variant) -> String:
	var dd := d as Dictionary
	return "%s|%d" % [String(dd.get("code", "")).strip_edges(), int(dd.get("level", 0))]

## 服务端 meta.json → 选曲卡片/难度胶囊结构（字段名与 PzApi._map_charts 对齐）
static func map_songs(results: Array) -> Array:
	var out: Array = []
	for sv in results:
		if sv is not Dictionary:
			continue
		var s: Dictionary = sv
		var charts: Array = s.get("charts", [])
		if charts.is_empty():
			continue
		var diffs: Array = []
		var best: Dictionary = {}
		var best_lv := -1.0
		for cv in charts:
			if cv is not Dictionary:
				continue
			var c: Dictionary = cv
			var lv := _f(c.get("difficulty", 0.0))
			var code := String(c.get("level", "")).strip_edges()
			var cd := {
				"code": code,
				"level": int(lv),
				"designer": String(c.get("charter", "")),
				"notes": _i(c.get("notes", 0)),
				"id": String(c.get("id", "")),
				"file": String(c.get("chart", "")),
				"playable": String(c.get("chart", "")) != "",
				"pt_difficulty": lv,
				"custom_res": String(c.get("customRes", s.get("customRes", ""))),
			}
			diffs.append(cd)
			if lv > best_lv:
				best_lv = lv
				best = cd
		if best.is_empty():
			continue
		out.append({
			"pt_id": String(s.get("id", "")),
			"title": String(s.get("name", "")),
			"artist": String(s.get("composer", "")),
			"illustrator": String(s.get("illustrator", "")),
			"code": String(best.get("code", "")),
			"level": _i(best.get("level", 0)),
			"bpm": _i(s.get("bpm", 0)),
			"notes": _i(best.get("notes", 0)),
			"designer": String(best.get("designer", "")),
			"cover_url": String(s.get("illustration", "")),
			"song_file": String(s.get("song", "")),
			"edition": String(s.get("edition", "")),
			"duration": String(s.get("duration", "")),
			"diffs": diffs,
			"tags": [],
			"pt_song": s,
		})
	return out

## 单曲单难度落盘目录（下载后就是普通本地谱；记录键/重下判定都用它）
static func local_dir(song: Dictionary, chart: Dictionary) -> String:
	var nm := clean_name(String(song.get("title", "PT")))
	var code := String(chart.get("code", "")).strip_edges()
	var lv := _i(chart.get("level", 0))
	var tail := ""
	if code != "":
		tail = " [%s %d]" % [code, lv] if lv > 0 else " [%s]" % code
	var id := String(chart.get("id", ""))
	if id != "" and tail == "":
		tail = " [" + id + "]"
	return "user://local/PT " + nm + tail

static func _f(v: Variant) -> float:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_STRING:
			var t := String(v).strip_edges()
			return float(t) if t.is_valid_float() else 0.0
	return 0.0

static func _i(v: Variant) -> int:
	match typeof(v):
		TYPE_INT:
			return int(v)
		TYPE_FLOAT:
			return int(v)
		TYPE_STRING:
			var t := String(v).strip_edges()
			return int(float(t)) if t.is_valid_float() else 0
	return 0

static func clean_name(s: String) -> String:
	var out := ""
	for ch in s:
		var c := String(ch)
		if c in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
			out += "_"
		elif c.unicode_at(0) < 32:
			out += " "
		else:
			out += c
	out = out.strip_edges()
	if out.length() > 48:
		out = out.substr(0, 48).strip_edges()
	return out if out != "" else "PT"
