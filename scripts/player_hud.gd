class_name PlayerHud
extends Control
## 跨页面常驻玩家信息组件：头像 + 名称胶囊 + RKS/等级两枚胶囊，整体贴右上角。
## 口径（用户 2026-10-27 照 Cytoid 结算页重画）：头像直径 = 10% 屏高，圆右缘距屏右
## 2.5% 屏宽、圆顶距屏顶 2.5% 屏宽；主菜单整组再乘 MENU_SCALE=1.2。选曲页与结算页用的
## 就是这一份（game._hud_on_results 复用常驻 HUD，不复制组件）。
## 胶囊宽度"根据具体长度来"：由文字最小尺寸撑开，右缘统一收到头像左边。

const AV_D := 0.10          # 头像直径（屏高占比）
const AV_RIGHT_M := 0.025   # 圆右缘距屏右（屏宽占比）
const AV_TOP_M := 0.025     # 圆顶距屏顶（屏宽占比）
const MENU_SCALE := 1.2     # 主菜单整组放大倍数
const SELECT_SCALE := 1.0   # 选曲/结算=基准口径（页面布局让位以这组为准）
const GAP := 0.012          # 头像与胶囊、胶囊与胶囊的间隙（屏高占比）
const CHIP_FILL := Color(0.09, 0.09, 0.10, 0.72)  # Cytoid 那层"比黑幕略亮"的 chip 底
# 数值来源：本地还没有 Rating/等级/经验的服务端口径（PlayRecords 只存分数/Acc/连击），
# 这三项是常驻占位，要接真数据只改这里一处。
const PLAYER_NAME := "PZ_Player"
const PLAYER_RKS := 10.42
const PLAYER_LEVEL := 24
# 未登录口径（用户 2026-10-27 指定）：名称 Player、RKS --.---、Level ?
const GUEST_NAME := "Player"
const GUEST_RKS := "--.---"
const GUEST_LEVEL := "?"

var logged_in := false    # 登录端口前恒为 false ⇒ 三枚胶囊一律走 GUEST_*

signal avatar_pressed   # 点头像 = 开「登录 PhiZone」卡片（game 侧接）

var avatar: AvatarCircle
var _chip_name: PanelContainer
var _chip_rks: PanelContainer
var _chip_lv: PanelContainer
var _lv_fill: PillProgress  # Level 胶囊底子的经验条（PZ 经验值的表现）
var _chips: Array = []  # [{p:PanelContainer, l:Label, sb:StyleBoxFlat}]
var _scale := MENU_SCALE  # 整组缩放：开屏就在主菜单 ⇒ 初值必须是菜单档（用户："一开始在主菜单是选曲界面的大小"）
var _scale_tw: Tween

## 身份区（头像 + 三枚胶囊）整体显隐：进二级页时用户要求"直接隐藏头像与用户简要"，
## 回主菜单再放回来。只动这些节点的 visible，不碰 HUD 的其余游玩件。
func set_identity_visible(v: bool) -> void:
	(avatar as CanvasItem).visible = v
	for c in _chips:
		(c["p"] as CanvasItem).visible = v

func set_hud_scale(v: float) -> void:  # 不能叫 set_scale：Control 原生已有 set_scale(Vector2)
	if _scale_tw != null and _scale_tw.is_valid():
		_scale_tw.kill()
	_scale_tw = create_tween()
	_scale_tw.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	_scale_tw.tween_method(_set_scale_now, _scale, v, 0.4)

func _set_scale_now(v: float) -> void:
	_scale = v
	_layout()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_chip_name = _chip(GUEST_NAME, UiTokens.INK)
	_chip_rks = _chip("RKS " + GUEST_RKS, UiTokens.INK_SUB)
	_chip_lv = _chip("Level " + GUEST_LEVEL, UiTokens.INK_SUB)
	# 经验条塞在 Level 胶囊里、文字之下（PanelContainer 把子节点铺满同一格 ⇒ 先加的在下层）
	_lv_fill = PillProgress.new()
	_chip_lv.add_child(_lv_fill)
	_chip_lv.move_child(_lv_fill, 0)
	avatar = AvatarCircle.new()
	add_child(avatar)  # 后加 = 画在胶囊之上，头像保持完整圆形
	# 头像是这一区里唯一可点的控件（根节点仍 IGNORE，别挡页面其它点击）
	avatar.mouse_filter = Control.MOUSE_FILTER_STOP
	avatar.gui_input.connect(_on_avatar_input)
	get_viewport().size_changed.connect(_layout)
	_layout()

## 登录态变化时刷新三枚胶囊的文字（宽度"根据具体长度来"，下一次 _layout 自动重算）。
func set_logged_in(v: bool) -> void:
	logged_in = v
	_lbl_of(_chip_name).text = PLAYER_NAME if v else GUEST_NAME
	_lbl_of(_chip_rks).text = ("RKS %.2f" % PLAYER_RKS) if v else ("RKS " + GUEST_RKS)
	_lbl_of(_chip_lv).text = ("Level %d" % PLAYER_LEVEL) if v else ("Level " + GUEST_LEVEL)
	_layout()

func _lbl_of(p: PanelContainer) -> Label:
	var e := _entry(p)
	return e["l"] if not e.is_empty() else null

func _on_avatar_input(ev: InputEvent) -> void:
	# 先按类型分流再碰 pressed：InputEventMouseMotion 也是 InputEventWithModifiers，
	# 但它没有 pressed 属性，头像改成可点后每帧移动都会来一次这里。
	if ev is InputEventMouseButton:
		var b := ev as InputEventMouseButton
		if not b.pressed or b.button_index != MOUSE_BUTTON_LEFT:
			return
		avatar_pressed.emit()
	elif ev is InputEventScreenTouch:
		if not (ev as InputEventScreenTouch).pressed:
			return
		avatar_pressed.emit()

## 登录成功后一次性把三枚胶囊的值换掉（PZ 口径：名称=userName、RKS=rks、等级/经验=experience）。
func set_identity(nm: String, rks: float, level: int, exp_frac: float) -> void:
	logged_in = true
	_lbl_of(_chip_name).text = nm
	_lbl_of(_chip_rks).text = "RKS %.2f" % rks
	_lbl_of(_chip_lv).text = "Level %d" % level
	set_level_progress(exp_frac)
	_layout()

func _chip(txt: String, ink: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = CHIP_FILL
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = txt
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_color_override("font_color", ink)
	p.add_child(l)
	add_child(p)
	_chips.append({"p": p, "l": l, "sb": sb})
	return p

func _entry(p: PanelContainer) -> Dictionary:
	for c in _chips:
		if c["p"] == p:
			return c
	return {}

## 摆一枚胶囊：右缘贴 right_x、顶在 y、高 h，宽度由文字撑（"根据具体长度来"）。返回宽度。
func _place(p: PanelContainer, right_x: float, y: float, h: float, fs: int) -> float:
	var e := _entry(p)
	if e.is_empty():
		return 0.0
	var sb: StyleBoxFlat = e["sb"]
	var lbl: Label = e["l"]
	sb.set_corner_radius_all(int(h * 0.5))
	sb.content_margin_left = h * 0.46
	sb.content_margin_right = h * 0.46
	sb.content_margin_top = h * 0.04
	sb.content_margin_bottom = h * 0.04
	lbl.add_theme_font_size_override("font_size", fs)
	p.custom_minimum_size = Vector2(0, h)
	p.reset_size()
	var ms: Vector2 = p.get_combined_minimum_size()
	p.size = Vector2(maxf(ms.x, h), maxf(ms.y, h))
	p.position = Vector2(right_x - p.size.x, y)
	return p.size.x

func _layout() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	var d: float = vp.y * AV_D * _scale
	var right: float = vp.x - vp.x * AV_RIGHT_M
	var top: float = vp.x * AV_TOP_M
	avatar.position = Vector2(right - d, top)
	avatar.size = Vector2(d, d)
	avatar.queue_redraw()
	# 两行胶囊：上行名称、下行 RKS + 等级，整组以头像垂直中心对称，右缘留一道间隙
	var cx: float = right - d - vp.y * GAP
	var cy: float = top + d * 0.5
	var h: float = d * 0.40
	var fs: int = maxi(int(h * 0.50), 10)
	var gap2 := d * 0.06
	_place(_chip_name, cx, cy - h - gap2 * 0.5, h, fs)
	var lw: float = _place(_chip_lv, cx, cy + gap2 * 0.5, h, fs)
	_place(_chip_rks, cx - lw - vp.y * GAP * 0.5, cy + gap2 * 0.5, h, fs)
	# 经验条要铺满整颗胶囊：把胶囊的内容边距当"外扩量"告诉它（见 PillProgress.bleed）
	if _lv_fill != null and is_instance_valid(_lv_fill):
		_lv_fill.bleed = Vector2(h * 0.46, h * 0.04)
		_lv_fill.refresh()

## PZ 的 /me 带 avatar URL，取回来换掉本地默认头像（登录成功那一刻异步到货）。
## 换图必须走 set_source：AvatarCircle 按尺寸缓存烘好的圆贴图，直接赋 source 不会重烘。
func set_avatar(tex: Texture2D) -> void:
	if tex == null or avatar == null:
		return
	avatar.set_source(tex)

## 经验值的表现：Level 胶囊底子的进度条（0..1 = 本等级内经验占比）。
## 数值口径跟 PZ 走（等级即经验值换算），登录端口拿到 PZ 的 user.level/exp 之前恒为 0。
func set_level_progress(f: float) -> void:
	if _lv_fill != null and is_instance_valid(_lv_fill):
		_lv_fill.set_frac(f)
