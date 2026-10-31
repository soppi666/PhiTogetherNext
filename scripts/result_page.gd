class_name ResultPage
extends Control
## PT 结算页（sim-phi/renderer/ResultPage.ts）移植：版式、滑入时序、徽章缩放逐条照设计格抄。
##
## 设计格 = 1920×1080，PT 用 `q=(W−H/tan75°)/(16−9/tan75°)`、`u=q/120`、原点=画布中心−(960u,540u)
## 把它映射进 canvasos（ResultPage.ts:12-23）。**区域规则按用户指定改了**：结算块的左右边界落在
## **屏宽 5% 与 85%**（u = 0.8·W/1920，另夹一道"高不出屏"的保险）。这条区间不是居中——80% 宽居中
## 会跑到 10%→90%，所以设计原点直接钉在 x=5%·W，纵向仍按屏高居中、比例仍按 16:9 同比，
## 所以 PT 版式里的每个设计坐标、每组滑入/淡入曲线都原样成立，只是整块按比例缩放并左移。
##
## 与 PT 的两处差别（用户明确要求）：不搬 PT 的 DOM 导航条——
##   ① 两枚按钮：继续=与选曲页"开始游戏"完全相同的布局（`SongSelect.play_btn_rect()`），
##      按下回到刚才的选曲页；重玩=继续正上方隔 1.5% 屏高的同尺寸按钮，重开本谱。
##   ② 导航条里的"头像 + 旁边那条详情"要留在画面上：由 game 层把常驻 `PlayerHud` 提到本页之上
##      （尺寸/字号与选曲页同一档 `SELECT_SCALE`），本页不复制一份组件。

signal continue_pressed
signal replay_pressed

const WHITE := Color(1, 1, 1, 1)
const REGION_X0 := 0.05  # 结算块的左右边界 = 屏宽 5%→85%（用户指定）
const REGION_X1 := 0.85
const BTN_GAP := 0.015   # 继续↔重玩 的空隙（屏高占比）
const SHADE := Color(0, 0, 0, 0.45)  # 阴影：canvas 的 shadowBlur=40 把同一份黑摊到 40px 上，
									 # Godot 的盒阴影边缘实心得多，同色同尺寸会明显偏重 → 压 alpha
## 四组元素各自的滑入曲线 A,k,b：位移 = +A·(1 − ease10(clip(t·k − b)))（源行号见右）
const SL := {
	"card": [1920.0, 1.0, 0.0],     # :34/44/103/112/185
	"score": [1720.0, 1.0, 0.1],    # :59/175/195/204/211
	"acc": [1020.0, 0.9, 0.25],     # :68/145/151/158/165
	"judge": [1020.0, 0.8, 0.3],    # :76/223-289
}
## alpha = clip((t − b)·k)
const AL := {
	"score": [0.4, 2.0],            # :172
	"score2": [0.4, 2.5],           # :190
	"acc": [0.8, 1.5],              # :140
	"judge": [1.25, 2.5],           # :218
	"badge": [1.3, 3.75],           # :117
}

var data := {}
var _t := -1.0  # PT 在曲目结束 1s 后才 end.reset()/play()：起点设成 −1 让这一秒只留背景
var _u := 1.0
var _origin := Vector2.ZERO  # 设计原点在 _content 局部系里的位置
var _play := Rect2()

var _f: Font
## 背景只处理一次：整屏一张模糊曲绘 cover + 压暗 20%，不分"画布内/两侧带"两层
## （PT 那两层是 canvas 合成出来的产物，用户明确不要那种两边另处理的观感）
var _outer: TextureRect
var _content: Control        # clip 到画布矩形：canvas 本身就是边界，飞入途中的内容不得漏出
var _card_shadow: Panel
var _card_art: TextureRect
var _card_mat: ShaderMaterial
var _card_border: Panel
var _badge: TextureRect
var _labels: Array = []      # {n, dx, dy, dfs, sl, al, maxw}
var _panels: Array = []      # {n, sb, dx, dy, dw, dh, sl}
var _b_cont: NeoButton
var _b_retry: NeoButton
var _fps_lbl: Label = null   # 本局帧率 最大/平均/最小：调试模式才有（payload 带 fps 才建）
var _jingle: AudioStreamPlayer  # PT 的结算 BGM：LevelOver{难度}_v2，循环播（Loop.ts:61-72）
var _jingle_on := false

## 必须在 add_child 之前调用（_ready 里就要读 data 建文字）
func setup(d: Dictionary) -> void:
	data = d

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP  # 结算期间吞掉全部点击（舞台输入已关）
	_build()
	_layout()

func _process(delta: float) -> void:
	_t += delta  # PT 每帧整层重画；这里等价地每帧重设 rect/alpha
	# 结算 BGM：PT 在结束 1s 后（end 计时器起点的同一个 setTimeout 里）才放 LevelOver（Loop.ts:56-80）
	if _jingle != null and not _jingle_on and _t >= 0.0:
		_jingle_on = true
		_jingle.play()
	_layout()

# ── 建节点 ─────────────────────────────────────────────────────────────
func _build() -> void:
	_f = UiTokens.install_font()
	_outer = _rect_tex()
	add_child(_outer)
	_content = Control.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.clip_contents = true
	add_child(_content)

	# 曲绘卡三层：阴影（在剪贴之下）→ 圆角插图 → 描边（ResultPage.ts:32-53）
	_card_shadow = _box(Color(0, 0, 0, 0), SHADE, 40, 0)
	_content.add_child(_card_shadow)
	_card_art = TextureRect.new()
	_card_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_card_art.stretch_mode = TextureRect.STRETCH_SCALE
	_card_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_mat = ShaderMaterial.new()
	_card_mat.shader = load("res://shaders/round_clip.gdshader")
	_card_art.material = _card_mat
	_card_art.texture = data.get("art", null)
	_content.add_child(_card_art)
	_card_border = _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 1)
	_content.add_child(_card_border)

	_add_panel(1020.0, 180.0, 800.0, 360.0, "score")
	_add_panel(1020.0, 563.0, 800.0, 150.0, "acc")
	_add_panel(1020.0, 735.0, 800.0, 150.0, "judge")

	_badge = TextureRect.new()
	_badge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.texture = data.get("badge", null)
	_content.add_child(_badge)

	# 曲绘卡上的两行：73.5px 曲名（超 600 宽降号）/ 30px 难度（超 150 降号）—— :94-114
	_tx(str(data.get("name", "")), 130.0, 830.0, 73.5, HORIZONTAL_ALIGNMENT_LEFT, WHITE,
			"card", "", 600.0)
	_tx(str(data.get("level", "")), 940.0, 835.0, 30.0, HORIZONTAL_ALIGNMENT_RIGHT, WHITE,
			"card", "", 150.0)
	# 分数板：NEW BEST（:191 #a2e27f）/ 本次分（:171 86px）/ 历史最佳 + 差值（:198-212）
	_tx(str(data.get("new_best", "")), 1080.0, 337.0, 25.0, HORIZONTAL_ALIGNMENT_LEFT,
			Color("a2e27f"), "score", "score2", 0.0)
	_tx(str(data.get("score_str", "")), 1075.0, 415.0, 86.0, HORIZONTAL_ALIGNMENT_LEFT, WHITE,
			"score", "score", 0.0)
	_tx(str(data.get("best_str", "")), 1080.0, 460.0, 30.0, HORIZONTAL_ALIGNMENT_LEFT, WHITE,
			"score", "score2", 0.0)
	_tx(str(data.get("delta_str", "")), 1230.0, 460.0, 30.0, HORIZONTAL_ALIGNMENT_LEFT, WHITE,
			"score", "score2", 0.0)
	# 准度板：左 MAX COMBO、右 ACCURACY（:141-166，值 55px / 标签 26px）
	_tx(str(data.get("max_combo", 0)), 1075.0, 638.0, 55.0, HORIZONTAL_ALIGNMENT_LEFT, WHITE,
			"acc", "acc", 0.0)
	_tx("MAX COMBO", 1075.0, 673.0, 26.0, HORIZONTAL_ALIGNMENT_LEFT, WHITE, "acc", "acc", 0.0)
	_tx(str(data.get("acc_str", "")), 1765.0, 638.0, 55.0, HORIZONTAL_ALIGNMENT_RIGHT, WHITE,
			"acc", "acc", 0.0)
	_tx("ACCURACY", 1763.0, 673.0, 26.0, HORIZONTAL_ALIGNMENT_RIGHT, WHITE, "acc", "acc", 0.0)
	# 判定板：PERFECT/GOOD/BAD/MISS 四列（:215-261，值 45px / 标签 20px）
	var xs := [1120.0, 1268.0, 1375.0, 1482.0]
	var keys := ["perfect", "good", "bad", "miss"]
	var caps := ["PERFECT", "GOOD", "BAD", "MISS"]
	for i in 4:
		_tx(str(int(data.get(keys[i], 0))), xs[i], 812.0, 45.0, HORIZONTAL_ALIGNMENT_CENTER, WHITE,
				"judge", "judge", 0.0)
		_tx(caps[i], xs[i], 842.0, 20.0, HORIZONTAL_ALIGNMENT_CENTER, WHITE,
				"judge", "judge", 0.0)
	# 早/晚（:262-290：28px；标签左对齐 1590/1605，数值右对齐 1755）
	_tx("EARLY", 1590.0, 800.0, 28.0, HORIZONTAL_ALIGNMENT_LEFT, WHITE, "judge", "judge", 0.0)
	_tx("LATE", 1605.0, 838.0, 28.0, HORIZONTAL_ALIGNMENT_LEFT, WHITE, "judge", "judge", 0.0)
	_tx(str(int(data.get("early", 0))), 1755.0, 800.0, 28.0, HORIZONTAL_ALIGNMENT_RIGHT, WHITE,
			"judge", "judge", 0.0)
	_tx(str(int(data.get("late", 0))), 1755.0, 838.0, 28.0, HORIZONTAL_ALIGNMENT_RIGHT, WHITE,
			"judge", "judge", 0.0)
	# 本局帧率（调试模式才带，见 chart_stage._results_payload）：放在曲绘卡下方左侧空区，
	# 两枚按钮在右侧，互不冲突。打完一眼核对"最低 119 / 平均 120"。
	var fsd: Variant = data.get("fps", {})
	if fsd is Dictionary and not (fsd as Dictionary).is_empty():
		var fd: Dictionary = fsd
		_fps_lbl = Label.new()
		_fps_lbl.add_theme_font_override("font", _f)
		_fps_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
		_fps_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fps_lbl.text = "帧率  最大 %.0f · 平均 %.1f · 最小 %.0f" % [
				float(fd.get("max", 0.0)), float(fd.get("avg", 0.0)), float(fd.get("min", 0.0))]
		_content.add_child(_fps_lbl)

	_b_cont = _btn("继续")
	_b_cont.pressed.connect(func() -> void: continue_pressed.emit())
	_b_retry = _btn("重玩")
	_b_retry.pressed.connect(func() -> void: replay_pressed.emit())

	var jp := str(data.get("jingle", ""))
	if jp != "" and ResourceLoader.exists(jp):
		_jingle = AudioStreamPlayer.new()
		var s := load(jp)
		if s is AudioStreamOggVorbis:
			(s as AudioStreamOggVorbis).loop = true  # PT：audio.play(..., {loop: true})
		_jingle.stream = s
		add_child(_jingle)  # 必须先入树：AudioStreamPlayer 不在树里 play() 直接报错

func _rect_tex() -> TextureRect:
	var r := TextureRect.new()
	r.texture = data.get("bg", null)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.modulate = Color(0.8, 0.8, 0.8, 1)  # = 其上再铺 #000 α0.2：亮度 ×0.8
	return r

## 圆角板：填充/描边/阴影三件都可单独给（PT 用同一 roundRect 分别 fill 与 stroke）
func _box(fill: Color, shadow: Color, shadow_size: int, border: int) -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(30)
	sb.shadow_color = shadow
	sb.shadow_size = shadow_size
	sb.shadow_offset = Vector2.ZERO
	sb.set_border_width_all(border)
	sb.border_color = Color(0, 0, 0, 1)
	p.add_theme_stylebox_override("panel", sb)
	return p

## 三块黑板：fillStyle=black + globalAlpha=0.5 + roundRect(30)，canvas 的 40px 阴影一起乘 α
func _add_panel(dx: float, dy: float, dw: float, dh: float, sl: String) -> void:
	var p := _box(Color(0, 0, 0, 1), SHADE, 40, 0)
	p.modulate = Color(1, 1, 1, 0.5)
	_content.add_child(p)
	_panels.append({"n": p, "sb": p.get_theme_stylebox("panel"), "dx": dx, "dy": dy,
			"dw": dw, "dh": dh, "sl": sl})

func _tx(t: String, dx: float, dy: float, dfs: float, algn: int, col: Color,
		sl: String, al: String, maxw: float) -> void:
	var l := Label.new()
	l.text = t
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", _f)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = algn
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_content.add_child(l)
	_labels.append({"n": l, "dx": dx, "dy": dy, "dfs": dfs, "sl": sl, "al": al, "maxw": maxw})

func _btn(caption: String) -> NeoButton:
	var b := NeoButton.new()
	b.text = caption
	b.min_size_hint = Vector2.ZERO
	b.square_right = true  # 与开始游戏一样：右端出血 1%，右两角取直
	add_child(b)
	return b

# ── 每帧摆位 ───────────────────────────────────────────────────────────
func _layout() -> void:
	if size.x <= 0.0 or size.y <= 0.0 or _content == null:
		return
	var pw := minf(size.x, size.y * 16.0 / 9.0)
	_play = Rect2((size.x - pw) * 0.5, 0.0, pw, size.y)
	# 结算块 = 屏宽 5%→85%（用户指定，取代 PT 的 tan75 那条）。注意这条区间**不是居中**：
	# 80% 宽居中会落在 10%→90%，所以左边界要直接钉在 5%·W 上；右侧留白给那两枚按钮。
	# 再夹一道"1080 高不出屏"的保险，避免极扁屏上内容溢出。
	_u = minf(size.x * (REGION_X1 - REGION_X0) / 1920.0, size.y / 1080.0)
	_origin = Vector2(size.x * REGION_X0, size.y * 0.5 - 540.0 * _u)

	_outer.position = Vector2.ZERO
	_outer.size = size
	_outer.pivot_offset = size * 0.5
	# 裁剪框 = 整屏：块现在按屏幕定位（不再按 16:9 画布），飞入途中的内容仍要在屏外被切掉
	_content.position = Vector2.ZERO
	_content.size = size

	var rad := maxi(int(round(30.0 * _u)), 1)
	# 曲绘卡：终值 x=2010.24−1920=90.24，y=182，890×700，r=30（:42-49）
	var cp := _d2c(90.24 + _sx("card"), 182.0)
	var cd := Vector2(890.0, 700.0) * _u
	for nd in [_card_shadow, _card_border]:
		var pn: Panel = nd
		pn.position = cp
		pn.size = cd
		(pn.get_theme_stylebox("panel") as StyleBoxFlat).set_corner_radius_all(rad)
	# 插图：imgW=700·宽高比（不足 1200 取 1200）、imgH 同比，中心 (540.5, 530.5)（:26-40）
	if _card_art.texture != null:
		var tex := _card_art.texture
		var asp := float(tex.get_width()) / float(maxi(tex.get_height(), 1))
		var iw := 700.0 * asp
		var ih := 700.0
		if iw < 1200.0:
			iw = 1200.0
			ih = 1200.0 / maxf(asp, 0.0001)
		var box := Vector2(iw, ih) * _u
		var art_pos := _d2c(540.5 + _sx("card"), 530.5) - box * 0.5
		_card_art.position = art_pos
		_card_art.size = box
		_card_mat.set_shader_parameter("item_size", box)
		_card_mat.set_shader_parameter("card_pos", cp - art_pos)
		_card_mat.set_shader_parameter("card_size", cd)
		_card_mat.set_shader_parameter("radius", float(rad))
	for pb in _panels:
		var s2: Array = SL[pb["sl"]]
		var p2: Panel = pb["n"]
		p2.position = _d2c(_slide_x(pb["dx"], s2), pb["dy"])
		p2.size = Vector2(pb["dw"], pb["dh"]) * _u
		(pb["sb"] as StyleBoxFlat).set_corner_radius_all(rad)

	# 徽章：中心 (1685,373)，半径 410→246 走 ease15（:120-138），α=clip((t−1.3)·3.75)
	var rr := (410.0 - _e15(_clip((_t - 1.3) * 1.5)) * 164.0) * _u
	_badge.modulate.a = _alpha("badge")
	_badge.position = _d2c(1685.0, 373.0) - Vector2(rr, rr)
	_badge.size = Vector2(rr * 2.0, rr * 2.0)

	for it in _labels:
		var l: Label = it["n"]
		var dfs: float = it["dfs"] * _u
		var maxw: float = it["maxw"]
		if maxw > 0.0:
			var w0 := _f.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(round(dfs))).x
			if w0 > maxw * _u:
				dfs *= maxw * _u / w0  # PT：超宽就把字号按比例压下来
		var fs := clampi(int(round(dfs)), 8, 4096)
		l.add_theme_font_size_override("font_size", fs)
		var tw := _f.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var lx := _d2c(it["dx"] + _sx(it["sl"]), it["dy"]).x
		var bx := lx
		if l.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
			bx = lx - tw
		elif l.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
			bx = lx - tw * 0.5
		# canvas 的 y 是 baseline（textBaseline=alphabetic 是默认态），Godot Label 从框顶排：
		# 框顶 = baseline − ascent
		l.position = Vector2(bx, _d2c(0.0, it["dy"]).y - _f.get_ascent(fs))
		l.size = Vector2(tw, _f.get_ascent(fs) + _f.get_descent(fs))
		l.modulate.a = _alpha(it["al"])

	# 帧率行：跟判定板同一波淡入（_t 1.2s 起）
	if is_instance_valid(_fps_lbl):
		var fs2 := maxi(int(round(24.0 * _u)), 8)
		_fps_lbl.add_theme_font_size_override("font_size", fs2)
		_fps_lbl.position = _d2c(130.0, 955.0) - Vector2(0.0, _f.get_ascent(fs2))
		_fps_lbl.modulate.a = _clip((_t - 1.2) * 2.0)

	# 两枚按钮：与 song_select 的开始游戏同一套百分比布局（play_btn_rect 是唯一定义处），
	# 重玩在正上方隔 BTN_GAP（用户把这条空隙从 3% 收到 1.5%）
	var rect := SongSelect.play_btn_rect(size)
	_place(_b_cont, rect)
	_place(_b_retry, Rect2(rect.position.x, rect.position.y - rect.size.y - size.y * BTN_GAP,
			rect.size.x, rect.size.y))

## 板的滑入位移（与 _sx 同式，供设计 x 直接相加）
func _slide_x(dx: Variant, s: Array) -> float:
	return float(dx) + s[0] * (1.0 - _e10(_clip(_t * s[1] - s[2])))

func _alpha(id: String) -> float:
	if id == "":
		return 1.0
	var a: Array = AL[id]
	return _clip((_t - a[0]) * a[1])

func _place(b: NeoButton, rect: Rect2) -> void:
	b.position = rect.position
	b.size = rect.size
	b.fit_font()  # 字号规则与开始游戏同一条（NeoButton.fit_font）

## 设计坐标 → _content 局部坐标
func _d2c(x: float, y: float) -> Vector2:
	return _origin + Vector2(x, y) * _u

## x 位移：PT 源里写的是"起点常数 − A·ease10(...)"（如曲绘卡 2010.24−1920·ease10），
## 这里把每个元素的 dx 存成**终值**（90.24），位移等价地写成 +A·(1−ease10)：
## t=0 → dx+A（=PT 的起点，画布外右侧），t≥1 → dx。
func _sx(id: String) -> float:
	if id == "":
		return 0.0
	var s: Array = SL[id]
	return s[0] * (1.0 - _e10(_clip(_t * s[1] - s[2])))

func _clip(v: float) -> float:
	return clampf(v, 0.0, 1.0)

func _e10(p: float) -> float:  # tween.ease10 = 1 − (p−1)^4
	var d := p - 1.0
	return 1.0 - d * d * d * d

func _e15(p: float) -> float:  # tween.ease15 = p^5
	var s := p * p
	return s * s * p

## QA：把动画推到终态（t 越大越接近静止布局）
func fast_forward(sec: float) -> void:
	_t = sec

## QA：终态几何摘要，便于断言而不靠看图
func qa_geometry() -> Dictionary:
	return {
		"u": _u, "play": _play, "origin": _origin, "t": _t,
		"bg": _outer.get_global_rect(),  # 背景只有一层，且铺满整屏（不是"画布内+两侧带"两层）
		"card": _card_shadow.get_global_rect(),
		"score_panel": _panels[0]["n"].get_global_rect(),
		"acc_panel": _panels[1]["n"].get_global_rect(),
		"judge_panel": _panels[2]["n"].get_global_rect(),
		"badge": _badge.get_global_rect(),
		"cont": _b_cont.get_global_rect(), "retry": _b_retry.get_global_rect(),
		"score_text": (_labels[3]["n"] as Label).get_global_rect(),
	}
