class_name LoginCard
extends Control
## 「登录 PhiZone」卡片：点头像弹出。三步（协议 → 账号密码 → 连接结果）。
## 版式按用户 2026-10-27 的草图：卡片居中、宽 80%屏宽、高 80%屏高、圆角 = 10% 卡片高；
## 顶部 18% 是标题区（左标题 + 右 1-2-3 步骤点），20%→80% 是文字/功能区，82% 以下是按钮区。
## 弹出时：整屏拍一张→糊掉垫在最下面（"后面的 UI 会模糊"），卡片本身 50% 透明、渐显。
## 只有登录之后才允许连 PZ 社区（game 侧把 PhiZone 页挡在 logged() 之后）。

const BgBlur := preload("res://scripts/bg_blur.gd")

signal cancelled
signal continue_pressed(step: int)

const W_RATIO := 0.80      # 卡片宽 = 80% 屏宽
const H_RATIO := 0.80      # 卡片高 = 80% 屏高
const RADIUS_OF_H := 0.10  # 圆角 = 10% 卡片高
const TITLE_H := 0.18      # 标题+步骤区占卡片高 18%
const BODY_TOP := 0.20     # 功能区从 20% 起
const BODY_BOTTOM := 0.80  # 到 80% 止
const BTN_TOP := 0.82      # 82% 以下是按钮区
const PANEL_ALPHA := 0.5   # 卡片底自身的不透明度（用户 2026-10-28："卡片应该是 50% 透明"）
const DIM := 0.55          # 遮罩黑度：垫底的截图按 (1-DIM) 乘暗，等价于盖一层 55% 黑
const BACKDROP_BLUR := 0.16  # 弹窗背后那张截图的糊量（115·此值 px @900 高，≈18px）——主观旋钮
const AGREE_TEXT := """《用户协议》

一、软件性质
本软件为离线单机客户端。游玩过程与成绩记录全部保存在本机，不依赖任何在线服务即可完整使用。

二、PhiZone 账号的用途
登录 PhiZone 账号仅用于访问社区谱面资源，即检索谱面列表、下载谱面及其素材。
除上述只读操作外，本软件不会向 PhiZone 服务器提交任何数据，
包括但不限于游玩成绩、判定参数、设备信息与配置项。

三、凭据的保存与删除
登录获得的访问令牌仅保存在本机用户目录（user://pz_session.json），不会转发给任何第三方。
您可随时退出登录以删除该文件。账号与密码请自行妥善保管。

四、责任范围
本软件为非官方的开发版本，与 PhiZone 社区不存在隶属或授权关系。
社区内容的合法性、可用性与准确性由社区自身负责；因通过本软件访问社区资源
而产生的账号风险、数据损失或其他后果，本软件不承担相应责任。

五、支持渠道
本软件处于开发阶段，登录与网络相关问题请先在本机自查（网络环境、账号密码、软件版本）。
请勿就本软件引起的问题联系 PhiZone 社区管理员，以免占用其社区管理资源。

六、条款生效
点击「继续」即表示您已阅读、理解并同意上述全部条款。"""

var step := 1          # 1=协议 2=账号密码 3=连接
var card: Control
var _title: Label
var _body: Label
var _scroll: ScrollContainer
var _edit_user: LineEdit
var _edit_pass: LineEdit
var _btn_cancel: NeoButton
var _btn_next: NeoButton
var _dots: StepDots
var _backdrop: TextureRect     # 弹出瞬间拍的那张全屏（清楚版，先垫底）
var _backdrop2: TextureRect    # GPU 高斯到货的那张，淡入盖上去 = 渐渐模糊
const BLUR_FADE := 0.30        # 清楚→模糊的交叉淡入时长（主观旋钮）
var _panel_bg: TextureRect    # 卡片底：SDF 抗锯齿烘出来的圆角纹理（不是 StyleBoxFlat）
var _panel_key := ""
var _shot := false            # 拿到截图了没（拿到就不再用 _draw 画遮罩黑）
var _pending_shot: Image      # 拍下来待糊的那一张（只拍一次，卡片关掉后也不再回头取）

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP           # 卡片是模态的：别把点击漏到下面的页面
	_grab_backdrop()
	card = Control.new()   # 底由 _panel_bg 那张抗锯齿纹理负责，Panel/StyleBoxFlat 的圆角是硬边
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(card)
	_panel_bg = TextureRect.new()
	_panel_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_panel_bg.stretch_mode = TextureRect.STRETCH_SCALE
	card.add_child(_panel_bg)   # 最先加 = 永远在标题/输入框/按钮底下
	_title = _lbl(UiTokens.TITLE_FONT, UiTokens.INK)
	_body = _lbl(UiTokens.BODY_FONT, UiTokens.INK_SUB)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# 全站口径"手势滑动，不要滑动条"（4.7 里 visible 会被容器下一轮布局改回来，
	# 唯一稳的是把两个样式盒置空——没得画，最小宽度自然塌成 0，滚轮/拖拽照旧）
	var vsb := _scroll.get_v_scroll_bar()
	vsb.add_theme_stylebox_override("scroll", StyleBoxEmpty.new())
	vsb.add_theme_stylebox_override("scroll_background", StyleBoxEmpty.new())
	card.add_child(_title)
	card.add_child(_scroll)
	_scroll.add_child(_body)
	_edit_user = _edit("账号 / 邮箱")
	_edit_pass = _edit("密码")
	_edit_pass.secret = true
	card.add_child(_edit_user)
	card.add_child(_edit_pass)
	_btn_cancel = _btn("取消")
	_btn_next = _btn("继续")
	_btn_cancel.pill = true
	_btn_next.pill = true
	_btn_next.accent = UiTokens.ACCENT
	card.add_child(_btn_cancel)
	card.add_child(_btn_next)
	_dots = StepDots.new()
	_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(_dots)   # 必须在 card 里面：板底是 card 画的，点在板底之上才看得见
	_btn_cancel.pressed.connect(_on_cancel)
	_btn_next.pressed.connect(_on_next)
	resized.connect(_layout)
	_layout()
	_show_step(1)
	# 只渐显，不放大（用户 2026-10-28："出现卡片时不透明度遮罩是渐显，不是放大"）。
	# 垫底那张截图是本卡片的子节点，所以这一个 alpha 同时把"遮罩变黑 + 背景变糊"推到位。
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

## 弹的瞬间把画面拍下来糊掉垫底：模态期间后面的东西本来就不动，一次烘焙零运行时开销
## （跟舞台曲绘背景同一个思路，别每帧采屏幕纹理——那张 hint_screen_texture 在根画布上是实测过的掉帧源）。
## 先立刻贴原图（保证第一帧就有遮罩），GPU 高斯到货再换糊的那张：
## 用 CPU 的"缩小再放大"糊整屏会在曲库斜纹上打出马赛克（欠采样），那条路只配当开屏近似。
func _grab_backdrop() -> void:
	var shot := get_viewport().get_texture().get_image()
	if shot == null or shot.is_empty() or shot.get_width() < 8:
		return   # 拿不到（headless/被遮挡）就退回 _draw 里那层纯黑遮罩
	shot.convert(Image.FORMAT_RGBA8)
	_backdrop = TextureRect.new()
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop.stretch_mode = TextureRect.STRETCH_SCALE
	_backdrop.texture = ImageTexture.create_from_image(shot)
	# 乘暗 = 盖一层 (1-x) 黑，同一件事但不用再多画一层
	_backdrop.modulate = Color(1.0 - DIM, 1.0 - DIM, 1.0 - DIM, 1.0)
	add_child(_backdrop)   # 在 card 之前 add ⇒ 永远垫在卡片下面
	# 第二层：糊好的那张先以 0 透明度等着，到货后淡入 ⇒ "渐渐模糊"而不是一帧跳糊。
	# 必须 add 在清楚那张**之后**：树序决定绘制序，反过来就永远看不见模糊层（踩过一次）。
	_backdrop2 = TextureRect.new()
	_backdrop2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop2.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop2.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop2.stretch_mode = TextureRect.STRETCH_SCALE
	_backdrop2.modulate = Color(1.0 - DIM, 1.0 - DIM, 1.0 - DIM, 0.0)
	add_child(_backdrop2)
	_shot = true
	_pending_shot = shot
	_blur_backdrop.call_deferred()

## 截图只拍一次（在卡片自己画出来之前）；烘的时候卡片可能已经被关掉，
## 所以 host 用根视口、像素用存下来的那张，不再回头 get_viewport()/get_texture()。
func _blur_backdrop() -> void:
	if _pending_shot == null:
		return
	var host: Node = get_tree().root
	var img: Image = _pending_shot
	_pending_shot = null
	var vs := Vector2(img.get_width(), img.get_height())
	var blurred: Image = await BgBlur.bake(host, img, vs, BACKDROP_BLUR, 1.0)
	# 压暗由 modulate 做，这里 lum 给 1.0（不再叠一层黑）
	if blurred == null or not is_instance_valid(_backdrop2):
		return
	_backdrop2.texture = ImageTexture.create_from_image(blurred)
	_backdrop2.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_backdrop2, "modulate:a", 1.0, BLUR_FADE) 			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)

func _lbl(fs: int, ink: Color) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", ink)
	return l

func _edit(ph: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = ph
	e.add_theme_font_size_override("font_size", UiTokens.BUTTON_FONT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiTokens.SURFACE_PANEL
	sb.set_corner_radius_all(UiTokens.R_BUTTON)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	for s in ["normal", "read_only", "focus"]:
		e.add_theme_stylebox_override(s, sb)
	# 4.7 Android 不会自动弹软键盘（memory）：聚焦时手动唤
	e.focus_entered.connect(func() -> void:
		if not DisplayServer.has_hardware_keyboard():
			DisplayServer.virtual_keyboard_show(e.text))
	e.focus_exited.connect(func() -> void: DisplayServer.virtual_keyboard_hide())
	return e

func _btn(t: String) -> NeoButton:
	var b := NeoButton.new()
	b.set_caption(t)
	return b

func _layout() -> void:
	var vs := get_viewport_rect().size
	if vs.x <= 1.0 or vs.y <= 1.0:
		return
	var cw: float = vs.x * W_RATIO
	var ch: float = vs.y * H_RATIO
	var ox: float = (vs.x - cw) * 0.5
	var oy: float = (vs.y - ch) * 0.5
	card.position = Vector2(ox, oy)
	card.size = Vector2(cw, ch)
	_sync_panel(int(cw), int(ch), int(ch * RADIUS_OF_H))
	# 下面全部是**卡片本地**坐标：这些控件都挂在 card 下，再带一次 ox/oy 就是偏移两遍。
	var pad: float = cw * 0.045
	_title.position = Vector2(pad, ch * 0.045)
	_title.size = Vector2(cw * 0.55, ch * 0.09)
	_body.add_theme_font_size_override("font_size", maxi(int(ch * 0.030), 13))
	# 功能区随步骤换位置：第 2 步要腾出两个输入框，提示文字落在它们下面
	if step == 2:
		_scroll.position = Vector2(pad, ch * 0.55)
		_scroll.size = Vector2(cw - pad * 2.0, ch * (BODY_BOTTOM - 0.55))
	else:
		_scroll.position = Vector2(pad, ch * BODY_TOP)
		_scroll.size = Vector2(cw - pad * 2.0, ch * (BODY_BOTTOM - BODY_TOP))
	# ScrollContainer 不给子节点宽度 ⇒ autowrap 会量到 0 高、文字消失。
	# 用 custom_minimum_size.x 把可用宽度喂给 Label（4.7 实测唯一稳的写法）。
	_body.custom_minimum_size = Vector2(maxf(_scroll.size.x - 12.0, 16.0), 0.0)
	_edit_user.position = Vector2(pad, ch * 0.26)
	_edit_user.size = Vector2(cw - pad * 2.0, ch * 0.11)
	_edit_pass.position = Vector2(pad, ch * 0.405)
	_edit_pass.size = Vector2(cw - pad * 2.0, ch * 0.11)
	var bh: float = ch * 0.11
	var bw: float = cw * 0.30
	_btn_cancel.position = Vector2(pad, ch * BTN_TOP + (ch * (1.0 - BTN_TOP) - bh) * 0.5)
	_btn_cancel.size = Vector2(bw, bh)
	_btn_next.position = Vector2(cw - pad - bw, _btn_cancel.position.y)
	_btn_next.size = Vector2(bw, bh)
	for b in [_btn_cancel, _btn_next]:
		b._sync_icon()
		(b as NeoButton).set_font_size(maxi(int(bh * 0.42), 14))
	_dots.rad = ch * 0.035
	_dots.gap = _dots.rad * 3.2
	var dw: float = _dots.rad * 2.0 + _dots.gap * 2.0
	_dots.size = Vector2(dw, _dots.rad * 2.0)
	_dots.position = Vector2(cw - pad - dw, ch * TITLE_H * 0.5 - _dots.rad)
	_dots.step = step
	_dots.queue_redraw()
	queue_redraw()

func _draw() -> void:
	# 有垫底截图时，遮罩黑已经乘进那张图里了（_backdrop.modulate），别再盖一层。
	if _shot:
		return
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), Color(0, 0, 0, DIM))

## 卡片底纹理：尺寸/圆角变了才重烘（一次弹窗最多烘两三张，拖窗口时按档复用）。
func _sync_panel(w: int, h: int, r: int) -> void:
	if w < 8 or h < 8 or _panel_bg == null:
		return
	var border := maxi(int(h * 0.004), 1)
	var fill := Color(0.075, 0.068, 0.090, PANEL_ALPHA)
	var key := "%dx%d|%d|%d|%s" % [w, h, r, border, fill.to_html(true)]
	_panel_bg.position = Vector2.ZERO
	_panel_bg.size = Vector2(w, h)
	if key == _panel_key and _panel_bg.texture != null:
		return
	_panel_key = key
	_panel_bg.texture = bake_panel(w, h, r, border, fill, UiTokens.BORDER_FAINT)

## 圆角面板烘焙。StyleBoxFlat / draw_polygon 的圆角边是**硬**的（canvas 三角填充不做边缘
## 抗锯齿），卡片圆角有 10% 屏高这么大，台阶就看得见了（用户 2026-10-28："圆角还是有问题，
## 还是有毛边"）。这里走项目里 SongCard/AvatarCircle 同一套路：整块用 fill_rect 铺，
## 只有四个 r×r 角块逐像素算 SDF 覆盖率——1280×720 的卡片也只算 4×72² 个点。
static func bake_panel(w: int, h: int, r: int, border: int, fill: Color, edge: Color) -> Texture2D:
	var rr := mini(r, int(mini(w, h) * 0.5))
	var b := mini(border, rr)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	# 描边色铺满整个圆角矩形轮廓：十字区（不含四角）直接填，角块稍后逐像素
	if w - 2 * rr > 0:
		img.fill_rect(Rect2i(rr, 0, w - 2 * rr, h), edge)
	if h - 2 * rr > 0:
		img.fill_rect(Rect2i(0, rr, w, h - 2 * rr), edge)
	# 主体色：内缩 border 的同形状
	var iw: int = w - 2 * b
	var ih: int = h - 2 * b
	var ir: int = maxi(rr - b, 0)
	if iw - 2 * ir > 0:
		img.fill_rect(Rect2i(b + ir, b, iw - 2 * ir, ih), fill)
	if ih - 2 * ir > 0:
		img.fill_rect(Rect2i(b, b + ir, iw, ih - 2 * ir), fill)
	var half := Vector2(w * 0.5, h * 0.5)
	var ihalf := Vector2(iw * 0.5, ih * 0.5)
	var io := Vector2(b, b)
	for cy in 2:
		for cx in 2:
			var x0: int = cx * (w - rr)
			var y0: int = cy * (h - rr)
			for y in rr:
				for x in rr:
					var p := Vector2(x0 + x + 0.5, y0 + y + 0.5)
					var cov: float = SongCard._sdf_coverage(p, half, rr)
					if cov <= 0.001:
						continue
					var c := edge.lerp(fill, SongCard._sdf_coverage(p - io, ihalf, ir))
					# 覆盖率只削边缘那半个像素，不能拿来顶掉面板自己的透明度：
					# 写成 c.a = cov 会让四个角块变成**不透明**，50% 透明的卡片上多出四块暗角
					c.a *= cov
					img.set_pixel(x0 + x, y0 + y, c)
	return ImageTexture.create_from_image(img)

func _show_step(s: int) -> void:
	step = s
	_title.text = "登录 PhiZone"
	_btn_next.set_caption("继续" if s < 3 else "完成")
	_scroll.visible = true
	_edit_user.visible = s == 2
	_edit_pass.visible = s == 2
	match s:
		1:
			_body.text = AGREE_TEXT
		2:
			if _body.text == AGREE_TEXT:
				_body.text = ""
		3:
			_body.text = "正在连接 PhiZone…"
	_layout()

## 第 2 步下方的提示/错误行（空账号、登录失败都走这里）；顺带把卡片拉回第 2 步。
func set_hint(t: String) -> void:
	if step != 2:
		_show_step(2)
	_body.text = t
	_layout()

func set_status(t: String) -> void:
	if step == 3:
		_body.text = t

func user_name() -> String:
	return _edit_user.text.strip_edges()

func user_pass() -> String:
	return _edit_pass.text

func _on_cancel() -> void:
	cancelled.emit()

func _on_next() -> void:
	if step == 1:
		_show_step(2)
		queue_redraw()
		return
	continue_pressed.emit(step)   # 2=去登录 3=完成（由 game 决定何时关卡片）

func goto(s: int) -> void:
	_show_step(s)

## 标题区右侧的 1-2-3 步骤点：当前及已完成步实心粉底、未到的步只描边，点之间一条细线连着。
## 单独一个子 Control 而不是画在 LoginCard._draw 里——父节点的内容永远压在子节点 card 的板底下面。
class StepDots extends Control:
	var step := 1
	var rad := 20.0
	var gap := 64.0
	func _draw() -> void:
		var cy := size.y * 0.5
		for i in 3:
			var c := Vector2(rad + gap * i, cy)
			var active: bool = (i + 1) <= step
			draw_circle(c, rad, UiTokens.ACCENT if active else Color(0, 0, 0, 0))
			if not active:
				draw_arc(c, rad, 0, TAU, 48, UiTokens.INK_SUB, maxf(rad * 0.10, 1.0))
			draw_string(ThemeDB.fallback_font, c + Vector2(-rad * 0.34, rad * 0.42), str(i + 1),
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, maxi(int(rad * 1.15), 10),
					Color(0.10, 0.06, 0.09) if active else UiTokens.INK_SUB)
			if i < 2:
				draw_line(c + Vector2(rad, 0), c + Vector2(gap - rad, 0), UiTokens.INK_SUB, 1.5)
