class_name PzAuth
extends Node
## PhiZone 账号：登录换 token + 拉自己的资料（名称/头像/RKS/经验）。
## 端点与表单字段取自 PhiTogether 的 PZ api 层（src/components/community/phizone/api.ts）：
##   POST https://api.phizone.cn/auth/token   form: client_id/client_secret/grant_type/
##                                            password/username  → {access_token, refresh_token,…}
##   GET  https://api.phizone.cn/me/          Authorization: Bearer → {userName, avatar, rks, experience,…}
## client_secret 是"公开客户端"那一份（PT 的打包产物里同样是明文），不是我们泄露的密钥。
## 会话单独存 user://pz_session.json —— 不往 prefs.json 里塞，免得脏了设置表。

signal login_done(ok: bool, msg: String)
signal me_done(ok: bool, info: Dictionary)
signal logged_out

const AUTH_URL := "https://api.phizone.cn/auth/token"
const ME_URL := "https://api.phizone.cn/me/"
const SESSION_FILE := "user://pz_session.json"
const CLIENT_ID := "regular"
const CLIENT_SECRET := "c29b1587-80f9-475f-b97b-dca1884eb0e3"

var access_token := ""
var refresh_token := ""
var user := {}          # /me 的 data（userName/avatar/rks/experience/id…）
var busy := false
var expires_at := 0   # 访问令牌到期的 Unix 毫秒（0=服务器没给/不知道）

## PhiZone 官方"经验→等级"表。两个权威源互证过（2026-10-27 拉的原仓源码）：
##   后端 PhiZone/api-anc  Services/VoteService.cs：
##     _experienceList = [0,50,100,500,1000,3000,6000,10000,30000,60000,100000]
##     GetUserLevel = _experienceList.FindLastIndex(e => e <= user.Experience)
##   前端 PhiZone/ui  src/lib/constants.ts 的 USER_LEVELS + utils.ts 的 getUserLevel()：
##     {50:1, 100:2, 500:3, 1000:4, 3000:5, 6000:6, 10000:7, 30000:8, 60000:9, 100000:10}
## 两条写法语义相同（后端那张表多一个 0 打头，索引正好等于等级），上限都是 10 级。
## 核对点：experience=14752 ⇒ Level 7（用户 2026-10-27 亲口给的数）。
const LEVEL_AT := [0, 50, 100, 500, 1000, 3000, 6000, 10000, 30000, 60000, 100000]

static func level_of(exp: float) -> int:
	var lv := 0
	for i in LEVEL_AT.size():
		if exp >= float(LEVEL_AT[i]):
			lv = i
	return lv

## 本级内进度：离下一档还差多少经验就走多少。PZ 自己只有 LV 徽章、没有条子，
## 这条是"经验值表现为 Level 底子上进度条"（用户 2026-10-27）最不掺水的写法。
## 满级（≥100000）没有下一档，恒满。
static func level_progress(exp: float) -> float:
	var lv := level_of(exp)
	if lv >= LEVEL_AT.size() - 1:
		return 1.0
	var lo := float(LEVEL_AT[lv])
	return clampf((exp - lo) / (float(LEVEL_AT[lv + 1]) - lo), 0.0, 1.0)

func logged() -> bool:
	return access_token != ""

## 开机恢复上次会话：**先把上次存下的资料立刻贴回界面**（名字/等级/头像不至于闪一帧"Player"），
## 再拿 token 去 /me 核对。令牌过期就先刷，刷不动才算没登录。
func restore() -> void:
	if not FileAccess.file_exists(SESSION_FILE):
		return
	var fa := FileAccess.open(SESSION_FILE, FileAccess.READ)
	if fa == null:
		return
	var j: Variant = JSON.parse_string(fa.get_buffer(fa.get_length()).get_string_from_utf8())
	fa.close()
	if typeof(j) != TYPE_DICTIONARY:
		return
	access_token = String(j.get("access_token", ""))
	refresh_token = String(j.get("refresh_token", ""))
	expires_at = int(j.get("expires_at", 0))
	var cached: Variant = j.get("user", {})
	if typeof(cached) == TYPE_DICTIONARY:
		user = cached
		if user.has("data") and typeof(user.get("data")) == TYPE_DICTIONARY:
			user = user["data"]   # 老版本整封存过，这里也认
	if not user.is_empty() and access_token != "":
		me_done.emit(true, user)
	if access_token == "":
		return
	fetch_me()

## 令牌还有没有效（提前 60s 判过期，免得请求半路失效）
func expired() -> bool:
	return expires_at > 0 and Time.get_unix_time_from_system() * 1000.0 >= float(expires_at - 60000)

## 用 refresh_token 换一把新的访问令牌（PZ 的 token 是会过期的，不刷就得让用户反复输密码）
func refresh(then_me: bool = true) -> void:
	if refresh_token == "" or busy:
		return
	busy = true
	var body := "client_id=%s&client_secret=%s&grant_type=refresh_token&refresh_token=%s" % [
		CLIENT_ID, CLIENT_SECRET, refresh_token.uri_encode()]
	var r := _req(AUTH_URL, ["Content-Type: application/x-www-form-urlencoded"],
			HTTPClient.METHOD_POST, body)
	r.request_completed.connect(_on_token.bind(r, "refresh" if then_me else ""), CONNECT_ONE_SHOT)

func login(name: String, password: String) -> void:
	if busy:
		return
	busy = true
	var body := "client_id=%s&client_secret=%s&grant_type=password&username=%s&password=%s" % [
		CLIENT_ID, CLIENT_SECRET, name.uri_encode(), password.uri_encode()]
	var r := _req(AUTH_URL, ["Content-Type: application/x-www-form-urlencoded"],
			HTTPClient.METHOD_POST, body)
	r.request_completed.connect(_on_token.bind(r, "login"), CONNECT_ONE_SHOT)

func fetch_me() -> void:
	if access_token == "":
		me_done.emit(false, {})
		return
	if expired() and refresh_token != "":
		# 过期就先静默续期，续上由 _on_token 接着去 /me；用户不用重新输密码
		refresh()
		return
	# 4.7 的 request(method) 用的是 HTTPClient.Method 那组常量（HTTPRequest 上没有枚举，
	# ClassDB 实测 HTTPRequest 只有 Result）
	var r := _req(ME_URL, ["Authorization: Bearer " + access_token], HTTPClient.METHOD_GET)
	r.request_completed.connect(_on_me.bind(r, true), CONNECT_ONE_SHOT)

func logout() -> void:
	access_token = ""
	refresh_token = ""
	expires_at = 0
	user = {}
	DirAccess.remove_absolute(SESSION_FILE)
	logged_out.emit()

## mode="login" 登录换到的 token（要报成功）；"refresh" 静默续期（只把 /me 再跑一遍）；"" 只落盘。
func _on_token(result: int, code: int, _h: PackedStringArray, body: PackedByteArray,
		r: HTTPRequest, mode: String) -> void:
	busy = false
	r.queue_free()
	var d := _json(body)
	if result != HTTPRequest.RESULT_SUCCESS:
		login_done.emit(false, "网络失败（result=%d）" % result)
		return
	if code != 200 or d.is_empty() or not d.has("access_token"):
		login_done.emit(false, _err_text(d, code))
		return
	access_token = String(d.get("access_token", ""))
	refresh_token = String(d.get("refresh_token", refresh_token))
	var ei: int = int(d.get("expires_in", 0))
	if ei > 0:
		expires_at = int(Time.get_unix_time_from_system() * 1000.0) + ei * 1000
	else:
		expires_at = 0
	_save_session()
	if mode == "login":
		login_done.emit(true, "")
	if mode == "login" or mode == "refresh":
		fetch_me()

func _on_me(result: int, code: int, _h: PackedStringArray, body: PackedByteArray,
		r: HTTPRequest, can_retry: bool) -> void:
	r.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		# 401/403：先当"令牌过期"处理，拿 refresh_token 续一把再来；续不动才算真没登录。
		# 其它错误（断网/5xx）绝不清会话——否则一次地铁隧道就得重新输密码。
		if can_retry and (code == 401 or code == 403) and refresh_token != "":
			refresh()
			return
		if code == 401 or code == 403:
			logout()
		me_done.emit(false, {"http": code})
		return
	var d := _json(body)
	if d.is_empty():
		me_done.emit(false, {"http": code})
		return
	# /me 真正的人物字段在 data 里，外层是 {code, data, errors, status, …} 这层信封
	# （2026-10-27 用真账号核实：userName/rks/experience 全在 data 下，顶层一个都没有）。
	# 直接吃信封的结果就是登录后名字仍是 Player、RKS 0.00。
	if d.get("data") is Dictionary and not (d.get("data") as Dictionary).is_empty():
		d = d["data"]
	user = d
	_save_session()
	me_done.emit(true, d)

func _err_text(d: Dictionary, code: int) -> String:
	var e := String(d.get("error", ""))
	var ed := String(d.get("error_description", ""))
	if e != "" or ed != "":
		return "%s %s" % [e, ed]
	return "登录失败（http=%d）" % code

func _save_session() -> void:
	# 没 token 就别落盘：/me 是异步回来的，回来的那一刻手上可能已经 logout()（或 QA 清了态），
	# 无条件写会把好会话覆盖成空文件——实测就这么把一次真登录擦掉了。
	if access_token == "":
		return
	var fa := FileAccess.open(SESSION_FILE, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify({"access_token": access_token,
			"refresh_token": refresh_token, "expires_at": expires_at, "user": user}))
	fa.flush()
	fa.close()

func _json(body: PackedByteArray) -> Dictionary:
	# 大 JSON 用实例口解析（静态 JSON.parse_string 在几 MB 单行上会失败，这里也统一走实例口）
	var j := JSON.new()
	if j.parse(body.get_string_from_utf8()) != OK:
		return {}
	return j.data if typeof(j.data) == TYPE_DICTIONARY else {}

func _req(url: String, headers: PackedStringArray, m: int, body := "") -> HTTPRequest:
	var r := HTTPRequest.new()
	r.timeout = 15.0
	add_child(r)
	var e := r.request(url, headers, m, body)
	if e != OK:
		push_warning("QA-PZ 请求发不出去 %s err=%d" % [url, int(e)])
	return r
