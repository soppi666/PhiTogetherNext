extends Control
## 游戏入口：页面容器（主菜单 ↔ 单人选曲）+ 常驻 PlayerHud + 开场遮罩。
## --qa 时自动截图验证（主场景负责 QA 分发）。

const BgBlur := preload("res://scripts/bg_blur.gd")  # 背景虚化烘焙（与舞台共用）

var _menu: MainMenu
var _select: SongSelect
var _settings: SettingsPage
var _page_ctl: Control = null  # 当前占屏的二级页（返回键/Esc 要知道淡出谁）
var _hud: PlayerHud
var _pzauth: PzAuth       # PhiZone 账号（登录/会话/资料）
var _login: LoginCard     # 点头像弹出的登录卡片（同一时刻最多一张）

## 高帧率投票器（只有 Android 才有这个 GDExtension 类；桌面上保持 null 全程静默）。
## 为什么必须存在：荣耀 ROD-W09 的"智能刷新率"只认触摸事件抬档，静置就压回 60，
## 而 Godot 的节拍在第一次 present 时就按当时屏档锁死（冷启动 60 ⇒ 整局 60，
## 中途被触摸抬到 120 也不跟着走，实测见 QA-TOUR）。app 自己以 surface 的身份投票
## （ANativeWindow_setFrameRate）是唯一的公开入口，GDScript 侧没有等价 API。
## 类型故意不写：`AndroidRate` 只在移动端 .so 里注册，写死类型会让桌面端解析失败。
var _rate = null
var _rate_t := 0.0
var _rate_votes := 0
var _rate_ok := false        # native 投票有没有真的提交出去（决定还要不要用 max_fps 兜底）
var _rate_latched := false   # 是否已经把交换链重新落拍到目前屏档

func _open_login_card() -> void:
	if is_instance_valid(_login):
		return
	var c := LoginCard.new()
	c.z_index = 130   # 放大层(120) 之上：登录是模态的
	add_child(c)
	_login = c
	c.cancelled.connect(_close_login_card)
	c.continue_pressed.connect(_on_login_continue)
	if _pzauth.logged():
		c.goto(3)
		c.set_status("已连接：%s" % _pz_label())

func _close_login_card() -> void:
	if is_instance_valid(_login):
		_login.queue_free()
	_login = null

func _on_login_continue(s: int) -> void:
	if s != 2 or not is_instance_valid(_login):
		_close_login_card()
		return
	var nm := _login.user_name()
	var pw := _login.user_pass()
	if nm == "" or pw == "":
		_login.set_hint("账号和密码都要填。")
		return
	_login.goto(3)
	_login.set_status("正在连接 PhiZone…")
	_pzauth.login(nm, pw)

func _pz_label() -> String:
	var u: Dictionary = _pzauth.user
	# PZ 自己在徽章上就是 "LV{等级}"（ui/components/User.svelte），这里同一口径
	return "%s（RKS %.2f · Lv%d）" % [String(u.get("userName", "?")), float(u.get("rks", 0.0)),
			PzAuth.level_of(float(u.get("experience", 0.0)))]

## Level 走 PhiZone 官方那张经验表（PzAuth.LEVEL_AT，api-anc 与 ui 两处互证）：
## 14752 经验 = Level 7，条子=本级内到下一档的进度（10000→30000 那档，23.8%）。
## 换曲线只改 PzAuth 那一处，别在这里再算一遍。
## 换 token 这一步的结果：失败要退回第 2 步并把 PZ 给的原因写出来，别把卡片停在"连接中"。
func _on_pz_login(ok: bool, msg: String) -> void:
	if ok or not is_instance_valid(_login):
		return
	_login.set_hint("登录失败：" + msg)

func _on_pz_me(ok: bool, info: Dictionary) -> void:
	if not ok:
		if is_instance_valid(_login):
			_login.goto(2)
			_login.set_hint("连接失败：账号或密码不对，或 PZ 服务不可达。")
		return
	var exp: float = float(info.get("experience", 0.0))
	_hud.set_identity(String(info.get("userName", "Player")), float(info.get("rks", 0.0)),
			PzAuth.level_of(exp), PzAuth.level_progress(exp))
	# 头像：/me 的 avatar 是一张远端图，取回来换掉本地默认线稿。
	# URL 后缀按 PZ 前端自己的写法（ui/src/lib/utils.ts getAvatar → ?imageslim&imageMogr2/quality/N）：
	# 实测同一张 214,968B → 93,812B，仍是 RIFF/WEBP，手机上少下一半多。
	var av := String(info.get("avatar", ""))
	if av != "" and not av.contains("?"):
		av += "?imageslim&imageMogr2/quality/15"
	if av != "" and av != _pz_avatar_url:
		_pz_avatar_url = av
		_select.api().load_cover(av)

var _pz_avatar_url := ""

func _on_cover_loaded(url: String, tex: Texture2D) -> void:
	if url == "" or url != _pz_avatar_url or tex == null:
		return
	# 源图是 2048²，而头像只画 10% 屏高（手机上白占 ~16MB）：先降到 512 再交给控件
	var img := tex.get_image()
	if img != null and img.get_width() > 512:
		img.resize(512, 512, Image.INTERPOLATE_BILINEAR)
		tex = ImageTexture.create_from_image(img)
	_hud.set_avatar(tex)
	if is_instance_valid(_login):
		_login.set_status("已连接：%s" % _pz_label())
		# 只有卡片真的开着才装这颗自动关。开机 restore() 也会走这条：不判的话
		# "0.9s 后关卡片"会挂在没有卡片的时刻上，晚到的 /me 把用户正在填的卡片凭空关掉
		# （--qalogin 就是这么被 0.9s 那颗定时器掐掉的，症状是 _login 变 Nil）。
		_login_timer = get_tree().create_timer(0.9)
		_login_timer.timeout.connect(_close_login_card)

var _login_timer: SceneTreeTimer

var _stage: ChartStage
var _fx: GlitchFx  # 未实现按钮的 fluXis??? 故障特效
var _bake: BakePump  # 每帧一张的首烘摊平泵（全页共用一条队列=全局每帧只重一次）



func _ready() -> void:
	# 帧率策略默认仍是"不锁，上限交给显示器"（120Hz 屏就出 120 帧）；
	# 但设置页里选了档并打开「锁定帧率」时，这里必须一开机就照办——
	# 否则要等到进舞台才被应用，主菜单/选曲页一路跑满帧，用户会以为设置没生效。
	Engine.max_fps = UserPrefs.int_of("fps_cap") if UserPrefs.flag("fps_lock") else 0
	# 厂商的"智能刷新率"不会因为 app 跑得多快而抬档：ROD-W09 静置就是 60Hz，只有触摸才给
	# 120Hz，停手 6s 又掉回去（真机量过）。Godot 自己那条 max_fps→Swappy 的表态在这一版
	# 根本不触发（vsync 开/关 × max_fps 0/120 四种组合一次都没抬起屏档），所以要由
	# AndroidRate 直接对 surface 投 ANativeWindow_setFrameRate(120, DEFAULT, ALWAYS)。
	# ⚠ 上限这一档**不能**收回成 0：perfF 真机实测，开机投到 120Hz 之后 max_fps=0 的菜单
	# 只有 60.3/s（引擎在第一次 present 时按开机时的屏档锁了排程，之后面板抬到 120 也不跟），
	# 而 perfE 的 vsync 开 + max_fps=120 菜单是 120.0/s。所以移动端"没锁帧"时要的是：
	# native 投票负责抬/钉屏档，max_fps=目标帧负责给引擎一个不比面板低的节拍。
	# 两者谁都不能少，真正的锯齿问题（游玩 均110/小37）交给 QA-PACE 扫掠定位。
	_rate_boot()
	if Engine.max_fps == 0 and OS.has_feature("mobile"):
		Engine.max_fps = maxi(int(DisplayServer.screen_get_refresh_rate()),
				UiTokens.MOBILE_TARGET_FPS)
	# 全局音频/图像项开机即应用（舞台只负责它自己那几条：判定窗口、模糊、音符大小…）
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(UserPrefs.num("master_vol"), 0.001)))
	get_viewport().use_hdr_2d = UserPrefs.flag("hdr")
	get_viewport().msaa_2d = UserPrefs.int_of("msaa")
	# 启动基线一行（真机 adb logcat 直接可见）：上限与屏档是排查"上屏只有 60"的第一手信息
	print("启动 max_fps=%d 屏=%.0fHz vsync=%d 核=%d" % [
		Engine.max_fps, DisplayServer.screen_get_refresh_rate(),
		DisplayServer.window_get_vsync_mode(), OS.get_processor_count()])
	# ThemeDB.fallback_font 只是缺字兜底；控件默认字体走 Theme.default_font，
	# 不设它就会落到内置 OpenSans SemiBold（看起来像粗体）
	var th := Theme.new()
	th.default_font = UiTokens.install_font()
	theme = th
	var bg := ColorRect.new()
	bg.color = UiTokens.bg(0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_index = -11
	add_child(bg)
	# 全局背景图：cover 裁切铺满 + 压暗，保证磨砂 UI 可读
	var bg_img := TextureRect.new()
	var bg_tex: Texture2D = load("res://assets/bg/main_bg.jpg")
	bg_img.texture = bg_tex
	bg_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg_img.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg_img.z_index = -10
	add_child(bg_img)
	_bg_img = bg_img
	_bg_src = bg_tex
	# 开屏先贴一张**同步**的近似糊：真烘焙要等 GPU 好几帧，遮罩一揭开就是清晰原图
	# （用户 2026-10-27 "一开始的背景模糊又没有了"）。下面 deferred 的高斯版到货后替换。
	var _pre := BgBlur.cheap_preview(bg_tex.get_image(), get_viewport_rect().size,
			UserPrefs.num("bg_blur") * 0.5)
	if _pre != null:
		bg_img.texture = ImageTexture.create_from_image(_pre)
	# 背景模糊对所有页面生效（主菜单/选曲/设置/结算共用这一张底图）：
	# 开场遮罩盖着的时候先烘，揭开时就已经是糊好的。
	_rebake_menu_bg.call_deferred()
	if not get_viewport().size_changed.is_connected(_on_vp_resized):
		get_viewport().size_changed.connect(_on_vp_resized)
	# 窗口尺寸在第一帧之后才定（QA --resolution / 手机旋转）：1 秒后再校一次，
	# 参数没变时 _bg_key 会直接短路，不会多烘一遍
	_late_bg_check()
	var deco := BgDeco.new()
	deco.z_index = -9
	add_child(deco)
	_menu = MainMenu.new()
	_menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_menu)
	_menu.nav.connect(_on_nav)
	_select = SongSelect.new()
	_select.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_select.visible = false
	_bake = BakePump.new()
	add_child(_bake)
	_select.bake = _bake  # add_child 前赋值：_select._ready 里要把它交给 SongGrid
	add_child(_select)
	_select.nav.connect(_on_nav)
	_select.art_changed.connect(_bg_use)
	_select.download_requested.connect(download_only)
	_select.import_requested.connect(_import_local_pack)
	_select.api().chart_file_done.connect(_on_chart_file)
	_select.api().raw_file_done.connect(_on_raw_file)
	_select.api().asset_list_done.connect(_on_asset_list)
	# PZ 头像复曲库那条封面通道（按魔数解码 + 内存缓存），只认 /me 给的那一个 URL
	_select.api().cover_loaded.connect(_on_cover_loaded)
	# 设置页：与选曲页同一套外壳（一级导航带 + 内容带），从主菜单「设置」进
	_settings = SettingsPage.new()
	_settings.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings.visible = false
	add_child(_settings)
	_settings.nav.connect(_on_nav)
	# **这一行才是"手机上滑动返回直接闪退"的真身**：SceneTree 默认 quit_on_go_back=true，
	# 返回通知传播到 SceneTree 时引擎直接 quit() 结束进程——我们的 _notification 再怎么
	# 分层处理也拦不住（通知是递归传播的，SceneTree 也在链上）。
	# 关掉之后，返回键只走下面这套层级动作，永不退出进程。
	get_tree().quit_on_go_back = false
	# Android 返回键的另一条投递路（信号版）：与下面的 _notification 一起去重，只算一次
	get_window().go_back_requested.connect(_request_back)
	var hud := PlayerHud.new()
	hud.z_index = 50  # 跨页面常驻，盖在页面之上
	add_child(hud)
	_fx = GlitchFx.new()
	_fx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fx.z_index = 60  # 盖 HUD(50)，仍低于选曲弹窗(90)/放大层(120)
	add_child(_fx)
	_fx.locked.connect(_on_btn_locked)
	_hud = hud
	# PhiZone 账号：只有登录后才允许进 PZ 社区；会话存 user://pz_session.json，开机静默恢复。
	_pzauth = PzAuth.new()
	_pzauth.name = "PzAuth"
	add_child(_pzauth)
	_pzauth.me_done.connect(_on_pz_me)
	_pzauth.login_done.connect(_on_pz_login)
	_hud.avatar_pressed.connect(_open_login_card)
	_select.pz_logged_check = func() -> bool: return _pzauth.logged()
	_select.pz_login_requested.connect(_open_login_card)
	_pzauth.restore()
	var splash := SplashOverlay.new()
	_splash = splash
	add_child(splash)
	splash.dismissed.connect(_menu.reveal)  # 轻触开始 → 菜单按钮逐级浮现

	# 渲染录制的**子进程**入口：父进程把一张谱切成几段，各段由一个子进程渲。
	# 这条必须在所有 QA/交互分发之前退回去，否则子进程会跟着 --qa* 参数跑回归。
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--ptnrec="):
			_rec_worker.call_deferred(String(a).trim_prefix("--ptnrec="))
			return

## 未实现功能的按钮 nav id（唯一吃 GlitchFx 特效的名单）。
## 注意：song_select 所有按钮都会发射 nav（历史死代码），不能拿 _on_nav 兜底当"未实现"判据。
## 功能上线 = 加 match 分支 + 从这里删掉该 id。（"settings" 已上线 → 已删）
const STUB_NAV := ["multi", "replay", "event", "art_config"]

## 彩蛋门控：主菜单这三个未实现按钮全部被「按灭」→ 打开官方谱 blockArea（噪域）。
## 判据取 GlitchFx 的上锁记录（不是 disabled——别的代码也会禁用按钮）。
const EGG_MENU_IDS := ["multi", "replay", "event"]

func _on_btn_locked(_btn: Control) -> void:
	if GameFlags.block_area:
		return
	for id in EGG_MENU_IDS:
		var b: NeoButton = _menu.button_for(id)
		if b == null or not _fx.is_locked(b):
			return
	GameFlags.block_area = true
	print("[EGG] 四个按钮全部按灭 → blockArea（噪域）已开启")

func _on_nav(id: String) -> void:
	match id:
		"single":
			_go_select(func() -> void: _select._enter_local())  # 进单人游戏默认落在本地谱面页签
		"back":
			_back_to_menu()
		"fav":
			_go_select(_select._enter_fav)
		"play":
			_open_player()
		"settings":
			_go_settings()
		_:
			# fluXis??? 故障反馈：仅 STUB_NAV 名单内的未实现按钮（1s 内连点 5 次上锁）
			if id in STUB_NAV:
				var b: NeoButton = _menu.button_for(id)
				if b == null and _select != null:
					b = _select.button_for(id)
				if b != null and not b.disabled:
					_fx.click(b)
			print("menu nav: ", id)

## 开始游戏：只玩当前选中的谱（未选中时按钮已禁用）；PZ 谱先下 .pez 再解压进舞台
## 进选曲页：菜单淡出交接 + 头像信息条整组缩到 70% + 页内控件逐级浮现。
## 顺序很关键：先 enter（把内容/禁用态都写好），再 reveal——reveal 的静止基准
## 取的是"当前 modulate"，内容刷新必须在它之前完成。
func _go_select(enter: Callable) -> void:
	_page_ctl = _select
	_menu.fade_out(_hide_menu)
	_select.visible = true
	_hud.set_hud_scale(PlayerHud.SELECT_SCALE)
	enter.call()
	_select.reveal()

## 进设置页：与进选曲页同一套交接（菜单淡出 → HUD 缩到选曲档 → 页面逐级浮回）。
## 设置页所有值写进 UserPrefs，离开本页不需要"保存"这一步——改即生效（下次开谱读取）。
func _go_settings() -> void:
	_page_ctl = _settings
	_menu.fade_out(_hide_menu)
	_settings.visible = true
	_hud.set_hud_scale(PlayerHud.SELECT_SCALE)
	# 用户指定：进设置页直接收掉头像与用户简要（设置页要占满右侧，身份区没有位置）
	_hud.set_identity_visible(false)
	_settings.reveal()

func _hide_menu() -> void:
	_menu.visible = false

## 黑幕层：盖住"必然卡一帧"的同步重活（开谱解析、拆台释放 SubViewport/贴图链）。
## 这是"防止卡顿"里最实在的一招——不是把动画做快，而是把无法拆分的那一帧藏进转场里。
var _dip: ColorRect
var _dip_tw: Tween

func _dip_rect() -> ColorRect:
	if _dip == null:
		_dip = ColorRect.new()
		_dip.color = Color(0, 0, 0, 1)
		_dip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_dip.mouse_filter = Control.MOUSE_FILTER_IGNORE  # 装饰层吃掉点击会让转场期间"点不动"
		_dip.z_index = 200  # HUD(50)/装饰(60)/弹窗(90)/放大层(120) 之上
		_dip.modulate.a = 0.0  # 起手必须全透明！否则建层那一刻就是一块盖住全屏的黑板
		add_child(_dip)
	return _dip

## 落黑 → mid（同步重活）→ 揭黑。QA 模式（动画关）不生成黑幕、mid 同帧执行，
## 这样 _launch_stage 之后立刻读 _stage 的老断言仍然成立。
func _dip_then(dur_in: float, mid: Callable, dur_out: float) -> void:
	if not UiMotion.enabled:
		mid.call()
		return
	if _dip_tw != null and _dip_tw.is_valid():
		_dip_tw.kill()
	var r := _dip_rect()
	var tw := r.create_tween()
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(r, "modulate:a", 1.0, dur_in)
	tw.tween_callback(mid)
	tw.tween_interval(0.04)
	tw.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	tw.tween_property(r, "modulate:a", 0.0, dur_out)
	_dip_tw = tw

## 硬切铺黑（一帧都不露）+ 淡开
func _dip_lift(dur_out: float) -> void:
	if not UiMotion.enabled:
		return
	if _dip_tw != null and _dip_tw.is_valid():
		_dip_tw.kill()
	var r := _dip_rect()
	r.modulate.a = 1.0
	var tw := r.create_tween()
	tw.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	tw.tween_property(r, "modulate:a", 0.0, dur_out)
	_dip_tw = tw

func _open_player() -> void:
	if _stage != null:
		return
	_pending_skin_dir = ""
	var tgt: Dictionary = _select.play_target()
	print("QA-PLAY tgt=", tgt.get("kind"), " song=", (tgt.get("song", {}) as Dictionary).get("title"),
			" chart=", (tgt.get("chart", {}) as Dictionary).get("code"), " file=",
			str((tgt.get("chart", {}) as Dictionary).get("file", "")).left(30))
	if tgt.is_empty():
		return
	# JSON/服务器来源值一律 str() 不用 String() 构造（StringName/int/null 都会让 String() 抛
	# "Invalid call 'String' constructor"，见 2026-10-04 pzc:926… 崩溃案）
	if str(tgt.get("kind", "")) == "local":
		var jf := str(tgt.get("json", ""))
		_pending_key = "local:" + str(tgt["dir"]) + ("/" + jf if jf != "" else "")
		# 本地 PE 谱同样无 META：用选曲卡片的数据做 hint（title 兜底=目录名）
		var ls: Dictionary = _select._sel_song
		var lvq: Variant = ls.get("level", 0)
		_pending_hint = [str(ls.get("title", "")),
			"" if lvq == null or int(lvq) == 0 else "%s Lv.%d" % [str(ls.get("code", "")), int(lvq)]]
		# 从本地页再玩 PT 下载谱：带上它自己的 customRes 包（下载时写在谱目录的 pt_res.txt）
		var ld0 := str(tgt["dir"])
		var skf := ld0.path_join("pt_res.txt")
		if FileAccess.file_exists(skf):
			var sd := FileAccess.get_file_as_string(skf).strip_edges()
			if sd != "" and DirAccess.dir_exists_absolute(sd):
				_pending_skin_dir = sd
		_launch_stage(ld0, jf)
		return
	if str(tgt.get("kind", "")) == "pt":
		_play_pt(tgt)
		return
	var ch: Dictionary = tgt["chart"]
	var cid := str(ch.get("id", ""))
	var url := str(ch.get("file", ""))
	if url == "" or not bool(ch.get("playable", true)):
		push_warning("Phigrim 独占谱面：无 file 直链，无法游玩")
		return
	_pending_key = "pzc:" + cid
	# 服务器已知的曲名/难度 → 舞台兜底 hint（老 .pe 直下既无 META 也无 info.txt）。
	# JSON 来源值可能是 int/null（chart.level 是难度数字）——String(v) 构造会炸，统一 str()+null 防护
	var lv_raw: Variant = ch.get("level", "")
	var songd0: Dictionary = tgt.get("song", {})
	_pending_hint = [
		"" if songd0.get("title") == null else str(songd0.get("title")),
		"" if lv_raw == null else "%s Lv.%s" % [str(ch.get("code", "")), str(lv_raw)],
	]
	# 下载完成时把服务器元数据固化成谱包 info.txt——之后从本地页签进也有信息
	_pending_meta = {
		"name": str(songd0.get("title", "")),
		"artist": str(songd0.get("artist", "")),
		"level": _pending_hint[1],
		"charter": str(ch.get("designer", "")),
		# 同一首 PZ 歌的不同难度下成不同目录；靠这行让选曲页并成一张卡
		"song_key": ("pz:" + str(songd0.get("pz_id", ""))) if str(songd0.get("pz_id", "")) != "" else "",
	}
	_pending_cid = cid
	# 已解压过的 PZ 谱：直接用目录（.pez 在解压成功后已删除），不再下一份
	var cached_pz := "user://pz/" + cid
	if FileAccess.file_exists(cached_pz.path_join("chart.json")):
		_pending_cid = ""
		_launch_stage(cached_pz)
		return
	if _pz_busy:
		# 下载进行中：连点不重入（并发写同一文件会读到截断内容）；卡死超 20s 允许重下
		if Time.get_ticks_msec() - _pz_busy_msec < 20000:
			return
	_pz_busy = true
	_pz_busy_msec = Time.get_ticks_msec()
	var songd: Dictionary = tgt.get("song", {})
	_pending_song_file = String(songd.get("song_file", ""))
	_pending_cover_url = String(songd.get("cover_url", ""))
	_select.api().download_chart(cid, url)

var _pending_cid := ""
var _pending_key := ""  # 本局记录键（local:dir / pzc:id），_launch_stage 消费后置空
var _pending_hint: Array = ["", ""]  # [曲名, 难度] 服务器兜底 hint，_launch_stage 消费后置空
var _pending_meta := {}  # 下载完成时写成谱包 info.txt 的服务器元数据
var _qa_skin := ""  # QA：--qaskin=DIR 皮肤目录覆盖（A/B 对拍用 player 默认 respack）
var _pending_skin_dir := ""  # PT 谱面的 customRes 包（按谱覆盖，不写 prefs）
var _pt_story_file := ""      # PT 故事版视频文件名（下载齐后写 extra.json）
var _pz_busy := false
var _pz_busy_msec := 0
# 只下载不游玩（选曲页那颗下载钮）：走同一条准备/下载链，但收尾不 _launch_stage，
# 改成通知选曲页"下好了"，按钮从下载图标切成播放图标，由用户再点一次。
var _dl_only := false
var _dl_total := 0
var _dl_done := 0
var _pending_song_file := ""
var _pending_cover_url := ""
var _pending_raw_dir := ""
var _pending_raws: Array = []

## PT 谱面库：一条 chart 直链 + 音频/曲绘直链 → 普通本地谱目录（user://local/PT ...）。
## 下载队列直接复用 PzApi.download_raw（_pending_raw_dir/_next_raw 会把齐后开谱）。
func _play_pt(tgt: Dictionary) -> void:
	var ch: Dictionary = tgt["chart"]
	var song: Dictionary = tgt["song"]
	if String(ch.get("file", "")) == "":
		push_warning("PT 谱面没有直链")
		return
	var dir := PtApi.local_dir(song, ch)
	_pending_key = "local:" + dir
	var code := String(ch.get("code", ""))
	var lv := int(ch.get("level", 0))
	_pending_hint = [String(song.get("title", "")),
		("%s Lv.%d" % [code, lv]) if code != "" and lv > 0 else code]
	# 谱面自带资源包（PT meta 的 customRes）：按谱覆盖 node 皮肤，不写 prefs/skins 列表
	var cr := String(ch.get("custom_res", "")).strip_edges()
	var res_dir := "user://pt_res/" + String(ch.get("id", "x"))
	if cr != "":
		DirAccess.make_dir_recursive_absolute(dir)
		var sf := FileAccess.open(dir.path_join("pt_res.txt"), FileAccess.WRITE)
		if sf != null:
			sf.store_string(res_dir)
			sf.close()
	var need_pack := cr != "" and not FileAccess.file_exists(res_dir.path_join(".ok"))
	var have_chart := FileAccess.file_exists(dir.path_join("chart.json"))
	var se0 := String(song.get("song_file", "")).get_extension().to_lower()
	var is_video := se0 in ["mp4", "webm", "mkv", "mov"]
	var story_name := "story." + se0
	var have_story := not is_video 			or FileAccess.file_exists(dir.path_join(story_name)) 			or FileAccess.file_exists(dir.path_join(story_name.get_basename() + ".ptn2.ogv"))
	if have_chart and not need_pack and have_story:
		if cr != "":
			_pending_skin_dir = res_dir
		_launch_or_done(dir)
		return
	if _pz_busy and Time.get_ticks_msec() - _pz_busy_msec < 20000:
		return
	_pz_busy = true
	_pz_busy_msec = Time.get_ticks_msec()
	var start := func() -> void:
		if have_chart and have_story:
			_pz_busy = false
			_launch_or_done(dir)
		else:
			_pt_start_dl(dir, ch, song)
	if need_pack:
		_pending_skin_dir = res_dir
		_pt_fetch_skin(cr, res_dir, start)
	else:
		if cr != "":
			_pending_skin_dir = res_dir
		start.call()

## PT customRes：PT 的在线资源包协议（GET meta.json + 逐文件），落到谱面私有目录。
## 成功写 .ok 作为完整标记；失败就按默认皮肤继续打，不挡开谱。
func _pt_fetch_skin(url: String, dest: String, next: Callable) -> void:
	var so := SkinOnline.new()
	add_child(so)
	var once := [false]
	var finish := func(ok: bool) -> void:
		if bool(once[0]):
			return
		once[0] = true
		if ok:
			var f := FileAccess.open(dest.path_join(".ok"), FileAccess.WRITE)
			if f != null:
				f.store_string("1")
				f.close()
		else:
			_pending_skin_dir = ""
		so.queue_free()
		next.call()
	so.done.connect(func(_pack: Dictionary) -> void:
		print("QA-PT skin ok ", dest)
		finish.call(true))
	so.failed.connect(func(what: String) -> void:
		push_warning("PT customRes: " + what)
		finish.call(false))
	so.fetch(url, dest)

func _pt_start_dl(dir: String, ch: Dictionary, song: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_pending_meta = {
		"name": String(song.get("title", "")),
		"artist": String(song.get("artist", "")),
		"level": _pending_hint[1],
		"charter": String(ch.get("designer", "")),
	}
	_write_info_txt(dir)
	_pending_raw_dir = dir
	_pending_raws = []
	_pending_assets = false
	_raw_outstanding = 0
	_pending_raws.append(["chart.json", String(ch.get("file", ""))])
	_pt_story_file = ""
	var su := String(song.get("song_file", ""))
	if su != "":
		var se := su.get_extension().to_lower()
		# 故事版：song 是 mp4，Godot 无 mp4 解码 → 下视频源交给 ChartStage 异步转 OGV，
		# 同时取同目录 mp3 当伴奏（转码完的视频在音符后面播，源文件转码后删掉）。
		if se in ["mp4", "webm", "mkv", "mov"]:
			_pt_story_file = "story." + se
			_pending_raws.append([_pt_story_file, su])
			var alt := su.get_basename() + ".mp3"
			print("QA-PT video->xcode ", su, " audio=", alt)
			su = alt
			se = "mp3"
		if se == "":
			se = "mp3"
		_pending_raws.append(["song." + se, su])
	var cu := String(song.get("cover_url", ""))
	if cu != "":
		var ce := cu.get_extension().to_lower()
		if ce == "":
			ce = "jpg"
		_pending_raws.append(["bg." + ce, cu])
	print("QA-PT dl dir=", dir, " chart=", String(ch.get("file", "")).left(70),
			" song=", su.left(70), " cover=", cu.left(70))
	_next_raw()

## PT 故事版：把视频挂成 extra.json 的全屏背景（depth 在背景之上、判定线之下），
## 360p/质量5 转码（4K/1080p 原片转 Theora 太慢）；转码完成后删源 mp4 省空间。
func _pt_write_video_extra(dir: String, fn: String) -> void:
	var ep := dir.path_join("extra.json")
	var d: Dictionary = {}
	if FileAccess.file_exists(ep):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(ep))
		if j is Dictionary:
			d = j
	var vids: Array = d.get("videos", [])
	var keep: Array = []
	for v in vids:
		if v is Dictionary and String(v.get("path", "")) != fn:
			keep.append(v)
	keep.append({
		"path": fn,
		"time": [0, 0, 1],
		"scale": "cropCenter",
		"alpha": 1.0,
		"dim": 0.0,
		"removeSource": true,
		"xcodeHeight": 360,
		"xcodeQuality": 5,
	})
	d["videos"] = keep
	var f := FileAccess.open(ep, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d))
		f.close()
		print("QA-PT extra.json video=", fn)

## 开机建投票器并把第一次诊断打出来（桌面上没有 AndroidRate 类 → 全程 null，零影响）
## native 投票那条反射链的诊断是多行文本，logcat 会把它拆成一堆不相邻的行 ⇒ 压成一行
static func _one_line(t: String) -> String:
	return t.replace("\n", " | ").strip_edges()


func _rate_boot() -> void:
	if _rate != null or not OS.has_feature("mobile"):
		return
	if not ClassDB.class_exists("AndroidRate"):
		print("QA-FRAME 扩展里没有 AndroidRate（arm64 .so 没更新？）")
		return
	_rate = ClassDB.instantiate("AndroidRate")
	_rate_t = 3.0
	print("QA-FRAME 开机探测:", _rate.probe())
	_rate_reassert()

## 投一次目标帧率，并把 native 侧那条反射链的诊断原样上 logcat。
## 只在"面板低于目标"时重申（_process 里 3s 一次，最多 24 次），避免和厂商策略来回拉扯。
func _rate_reassert() -> void:
	if _rate == null:
		return
	var want := float(UiTokens.MOBILE_TARGET_FPS)
	var now := DisplayServer.screen_get_refresh_rate()
	if now >= want - 1.0:
		_rate_votes = 0      # 面板在目标档 ⇒ 这次不算"投不动"，失败配额清零
		return
	if _rate_votes >= 24:    # 连续 24 次（≈72s）都投不上就停手，别和厂商策略死磕
		return
	_rate_votes += 1
	var diag := String(_rate.vote(want))
	if diag.contains("VOTE SUBMITTED"):
		if not _rate_ok:
			_rate_ok = true
			print("QA-FRAME 投票已生效 面板 ", now, "→", want, "Hz max_fps=", Engine.max_fps)
			print("QA-FRAME 链路 ", _one_line(diag))
	else:
		print("QA-FRAME 投票#", _rate_votes, " 面板=", now, "Hz 目标=", want, "Hz 失败 → ",
				_one_line(diag))

## 重新落拍：Godot 的 Vulkan 交换链在**第一次建立时**按当时的屏刷新率定死放行节拍，
## 之后面板被我们投到 120Hz 它也不跟着走（perfF/perfT 真机：面板 renderFrameRate=120.00001、
## 投票返回 0、焦点在本 app，可是上屏就是 59.0/s、循环也 59.0/s —— 是 FIFO 在半速放行）。
## 而 perfM/perfP 那两轮"先跑排程扫掠"的读数却是 110~120：原因正是扫掠里 `window_set_vsync_mode`
## 每切一档就触发一次 swap_chain_resize（真机日志：The requested V-Sync mode Disabled is not
## available … 与 BufferQueue connect/disconnect 成对出现），交换链在**面板已经是 120 之后**
## 重建了一次，于是重新按 120 落拍。
## 结论：不需要扫掠，也不需要重启进程 —— 投票成功、面板确实上来之后，主动切一次 vsync 档
## 让交换链重建，就把节拍落到 120 上。只切一次（_rate_latched 之后不再动，避免来回重建）。
func _rate_relatch() -> void:
	if _rate_latched or _rate == null:
		return
	var want := float(UiTokens.MOBILE_TARGET_FPS)
	if DisplayServer.screen_get_refresh_rate() < want - 1.0:
		return
	_rate_latched = true
	var back := UserPrefs.vsync_ds()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ADAPTIVE if back != DisplayServer.VSYNC_ADAPTIVE
			else DisplayServer.VSYNC_ENABLED)
	DisplayServer.window_set_vsync_mode(back as DisplayServer.VSyncMode)
	print("QA-FRAME 重新落拍 面板=", DisplayServer.screen_get_refresh_rate(),
			"Hz 档→实际=", "%d→%d" % [UserPrefs.int_of("vsync"), DisplayServer.window_get_vsync_mode()],
			" max_fps=", Engine.max_fps, "（交换链已重建，接下来这一档才是真读数）")

func _process(dt: float) -> void:
	# 高帧率投票重申：投出去的那次票会在息屏/切后台（surface 重建）时丢掉，
	# 面板一旦跌回目标以下就再投一次；达到目标后不再调用，免得来回切档闪屏。
	if _rate != null:
		_rate_t -= dt
		if _rate_t <= 0.0:
			_rate_t = 3.0
			_rate_reassert()
			# surface 是在后台被系统丢掉的 ⇒ 票没了；下一次 _rate_reassert 重新投中之后
			# 必须允许再落一次拍，否则这一局会一直停在开机那一档（真机：切回来 59/s）。
			if not _rate_ok:
				_rate_latched = false
	_rate_relatch()
	# 只下载模式：把进度推给选曲页那颗按钮的进度环
	if _dl_only and _select != null:
		var f := dl_fraction()
		if f >= 0.0:
			_select.set_download_progress(f)

## 选曲页那颗下载钮：只把这首谱下到本地（不自动开谱）
func download_only() -> void:
	if _dl_only or _pz_busy:
		return
	_dl_only = true
	_dl_total = 0
	_dl_done = 0
	_dl_pez = false
	_dl_shown = 0.0
	_select.api().reset_raw_progress()
	var before := _pz_busy
	_open_player()
	if not _pz_busy and _dl_only and not before:
		# 什么也没启动（目标不可下）→ 复位，别把按钮卡在进度环上
		_dl_only = false
		if _select != null:
			_select.on_download_failed("没有可下载的直链")

## 只下载模式下失败：复位并把按钮切回（别让进度环永远挂着）
func _dl_failed(msg: String) -> void:
	if not _dl_only:
		return
	_dl_only = false
	_pz_busy = false
	_pending_cid = ""
	_pending_raw_dir = ""
	_pending_raws = []
	_pending_assets = false
	if _select != null:
		_select.on_download_failed(msg)

## 下载收尾：只下载模式 → 通知选曲页；正常模式 → 开谱
func _launch_or_done(dir: String, jf := "") -> void:
	if _dl_only:
		_dl_only = false
		_pz_busy = false
		_pending_cid = ""
		_pending_raw_dir = ""
		_pending_raws = []
		_pending_assets = false
		print("QA-DL 只下载完成 ", dir)
		if _select != null:
			_select.on_download_finished(dir)
		return
	_launch_stage(dir, jf)

## 连续进度 0..1：PZ 先过 .pez（字节，占 0→0.6），之后音频/曲绘/资产按文件数（0.6→1.0）；
## PT 没有 .pez，直接从 0 按文件数走。**只增不减**（总数会随资产清单变大，否则环会往回退）。
var _dl_pez := false
var _dl_shown := 0.0

func _raw_frac() -> float:
	# 优先按字节（HTTPRequest 每帧都在更新，进度才是"慢慢累加"）；
	# 服务器不给 Content-Length 时才退回按文件数
	var b: float = _select.api().raw_frac()
	if b >= 0.0:
		return b
	if _dl_total <= 0:
		return 0.0
	return clampf(float(_dl_done) / float(_dl_total), 0.0, 1.0)

func dl_fraction() -> float:
	if not _dl_only:
		return -1.0
	var f := -1.0
	if _pending_cid != "":
		_dl_pez = true
		var b: float = _select.api().dl_fraction()
		if b >= 0.0:
			f = 0.6 * b
	elif _dl_pez:
		f = 0.6 + 0.4 * _raw_frac()
	else:
		f = _raw_frac()
	if f < 0.0:
		return -1.0
	_dl_shown = maxf(_dl_shown, f)
	return _dl_shown

func _on_chart_file(cid: String, path: String, ok: bool) -> void:
	if cid != _pending_cid:
		return
	_pending_cid = ""
	if not ok:
		_pz_busy = false
		push_warning("PZ 谱面下载失败")
		_dl_failed("谱面包下载失败")
		return
	var out_dir := "user://pz/" + cid
	if not _extract_pez(path, out_dir):
		_pz_busy = false
		push_warning("PZ 谱面解压失败")
		_dl_failed("谱面包解压失败")
		return
	# 解压完成即删 .pez：以前同一份资源留两份（压缩包 + 目录），用户点名要省
	DirAccess.remove_absolute(path)
	print("QA-DL pez removed ", path)
	_write_info_txt(out_dir)
	# PZ 谱文件是裸 json：音频/曲绘要按 song.file / song.illustration 补下
	_pending_raw_dir = out_dir
	_select.api().reset_raw_progress()
	_pending_raws = []
	_raw_outstanding = 0  # 上一张谱可能还有在途请求：计数归零，新队列满并发
	var has_song := false
	var has_bg := false
	var da := DirAccess.open(out_dir)
	if da != null:
		for f in da.get_files():
			var e := f.get_extension().to_lower()
			if e in ["ogg", "mp3", "wav"]:
				has_song = true
			elif e in ["webp", "jpg", "jpeg", "png"]:
				has_bg = true
	print("QA-DL cid=", cid, " has_song=", has_song, " has_bg=", has_bg,
			" song_url=", _pending_song_file.left(40), " cover_url=", _pending_cover_url.left(40))
	if not has_song and _pending_song_file != "":
		var ext := _name_ext(_pending_song_file, "ogg")
		_pending_raws.append(["song." + ext, _pending_song_file])
	if not has_bg and _pending_cover_url != "":
		_pending_raws.append(["bg.webp", _pending_cover_url])
	# 附加资产（extra.json 后期特效等）：拉列表后并入下载队列。清单请求自带 12s 引擎超时，
	# 这条看门狗只兜"连接彻底挂死"的极端情况（手机上曾 8s 就放行 → 94 个资产全丢）
	_pending_assets = true
	_pending_asset_cid = cid
	_select.api().fetch_assets(cid)
	get_tree().create_timer(20.0).timeout.connect(_assets_watchdog)
	_next_raw()

var _pending_assets := false
var _pending_asset_cid := ""

func _assets_watchdog() -> void:
	if not _pending_assets:
		return
	_pending_assets = false
	push_warning("QA: 资产清单超时未回，先放行下载队列")
	_next_raw()

func _on_asset_list(cid: String, assets: Array) -> void:
	# 只要还没进舞台（_pending_raw_dir 被清=已开谱），迟到的清单照样并进来：
	# 看门狗放行不代表这份数据作废，手机上它常和 4 路并发下载抢带宽
	if cid != _pending_asset_cid or _pending_raw_dir == "":
		return
	var added := 0
	for a in assets:
		var nm := String(a["name"])
		var dest := _pending_raw_dir.path_join(nm)
		if nm == "" or FileAccess.file_exists(dest):
			continue
		_pending_raws.append([nm, String(a["file"])])
		added += 1
	_pending_assets = false
	print("QA-DL 资产清单 n=", assets.size(), " 需补下=", added)
	_next_raw()

func _name_ext(url: String, dflt: String) -> String:
	var e := url.get_file().get_extension().to_lower()
	return e if e != "" else dflt

## 服务器元数据 → 谱包 info.txt（已存在则不覆盖：zip 自带的 info.txt 更权威）
func _write_info_txt(dir: String) -> void:
	if _pending_meta.is_empty():
		return
	var ip := dir.path_join("info.txt")
	var lv := str(_pending_meta.get("level", ""))
	if FileAccess.file_exists(ip):
		var old := FileAccess.get_file_as_string(ip)
		# 例外：旧版本把自定义难度名截成两字母（Pixel→PI）写进了我们生成的 info.txt，
		# 缓存不刷新他就永远还看到 PI。判据见 DiffCode.is_truncation_of（三条都成立才改这一行）。
		var cached := SongSelect.info_line(old, "Level")
		if DiffCode.is_truncation_of(cached, lv):
			var fa2 := FileAccess.open(ip, FileAccess.WRITE)
			if fa2 != null:
				fa2.store_string(SongSelect.info_with_level(old, lv))
				fa2.close()
				ChartMetaCache.drop(dir)  # 卡片读的是缓存：不清掉还是旧码
				print("QA-INFO 刷新 Level：", cached, " → ", lv)
		return
	var fa := FileAccess.open(ip, FileAccess.WRITE)
	if fa == null:
		return
	var body := "Name:%s\nArtist:%s\nLevel:%s\nCharter:%s\n" % [
		str(_pending_meta.get("name", "")), str(_pending_meta.get("artist", "")),
		lv, str(_pending_meta.get("charter", ""))]
	var sk := str(_pending_meta.get("song_key", ""))
	if sk != "":
		body += "SongKey:%s\n" % sk
	fa.store_string(body)
	fa.close()
	print("QA-INFO wrote ", ip)

func _next_raw() -> void:
	if _pending_assets:
		return  # 等 asset_list_done/看门狗解锁（防止 extra.json 没下完就进舞台）
	# 4 路并发：テレパシ 这类多贴图谱（补下 63 张线贴图）串行要几十秒
	while _raw_outstanding < 4 and not _pending_raws.is_empty():
		var item: Array = _pending_raws.pop_front()
		_raw_outstanding += 1
		_dl_total += 1
		_select.api().download_raw(String(item[1]), _pending_raw_dir.path_join(String(item[0])))
	if _raw_outstanding > 0:
		return
	if _pending_raws.is_empty():
		var dir := _pending_raw_dir
		_pending_raw_dir = ""
		_pending_raws = []
		if _pt_story_file != "":
			_pt_write_video_extra(dir, _pt_story_file)
			_pt_story_file = ""
		_pz_busy = false
		_launch_or_done(dir)

var _raw_outstanding := 0

func _on_raw_file(dest: String, ok: bool) -> void:
	if _pending_raw_dir == "" or not dest.begins_with(_pending_raw_dir):
		return
	_raw_outstanding = maxi(_raw_outstanding - 1, 0)
	_dl_done += 1
	if not ok:
		# 单文件失败（404 等）只丢这一张：全量清单里个别资产缺失不该禁掉整谱贴图
		push_warning("QA: raw asset failed " + dest)
	_next_raw()


## 原生资源管理器选定谱面包 → 解到 user://local/<包名>/（重名自动加序号），成功后刷新本地页
func _import_local_pack(path: String) -> void:
	if not FileAccess.file_exists(path):
		print("QA-IMPORT missing ", path)
		return
	var nm := path.get_file().get_basename()
	for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		nm = nm.replace(bad, "_")
	if nm.strip_edges() == "":
		nm = "pack"
	var base := "user://local/" + nm
	var out := base
	var i := 1
	# 撞名判断不能只看 chart.json：official 包里根本没有 chart.json（每难度一份 IN.json/AT.json），
	# 只看它会让第二次导入直接盖进同一个目录。
	while _dir_has_chart(out):
		out = base + "-" + str(i)
		i += 1
	if _extract_pez(path, out):
		print("QA-IMPORT ok ", out)
		_select.refresh_local()
	else:
		print("QA-IMPORT fail ", path)
		DirAccess.remove_absolute(out)

## 目录里有没有谱面文件（chart.json 或任意 *.json，extra.json 不算）
func _dir_has_chart(dir: String) -> bool:
	if FileAccess.file_exists(dir.path_join("chart.json")):
		return true
	var da := DirAccess.open(dir)
	if da == null:
		return false
	da.list_dir_begin()
	var fn := da.get_next()
	while fn != "":
		if fn.get_extension().to_lower() == "json" and fn.to_lower() != "extra.json":
			da.list_dir_end()
			return true
		fn = da.get_next()
	da.list_dir_end()
	return false

func _extract_pez(pez_path: String, out_dir: String) -> bool:
	var z := ZIPReader.new()
	if z.open(pez_path) != OK:
		# 非 zip：RPE 裸 json 或 PhiEditer .pe —— 解析器按魔数自分发，原样落盘
		DirAccess.make_dir_recursive_absolute(out_dir)
		var cf := FileAccess.open(pez_path, FileAccess.READ)
		if cf == null:
			return false
		var w := FileAccess.open(out_dir.path_join("chart.json"), FileAccess.WRITE)
		if w == null:
			cf.close()
			return false
		w.store_buffer(cf.get_buffer(cf.get_length()))
		w.close()
		cf.close()
		return true
	var files := z.get_files()
	# info.txt / info.yml / info.csv 都吃（解析只在 ChartInfo 一处），先出现的赢。
	# RTX 20000 那种包只带 info.csv：以前这里啥也读不到，于是 Chart/Song/Picture 三根线
	# 全断，元数据也随源文件一起被丢掉 ⇒ 资料库里既没曲名也没伴奏。
	var info := {}
	var info_src := ""
	for f in files:
		var bn := f.get_file()
		if bn in ["info.txt", "info.yml", "info.yaml", "info.csv"]:
			if info.is_empty():
				info = ChartInfo.parse_text(z.read_file(f).get_string_from_utf8(), bn)
				info_src = bn
	var chart_n := String(info.get("chart", ""))
	var song_n := String(info.get("song", ""))
	var pic_n := String(info.get("picture", ""))
	# ── official 谱包（一个目录多难度）识别 ──
	# 判据跟原生 load_chart_json 用同一把尺子：根级有 "formatVersion" 就是 official
	# （RPE json 没这个键，它用 META/rpVersion）。旧实现只认 PE/RPE 那一套约定，于是
	# 用户报的三个症状全都能对上：
	#   ① 每个 json 都被改名成 chart.json ⇒ zip 里最后一份覆盖前面所有 → "只能导入一个谱面"；
	#   ② `.txt` 不在透传白名单里 ⇒ 难度 sidecar（IN.txt/AT.txt）全丢 → "没根据难度名.txt 自动加信息"；
	#   ③ 没有 info.txt 时 song_select._mk_entry 的默认难度就是 "IN Lv.?" → AT 的谱被写成 IN。
	var official := {}        # official json 的落盘名 → true（保留原名，一难度一份）
	for f in files:
		var jb := f.get_file()
		if jb.get_extension().to_lower() != "json" or jb.to_lower() == "extra.json":
			continue
		if z.read_file(f).get_string_from_utf8().contains("\"formatVersion\""):
			official[jb] = true
	# 两份以上 official json 时必须按名字各留一份（哪怕包里还带着 info.txt 指了其中一份，
	# 那种包按 chart.json 走会把第二、第三难度覆盖掉）；只有一份且包里有 Chart: 时，
	# 尊重包的约定走 chart.json。
	var multi_official: bool = official.size() > 1 or (official.size() == 1 and chart_n == "")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var da := DirAccess.open(out_dir)
	for f in files:
		var base := f.get_file()
		if base == "info.txt":
			# 原样落盘：PE 谱没有 META，曲名/难度只能从 info.txt 读（chart_stage._read_info）
			var iw := FileAccess.open(out_dir.path_join("info.txt"), FileAccess.WRITE)
			if iw != null:
				iw.store_buffer(z.read_file(f))
				iw.close()
			continue
		var ext := base.get_extension().to_lower()
		var target := ""
		if multi_official and official.has(base):
			target = base             # IN.json / AT.json 各自留一份，_scan_official 按文件认难度
		elif multi_official and ext == "txt" and official.has(base.get_basename() + ".json"):
			target = base             # 同名难度 sidecar：Name:/Level:/Composer:/Charter:
		elif base == chart_n or (chart_n == "" and ext == "json"):
			target = "chart.json"
		elif base == song_n or (song_n == "" and ext in ["ogg", "mp3", "wav"]):
			target = "song." + ext    # 舞台只认 song.*（其余音频按打击音效收）
		elif base == pic_n or (pic_n == "" and ext in ["webp", "jpg", "jpeg", "png"]):
			# official 包保留 illustration.* 原名（_cover_of 与舞台背景都认这个名字，
			# 而且谱面引用的线贴图也按原名找）；PE/RPE 包仍旧改名 bg.*
			target = base if multi_official else "bg." + ext
		elif ext in ["json", "txt", "png", "webp", "jpg", "jpeg", "gif", "apng", "glsl", "frag", "wav", "ogg", "mp3",
				"mp4", "webm", "ogv", "mov", "mkv", "csv", "yml", "yaml"]:
			target = base  # 附带资产（线贴图/extra.json/自定义 glsl/打击音效/视频）平铺落盘（导入谱完整性）
		if target != "":
			da.remove(target)
			var w := FileAccess.open(out_dir.path_join(target), FileAccess.WRITE)
			if w != null:
				w.store_buffer(z.read_file(f))
				w.close()
	# 只有 csv/yml 的包：把归一结果回写成一份 info.txt，资料库与舞台读的是同一套键
	# （和"PZ 下载完成后把服务器元数据固化成 info.txt"沿用同一条约定；已有 info.txt 的包不动）
	if info_src != "" and info_src != "info.txt" and not info.is_empty() \
			and not FileAccess.file_exists(out_dir.path_join("info.txt")):
		var gw := FileAccess.open(out_dir.path_join("info.txt"), FileAccess.WRITE)
		if gw != null:
			gw.store_string(ChartInfo.to_info_txt(info))
			gw.close()
	z.close()
	if multi_official:
		return not official.is_empty() and DirAccess.open(out_dir) != null
	return FileAccess.file_exists(out_dir.path_join("chart.json"))

## 开谱=必然重的一帧（解析 + 曲绘烘焙 + 模糊链），所以整段放进黑幕里做
func _launch_stage(dir_path: String, chart_f: String = "") -> void:
	_dip_then(UiTokens.DUR_DIP, _launch_stage_now.bind(dir_path, chart_f), UiTokens.DUR_DIP_OUT)

## 舞台底：屏幕比宽于 16:9 时左右多出来的两条**不是纯黑**，而是同一张（烘焙过模糊的）曲绘
## 继续铺出去——背景只处理一次，不给两侧单独一层（用户："背景还是一次处理，不是两边加特殊处理"）。
## 压暗系数取舞台自己的 background_luminance，让带子和画布里的背景同亮度，接缝才读不出来。
## 纯黑那层留着当兜底：谱包没图、图还没加载完时不能透出选曲页。
var _stage_bg: ColorRect
var _stage_bg_tex: TextureRect
var _results: ResultPage      # PT 结算页（打完才出现；继续→回选曲，重玩→重开本谱）
var _last_play := {}          # 重玩要的入场参数：目录/指定谱文件


func _make_stage_backdrop() -> void:
	if is_instance_valid(_stage_bg):
		return  # 重玩时底图（模糊曲绘）原样留着，两侧带不必重新铺过
	_stage_bg = ColorRect.new()
	_stage_bg.color = Color(0, 0, 0, 1)
	_stage_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_stage_bg)
	_stage_bg_tex = TextureRect.new()
	_stage_bg_tex.texture = load("res://assets/covers/cover_01.png")  # 开谱成功后换成谱面曲绘
	_stage_bg_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_stage_bg_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_stage_bg_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage_bg_tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_stage_bg_tex)


func _launch_stage_now(dir_path: String, chart_f: String = "") -> void:
	_last_play = {"dir": dir_path, "chart": chart_f}  # 结算页"重玩"要用同一份入场参数
	_make_stage_backdrop()
	var s := ChartStage.new()
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	s.chart_file = chart_f  # official 多难度目录：指定 IN.json 等；空=chart.json
	if _qa_skin != "":
		s.skin_dir = _qa_skin  # A/B 对拍：换 player 默认 respack 验证皮肤贡献
	elif _pending_skin_dir != "":
		s.skin_dir = _pending_skin_dir  # PT customRes：只作用于本局
		print("QA-PT skin=", _pending_skin_dir)
	_pending_skin_dir = ""
	if _lowres:
		s.render_scale = 0.5  # F10 低预设跨开谱保持
	# hint/record_key 必须在 open() 前注入——open() 内 _build_hud 就要读它们（PE 谱无 META 全靠这条链）
	s.record_key = _pending_key
	s.hint_name = str(_pending_hint[0])
	s.hint_level = str(_pending_hint[1])
	_pending_key = ""
	_pending_hint = ["", ""]
	if not s.open(dir_path):
		push_warning("chart load failed")
		s.free()  # 没进树的 Node 不归树管：不手动释放就漏一份舞台
		_remove_stage_backdrop()  # 开谱失败也得把底撤掉，否则一层全黑糊在页面上
		return
	_stage_bg_tex.texture = s._bg.texture if is_instance_valid(s._bg) else null
	# 两侧与画布内同亮度：直接用舞台背景的压暗系数，这样"一条带"读起来就是同一张背景延伸出去
	var bg_lum: float = clampf(s.background_luminance, 0.05, 1.0)
	_stage_bg_tex.modulate = Color(bg_lum, bg_lum, bg_lum, 1)
	s.background_ready.connect(_on_stage_bg)
	s.results_ready.connect(_show_results)
	s.finished.connect(_close_player)
	add_child(s)
	_stage = s
	_select.visible = false
	_hud.visible = false
	s.start()
	# 噪域 Active 层提到 HUD 之上（官方=后处理）；与 QA 定帧脚本共用同一个方法，
	# 免得"我截的图"和"他实机看到的"不是同一层序
	s.place_block_overlay(self, 52)  # HUD(50) 之上、噪域 Active 层、相机滤镜(60) 之下
	_maybe_record(s)                 # 「渲染录制」开着：这一局不进游玩，改出片（见 render_record.gd）

func _on_stage_bg(tex: Texture2D) -> void:
	if is_instance_valid(_stage_bg_tex):
		_stage_bg_tex.texture = tex

func _remove_stage_backdrop() -> void:
	if is_instance_valid(_stage_bg):
		_stage_bg.queue_free()
	_stage_bg = null
	if is_instance_valid(_stage_bg_tex):
		_stage_bg_tex.queue_free()
	_stage_bg_tex = null

## ── 全局背景虚化（设置页「背景模糊」）────────────────────────────────────
## 舞台里那套烘焙（cover 裁剪 → 降采样 → GPU 高斯级联 → 放大/压暗/抖动）挪到了
## scripts/bg_blur.gd，菜单这边只是"拿同一张底图再烘一遍"，所以两处的糊量完全一致。
var _bg_img: TextureRect = null
var _bg_src: Texture2D = null      # 默认底图（main_bg）
var _bg_cur: Texture2D = null      # 当前底图：选曲页点歌后是那首歌的曲绘
var _bg_deb := 0                   # 换底图的防抖令牌（连续点卡片只烘最后一张）
var _bg_want := 0        # 每次请求自增：烘焙中途参数又变了就丢掉旧结果
var _bg_busy := false
var _bg_key := ""        # 已烘过的 (模糊量|视口尺寸)：没变就不再重烘

func _rebake_menu_bg() -> void:
	if _bg_img == null or _bg_src == null:
		return
	_bg_want += 1
	var want := _bg_want
	var src: Texture2D = _bg_cur if _bg_cur != null else _bg_src
	# 菜单底图只取**一半**糊量（用户 2026-10-26："模糊为一半"）：main_bg 只有 756×614，
	# 按 115·屏高/900 全量糊会变成纯色块，构图全没了；皮肤演示带那边用完整量。
	var blur := UserPrefs.num("bg_blur") * 0.5
	var vs := get_viewport_rect().size
	var key := "%d|%.3f|%.1fx%.1f" % [src.get_instance_id(), blur, vs.x, vs.y]
	if key == _bg_key and _bg_img.texture != null:
		return                      # 同一套参数已经烘过
	_bg_key = key
	if blur <= 0.001:
		_bg_img.texture = src   # 0 = 不糊：原图直出
		return
	if _bg_busy:
		return                      # 正在烘：等它收尾时会自己补一次（见下面 want 比较）
	_bg_busy = true
	var img := src.get_image()
	if img != null:
		img.convert(Image.FORMAT_RGBA8)
		var out: Image = await BgBlur.bake(self, img, vs, blur, 1.0)
		if out != null and want == _bg_want:
			_bg_img.texture = ImageTexture.create_from_image(out)
			print("QA-BG 菜单底图已烘 blur=%.2f size=%s px=%s" % [blur, out.get_size(),
					str(out.get_pixel(out.get_width() / 2, out.get_height() / 2))])
		elif out == null:
			print("QA-BG 菜单底图烘焙失败 blur=%.2f" % blur)
	_bg_busy = false
	if want != _bg_want:
		_rebake_menu_bg()

## 选曲页选中某首歌：整页底图换成它的曲绘（糊量同菜单=一半），换页/回菜单再换回 main_bg。
## 连续点卡片会连发，这里防抖 0.15s，只烘最后一张。
func _bg_use(tex: Texture2D) -> void:
	_bg_cur = tex if tex != null else _bg_src
	_bg_deb += 1
	var tok := _bg_deb
	await get_tree().create_timer(0.15).timeout
	if tok == _bg_deb:
		_rebake_menu_bg()

func _late_bg_check() -> void:
	await get_tree().create_timer(1.0).timeout
	_rebake_menu_bg()

var _bg_resize_tok := 0

## 窗口尺寸一变，糊径要按新的短边重算（拖窗口时防抖 0.35s）
func _on_vp_resized() -> void:
	_bg_resize_tok += 1
	var tok := _bg_resize_tok
	await get_tree().create_timer(0.35).timeout
	if tok == _bg_resize_tok:
		_rebake_menu_bg()

## 拆台：结算页 + 舞台 + 底图一起收。_close_player（回选曲）和 _replay（重开）共用，
## 差别只在收完之后干什么。
func _teardown_play() -> void:
	_free_results()
	if _stage == null:
		_remove_stage_backdrop()
		return
	if _stage._blocks_on and is_instance_valid(_stage._bout):
		_stage._bout.queue_free()  # 噪域层挂在 game 层（不在舞台子树里），不随舞台一起释放
	_stage.queue_free()
	_stage = null
	_remove_stage_backdrop()

func _close_player() -> void:
	if _stage == null and _results == null:
		return
	_teardown_play()
	# 先铺黑再拆台：舞台那串 SubViewport/滤镜链释放不是一帧能吸收的，露在转场里就是卡顿
	_dip_lift(UiTokens.DUR_DIP_OUT)
	_select.visible = true
	_hud.visible = true
	_select.refresh_records()  # 打完回来：详情行评级/分数/Acc 换成本局（若刷新了纪录）
	_select.reveal()           # 回到选曲=整套控件重新逐级浮现（黑幕揭开时正好在放）

## 打完：铺 PT 结算页。舞台不拆——结算页的底色就是那张模糊曲绘，拆了反而要重铺。
func _show_results(payload: Dictionary) -> void:
	if is_instance_valid(_results) or _stage == null:
		return
	var r := ResultPage.new()
	r.setup(payload)
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	r.z_index = 70  # HUD(50)/噪域层(52)/GlitchFx(60) 之上：结算页是本局的终点态
	r.continue_pressed.connect(_close_player)
	r.replay_pressed.connect(_replay)
	add_child(r)
	_results = r
	_hud_on_results(true)  # 头像旁边那条详情也要在结算上（复用常驻 HUD，不复制组件）
	print("QA-RESULT name=", payload.get("name"), " level=", payload.get("level"),
			" score=", payload.get("score_str"), " acc=", payload.get("acc_str"),
			" combo=", payload.get("max_combo"), " P/G/B/M=", payload.get("perfect"), "/",
			payload.get("good"), "/", payload.get("bad"), "/", payload.get("miss"),
			" 早/晚=", payload.get("early"), "/", payload.get("late"),
			" best=", payload.get("best_str"), " delta=", payload.get("delta_str"),
			" new=", payload.get("new_best"), " badge=", str(payload.get("badge")))

## 重玩：收掉结算页与旧舞台，用同一份入场参数重新开谱（底图留着，两侧带不闪）。
func _replay() -> void:
	if _stage == null or _last_play.is_empty():
		return
	var dir := str(_last_play.get("dir", ""))
	var cf := str(_last_play.get("chart", ""))
	_pending_key = _stage.record_key
	_pending_hint = [_stage.hint_name, _stage.hint_level]
	_free_results()
	if _stage._blocks_on and is_instance_valid(_stage._bout):
		_stage._bout.queue_free()
	_stage.queue_free()
	_stage = null
	_launch_stage(dir, cf)

func _free_results() -> void:
	if is_instance_valid(_results):
		_results.queue_free()
	_results = null
	_hud_on_results(false)  # HUD 跟着结算页一起收：回舞台/回选曲由各自那条路摆可见性

## 结算页要留着"头像 + 旁边那条详情"（用户要求），但**不复制一份组件**：把跨页面常驻的
## PlayerHud 提到结算页（z=70）之上，并按选曲页那一档 SELECT_SCALE 缩放——尺寸/字号/位置
## 全部与别处同源，HUD 自己改常量这里就跟着变。
func _hud_on_results(v: bool) -> void:
	if not is_instance_valid(_hud):
		return
	_hud.visible = v
	_hud.z_index = 80 if v else 50
	_hud.set_hud_scale(PlayerHud.SELECT_SCALE)

## Android 手势返回/物理返回键有两条投递路：① Window.go_back_requested 信号
## ② NOTIFICATION_WM_GO_BACK_REQUEST —— 而 **通知是递归传播的**（Object::notification
## 默认 recurse=true，会一路传到舞台和它的每个子节点）。
## 所以绝不能在 _notification 的调用栈里拆台：`_close_player()` 里 queue_free 舞台时，
## 传播循环手上还握着这些节点 → 后面有人对 freed instance 调方法，手机上就是
## "滑动返回直接崩溃"。这里两条投递都只**登记一次请求**，真正动作放到 deferred 里做。
var _back_pending := false

func _request_back() -> void:
	if _back_pending:
		return  # 同一按键的信号+通知两路投递，只算一次
	_back_pending = true
	_back_pressed.call_deferred()

func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	_request_back()

## 返回键的层级语义（用户指定）：游玩中=先暂停，已暂停=退本局；
## 选曲/设置=回上一个界面；主菜单=吞掉（永不退出进程）。
func _back_pressed() -> void:
	_back_pending = false
	if is_instance_valid(_stage) and _stage.visible:
		if is_instance_valid(_results):
			_close_player()  # 结算页：返回等同那颗「继续」→ 回选曲
			return
		if _stage._paused:
			_close_player()  # 已经暂停了，再按一次才真的退本局
		else:
			_stage.request_pause()  # 游玩中：返回=暂停（PT 暂停层）
		return
	if _select.visible:
		if _select.popup_open():
			_select.close_popup()  # 与 Esc 同一条逐层收：弹窗 → 页码输入 → 放大层 → 回菜单
		elif _select.jump_editing():
			_select.close_jump_edit()
		elif _select.zoom_open():
			_select.close_zoom()
		else:
			_back_to_menu()
		return
	if is_instance_valid(_settings) and _settings.visible:
		_back_to_menu()
		return
	# 主菜单/过场/闪屏期间：什么都不做（退出用系统手势的第二下或任务键）

func _back_to_menu() -> void:
	# 与进场对称：当前二级页整页淡出让位，菜单按钮再逐级浮回来
	var pg: Control = _page_ctl if _page_ctl != null else _select
	pg.fade_out(_hide_page)
	_menu.visible = true
	_hud.set_hud_scale(PlayerHud.MENU_SCALE)  # 主菜单整组 1.2 倍（选曲/结算=1.0 基准口径）
	_hud.set_identity_visible(true)  # 设置页收掉的头像/简要在这里放回来（其余页面本就是可见）
	_menu.reveal()
	# 从设置页回来时把皮肤重新贴一遍：舞台只在**建谱**时读一次 skin_pack，
	# 不补这一下就是"换了包回到游戏还是上一个包"（用户报的换包不生效）
	if _stage != null and is_instance_valid(_stage):
		_stage.apply_skin_pack()
	# 回到菜单：底图换回 main_bg（选曲时被换成了那首歌的曲绘）
	_bg_cur = _bg_src
	# 「背景模糊」改了量：菜单底图跟着重烘（舞台那边下次建谱时自己读新值）
	_rebake_menu_bg()

func _hide_page() -> void:
	if _page_ctl != null:
		_page_ctl.visible = false
		_page_ctl = null

var _un_n := 0  # QA 诊断：_unhandled_input 分发计数与处理时长（µs 累计）
var _un_us := 0

func _input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		if _rec != null and ev.keycode == KEY_ESCAPE:
			_rec.cancel()   # 录制中 Esc=收手：已经渲出来的部分照常拼成片
			return
		var ch := ""
		if ev.unicode >= 65 and ev.unicode <= 122:   # 只收字母：功能键 unicode=0，char(0) 会报错
			ch = String(char(ev.unicode)).to_upper()
		_rec_code(ch)
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F10:
		_lowres = not _lowres
		# Window 没有 content_scale_scale（4.7 实名 content_scale_factor，且那是 UI 缩放不是降分辨率）；
		# 整屏降采样由舞台 _csv 的 render_scale 承担（backbuffer 等价物）
		if _stage != null:
			_stage.set_render_scale(0.5 if _lowres else 1.0)
		print("QA-LOWRES ", _lowres)

var _lowres := UserPrefs.flag("low_res")  # F10 低预设：backbuffer+全部特效 SubViewport 半分辨率（填充量 ×1/4）
											  # 初值来自设置页，F10 只改本次会话（与 hi_res 同一口径）

## ── 渲染录制（REC 彩蛋 / 设置页「渲染」两类同一个键，见 render_record.gd）────
var _rec: RenderRecorder = null
var _rec_limit := 0            # QA：只录前 N 帧（--qarender=秒）
var _rec_force := false        # QA：本次强制录制（不改 prefs，避免留下设置污染）
var _rec_block := false        # 子进程渲染工作器里不许再起一条录制（见 _rec_worker）
var _rec_qa_wh := Vector2i.ZERO
var _rec_qa_fps := 0
var _rec_qa_mbps := 0          # QA：本次强制码率（不改 prefs，用来验 CBR 是否贴着设定值）
var _rec_qa_workers := 0       # QA：本次强制并行进程数（不改 prefs）
const REC_CODE := "REC"
var _code_s := ""
var _splash: SplashOverlay = null   # 子进程要自己把开场遮罩收掉（它会糊在录出来的帧上）

## 主菜单逐字母攒 "REC"：只在主菜单且没有二级页时收——选曲页搜索框里打 rec 不该翻开关。
func _rec_code(ch: String) -> void:
	if ch == "" or not _menu.visible or _page_ctl != null:
		_code_s = ""
		return
	var i := _code_s.length()
	if i < REC_CODE.length() and ch == String(REC_CODE[i]):
		_code_s += ch
	elif ch == String(REC_CODE[0]):
		_code_s = String(REC_CODE[0])   # "RRE" 也要能从第二个 R 重新起头
	else:
		_code_s = ""
	if _code_s == REC_CODE:
		_code_s = ""
		_toggle_rec()

func _toggle_rec() -> void:
	var on := RenderRecorder.toggle()
	var msg := "渲染录制：关"
	if on:
		msg = "渲染录制：开 · %s · %dfps · %dMbps · %s" % [RenderRecorder.res_label(),
				UserPrefs.int_of("rec_fps"), UserPrefs.int_of("rec_mbps"),
				"H264" if UserPrefs.int_of("rec_vcodec") == 0 else "H265"]
		if not RenderRecorder.has_encoder():
			msg += "（这台设备没有可用编码器，进谱面照常打）"
	print("QA-REC toggle on=", on, " ", msg)
	_toast(msg)

## 子进程入口。spec = dir|chart|skin|tmp|k|from|to|w|h|fps|mbps|codec
## 走和平时完全一样的开谱路径（皮肤包、谱内字体、PT 自定义资源都在），
## 差别只有：只渲自己那段、不编码、写完块+音轨片段+完成标记就退。
func _rec_worker(spec: String) -> void:
	var p := spec.split("|")
	if p.size() < 12:
		print("QA-REC worker 参数不完整: ", spec)
		get_tree().quit(1)
		return
	_rec_block = true
	if is_instance_valid(_splash):
		_splash._finish()
	_menu.visible = false
	_select.visible = false
	_hud.visible = false
	_pending_skin_dir = String(p[2])
	_last_play = {"dir": String(p[0]), "chart": String(p[1])}
	_launch_stage(String(p[0]), String(p[1]))
	# 开谱是异步的（_launch_stage 走黑幕 tween，建台在 tween 中点的回调里），必须等
	var t := 0.0
	while _stage == null and t < 120.0:
		await get_tree().create_timer(0.5).timeout
		t += 0.5
	if _stage == null:
		print("QA-REC worker 开谱失败 ", p[0])
		get_tree().quit(1)
		return
	var codecs := int(p[11])
	var st := _stage
	var r := RenderRecorder.new()
	add_child(r)
	_rec = r
	r.finished.connect(_on_worker_done)
	r.start(st, {
		"w": int(p[7]), "h": int(p[8]), "fps": float(p[9]), "mbps": int(p[10]),
		"vcodec": codecs >> 1, "acodec": codecs & 1,
		"out": "",
		"song": ProjectSettings.globalize_path(st.song_file) if st.song_file != "" else "",
		"worker": true, "tag": "w%d" % int(p[4]),
		"from": int(p[5]), "to": int(p[6]), "tmp": String(p[3]),
		"dir": String(p[0]), "chart": String(p[1]), "skin": String(p[2]),
		"extras": [_stage_bg, _stage_bg_tex],
	})

func _on_worker_done(info: Dictionary) -> void:
	print("QA-REC worker 退出 ok=", info.get("ok"), " err=", info.get("error"))
	get_tree().quit(0 if bool(info.get("ok", false)) else 3)

## 开谱时开关是亮的 ⇒ 不进游玩，改跑离线渲染。编码器不可用时如实退回正常游玩。
func _maybe_record(s: ChartStage) -> void:
	if _rec != null or _rec_block:
		return
	if not (UserPrefs.flag("render_rec") or _rec_force):
		return
	if not RenderRecorder.has_encoder():
		return
	# 预设档固定 16:9（用户定案）；只有"自定义"是精确像素
	var sz := RenderRecorder.target_size()
	if _rec_qa_wh != Vector2i.ZERO:
		sz = _rec_qa_wh
	var rfps := float(UserPrefs.int_of("rec_fps"))
	if _rec_qa_fps > 0:
		rfps = float(_rec_qa_fps)
	var dirv := RenderRecorder.video_dir()
	var nm := PtApi.clean_name("%s %s" % [s.hint_name, s.hint_level]).strip_edges()
	if nm == "":
		nm = s.hint_name if s.hint_name != "" else "chart"
	# 手机走 MediaStore（相册 Pictures/PhiTogetherNext）：重名由系统自动加 (1)(2)，
	# 这里查不到文件系统，就不做去重
	var out := RenderRecorder.output_path(nm)
	if not out.begins_with("mediastore:"):
		var dup := 2
		while FileAccess.file_exists(out):
			out = RenderRecorder.output_path("%s (%d)" % [nm, dup])
			dup += 1
	var r := RenderRecorder.new()
	add_child(r)
	_rec = r
	r.finished.connect(_on_rec_done)
	r.start(s, {
		"w": sz.x, "h": sz.y,
		"fps": rfps,
		"mbps": _rec_qa_mbps if _rec_qa_mbps > 0 else UserPrefs.int_of("rec_mbps"),
		"vcodec": UserPrefs.int_of("rec_vcodec"),
		"acodec": UserPrefs.int_of("rec_acodec"),
		"out": ProjectSettings.globalize_path(out),
		"song": ProjectSettings.globalize_path(s.song_file) if s.song_file != "" else "",
		"limit": _rec_limit,
		# 两侧那条背景延伸带是 game 层的节点，跟舞台一起搬进离屏画布才不会被录成黑边
		"extras": [_stage_bg, _stage_bg_tex],
		# 多进程：一张谱切成 K 段，主进程渲第 0 段，其余段交给子进程
		"workers": _rec_qa_workers if _rec_qa_workers > 0
				else RenderRecorder.worker_count(s.note_total()),
		"dir": str(_last_play.get("dir", "")),
		"chart": str(_last_play.get("chart", "")),
		"skin": s.skin_dir,
	})

func _on_rec_done(info: Dictionary) -> void:
	if is_instance_valid(_rec):
		_rec.queue_free()
	_rec = null
	if bool(info.get("ok", false)):
		print("QA-REC toast 已录制 → ", info.get("path"))
		_toast("已录制 " + String(info.get("path", "")))
	else:
		_toast("录制失败：" + String(info.get("error", "?")))
	_close_player()

## 一句话浮层：给彩蛋/录制结果这类"当场就得看见、但不在任何一页里"的反馈用。
## 录制期间不许调它（浮层会被一起抓进片子里），所以两条录制反馈都在录制**之外**发。
func _toast(msg: String) -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		print("QA-TOAST ", msg)
		return
	var l := Label.new()
	l.text = msg
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.z_index = 95          # 曲库放大层(120)之下、GlitchFx(60) 之上
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", UiTokens.install_font())
	l.add_theme_color_override("font_color", UiTokens.INK)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.82))
	var fs := int(vp.y * 0.026)
	l.add_theme_font_size_override("font_size", maxi(fs, 10))
	l.position = Vector2(0.0, vp.y * 0.88)
	l.size = Vector2(vp.x, vp.y * 0.06)
	l.modulate.a = 0.0
	add_child(l)
	var tw := l.create_tween()
	tw.tween_property(l, "modulate:a", 1.0, 0.14)
	tw.tween_interval(1.8)
	tw.tween_property(l, "modulate:a", 0.0, 0.4)
	tw.tween_callback(_drop_toast.bind(l))

func _drop_toast(l: Label) -> void:
	if is_instance_valid(l):
		l.queue_free()


func _unhandled_input(ev: InputEvent) -> void:
	_un_n += 1
	var _t := Time.get_ticks_usec()
	# 同 chart_stage：action 判定先按事件类型门控，鼠标移动不再进 action 全扫
	if (ev is InputEventKey or ev is InputEventMouseButton) and _select.visible and ev.is_action_pressed("ui_cancel"):
		if _select.popup_open():
			_select.close_popup()  # Esc 逐层收：过滤/排序弹窗 → 页码输入 → 放大层 → 返回
		elif _select.jump_editing():
			_select.close_jump_edit()
		elif _select.zoom_open():
			_select.close_zoom()
		else:
			_back_to_menu()
	elif (ev is InputEventKey or ev is InputEventMouseButton) and _settings.visible \
			and ev.is_action_pressed("ui_cancel"):
		_back_to_menu()  # 设置页没有子层要收：Esc 直接回主菜单
	_un_us += int(Time.get_ticks_usec() - _t)


## QA：PT 谱面库页/下载游玩。--qapt=idx[,play]








## 抽样校验和：每 4099 字节取一个，够分辨"整帧没变"和"真变了"，又不用整帧扫
static func _qp_sig(im: Image) -> String:
	var d := im.get_data()
	var h := 0
	var i := 0
	while i < d.size():
		h = (h * 31 + int(d[i])) & 0x7FFFFFFF
		i += 4099
	return str(h) + "@" + str(im.get_size())


func _local_covers() -> Array:
	var out: Array = []
	for c in _select._grid._cards:
		if not c.visible:
			continue
		out.append([c.song_title, c.cover.get_instance_id() if c.cover != null else -1])
	return out
















## 合成真触屏事件走完整输入链（不是直接调 cp.touch_down——那样测不到 GDScript 的槽映射）。
## push_input 第二参 true=按本视口局部坐标解释，和舞台/原生画布同一坐标系。
## 画布系坐标 → 视口系：舞台被 16:9 上限挪到了屏幕中间（chart_stage._input 里
## 会再减掉这个偏移），探针注入真实触屏事件时必须按视口系给坐标。
func _c2v(pos: Vector2) -> Vector2:
	if _stage == null:
		return pos
	# 离屏 _csv 里的控件报的是**舞台内部**坐标（= 逻辑×_k，见 _fit_play_rect），
	# 打回根视口要先除以 _k 再加舞台位置
	return pos / (_stage as ChartStage)._k + (_stage as Control).position


func _push_touch(index: int, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.device = 0
	ev.position = _c2v(pos)
	ev.pressed = pressed
	get_viewport().push_input(ev, true)



func _wait_clock(t: float) -> void:
	while _stage != null and _stage._clock < t:
		await get_tree().process_frame

func _world_of(cp, line: int, idx: int) -> Vector2:
	for w in cp.debug_note_worlds(_stage._clock):
		if int(w[0]) == line and int(w[1]) == idx:
			return Vector2(float(w[2]), float(w[3]))
	return Vector2(-1, -1)

## 单条音符的判定态（0未判 1Perfect 2Good 3Bad 4Miss）——
## --qatypes 的红键/划动断言要看"这一条"，聚合计数会被同轴的邻近音符带偏。
func _note_state(cp, line: int, idx: int) -> int:
	for nd in cp.debug_notes():
		if int(nd[0]) == line and int(nd[1]) == idx:
			return int(nd[15])
	return -1






## ── 平板自动巡测（标记文件驱动，不用手点）───────────────────────────────
## Android 上没有命令行通道（实测 `am start --esa args` 与 `--es cmdline` 都进不了
## Godot 的 args），但 adb 能写应用自己的 external 目录（/sdcard/Android/data/<包名>/files/，
## 实测可写）。所以巡测入口=那里的 `ptn_tour.txt`：存在就自动逐张跑本地谱，
## 每张打一行 QA-TOUR，最后一行汇总——"所有谱面最低 119 / 平均 120"就靠这张表归因。
## 内容（空格分节，都可省）：`ALL [秒数] [起点比例] [目录名过滤]`
##   `ALL 20 0.5`   每张从它时长的 50% 处起测 20 秒
##   `ALL 25 0.8 SY` 只测目录名含 SY 的，从 80% 处测 25 秒
## 为什么从"比例"起测而不是从头：谱面前段普遍稀疏，从头测会把每张谱都判成"没问题"，
## 归因必须落在真的堆音符的那一段。seek 之后先等 0.6s 再清零统计——跳秒本身会卡一下，
## 那一下不算谱面的账。
const TOUR_SECS := 20.0
const TOUR_AT := 0.5
















## 成对交错的部件归因：每一项都"开着量 3s → 立刻关掉再量 3s"，取同一小节的差。
## 为什么不再是顺序扫掠（perfP 的教训）：那张表从 108.7 一路读到 113.0，可漂的原因不是开关，
## 而是谱面在往前走（越往后越薄）——单项差值 ±2~4fps 完全被这个漂移吃掉，量不出结论。
## 成对之后同一对里两项只隔 3 秒，密度基本一样，Δ 才是这一项自己的账。
## 每一项还同时报"迟到一整拍的帧数"（13~18ms 那一档）：平均帧率是结果，迟到帧才是原因。
## QA-AB 用：往舞台上面叠 8 层全屏半透明矩形，作为"GPU 到底有没有余量"的探针。
## 为什么需要它：这台板在 Vulkan 交换链上**不接受 VSync Disabled**（真机日志直接回退到
## Enabled），所以拿不到"裸算力"读数；而 ±1fps 的开关对照又分不出谁在花钱。
## 叠 8 层全屏 ≈ 每帧多写读 130MB：如果帧率因此塌下去，说明我们本来就在 GPU 上限上，
## 剩下那 10fps 只能从"少画一层"里省；如果几乎不动，说明 GPU 有大把余量，
## 那 10fps 是提交/排程的账，画得少也没用——两种结论会导出完全不同的下一步。
var _ab_load_rects: Array = []













func _press_key(kc: Key) -> void:
	var k := InputEventKey.new()
	k.keycode = kc
	k.pressed = true
	get_viewport().push_input(k, true)
	k.pressed = false
	get_viewport().push_input(k, true)





func _seg_of(key: String) -> Array:
	for d in _settings._spec["rows"]:
		if String((d as Dictionary).get("k", "")) == key:
			return (d as Dictionary).get("_segs", [])
	return []

## 取当前分类里某一行的行 dict（控件引用都挂在它身上）。换分类后必须重新取。
func _row_of(key: String) -> Dictionary:
	for d in _settings._spec["rows"]:
		if String((d as Dictionary).get("k", "")) == key:
			return d as Dictionary
	return {}

func _ctl_of(key: String) -> Control:
	for d in _settings._spec["rows"]:
		if String((d as Dictionary).get("k", "")) == key:
			return (d as Dictionary).get("_ctl", null)
	return null






## 一次"真返回"的两条投递：信号 + 递归通知（引擎在 Android 上就是两条都发）
func _press_back() -> void:
	get_window().go_back_requested.emit()
	get_window().notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)






func _type_char(ch: String) -> void:
	var k := InputEventKey.new()
	k.unicode = ch.unicode_at(0)
	k.pressed = true
	get_viewport().push_input(k, true)
	k.pressed = false
	get_viewport().push_input(k, true)

func _press_enter() -> void:
	var k := InputEventKey.new()
	k.keycode = KEY_ENTER
	k.unicode = 13
	k.pressed = true
	get_viewport().push_input(k, true)
	k.pressed = false
	get_viewport().push_input(k, true)

## 合成一次真实拖拽：按下(带 button_mask)→分段位移→松开(mask 归零)。
## 设置页的手势滚动、滑条拖动都要靠它走真实输入通道，而不是直接调函数。
func _drag_to(from: Vector2, to: Vector2, steps := 6, release := true) -> void:
	_push_motion(from, MOUSE_BUTTON_MASK_LEFT)
	_push_press(from)
	for i in range(1, steps + 1):
		_push_motion(from.lerp(to, float(i) / float(steps)), MOUSE_BUTTON_MASK_LEFT)
	if release:
		_push_release(to)

func _push_motion(at: Vector2, mask := MOUSE_BUTTON_MASK_LEFT) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = at
	mm.global_position = at
	mm.button_mask = mask
	get_viewport().push_input(mm, true)

func _push_press(at: Vector2) -> void:
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.position = at
	mb.global_position = at
	mb.button_mask = MOUSE_BUTTON_MASK_LEFT
	mb.pressed = true
	get_viewport().push_input(mb, true)

func _push_release(at: Vector2) -> void:
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.position = at
	mb.global_position = at
	mb.button_mask = MOUSE_BUTTON_MASK_LEFT
	mb.pressed = false
	get_viewport().push_input(mb, true)

func _click_at(at: Vector2, dbl := false) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = at
	mm.global_position = at
	get_viewport().push_input(mm, true)
	var tap := InputEventMouseButton.new()
	tap.button_index = MOUSE_BUTTON_LEFT
	tap.position = at
	tap.global_position = at
	tap.pressed = true
	tap.double_click = dbl  # 合成事件里视口不自判双击，第二击手动置位
	tap.button_mask = MOUSE_BUTTON_MASK_LEFT  # 缺 mask 时视口命中测试会忽略该事件
	get_viewport().push_input(tap, true)
	tap.pressed = false
	tap.button_mask = 0
	tap.double_click = false
	get_viewport().push_input(tap, true)

## 一次"按住并从 a 拖到 b"：给"拖动不该算点击"那条判定当反证。
## 中间补 6 段 motion（SwipeScroll 靠它滚，卡片靠它知道手走远了），
## 抬起点的 button_mask 归零，跟真实鼠标一致。
func _drag_at(a: Vector2, b: Vector2) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = a
	mm.global_position = a
	get_viewport().push_input(mm, true)
	var tap := InputEventMouseButton.new()
	tap.button_index = MOUSE_BUTTON_LEFT
	tap.position = a
	tap.global_position = a
	tap.pressed = true
	tap.button_mask = MOUSE_BUTTON_MASK_LEFT
	get_viewport().push_input(tap, true)
	for i in 6:
		var p := a.lerp(b, float(i + 1) / 6.0)
		var md := InputEventMouseMotion.new()
		md.position = p
		md.global_position = p
		md.relative = p - a
		md.button_mask = MOUSE_BUTTON_MASK_LEFT
		get_viewport().push_input(md, true)
	tap.position = b
	tap.global_position = b
	tap.pressed = false
	tap.button_mask = 0
	get_viewport().push_input(tap, true)

## 贴图指纹 = 尺寸 + **第一个不透明像素**。对"渲染器上现在真的是哪张图"用它，
## 不能比对象（SkinPack.textures() 每次调用都新建 ImageTexture），也不能固定取 (2,2)：
## 内置 Tap 与 PT 官方包的左上角都是全透明的，取 (2,2) 会得到两条一样的签名。
func _tex_sig(t: Texture2D) -> String:
	if t == null:
		return "null"
	var img := t.get_image()
	if img == null:
		return "%dx%d/?" % [t.get_width(), t.get_height()]
	img = img.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(int(sqrt(float(w * h) / 4000.0)), 1)
	for y in range(0, h, step):
		for x in range(0, w, step):
			var c := img.get_pixel(x, y)
			if c.a > 0.5:
				return "%dx%d@%d,%d%s" % [w, h, x, y, c.to_html(3)]
	return "%dx%d/全透明" % [w, h]



func _opaque_bbox(im: Image) -> Rect2i:
	# QA 取证：内容覆盖 bbox。贴图若有透明通道按 alpha>8 判，否则按亮度>8 判。
	# 网格抽点（≈20 万样本上限）足够判断"半幅 vs 全幅"。
	var w := im.get_width()
	var h := im.get_height()
	var step := maxi(int(sqrt(float(w * h) / 200000.0)), 1)
	var has_alpha := im.get_format() in [Image.FORMAT_RGBA8, Image.FORMAT_RGBA16, Image.FORMAT_RGBAH]
	var minp := Vector2i(w, h)
	var maxp := Vector2i(-1, -1)
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			var c := im.get_pixel(x, y)
			var lit := false
			if has_alpha and c.a < 0.98:
				lit = c.a * 255.0 > 8.0
			else:
				lit = maxf(c.r, maxf(c.g, c.b)) * 255.0 > 8.0
			if lit:
				if x < minp.x:
					minp.x = x
				if y < minp.y:
					minp.y = y
				if x > maxp.x:
					maxp.x = x
				if y > maxp.y:
					maxp.y = y
			x += step
		y += step
	if maxp.x < 0:
		return Rect2i()
	return Rect2i(minp, Vector2i(maxp.x - minp.x + 1, maxp.y - minp.y + 1))

func _wait_frame() -> bool:
	var got := [false]
	var cb := func() -> void: got[0] = true
	RenderingServer.frame_post_draw.connect(cb, CONNECT_ONE_SHOT)
	var to := get_tree().create_timer(3.0)
	while not got[0] and to.time_left > 0.0:
		await get_tree().process_frame
	if not got[0]:
		RenderingServer.frame_post_draw.disconnect(cb)
		return false
	return true
