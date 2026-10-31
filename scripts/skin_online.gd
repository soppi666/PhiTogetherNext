class_name SkinOnline
extends Node
## 在线资源包：协议照 PhiTogether 的 pt-custom（源码 src/components/renderer/
## renderers/sim-phi/components/ResourcePack/index.ts）——
##   ① GET <url>/meta.json → {name, author, res{文件名: …}, holdAtlas}
##   ② 逐个 GET <url>/<文件名>，按**魔数**分 PNG / OGG（PT 也是看魔数不看扩展名）
##   ③ 落进 user://skins/<name>/ 当一个普通包用（SkinPack 负责读，皮肤列表自动出现）
## PT 那边没有"包目录/分页/版本比对/校验和"这套东西，所以这里也不编：一个 URL、一次拉取。
##
## 请求是串行的（一条一条下）：并发 4 路在手机上会和谱面资源抢带宽，
## 而皮肤包一共十几个文件，串行也就一两秒，换来的是"失败在哪一个文件"说得清。

signal done(pack: Dictionary)
signal failed(what: String)

## 拉取进度（已下载文件数 / 总数）。meta.json 到了之后先发一次 0/N。
signal progress(have: int, total: int)

const DIR := "user://skins"

var _base := ""
var _dir := ""
var _queue: Array = []
var _total := 0
var _have := 0
var _meta_req: HTTPRequest
var _file_req: HTTPRequest
var _busy := false
var _want := ""            # 当前在拉哪个文件（队列已 pop，回调里要用）
var _dest := ""            # 指定落盘目录（谱面 customRes 用；空 = user://skins/<name>）


func _ready() -> void:
	_meta_req = HTTPRequest.new()
	_meta_req.timeout = 12.0          # 门控类小请求自己要超时（大文件下载别设，会掐断正常传输）
	_meta_req.request_completed.connect(_on_meta)
	add_child(_meta_req)
	_file_req = HTTPRequest.new()
	_file_req.timeout = 30.0
	_file_req.request_completed.connect(_on_file)
	add_child(_file_req)


## 拉一个在线包。url 可以带或不带 https://（PT 也是自动补 https://）。
func fetch(url: String, dest_dir: String = "") -> void:
	if _busy:
		failed.emit("上一次拉取还没结束")
		return
	var u := url.strip_edges().trim_suffix("/")
	if u == "":
		failed.emit("没填地址")
		return
	if u.begins_with("//"):
		u = "https:" + u
	elif not u.begins_with("http://") and not u.begins_with("https://"):
		u = "https://" + u
	_base = u
	_dest = dest_dir.strip_edges()
	_busy = true
	if _meta_req.request(u + "/meta.json") != OK:
		_busy = false
		failed.emit("请求发不出去")


func _on_meta(result: int, code: int, _heads: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_busy = false
		failed.emit("meta.json 打不开（http=%d）" % code)
		return
	var j: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (j is Dictionary):
		_busy = false
		failed.emit("meta.json 不是对象")
		return
	var plan := plan_meta(body)
	if not bool(plan.get("ok", false)):
		_busy = false
		failed.emit(String(plan.get("error", "meta.json 不可用")))
		return
	var name := String(plan["name"])
	_dir = _dest if _dest != "" else String(plan["dir"])
	SkinPack.rmtree(_dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var w := FileAccess.open(_dir.path_join("meta.json"), FileAccess.WRITE)
	w.store_buffer(body)
	w.close()
	_queue = plan["queue"]
	_total = _queue.size()
	_have = 0
	progress.emit(_have, _total)
	_next()


## meta.json → 目标目录 + 要拉的文件清单。拆成静态口是为了这段逻辑能离线断言：
## HTTPRequest 在 -s 探针里根本发不出去（实测），只有真窗口才能跑完整拉取。
static func plan_meta(body: PackedByteArray) -> Dictionary:
	var j: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (j is Dictionary):
		return {"ok": false, "error": "meta.json 不是对象"}
	var d: Dictionary = j
	var name := String(d.get("name", "")).strip_edges()
	if name == "":
		return {"ok": false, "error": "meta.json 里没有 name"}
	# 队列项 = [落盘文件名, 源地址]：PT 的 res 既可能是 {文件名: 文件名}，
	# 也可能是 {Tap.png: https://host/xxx/click.png}（谱面 customRes 就是后者）。
	var queue: Array = []
	var res: Variant = d.get("res", {})
	if res is Dictionary and not (res as Dictionary).is_empty():
		for f in (res as Dictionary).keys():
			var v: Variant = (res as Dictionary)[f]
			queue.append([String(f), String(v) if v is String else String(f)])
	elif res is Array:
		for f in (res as Array):
			queue.append([String(f), String(f)])
	else:
		# 没有 res 表就按 phira/prpr 那套标准文件名挨个试（PT 的包都有 res，这里兜底）
		for k in SkinPack.FILES:
			var nf := String((SkinPack.FILES[k] as Array)[0])
			queue.append([nf, nf])
		queue.append(["info.yml", "info.yml"])
	return {"ok": true, "name": name, "dir": DIR.path_join(name), "queue": queue}


func _next() -> void:
	if _queue.is_empty():
		_busy = false
		var p := SkinPack.scan_path(_dir)
		p["id"] = _dir.get_file()
		if bool(p.get("ok", false)):
			done.emit(p)
		else:
			failed.emit("拉下来的文件不够成一个包")
		return
	var ent: Array = _queue.pop_front()
	_want = String(ent[0])
	var src := String(ent[1]).strip_edges()
	if src.begins_with("//"):
		src = "https:" + src
	elif not src.begins_with("http://") and not src.begins_with("https://"):
		src = _base + "/" + (src if src != "" else _want).uri_encode()
	if _file_req.request(src) != OK:
		_next()


func _on_file(result: int, code: int, _heads: PackedStringArray, body: PackedByteArray) -> void:
	# 只收"看起来是素材"的字节：CDN 的 404 页常常也是 200 + HTML，收下就是一张坏图
	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and _is_asset(body):
		var w := FileAccess.open(_dir.path_join(_want), FileAccess.WRITE)
		if w != null:
			w.store_buffer(body)
			w.close()
		elif _want.ends_with(".json"):
			pass
	_have += 1
	progress.emit(_have, _total)
	_next()


## 魔数判类型（PT index.ts:123-139 同做法：PNG / OGG，其余不收）
static func _is_asset(b: PackedByteArray) -> bool:
	if b.size() < 8:
		return false
	var png := b[0] == 0x89 and b[1] == 0x50 and b[2] == 0x4E and b[3] == 0x47
	# "OggS" = 4F 67 67 53（第三个字节是小写 g，不是 0x47——写错就是所有在线包的音全被丢掉）
	var ogg := b[0] == 0x4F and b[1] == 0x67 and b[2] == 0x67 and b[3] == 0x53
	var wav := b[0] == 0x52 and b[1] == 0x49 and b[2] == 0x46 and b[3] == 0x46
	var mp3 := (b[0] == 0xFF and (b[1] & 0xE0) == 0xE0) or (b[0] == 0x49 and b[1] == 0x44)
	return png or ogg or wav or mp3

## 删目录统一走 SkinPack.rmtree（4.7 的 remove_absolute 删不掉非空目录，见那里的说明）
static func _mkdirs(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
