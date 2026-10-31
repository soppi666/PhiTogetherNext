class_name PzApi
extends Node
## PhiZone 公开只读 API 客户端（接口形态取自其公开客户端用法，自行实现，不含官方代码）。
## GET /songs/?PerPage=&Page= → {total, perPage, data:[SongMeta]}；GET /songs/{id}/charts → 谱面列表。
## 曲绘为 webp URL，按需下载并缓存。

const BASE := "https://api.phizone.cn"
const UA := "User-Agent: PhiZoneRegularAccess"
const LEVEL_NAMES := ["EZ", "HD", "IN", "AT", "FA", "EZ+", "HD+", "IN+", "AT+"]

signal songs_loaded(page: int, songs: Array, pages: int)
signal chart_list_loaded(page: int, items: Array, pages: int)
signal search_done(items: Array)
signal charts_loaded(song_id: String, charts: Array)
signal chart_meta_done(cid: String, meta: Dictionary)  # 单谱元数据（回填老下载目录的 info.txt）
signal cover_loaded(url: String, tex: Texture2D)
## 网络失败的可读原因（手机上看不见 logcat，之前失败=页面空着，什么线索都没有）。
## 典型一次就能分层：result=9 连不上（缺 INTERNET 权限/防火墙/域名不通）、
## result=8 证书不被信任、http=4xx/5xx 才是服务端问题。
signal net_error(msg: String)
var last_error := ""

const RESULT_NAMES := {
	1: "未知错误", 2: "连接被断开", 3: "URL 非法", 4: "重定向过多", 5: "请求被中止",
	6: "缓存请求失败", 7: "TLS 握手失败", 8: "服务器证书不被信任",
	9: "连不上服务器（无网络权限/防火墙/域名不通）", 10: "连接超时", 11: "请求头过大",
}

func _fail(what: String, result: int, code: int, url: String) -> void:
	if result > 0 and RESULT_NAMES.has(result):
		what = String(RESULT_NAMES[result])
	last_error = "%s（http=%d result=%d）%s" % [what, code, result, url.get_slice("?", 0)]
	push_warning("PzApi: " + last_error)
	net_error.emit(last_error)

var _covers: Dictionary = {}
var _pend := 0
var _acc: Array = []
var _acc_seen := {}
var _stage2: Array = []      # 级联第二优先级：整短语零命中时才发（防 "of" 这类碎词污染结果）
var _search_max_diff := 18.0

func cover_cached(url: String) -> Texture2D:
	var t: Texture2D = _covers.get(url)
	return t

func load_songs(page := 1, query := "", order := "", desc := false) -> void:
	var url := "%s/songs/?PerPage=30&Page=%d%s" % [BASE, page, _q(query)]
	if order != "":
		url += "&Order=%s&Desc=%s" % [order, "true" if desc else "false"]
	_http_get(url, {"kind": "songs", "page": page})

## 谱面维度列表：服务端难度过滤（0~18）+ 排序 + #话题搜索；每条自带 song 元数据。
## 一页=30 首不重复曲：服务端一页 30 条谱面去重后常不足 30，连续补拉服务端页填满缓冲再出。
var _buf: Array = []
var _buf_ids := {}
var _buf_srv_pages := 0
var _buf_total := 0
var _buf_done := false
var _buf_busy := false
var _buf_key := ""
var _buf_want_page := 1

func load_chart_list(page := 1, query := "", max_diff := 18.0, order := "", desc := false) -> void:
	var key := "%s|%s|%s|%s" % [query, str(max_diff), order, str(desc)]
	if page == 1 or key != _buf_key:
		_buf_key = key
		_buf.clear()
		_buf_ids.clear()
		_buf_srv_pages = 0
		_buf_done = false
	_buf_want_page = page
	_buf_pump()

func _buf_url(srv_page: int) -> String:
	var order := ""
	var desc := false
	var max_diff := 18.0
	var query := ""
	var parts := _buf_key.split("|")
	query = String(parts[0])
	max_diff = float(parts[1])
	order = String(parts[2])
	desc = String(parts[3]) == "true"
	var url := "%s/charts/?PerPage=30&Page=%d%s" % [BASE, srv_page, _q(query)]
	if max_diff < 18.0:
		url += "&MaxDifficulty=%s" % str(max_diff)
	if order != "":
		url += "&Order=%s&Desc=%s" % [order, "true" if desc else "false"]
	return url

func _buf_pump() -> void:
	if _buf_busy:
		return
	var need := _buf_want_page * 30
	if _buf.size() >= need or _buf_done:
		var start := (_buf_want_page - 1) * 30
		var part: Array = _buf.slice(start, mini(start + 30, _buf.size()))
		var est := _buf.size() if _buf_done else _buf_total
		var pages: int = maxi(ceili(float(est) / 30.0), 1)
		chart_list_loaded.emit(_buf_want_page, part, pages)
		return
	_buf_busy = true
	_buf_srv_pages += 1
	_http_get(_buf_url(_buf_srv_pages), {"kind": "chartlist"})

func _buf_feed(j: Dictionary) -> void:
	for it in _map_charts(j.get("data", [])):
		var sid := String(it["pz_id"])
		if not _buf_ids.has(sid):
			_buf_ids[sid] = true
			_buf.append(it)
	_buf_total = int(j.get("total", 0))
	_buf_done = not bool(j.get("hasNext", false))
	_buf_busy = false
	_buf_pump()

## 宽搜索：空格/"-" 拆词；无分隔的长词（中文）再切 2-gram 兜底（"今天不是明天"→"今天"）。
## 每候选双路（原词 + #话题）并发查，合并去重后一次回报。
func search_charts(query: String, max_diff := 18.0) -> void:
	_acc.clear()
	_acc_seen.clear()
	_search_max_diff = max_diff
	var q := query.strip_edges()
	var parts: Array = []
	for t in query.split(" "):
		for p in String(t).split("-"):
			if String(p).strip_edges() != "":
				parts.append(String(p).strip_edges())
	# 第一优先级 = 完整短语；零命中才降级到分词/2-gram（旧版从不查整短语，
	# "Echoes of Memoria" 被拆成 Echoes/of/Memoria+碎片，只剩第一张卡碰巧是对的）
	var first: Array = []
	if q != "":
		first.append(q)
	var second: Array = []
	for p in parts:
		if not first.has(p) and not second.has(p):
			second.append(p)
		# 2-gram 只对含 CJK 的长词有意义（无词边界）；ASCII 切 "Ec"/"ch" 纯噪音
		if String(p).length() > 3 and _has_cjk(String(p)):
			for i in String(p).length() - 1:
				if second.size() >= 8:
					break
				var g2: String = String(p).substr(i, 2)
				if not second.has(g2):
					second.append(g2)
	if first.is_empty():
		first = second
		second = []
	_stage2 = second
	_fire_all(first)

static func _has_cjk(s: String) -> bool:
	for c in s:
		if c.unicode_at(0) >= 0x3000:  # 假名/汉字/谚文/全角标点
			return true
	return false

func _fire_all(cands: Array) -> void:
	_pend = cands.size() * 2
	for v in cands:
		for w in [v, "#" + String(v)]:
			var url := "%s/charts/?PerPage=30&Page=1%s" % [BASE, _q(String(w))]
			if _search_max_diff < 18.0:
				url += "&MaxDifficulty=%s" % str(_search_max_diff)
			_http_get(url, {"kind": "searchacc"})

func _q(query: String) -> String:
	if query.strip_edges() == "":
		return ""
	return "&Search=" + query.strip_edges().uri_encode()

func load_charts(song_id: String) -> void:
	_http_get("%s/songs/%s/charts?Order=difficulty&PerPage=20" % [BASE, song_id],
		{"kind": "charts", "song_id": song_id})

## 单谱元数据（GET /charts/{id}）：回填"修复前下载、目录里没 info.txt"的老谱
func load_chart_meta(cid: String) -> void:
	_http_get("%s/charts/%s" % [BASE, cid], {"kind": "chartmeta", "cid": cid})

signal chart_file_done(chart_id: String, path: String, ok: bool)
signal raw_file_done(dest: String, ok: bool)
signal asset_list_done(chart_id: String, assets: Array)  # [{name, file}]，失败也 emit([]) 保证流程不卡

## 拉取 /charts/<id>/assets（extra.json/线贴图等谱面附加资产），异步 emit asset_list_done。
## 服务端分页（PerPage 默认 30）：テレパシ 有 94 个资产=4 页，只取第一页会让
## 63 张线贴图缺失（用户报"很多图片都没在判定线上"）。逐页翻到 hasNext=false。
var _asset_acc: Array = []
var _asset_seen := {}
var _asset_cid := ""

func fetch_assets(chart_id: String) -> void:
	_asset_acc = []
	_asset_seen = {}
	_asset_cid = chart_id
	_asset_page(chart_id, 1)

func _asset_page(chart_id: String, page: int) -> void:
	# 这条请求是"进舞台前最后一道门"，必须自带超时：手机上它和 4 路并发下载抢带宽，
	# 8s 看门狗先到期的话清单就被丢了 → 整谱附加资源一个都不下（移动端实测症状）。
	# HTTPRequest.timeout 到点会以 RESULT_TIMEOUT 回调，走既有的失败分支立刻放行流程。
	_http_get("%s/charts/%s/assets?PerPage=100&Page=%d" % [BASE, chart_id, page],
		{"kind": "assetlist", "chart_id": chart_id, "page": page}, 12.0)

## 下载任意直链（音频 ogg 等）到 dest
## 在途请求与已完成字节都记账：按钮上的进度要"慢慢累加"，不能按文件数 0/33/66/100 跳。
var _raw_reqs := {}          # dest -> HTTPRequest（在途）
var _raw_bytes_done := 0

func reset_raw_progress() -> void:
	_raw_reqs.clear()
	_raw_bytes_done = 0

## 0..1：已下字节 / 总字节（在途 + 已完成）。拿不到 Content-Length 时返回 -1（调用方退回按文件数）
func raw_frac() -> float:
	if _raw_reqs.is_empty():
		return -1.0
	var have := _raw_bytes_done
	var total := _raw_bytes_done
	var known := true
	for k in _raw_reqs:
		var r: HTTPRequest = _raw_reqs[k]
		if not is_instance_valid(r):
			continue
		var d := r.get_downloaded_bytes()
		if d > 0:
			have += d
		var t := r.get_body_size()
		if t > 0:
			total += t
		else:
			known = false
	if not known or total <= 0:
		return -1.0
	return clampf(float(have) / float(total), 0.0, 1.0)

func download_raw(url: String, dest: String) -> void:
	if url == "":
		raw_file_done.emit(dest, false)
		return
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var r := _http_get(url, {"kind": "rawfile", "dest": dest})
	if r != null:
		_raw_reqs[dest] = r

## 下载 .pez 谱面包到 user://pz/<id>.pez（file 字段 = 直链，事实取自 PhiTogether phizone api 层）
## 当前在下的 .pez 请求（选曲页那颗下载钮的进度环每帧读它）
var _dl_req: HTTPRequest = null

## 0..1；没有总量（无 Content-Length）或没在下时返回 -1
func dl_fraction() -> float:
	if _dl_req == null or not is_instance_valid(_dl_req):
		return -1.0
	var total := _dl_req.get_body_size()
	var have := _dl_req.get_downloaded_bytes()
	if total <= 0 or have < 0:
		return -1.0
	return clampf(float(have) / float(total), 0.0, 1.0)

func download_chart(chart_id: String, url: String) -> void:
	var dest := "user://pz/%s.pez" % chart_id
	if FileAccess.file_exists(dest):
		chart_file_done.emit(chart_id, dest, true)
		return
	DirAccess.make_dir_recursive_absolute("user://pz")
	var r := _http_get(url, {"kind": "chartfile", "chart_id": chart_id, "dest": dest})
	if r != null:
		_dl_req = r

func load_cover(url: String) -> void:
	if url == "" or _covers.has(url):
		return
	_http_get(url, {"kind": "cover", "url": url})

## timeout>0 时给这一条请求装上引擎级超时（只有"门控类"的小请求需要：大文件下载慢是正常，
## 装超时会把好端端的传输掐断）。0 = 不限（Godot 默认）。
func _http_get(url: String, meta: Dictionary, timeout: float = 0.0) -> HTTPRequest:
	meta["url"] = url
	var r := HTTPRequest.new()
	if timeout > 0.0:
		r.timeout = timeout
	add_child(r)
	r.request_completed.connect(_on_done.bind(meta, r), CONNECT_ONE_SHOT)
	var e := r.request(url, [UA])
	if e != OK:
		_fail("请求发不出去 err=%d" % int(e), 0, 0, url)
		r.queue_free()
		return null
	return r

func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray,
	meta: Dictionary, r: HTTPRequest) -> void:
	if r == _dl_req:
		_dl_req = null
	if String(meta.get("kind", "")) == "rawfile":
		var dpath := String(meta.get("dest", ""))
		if _raw_reqs.has(dpath):
			_raw_reqs.erase(dpath)
		_raw_bytes_done += body.size()
	r.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		# 服务端偶发 5xx：1s 后自动重试，最多 2 次
		if code >= 500 and int(meta.get("tries", 0)) < 2:
			meta["tries"] = int(meta.get("tries", 0)) + 1
			get_tree().create_timer(1.0).timeout.connect(_http_get.bind(String(meta["url"]), meta))
			return
		_fail("拉取失败", result, code, String(meta.get("url", "")))
		if String(meta.get("kind", "")) == "assetlist":
			# 附加资产是可选的，失败继续进游戏：有几页发几页
			if String(meta.get("chart_id")) == _asset_cid:
				_asset_cid = ""
				asset_list_done.emit(String(meta.get("chart_id")), _asset_acc)
		return
	last_error = ""  # 任一请求成功即清掉旧失败提示（重试成功后不该还挂着红字）
	match String(meta.get("kind", "")):
		"assetlist":
			if String(meta.get("chart_id")) != _asset_cid:
				return  # 用户已换谱面：陈旧页丢弃
			var jassets: Dictionary = _json(body)
			for a in jassets.get("data", []):
				if typeof(a) != TYPE_DICTIONARY:
					continue
				var nm := _name_of(a.get("name", ""))
				var fu := _name_of(a.get("file", ""))
				if nm == "" or fu == "" or ("/" in nm or "\\" in nm or ".." in nm):
					continue
				if _asset_seen.has(nm):
					continue
				_asset_seen[nm] = true
				_asset_acc.append({"name": nm, "file": fu})
			if bool(jassets.get("hasNext", false)) and int(meta.get("page", 1)) < 20:
				_asset_page(String(meta.get("chart_id")), int(meta.get("page", 1)) + 1)
				return
			_asset_cid = ""
			asset_list_done.emit(String(meta.get("chart_id")), _asset_acc)
		"rawfile":
			var rf := FileAccess.open(String(meta["dest"]), FileAccess.WRITE)
			var rok := false
			if rf != null:
				rf.store_buffer(body)
				# 必须先 flush+close 再发信号：emit 同步进入 _on_raw_file→_launch_stage，
				# 舞台会立刻读这个文件——stdio 缓冲未落盘时读到的是截断内容（曲绘首开丢图真因）
				rf.flush()
				rf.close()
				rok = true
			raw_file_done.emit(String(meta["dest"]), rok)
		"chartfile":
			var fa := FileAccess.open(String(meta["dest"]), FileAccess.WRITE)
			var ok := false
			if fa != null:
				fa.store_buffer(body)
				fa.flush()
				fa.close()
				ok = true
			chart_file_done.emit(String(meta.get("chart_id")), String(meta["dest"]), ok)
		"songs":
			var j := _json(body)
			if j.is_empty():
				return
			var out: Array = []
			for s in j.get("data", []):
				# chartLevels: levelType 0..8 各档谱面数 → 存在的档位表 + 最高档徽章
				var badge := ""
				var tiers: Array = []
				var maxtier := -1
				for lv in s.get("chartLevels", []):
					var lt0: int = int(lv.get("levelType", -1))
					if int(lv.get("count", 0)) > 0:
						var tc: String = LEVEL_NAMES[lt0] if lt0 < LEVEL_NAMES.size() else "LV"
						tiers.append(tc)
						maxtier = lt0
						badge = tc
				out.append({
					"pz_id": _name_of(s.get("id")),
					"title": _name_of(s.get("title")),
					"artist": _name_of(s.get("authorName", "")),
					"code": badge, "level": 0,
					"bpm": int(s.get("bpm", 0.0)),
					"notes": 0,
					"designer": "",
					"cover_url": _name_of(s.get("illustration")),
					# 试听要的是音频直链。浏览列表这一支原来没映射 file，于是 PZ 页里
					# 点任何一首都不会响（只有搜索结果那条 _map_charts 带了 song_file）
					# ——用户 2026-10-29："某些音乐无法播放"。
					"song_file": _name_of(s.get("file")),
					"diffs": [],
					"plays": int(s.get("playCount", 0)),
					"likes": int(s.get("likeCount", 0)),
					"tiers": tiers,
					"maxtier": maxtier,
				})
			var per: int = maxi(int(j.get("perPage", 30)), 1)
			var pages: int = maxi(ceili(float(j.get("total", 0)) / float(per)), 1)
			songs_loaded.emit(int(meta.get("page", 1)), out, pages)
		"chartlist":
			var j := _json(body)
			if j.is_empty():
				_buf_busy = false
				return
			_buf_feed(j)
		"searchacc":
			var j := _json(body)
			for it in _map_charts(j.get("data", [])):
				var k := String(it["pz_id"])
				if not _acc_seen.has(k):
					_acc_seen[k] = true
					_acc.append(it)
			_pend -= 1
			if _pend <= 0:
				if _acc.is_empty() and not _stage2.is_empty():
					var s2: Array = _stage2  # 整短语零命中 → 降级分词宽搜（局部变量：数组无 set_type，直读成员会触发类型推断报错）
					_stage2 = []
					_fire_all(s2)
					return
				search_done.emit(_acc)
		"charts":
			var j := _json(body)
			if j.is_empty():
				return
			var cs: Array = []
			for c in j.get("data", []):
				var lt: int = int(c.get("levelType", 0))
				var au := _clean_author(_name_of(c.get("authorName", "")))
				# 难度代码走测试1的 DiffCode（"Fake"→FA），无名时按 levelType 表兜底
				var nm := _name_of(c.get("level", ""))
				var lcode := _level_code(nm, lt)
				cs.append({
					"code": lcode,
					"level": int(float(c.get("difficulty", 0.0))),  # 等级=难度向下取整（16.5→Lv.16，Phigros 惯例；roundf 会进成 17）
					"designer": au,
					"notes": int(c.get("noteCount", 0)),
					"id": _name_of(c.get("id")),
					"file": _name_of(c.get("file")),
					"playable": _name_of(c.get("file")) != "",
				})
			charts_loaded.emit(String(meta.get("song_id")), cs)
		"chartmeta":
			var j := _json(body)
			var cd: Variant = j.get("data", j)
			var out := {}
			if typeof(cd) == TYPE_DICTIONARY and (cd as Dictionary).has("levelType"):
				var c2: Dictionary = cd
				var s2: Dictionary = c2.get("song", {})
				var code2 := _level_code(_name_of(c2.get("level", "")), int(c2.get("levelType", 0)))
				out = {
					"name": _name_of(s2.get("title", "")),
					"artist": _clean_author(_name_of(s2.get("authorName", ""))),
					"level": "%s Lv.%d" % [code2, int(float(c2.get("difficulty", 0.0)))],
					"charter": _clean_author(_name_of(c2.get("authorName", ""))),
				}
			chart_meta_done.emit(String(meta.get("cid", "")), out)
		"cover":
			# 按魔数选解码器：PT/PZ 的曲绘 URL 后缀不可信（jpg 可能是 webp/png），
			# 逐个 load_* 失败会往控制台刷 ERR_FILE_CORRUPT，手机上还会白费解码。
			var img := Image.new()
			var err := ERR_FILE_UNRECOGNIZED
			if body.size() >= 12 and body[0] == 0x52 and body[1] == 0x49 					and body[8] == 0x57 and body[9] == 0x45:
				err = img.load_webp_from_buffer(body)
			elif body.size() >= 8 and body[0] == 0x89 and body[1] == 0x50 					and body[2] == 0x4E and body[3] == 0x47:
				err = img.load_png_from_buffer(body)
			elif body.size() >= 3 and body[0] == 0xFF and body[1] == 0xD8:
				err = img.load_jpg_from_buffer(body)
			if err != OK:
				push_warning("PzApi: undecodable cover %s" % String(meta.get("url")))
				return
			var tex := SongCard.make_from_image(img)  # 建纹理顺手登记源图：卡片烘焙就不用再从显存取像素
			_covers[String(meta.get("url"))] = tex
			cover_loaded.emit(String(meta.get("url")), tex)

## 谱面行 → 卡片数据：同一曲只留一张卡（徽章取最高档，tiers 记全部档）
func _map_charts(data: Array) -> Array:
	var by_song := {}
	var order: Array = []
	for c in data:
		var s: Dictionary = c.get("song", {})
		var sid := String(s.get("id", ""))
		if sid == "":
			continue
		var lt: int = int(c.get("levelType", 0))
		var lcode: String = _level_code(_name_of(c.get("level", "")), lt)
		var lvl := int(float(c.get("difficulty", 0.0)))  # 难度等级向下取整（同 /songs 映射）
		var diff := {
			"code": lcode,
			"level": lvl,
			"designer": _clean_author(_name_of(c.get("authorName", ""))),
			"notes": int(c.get("noteCount", 0)),
			"id": _name_of(c.get("id")),
			"file": _name_of(c.get("file")),
			"playable": _name_of(c.get("file")) != "",
		}
		if by_song.has(sid):
			var prev: Dictionary = by_song[sid]
			(prev["tiers"] as Array).append(lcode)
			(prev["diffs"] as Array).append(diff)
			if lt > int(prev["maxtier"]):
				prev["code"] = lcode
				prev["level"] = lvl
				prev["maxtier"] = lt
				prev["designer"] = _clean_author(_name_of(c.get("authorName", "")))
				prev["notes"] = int(c.get("noteCount", 0))
			continue
		by_song[sid] = {
			"pz_id": sid,
			"title": _name_of(s.get("title")),
			"artist": _name_of(s.get("authorName", "")),
			"code": lcode,
			"level": lvl,
			"bpm": int(s.get("bpm", 0.0)),
			"notes": int(c.get("noteCount", 0)),
			"designer": _clean_author(_name_of(c.get("authorName", ""))),
			"cover_url": _name_of(s.get("illustration")),
			"song_file": _name_of(s.get("file")),
			"diffs": [diff],
			"plays": int(s.get("playCount", 0)),
			"likes": int(s.get("likeCount", 0)),
			"tiers": [lcode],
			"maxtier": lt,
		}
		order.append(sid)
	var out: Array = []
	for sid in order:
		out.append(by_song[sid])
	return out

## [PZUser:<uid>:<显示名>:<tag>] → 显示名
## authorName 可能是字符串、数组（合作）或用户引用字典——宽容取显示名
func _name_of(v) -> String:
	match typeof(v):
		TYPE_NIL:
			return ""
		TYPE_STRING:
			return v
		TYPE_INT, TYPE_FLOAT:
			return str(int(v)) if typeof(v) == TYPE_INT else str(v)
		TYPE_ARRAY:
			var parts: Array[String] = []
			for it in v:
				parts.append(_name_of(it))
			return " × ".join(parts)
		TYPE_DICTIONARY:
			return _name_of(v.get("name", v.get("displayName", "")))
	return ""

func _clean_author(au: String) -> String:
	if au.begins_with("[PZUser:"):
		var parts := au.split(":")
		if parts.size() > 2:
			return parts[2]
	return au

## 难度代码：测试1 DiffCode 优先，无名按 levelType 表兜底
func _level_code(nm: String, lt: int) -> String:
	if nm != "":
		return DiffCode.to_code(nm)
	return LEVEL_NAMES[lt] if lt < LEVEL_NAMES.size() else "LV"

func _json(body: PackedByteArray) -> Dictionary:
	var j: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(j) != TYPE_DICTIONARY:
		push_warning("PzApi: bad JSON payload")
		return {}
	return j
