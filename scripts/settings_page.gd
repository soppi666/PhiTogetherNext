class_name SettingsPage
extends Control
## 设置页：**与单人游戏页同一套外壳**——左侧一级导航带（返回钮 + 分类钮，几何常量直接引用
## SongSelect，两边共用一份规则才不会各长一份），右侧是内容带。
##
## 与单人游戏页的唯一区别（用户指定）：**没有那条 50% 透明底的二级带**（曲库带的条纹层），
## 也没有三级详情带——内容直接铺在页面背景上。
## 一级导航的五个分类：通用 / 画面 / 音量 / 游玩 / 关于。
##
## 值全部走 UserPrefs（与游玩中的判定补偿面板同一份 JSON、同一套范围）。
## 能当场生效的（帧率上限、垂直同步）立刻应用；需要重建离屏链/音频链的
## （内部分辨率、背景模糊/亮度、音量、判定窗口）在下次进入谱面时由 chart_stage 读盘生效
## ——每个分类底部那行小字说的就是这件事。

signal nav(id)

const CATS := [
	{"id": "general", "name": "通用"},
	{"id": "display", "name": "画面"},
	{"id": "render", "name": "渲染"},
	{"id": "volume", "name": "音量"},
	{"id": "play", "name": "游玩"},
	{"id": "skin", "name": "皮肤"},
	{"id": "about", "name": "关于"},
]

## 开/关两档的公共选项表（bool 键统一用它，别各处再手写一遍字面量）
const ON_OFF := [{"v": true, "t": "开"}, {"v": false, "t": "关"}]

## 行几何：全部按屏高/内容带宽百分比（与选曲页同一套"百分比尺寸"约定）
##
## ⚠ 这一组里凡是"和单人游戏同一个东西"的量，都**直接引用 SongSelect 的那份常量**，
## 不再抄一遍数字：上一版这里自己写了 TOOL_H=0.075、搜索框又另给了 0.052 高，
## 结果"搜索框比单人游戏的搜索框矮一截、两颗圆钮和药丸没对齐"（用户：必须一致相等）。
const CTRL_R := SongSelect.SEG_LIBRARY   # 控件组右边界=曲库带右界（用户：控件右界=屏宽 70%）
const ROW_H := 0.072      # 单行高（屏高占比）
const ROW_GAP := 0.016    # 行间距
## 数值框（=滑块）的高：**和"开/关"那一档等高**（=整行高 rh，用户 2026-10-30 第二版草图），
## 而且它不钉在轨道正中——它就是滑块（0.8 贴轨道左端、1.5 贴右端）。
## 第三版（用户 2026-10-30："删除滑动条的左右调整，现在改为输入数字"）：轨道两端那两颗
## 加减圆钮没有了 ⇒ 轨道直接铺到控件右界；数值框从"只读的 Panel+Label"换成一颗 LineEdit，
## 点它弹输入法、回车/失焦提交。几何判据（框=滑块、进度填到框左沿）一条都没变。
const VAL_BOX_H := 1.0
## 数值框（=滑块）的底：**不透明**的中性深灰，色值是**量出来的**，不是调出来的。
## 三轮反馈的完整链条：
## ① "数字背景应该隐藏后面的线条" → 不透明；
## ② "这数字的背景颜色不对，貌似更深了" → 实渲对比：旧值 bg(4)=(56,50,60) 带紫调，
##    邻居"开/关"是 50% 黑叠在页面上的**中性**色，实渲 (60,58,61)/(63,63,65)/(61,57,60)；
##    差的就是 G/B 两个通道 8~9 级（紫调），不是明度；
## ③ 试过"和开关同一份半透明黑 + 滑块底下不画槽"→ 轨道被劈成两根（他："这个条怎么
##    变成两个条了"），作废。
## 所以终版：轨道一整根连续胶囊，数值框不透明压在上面，颜色取邻居实渲的中位数
## (61,58,61)。背景是糊图、各处亮度不同，不透明底没法逐点跟随，取中位数是唯一的静态解。
static func val_box_fill() -> Color:
	return Color(61.0 / 255.0, 58.0 / 255.0, 61.0 / 255.0)
const VAL_BOX_PAD := 0.55                   # 框内文字左右内边距 = 字号倍数
const VAL_BOX_MAX := 0.42                   # 框最宽占轨道（再宽就盖住整条进度了）
const PAD_X := SongSelect.LIB_PAD    # 内容带左右内边距=曲库那条带同一份
const TITLE_Y := SongSelect.TOOL_Y   # 标题顶=曲库工具条那条起线（内容紧跟其后，间隙不大）
const TITLE_H := 0.06     # 标题占高
const HEAD_GAP := 0.012   # 标题与内容之间的空隙（用户："应该与设置页标题间隙不大"）
const SEG_GAP := 0.10     # 段间"断层"宽 = 行高占比（用户手绘里两半之间那道缝）
## 皮肤卡网格的间距：**唯一权威值在 SongGrid.GAP_DEFAULT**（曲库就是 14px 固定值）。
## 这里不另写数字、也不用屏宽比例——比例间距在宽屏上会把卡算窄，和选曲页对不上
## （用户 2026-10-31：皮肤页卡片布局要与游玩界面一致）。列宽公式也必须和
## SongGrid.relayout 同步：(带宽 − 间距×(列数−1)) / 列数，带宽=同一条 16%→70% 带。
const GRID_GAP := SongGrid.GAP_DEFAULT
## 皮肤页的带划分（照用户草图 + 与单人游戏同一套）：16%→70% = 工具条 + 卡片网格，
## 70%→100% 整条从上到下 = 演示带。工具条与演示都不跟着卡片滚。
const DEMO_X := CTRL_R    # 演示带左缘=控件右界那条线（同一条线，两处不许各写一个数）
const TOOL_H := SongSelect.TOOL_H        # 工具条高=**单人游戏搜索框高**（同一个常量）
const TOOL_GAP := 0.008   # 药丸与圆钮之间的空隙（曲库那条带的同一数值）
const SEG_PAD := 0.34     # 段内文字左右内边距 = 行高占比
const SEG_MIN := 0.90     # 段最小宽 = 行高占比（"开/关"这种单字也要像个按钮）

## 数值框上的手势分流层（用户 2026-10-31："如果是滑动就是滑动，如果是点击就是输入"）。
## 盖在数值框透明输入层之上、先吞事件：按下去挪过阈值=滑动（喂给 SliderBar 调值），
## 原地抬起=点击（聚焦 LineEdit → 全选 + 弹输入法）。按下时**不许**碰值——点一下
## 不能把数值跳到手指位置。 claimed 住的触/鼠在抬手前的事件都归这层（视口按 index
## 路由），所以滑出框外也照收。
class PlateGest extends Control:
	var sc: SliderBar
	var ed: LineEdit
	var _down := false
	var _start := Vector2.ZERO
	var _sliding := false
	const THRESH := 10.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _gui_input(ev: InputEvent) -> void:
		var pos := Vector2(-1, -1)
		var down := false
		var up := false
		var move := false
		var mb := ev as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
			pos = mb.position
			down = mb.pressed
			up = not mb.pressed
		elif ev is InputEventScreenTouch:
			var st := ev as InputEventScreenTouch
			pos = st.position
			down = st.pressed
			up = not st.pressed
		elif ev is InputEventMouseMotion:
			pos = (ev as InputEventMouseMotion).position
			move = true
		elif ev is InputEventScreenDrag:
			pos = (ev as InputEventScreenDrag).position
			move = true
		if down:
			_down = true
			_sliding = false
			_start = pos
			accept_event()
		elif up:
			if _down and not _sliding and ed != null:
				ed.grab_focus()   # 点击=输入
			_down = false
			_sliding = false
			accept_event()
		elif move and _down:
			if not _sliding and pos.distance_to(_start) > THRESH:
				_sliding = true
			if _sliding and sc != null:
				sc.apply_global_x(get_global_rect().position.x + pos.x)
				accept_event()

var _b_back: NeoButton
var _b_cat: Array[NeoButton] = []
var _cat := "general"
var _scrim: ColorRect
var _title: Label
var _hint: Label
var _scroller: ScrollContainer
var _swipe: SwipeScroll
var _rows: Control
var _spec := {}            # 当前分类的行表（行 dict 里存着各自的控件引用，换分类才重建）
var _laid := false
var _online: SkinOnline          # 在线资源包拉取（PT 口径：GET <url>/meta.json 逐文件）
# 皮肤页专属的页面级控件（只在 _cat=="skin" 时可见）
var _url_edit: LineEdit
var _b_import: NeoButton
var _b_del: NeoButton
var _demo: SkinPreview
var _info_lbl: Label
var _bg_full: TextureRect = null    # 皮肤页整屏底图（完整糊量：演示带要和它拼成一张）
var _bg_full_key := ""
var _bg_full_busy := false

const BgBlur := preload("res://scripts/bg_blur.gd")
const BG_SRC := "res://assets/bg/main_bg.jpg"

var _note := ""                  # 上一次导入/导出/删除的结果，画在预览块第二行
var _url := ""                   # 在线包地址（这一页那颗 LineEdit 里的内容）
## 数值输入框提交时从文本里抠数字用（"55%" / "+12 ms" / "1.25" / "-600" 都能吃）。
## ⚠ 在正则源码里是 `\d`，所以 GDScript 字符串要写成 "\\d"。
var _num_rx := RegEx.create_from_string("-?\\d+(\\.\\d+)?")

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 内容区底：从屏宽 20% 到右边缘铺一层 50% 黑（用户指定）。
	# 一级导航带（0→14%）留在这层之外——那颗带上的按钮本来就是深磨砂，自己扛得住。
	# 皮肤页专用底：整屏「完整糊量」的那张。演示带自己不再画背景——两处各画一张，
	# 糊度/取景只要差一点就是一条明显的接缝（用户："这也太明显了"）。
	_bg_full = TextureRect.new()
	_bg_full.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg_full.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg_full.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_full.z_index = -2
	_bg_full.visible = false
	add_child(_bg_full)
	_bg_full.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim = ColorRect.new()
	_scrim.color = Color(0, 0, 0, 0.5)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scrim.z_index = -1
	add_child(_scrim)
	# 行区放进滚动容器：行高固定（各类字号才一致），某一类行多了就上下滑
	_scroller = ScrollContainer.new()
	_scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroller)
	_rows = Control.new()
	# 容器链全 PASS：滑动事件才冒泡到 ScrollContainer（曲库带同一套接线）
	_rows.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroller.add_child(_rows)
	# 全站滑动：鼠标拖/手指拖/触控板拨动 + 一点惯性，滚动条隐形（详见 swipe_scroll.gd）
	_swipe = SwipeScroll.attach(_scroller)
	_b_back = _btn("返回", self)
	_b_back.pressed.connect(func() -> void: nav.emit("back"))
	for c in CATS:
		var b := _btn(String(c["name"]), self)
		var cid := String(c["id"])
		b.pressed.connect(_select_cat.bind(cid))
		_b_cat.append(b)
	_online = SkinOnline.new()
	add_child(_online)
	_online.done.connect(_on_online_done)
	_online.failed.connect(_on_online_fail)
	_online.progress.connect(_on_online_progress)
	_url_edit = LineEdit.new()
	_url_edit.placeholder_text = "输入网址"
	_url_edit.add_theme_font_override("font", UiTokens.install_font())
	_url_edit.add_theme_color_override("font_color", UiTokens.INK)
	_url_edit.add_theme_color_override("font_placeholder_color", UiTokens.INK_SUB)
	var pill := StyleBoxFlat.new()
	pill.bg_color = UiTokens.SURFACE_PANEL
	pill.set_corner_radius_all(999)
	pill.content_margin_left = 24.0
	pill.content_margin_right = 24.0
	for st in ["normal", "focus"]:
		_url_edit.add_theme_stylebox_override(st, pill)
	_url_edit.text_changed.connect(func(t: String) -> void: _url = t)
	_url_edit.text_submitted.connect(func(_t: String) -> void: _act_online())
	add_child(_url_edit)
	# 两颗圆钮：导入（选 zip/目录）与删除（删当前选中的包）——图标都是工程里现成的
	_b_import = NeoButton.new()
	_b_import.text = "导入"
	_b_import.pill = true
	_b_import.min_size_hint = Vector2.ZERO
	_b_import.set_icon("res://assets/icons/load.svg", 0.5)
	_b_import.pressed.connect(_act_import)
	add_child(_b_import)
	_b_del = NeoButton.new()
	_b_del.text = "删除"
	_b_del.pill = true
	_b_del.min_size_hint = Vector2.ZERO
	_b_del.set_icon("res://assets/icons/delete.svg", 0.5)
	_b_del.set_icon_tint(Color(1.0, 0.45, 0.52, 1))
	_b_del.pressed.connect(_act_delete)
	add_child(_b_del)
	_demo = SkinPreview.new()
	# 演示带不再自带背景：整页用一张完整糊量的底图（见 _ensure_skin_bg），
	# 带子透明叠在上面，接缝从构造上就不存在。
	_demo.info.connect(_on_note)
	add_child(_demo)
	_info_lbl = _lbl(self, UiTokens.INK_SUB)
	_info_lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_title = _lbl(self, UiTokens.INK)
	_hint = _lbl(self, UiTokens.INK_SUB)
	get_viewport().size_changed.connect(_layout)
	_select_cat(_cat)

func _btn(t: String, parent: Control) -> NeoButton:
	var b := NeoButton.new()
	b.set_caption(t)
	# 全部手动摆位：custom_minimum_size 会把 size 顶回去（比矩形宽就是
	# 右缘对不上 70% 这条线），所以一律不设最小尺寸
	b.min_size_hint = Vector2.ZERO
	parent.add_child(b)
	return b

func _lbl(parent: Control, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", UiTokens.install_font())
	l.add_theme_color_override("font_color", col)
	# 本页按用户要求**不放**那条 50% 透明底的二级带，文字就直接压在亮色主背景图上；
	# 近白的 INK 在这种底上对比不够（截图实测行名发虚）。药丸是深磨砂所以自己扛得住，
	# 文字靠投影补对比——加底带是回到被否掉的那层，加投影才是不动结构的解。
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.78))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l

## 当前分类里有没有这一行（条件行的出现/消失由 QA 断言）
func has_row(k: String) -> bool:
	for d in _spec.get("rows", []):
		if String((d as Dictionary).get("k", "")) == k:
			return true
	return false

## 当前分类（QA/外部判选用）。NeoButton 的"选中"是自绘状态没有 getter，
## 所以分类归属只认这里的一份 _cat，不去问按钮。
func cat() -> String:
	return _cat

func button_for(id: String) -> NeoButton:
	if id == "back":
		return _b_back
	for i in CATS.size():
		if String(CATS[i]["id"]) == id:
			return _b_cat[i]
	return null

## 进场：一级导航逐级浮现 → 标题 → 行。只动 alpha/scale，转场期间零重排。
func reveal() -> void:
	UiMotion.cascade([_b_back] + _b_cat, UiTokens.DUR_ITEM, UiTokens.STEP_ITEM, 0.0)
	var kids: Array = [_title]
	for c in _rows.get_children():
		kids.append(c)
	if _hint.visible:
		kids.append(_hint)
	UiMotion.cascade(kids, UiTokens.DUR_ITEM, UiTokens.STEP_ITEM, UiTokens.STEP_GROUP)

func fade_out(done: Callable) -> void:
	if _demo != null:
		_demo.hush()    # 退出设置那一刻就收声，不等淡出结束（用户：退出后还在放打击音）
	UiMotion.fade_out(self, UiTokens.DUR_PAGE_OUT, done)

func _select_cat(id: String) -> void:
	_cat = id
	var skin := id == "skin"
	if not skin and _demo != null:
		_demo.hush()        # 切走=这一页不再演示，正在响的那几声立刻停
	for w in [_url_edit, _b_import, _b_del, _demo, _info_lbl]:
		(w as Control).visible = skin
	if _bg_full != null:
		_bg_full.visible = skin
	if skin:
		_ensure_skin_bg()
	for i in CATS.size():
		_b_cat[i].set_selected(String(CATS[i]["id"]) == id)
	_rebuild()
	_layout()

func _rebuild() -> void:
	for c in _rows.get_children():
		c.free()
	_spec = _spec_for(_cat)
	for c in CATS:
		if String(c["id"]) == _cat:
			_title.text = String(c["name"])
	_hint.visible = String(_spec["hint"]) != ""
	_hint.text = String(_spec["hint"])
	for r in _spec["rows"]:
		_build_row(r as Dictionary)

func _build_row(d: Dictionary) -> void:
	# 预览块自己会画标题（当前包名 · 作者），再压一行名称就是两行字叠在一起
	if String(d["kind"]) != "grid":
		d["_name"] = _lbl(_rows, UiTokens.INK)
		(d["_name"] as Label).text = String(d["n"])
	var kind := String(d["kind"])
	if kind == "text":
		d["_val"] = _lbl(_rows, UiTokens.INK_SUB)
		(d["_val"] as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		(d["_val"] as Label).text = String(d["v"])
		# 文本行的值是"事实"不是"选项"：长到放不下（输出目录那种绝对路径）必须省略号收尾，
		# 右对齐 + 不裁剪 = 一路顶出屏幕外（截图实测 "…PhiTogetherN" 被切在半路）
		(d["_val"] as Label).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		return
	if kind == "act":
		# 动作钮走和选项段同一条摆位通道：右对齐到 CTRL_R。
		# 之前它只建了钮没被摆位，所以一直停在左上角 (0,0)。
		var b := NeoButton.new()
		b.set_caption(String(d["label"]))
		b.min_size_hint = Vector2.ZERO
		_rows.add_child(b)
		b.pressed.connect(_on_act.bind(String(d.get("do", "reset"))))
		d["_segs"] = [b]
		return
	if kind == "grid":
		# 皮肤包用**曲库同款卡片**来选（用户指定）：一张卡=一个包，封面就是这套皮肤
		# 画在轨道上的样子，点卡片=换肤。列表页/箭头切换那种形态他早就否过一次。
		var g := Control.new()
		g.mouse_filter = Control.MOUSE_FILTER_PASS
		_rows.add_child(g)
		d["_ctl"] = g
		d["_cards"] = []
		d["_cur"] = UserPrefs.str_of("skin_pack")
		for pk in SkinPack.list_all():
			var c := SongCard.new()
			# 卡片链要 PASS：手指按在卡上也能把这一页滑下去（曲库网格同一套接线）
			c.mouse_filter = Control.MOUSE_FILTER_PASS
			c.fit_to_viewport = false
			c.max_size_hint = Vector2.ZERO
			c.song_title = String(pk["name"])
			var miss: Array = pk.get("missing", [])
			# 信息带=名字 + 作者（用户草图），右下角那颗徽章=皮肤类型（PT Skin / phira / …）
			c.song_artist = "%s%s" % [String(pk["author"]),
					"" if miss.is_empty() else " · 缺%d项" % miss.size()]
			c.diff_code = SkinPack.type_label(pk)
			c.cover = SkinPack.cover_image(pk, 320.0, SongCard.aspect_for_window(get_window().size))
			c.set_meta("pid", String(pk["id"]))
			g.add_child(c)
			c.card_pressed.connect(_on_skin_card.bind(String(pk["id"])))
			(d["_cards"] as Array).append(c)
		_refresh_row(d)
		return
	if kind == "slider":
		var s := SliderBar.new()
		s.min_value = float(d["min"])
		s.max_value = float(d["max"])
		s.step = float(d.get("step", 1))
		# 数值框就是滑块 ⇒ 那颗粉圆点不要了（它只会藏在框底下，轨道中段凭空多一个点）
		s.show_thumb = false
		s.set_value(_get_num(String(d["k"])))
		_rows.add_child(s)
		d["_ctl"] = s
		# 用户 2026-10-30 定稿：**删掉轨道两端那两颗加减钮，数字改成直接输入**。
		# 数值框仍是滑块（跟着进度走）：底板是一颗 Pill（2× 烘焙的 SDF 胶囊，白环+不透明底），
		# 上面叠一颗**透明**的 LineEdit 负责文字与输入（点它弹输入法，回车/失焦提交）。
		# 底板不透明 ⇒ 轨道那条线从它底下穿过去时看不见。
		var box := PillStyle.Pill.new()
		box.radius = float(UiTokens.RADIUS)
		_rows.add_child(box)
		d["_box"] = box
		var ed := LineEdit.new()
		ed.alignment = HORIZONTAL_ALIGNMENT_CENTER
		ed.max_length = 12
		ed.placeholder_text = ""
		ed.add_theme_font_override("font", UiTokens.install_font())
		ed.add_theme_color_override("font_color", UiTokens.INK)
		ed.add_theme_color_override("font_placeholder_color", UiTokens.INK_SUB)
		ed.add_theme_color_override("font_readonly_color", UiTokens.INK)
		ed.add_theme_color_override("cursor_color", UiTokens.INK)
		ed.caret_blink = true
		# 底板由 box 画，LineEdit 自己必须是全透明的（否则它主题默认那套硬边盒会叠在胶囊上）
		for st in ["normal", "focus", "read_only"]:
			ed.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		_rows.add_child(ed)
		d["_val"] = ed
		# 滑/点分流层盖在输入层上（后加的在上）：滑动=调值，点击=输入
		var gest := PlateGest.new()
		gest.sc = s
		gest.ed = ed
		_rows.add_child(gest)
		d["_gest"] = gest
		ed.text_submitted.connect(_on_val_submit.bind(d))
		ed.focus_exited.connect(_on_val_exit.bind(d))
		ed.focus_entered.connect(_on_val_enter.bind(ed))
		s.value_changed.connect(_on_slider.bind(d))
		_refresh_row(d)
		return
	# toggle / cycle：**全部展开**成一段一段的选项（用户手绘那张）——每档一颗，相邻边切直角，
	# 段与段之间留一道"断层"，当前档亮选中态。不再用"点一下换下一档"的单颗药丸：
	# 全部展开才看得见"这里一共有几个选择、现在在第几个"。
	var segs: Array[NeoButton] = []
	var opts: Array = d["opts"]
	for i in opts.size():
		var seg := NeoButton.new()
		seg.pill = false
		seg.square_left = i > 0
		seg.square_right = i < opts.size() - 1
		seg.set_caption(String(opts[i]["t"]))
		seg.min_size_hint = Vector2.ZERO
		_rows.add_child(seg)
		seg.pressed.connect(_on_pick.bind(d, i))
		segs.append(seg)
	d["_segs"] = segs
	_refresh_row(d)

func _on_pick(d: Dictionary, i: int) -> void:
	var opts: Array = d["opts"]
	var k := String(d["k"])
	_set_val(k, opts[i]["v"])
	_refresh_row(d)
	_apply_live(k)
	# 帧率上限从"不限"切到具体值才出现「锁定帧率」；渲染精度切到"自定义"才出现宽高两行。
	# 条件行的增删都要整类重建。
	# 必须 deferred：正在发射 pressed 信号的按钮就在这批节点里，当场 free 就是拆自己。
	if k == "fps_cap" or k == "rec_res":
		_rebuild_rows.call_deferred()

## 重建行 + 重摆（按钮信号里只能延后调这个）
func _rebuild_rows() -> void:
	_rebuild()
	_layout()

func _on_slider(v: float, d: Dictionary) -> void:
	_set_num(String(d["k"]), v)
	_refresh_row(d)
	_apply_live(String(d["k"]))

## ── 数值输入框（=滑块）────────────────────────────────────────────────
## 4.7 的 LineEdit 聚焦**不会自己**弹输入法（Android 必须显式调），实名是
## `DisplayServer.virtual_keyboard_show/hide`（旧的 keyboard_show 已不在 API 里）。
## 三条通道都要接上，否则"写了没生效 / 写了没提交"：
##   focus_entered → 全选 + 弹键盘；text_submitted（回车）→ 提交 + 交还焦点；
##   focus_exited（点别处）→ 也提交 + 收键盘。
func _on_val_enter(e: LineEdit) -> void:
	e.select_all()   # 一进来就全选：改数值的人要的是"覆盖"，不是"在后面接一位"
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_show(e.text)

func _kb_hide(_t: Variant = null) -> void:
	# 和 show 那条同一道门：桌面端这台 display server 不支持，无条件调会刷一排
	# "Virtual keyboard not supported by this display server."（他要求过清警告）
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_hide()

func _on_val_submit(txt: String, d: Dictionary) -> void:
	_commit_val(txt, d)
	# 交还焦点=让 focus_exited 那条通道再走一遍（同样的文本再提交一次是幂等的），
	# 换来的是：显示从"用户手打的那串"归位成格式化后的值（1.5 → 1.50），键盘也收了。
	var ed := d.get("_val", null) as LineEdit
	if ed != null:
		ed.release_focus()

## 点别处收键盘也算提交：不提交的话，框里写的和盘上存的就各说各话了
func _on_val_exit(d: Dictionary) -> void:
	var ed := d.get("_val", null) as LineEdit
	if ed != null:
		_commit_val(ed.text, d)
	_kb_hide()

## 抠出文本里的第一个数字（"55%" / "+12 ms" / "1.25" / "1080 px" 都能吃），
## 按该行的 min/max/step 归位。pct 那档屏上是百分数、存的是 0..1 ⇒ 先除以 100。
func _commit_val(txt: String, d: Dictionary) -> void:
	var ed := d.get("_val", null) as LineEdit
	var sc := d.get("_ctl", null) as SliderBar
	if ed == null or sc == null:
		return
	var m := _num_rx.search(txt)
	if m == null:
		ed.text = _fmt(d)   # 没写数字：把显示恢复成当前值，别留一个空框
		return
	var num := float(m.get_string())
	if String(d.get("fmt", "")) == "pct":
		num /= 100.0
	var k := String(d["k"])
	sc.set_value(num)   # clamp 到 [min,max] + 按 step 对齐都在 set_value 里
	_set_num(k, sc.value)
	_refresh_row(d)
	_apply_live(k)

func _index_of(d: Dictionary) -> int:
	var opts: Array = d["opts"]
	var cur: Variant = _get_raw(String(d["k"]))
	for i in opts.size():
		if opts[i]["v"] == cur:
			return i
	return 0

## 只影响引擎/窗口/总线全局的项当场应用；其余等下次开谱由 chart_stage 读盘生效
func _apply_live(k: String) -> void:
	match k:
		"fps_cap", "fps_lock":
			# 锁定关=不设上限（跟随刷新率/vsync）；锁定开=真的钉在所选档
			Engine.max_fps = UserPrefs.int_of("fps_cap") if UserPrefs.flag("fps_lock") else 0
		"vsync":
			# 必须走 DisplayServer：4.7 的 Window 已经没有 vsync_mode 属性，set() 静默失败，
			# 而且产品口径(0=开)与引擎枚举(0=DISABLED)的 0/1 是反的（证据见 UserPrefs.vsync_ds）
			UserPrefs.vsync_apply()
		"hdr":
			# HDR 在这里=**2D HDR 渲染**（use_hdr_2d）：帧缓冲换成 HDR 格式，颜色可以超过 1.0，
			# 亮部不再被钳成白的同一块——就是"色彩范围变大"。
			# （先前我接的是 hdr_output_requested，那是"把 HDR 信号推给显示器"，
			#   SDR 屏上直接被平台退回 false，语义也不对。）
			get_viewport().use_hdr_2d = UserPrefs.flag("hdr")
		"msaa":
			get_viewport().msaa_2d = UserPrefs.int_of("msaa")
		"master_vol":
			var mv: float = UserPrefs.num("master_vol")
			AudioServer.set_bus_volume_db(0, linear_to_db(mv) if mv > 0.001 else -80.0)

func _get_raw(k: String) -> Variant:
	var dflt: Variant = UserPrefs.DEFAULTS[k]
	if dflt is String:
		return UserPrefs.str_of(k)
	if dflt is bool:
		return UserPrefs.flag(k)
	if dflt is int:
		return UserPrefs.int_of(k)
	return UserPrefs.num(k)

func _get_num(k: String) -> float:
	return float(_get_raw(k))

func _set_val(k: String, v: Variant) -> void:
	var dflt: Variant = UserPrefs.DEFAULTS[k]
	if dflt is String:
		UserPrefs.set_str(k, String(v))
		return
	if dflt is bool:
		UserPrefs.set_flag(k, bool(v))
	elif dflt is int:
		UserPrefs.set_int(k, int(v))
	else:
		UserPrefs.set_num(k, float(v))

func _set_num(k: String, v: float) -> void:
	_set_val(k, v)
	# 判定窗口耦合：P 抬上去后 G 必须跟到下限（player Preferences.svelte 同一条约束），
	# 否则设置页能存出一对互相矛盾的窗口，开谱时被舞台的 clamp 悄悄改掉。
	if k == "perfect_ms":
		var lo := maxf(v + 5.0, v * 1.125)
		if UserPrefs.num("good_ms") < lo:
			UserPrefs.set_num("good_ms", lo)
			_refresh_all()

func _refresh_all() -> void:
	for d in _spec["rows"]:
		_refresh_row(d as Dictionary)

func _fmt(d: Dictionary) -> String:
	return _fmt_at(d, _get_num(String(d["k"])))

## 格式化一个**给定值**（不只当前值）：数值框是定尺寸的，排版前要能问"这一行最宽会显示成什么样"
static func _fmt_at(d: Dictionary, v: float) -> String:
	match String(d.get("fmt", "")):
		"pct":
			return "%d%%" % int(round(v * 100.0))
		"ms":
			return "%.0f ms" % v
		"msx":
			return "%+.0f ms" % v
		"x2":
			return "%.2f" % v
		"px":
			return "%d px" % int(round(v))
		"mbps":
			return "%d Mbps" % int(round(v))
		_:
			return str(v)

## 数值框（=滑块）的宽：按这一行**可能显示的最宽文本**量（min / max / 当前都比一遍），
## 再加左右内边距；上限是轨道的 42%——再宽就把进度整个盖住了，进度就没法看了。
## 现在它是输入框：手打的位数比显示值多（"0.85" 存成 "0.85"、也可能打 "0.8500"），
## LineEdit 会横向滚动，不会把框撑破——所以宽度只按**显示**口径量，不给输入另开一档。
func _val_w(d: Dictionary, track_w: float, fs: int) -> float:
	var f := UiTokens.install_font()
	var wide := 0.0
	for t in [_fmt(d), _fmt_at(d, float(d.get("min", 0.0))), _fmt_at(d, float(d.get("max", 0.0)))]:
		wide = maxf(wide, f.get_string_size(String(t), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var pad := float(fs) * VAL_BOX_PAD
	var lo := float(fs) * 1.6
	return clampf(wide + pad * 2.0, lo, maxf(track_w * VAL_BOX_MAX, lo))

## 把数值框按**当前进度**摆到轨道上：值最小贴轨道左端、值最大贴右端
## （用户 2026-10-30 草图两行：0.8 在左、1.5 在右）。用的就是 SliderBar.slide_x() 那条
## 算式——两边各写一遍迟早错位，所以只留一处。拖动每帧都会走这里。
func _place_slide(d: Dictionary) -> void:
	var sc := d.get("_ctl", null) as SliderBar
	var ed := d.get("_val", null) as LineEdit
	var box := d.get("_box", null) as PillStyle.Pill
	var gest := d.get("_gest", null) as Control
	if sc == null or ed == null or box == null or not d.has("_bw"):
		return
	var bh := float(d.get("_bh", 0.0))
	var pos := Vector2(sc.position.x + sc.slide_x(),
			sc.position.y + (sc.size.y - bh) * 0.5)
	var sz := Vector2(float(d["_bw"]), bh)
	box.position = pos
	box.size = sz
	ed.position = pos
	ed.size = sz
	if gest != null:
		gest.position = pos
		gest.size = sz

## 数值框是定尺寸，字号按"这一行可能显示的最宽文本"（min / max / 当前）倒推：
## 小了看不清、大了顶出框。两侧都量才敢保证拖动过程中也不溢出、不重排。
func _fit_fs(d: Dictionary, box: Vector2, start: int) -> int:
	var f := UiTokens.install_font()
	var cands: Array = [_fmt(d), _fmt_at(d, float(d.get("min", 0.0))),
			_fmt_at(d, float(d.get("max", 0.0)))]
	var fs := start
	while fs > 8:
		var over := float(fs) > box.y * 1.35
		for t in cands:
			if f.get_string_size(String(t), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > box.x:
				over = true
		if not over:
			break
		fs -= 1
	return fs

func _refresh_row(d: Dictionary) -> void:
	var kind := String(d["kind"])
	if kind == "text" or kind == "act":
		return
	if kind == "grid":
		# 选中态=当前包那张卡亮粉边（与曲库同一套：set_selected 自己带补间）
		var cur := String(d.get("_cur", UserPrefs.str_of("skin_pack")))
		for c in d.get("_cards", []):
			var card := c as SongCard
			if card != null:
				card.set_selected(String(card.get_meta("pid")) == cur, false)
	if kind == "slider" and d.has("_val"):
		var ed := d["_val"] as LineEdit
		# 正在输入的那一框**不回写文本**：回写会把光标弹到末尾、把刚敲的半截盖掉
		# （轨道每动一下都会走到这里，那时没有聚焦，照常刷新）
		if ed != null and not ed.has_focus():
			ed.text = _fmt(d)
		_place_slide(d)   # 值一动，滑块（数值框）就要跟着挪；进度前沿由 SliderBar 自己重算
	if kind == "toggle" or kind == "cycle":
		# 展开式选项：只有当前那一档亮选中态（这段被上一次裁剪误删过，断言"亮着=0"就是它）
		var idx := _index_of(d)
		var segs: Array = d["_segs"]
		for i in segs.size():
			(segs[i] as NeoButton).set_selected(i == idx)
	_refresh_skin()


func _on_skin_card(id: String) -> void:
	UserPrefs.set_str("skin_pack", id)
	SkinPack.clear_cache()
	for d in _spec.get("rows", []):
		var dd: Dictionary = d
		if String(dd["kind"]) == "grid":
			dd["_cur"] = id
			_refresh_row(dd)
	_refresh_all()
	var nm := "内置" if id == "" else id
	_apply_skin_note("已切换皮肤：" + nm)


## 演示带与"当前包是谁"那一格：皮肤页专属，值全从 prefs + SkinPack 现取
func _refresh_skin() -> void:
	if _cat != "skin" or _demo == null:
		return
	var cur := UserPrefs.str_of("skin_pack")
	var pk := SkinPack.scan(cur)
	if not bool(pk.get("ok", false)):
		# prefs 指的包不在了（被探针删过/换机）：按内置显示，不许出现"没有一张卡亮着"
		cur = SkinPack.BUILTIN_ID
		UserPrefs.set_str("skin_pack", "")
		pk = SkinPack.scan(cur)
	_demo.set_pack(pk)
	_demo.hit_volume = UserPrefs.num("hit_vol")
	var nl := String.chr(10)
	var desc := String(pk.get("desc", ""))
	_info_lbl.text = nl.join([String(pk.get("name", "")),
			"%s · %s" % [String(pk.get("author", "")), SkinPack.type_label(pk)],
			_note if _note != "" else desc])


func _on_act(which: String) -> void:
	match which:
		"reset":
			_act_reset()
		"import":
			_act_import()
		"delete":
			_act_delete()
		"open_video":
			# 系统文件管理器打开输出目录（桌面专用：手机是 MediaStore 相册条目，没有可打开的目录）
			var d := RenderRecorder.video_dir_abs()
			DirAccess.make_dir_recursive_absolute(d)
			var rc := OS.shell_open(d)
			print("QA-REC open ", d, " rc=", rc)


func _on_note(text: String) -> void:
	_apply_skin_note(text)


func _apply_skin_note(text: String) -> void:
	_note = text
	# 演示带左上角那三行就是"当前包 + 上一次操作结果"，必须当场跟着变
	# （以前这里刷的是 kind=="preview" 的行——那形态早就被卡片网格替掉了，等于没刷）
	_refresh_skin()
	print("QA-SKIN ", text)


## 导入：一个 zip 或一个目录（phira/prpr 两种包都吃，判据见 skin_pack.gd）
func _act_import() -> void:
	Dialogs.pick_file(PackedStringArray(["*.zip ; 资源包 zip"]), _on_import_picked)


func _on_import_picked(confirmed: bool, paths: PackedStringArray) -> void:
	if not confirmed or paths.is_empty():
		return
	var got: Dictionary = SkinPack.import_from(String(paths[0]))
	if not bool(got.get("ok", false)):
		_apply_skin_note("导入失败：" + String(got.get("error", "?")))
		return
	UserPrefs.set_str("skin_pack", String(got["id"]))
	_rebuild_rows.call_deferred()
	_apply_skin_note("已导入并启用：%s（%s）" % [String(got["name"]), String(got["source"])])


func _act_delete() -> void:
	var id := UserPrefs.str_of("skin_pack")
	if id == "":
		_apply_skin_note("当前就是内置皮肤")
		return
	SkinPack.uninstall(id)
	UserPrefs.set_str("skin_pack", "")
	SkinPack.clear_cache()
	_rebuild_rows.call_deferred()
	_apply_skin_note("已删除 " + id + "，回到内置皮肤")


## 在线包：PT 的 pt-custom 口径（一个地址，GET <url>/meta.json 后逐文件拉）
func _act_online() -> void:
	_b_import.set_progress(0.0)   # 进度画在导入钮面上（不再拉一条细线）
	if _url.strip_edges() == "":
		_apply_skin_note("先把地址填进上面那一格")
		return
	_apply_skin_note("正在拉取…")
	_online.fetch(_url)


func _on_online_done(p: Dictionary) -> void:
	_hide_progress()
	UserPrefs.set_str("skin_pack", String(p["id"]))
	SkinPack.clear_cache()
	_rebuild_rows.call_deferred()
	_apply_skin_note("在线包已启用：" + String(p["name"]))


func _on_online_progress(have: int, total: int) -> void:
	_b_import.set_progress(clampf(float(have) / maxf(float(total), 1.0), 0.0, 1.0))
	_apply_skin_note("正在拉取：%d/%d" % [have, total])


func _hide_progress() -> void:
	_b_import.set_progress(-1.0)


func _on_online_fail(what: String) -> void:
	_hide_progress()
	_apply_skin_note("拉取失败：" + what)


## 恢复默认：整份键表回到出厂值 + 当场把全局项应用回去
func _act_reset() -> void:
	UserPrefs.reset_all()
	Engine.max_fps = UserPrefs.int_of("fps_cap") if UserPrefs.flag("fps_lock") else 0
	UserPrefs.vsync_apply()
	get_viewport().use_hdr_2d = UserPrefs.flag("hdr")
	get_viewport().msaa_2d = UserPrefs.int_of("msaa")
	AudioServer.set_bus_volume_db(0, linear_to_db(UserPrefs.num("master_vol")))
	_rebuild_rows.call_deferred()
	print("QA-SET 已恢复默认设置")

## 皮肤页的整屏底图：完整糊量（bg_blur 原值），和游玩一致。
## 只在皮肤分类可见；按 (屏幕尺寸|模糊量) 缓存，切分类/改设置都不会重复烘。
func _ensure_skin_bg() -> void:
	if _bg_full == null or _cat != "skin":
		return
	var screen := get_viewport_rect().size
	if screen.x < 8.0 or screen.y < 8.0:
		return
	var blur := UserPrefs.num("bg_blur")
	var key := "%.0fx%.0f|%.3f" % [screen.x, screen.y, blur]
	if key == _bg_full_key or _bg_full_busy:
		return
	_bg_full_key = key
	if blur <= 0.001:
		_bg_full.texture = load(BG_SRC)
		return
	_bg_full_busy = true
	var tex: Texture2D = load(BG_SRC)
	var img := tex.get_image()
	if img != null:
		img.convert(Image.FORMAT_RGBA8)
		var out: Image = await BgBlur.bake(self, img, screen, blur, 1.0)
		if out != null:
			_bg_full.texture = ImageTexture.create_from_image(out)
	_bg_full_busy = false
	if key != _bg_full_key:
		_ensure_skin_bg()   # 烘的时候尺寸/参数又变了

func _layout() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	_laid = true
	# ── 一级导航带：返回钮与首行都直接取选曲页那组常量，本页不再自己算偏移。
	##    （之前这里写的是"返回钮底 + NAV_GAP"=14.5%，而选曲页/PZ 页首行一律 NAV_Y0=16%，
	##    同一套外壳两种首行高度 → 用户看到的"返回与通用之间距离不对"就是这 1.5%。）
	var br := SongSelect.BACK_RECT
	_place(_b_back, Rect2(vp.x * br.position.x, vp.y * br.position.y,
		vp.x * br.size.x, vp.y * br.size.y))
	var row_h := vp.y * SongSelect.NAV_ROW_H
	var y := vp.y * SongSelect.NAV_Y0
	for b in _b_cat:
		_place(b, Rect2(vp.x * SongSelect.NAV_X0, y,
			vp.x * (SongSelect.NAV_X1 - SongSelect.NAV_X0), row_h))
		y += row_h + vp.y * SongSelect.NAV_GAP
	# ── 内容带：**所有分类**都从单人游戏那条 16% 分界线起（用户："左边框你只做了皮肤页面，
	##    其他页面都没有移动"）。这一带铺一层 50% 黑遮罩（_scrim，用户指定），
	##    一级导航带（0→14%）留在遮罩之外——那些按钮本身就是深磨砂，不用垫。
	# 皮肤页再把 70%→100% 整条让给演示带，别的分类内容铺到右边缘。
	var is_skin := _cat == "skin"
	var band_l := SongSelect.SEG_NAV
	var band_r := DEMO_X if is_skin else 1.0
	_scrim.position = Vector2(vp.x * band_l, 0)
	_scrim.size = Vector2(vp.x * (1.0 - band_l), vp.y)
	var pad := vp.x * PAD_X
	var x0 := vp.x * band_l + pad
	var band_w: float = vp.x * (band_r - band_l) - pad * 2.0
	# 标题顶=曲库工具条那条起线，内容区紧跟在它下面（用户："应该与设置页标题间隙不大"）
	_title.position = Vector2(x0, vp.y * TITLE_Y)
	_title.size = Vector2(band_w, vp.y * TITLE_H)
	_sh(_title, int(vp.y * 0.05))
	var rows: Array = []
	for _r in _spec.get("rows", []):
		var _rd: Dictionary = _r
		if not _rd.is_empty():  # 手机上没有"打开输出目录"这一行，用 {} 占位后在这里滤掉
			rows.append(_rd)
	# 行高**固定**：上一版按"这一类有几行"等比压行高，结果画面类的字比别的类小一号
	# （用户指出的就是这个）。装不下的部分改成上下滑动。
	var rh := vp.y * ROW_H
	var gap := vp.y * ROW_GAP
	# 名称列宽=这一类里最宽的那条名称实测宽 + 余量。定死百分比会把滑条挤成一小截。
	var name_w := _widest_name(rows, int(rh * 0.44)) + vp.x * 0.014
	# 控件组右边界=屏宽 70%（用户指定）。滚动容器里是内容本地系，
	# 所以这条屏幕绝对线要减掉内容带左缘 x0 才是本地 x。
	var ctl_r := vp.x * CTRL_R - x0
	var ctl_x := name_w
	# 字号：行高占比。滑条行不再有"两端圆钮"要腾地方（用户第三版把加减钮删了、
	# 改成直接输入数字），所以轨道从 ctl_x 一路铺到 ctl_r，同类里所有轨道严格等长。
	var fs := int(rh * 0.44)
	var content_top := vp.y * (TITLE_Y + TITLE_H + HEAD_GAP)
	var th := vp.y * TOOL_H if is_skin else 0.0
	var area_top: float = content_top + (th + vp.y * ROW_GAP if is_skin else 0.0)
	var area_h := vp.y * 0.945 - area_top
	_scroller.position = Vector2(x0, area_top)
	_scroller.size = Vector2(band_w, area_h)
	if is_skin:
		# 工具条：长药丸 + 右边两颗圆钮（导入/删除），与单人游戏那条搜索带**同一套几何**：
		# 高=SongSelect.TOOL_H（直接引用那个常量，不是抄来的近似值）、顶在同一条线上、
		# 圆钮=th×th ⇒ 药丸与两颗圆钮的中心天然重合。
		# （上一版药丸 0.052、圆钮 min(0.075, 3%)，两个高度都不一样，就是"没中心对齐"的根因。）
		var ty := content_top
		var tg := vp.x * TOOL_GAP
		# 圆钮右缘就压在"控件右界=70%"那条线上（和别的行同一条线，不额外缩一进）
		_b_del.position = Vector2(vp.x * DEMO_X - th, ty)
		_b_del.size = Vector2(th, th)
		_b_import.position = Vector2(_b_del.position.x - tg - th, ty)
		_b_import.size = Vector2(th, th)
		_url_edit.position = Vector2(x0, ty)
		_url_edit.size = Vector2(maxf(_b_import.position.x - tg - x0, vp.x * 0.08), th)
		_url_edit.add_theme_font_size_override("font_size", int(th * 0.42))
		# 演示带：从上到下整条都是它（判定线在这块高度的 70%），**右边直接贴到屏幕右边缘**
		# （用户指定；内容列才留内边距，这条带是画面不是列表）。
		# "当前包是谁 / 上一次操作结果"压在带子左上角：判定线以下那块要给特效与粒子，
		# 字放那儿会被飞出来的粒子盖住（放最上面只会和刚进场的音符错开一小会儿）
		var dx := vp.x * DEMO_X
		var dw := vp.x * (1.0 - DEMO_X)
		_demo.position = Vector2(dx, 0)
		_demo.size = Vector2(dw, vp.y)
		# 作者名可以很长（PT 官方包就是"Pigeon Games.Packaged by 飞机上的长电视 · PT Skin"）。
		# 顺序有讲究：先定字号与换行/省略规则，再给 position/size——Label 的最小尺寸会
		# 按"上一次排版的结果"把 size 顶回去（先设 size 后设 autowrap 就等于白设，
		# 实测那行作者名一路顶到屏幕外 12px）。
		_sh(_info_lbl, int(vp.y * 0.02))
		_info_lbl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		_info_lbl.max_lines_visible = 4
		_info_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_info_lbl.position = Vector2(dx + 4.0, vp.y * 0.015)
		_info_lbl.size = Vector2(dw - 12.0, vp.y * 0.11)
	# 内容高度：先按行各自的高度算一遍（预览块 3 行、皮肤卡网格按卡片实际高），
	# 否则滚动范围算少，下面的行就滑不到底
	var cg0 := GRID_GAP
	var cell_w0: float = maxf((band_w - cg0 * 2.0) / 3.0, vp.x * 0.08)
	var cell_h0: float = cell_w0 / SongCard.aspect_for_window(get_window().size)
	var total_h := 0.0
	for d in rows:
		var dd0: Dictionary = d
		match String(dd0["kind"]):
			"grid":
				var n0: int = (dd0.get("_cards", []) as Array).size()
				var rows0: int = ceili(float(n0) / 3.0)
				dd0["_h"] = float(rows0) * cell_h0 + float(maxi(rows0 - 1, 0)) * cg0
			_:
				dd0["_h"] = rh
		total_h += float(dd0["_h"]) + gap
	_rows.custom_minimum_size = Vector2(band_w, maxf(total_h, 1.0))
	var ry := 0.0
	for d in rows:
		var dd: Dictionary = d
		var nl: Label = dd.get("_name", null)
		if nl != null:
			nl.position = Vector2(0, ry)
			nl.size = Vector2(name_w, rh)
			_sh(nl, fs)
			nl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var kind := String(dd["kind"])
		var c: Control = dd.get("_ctl", null)
		if kind == "text":
			var vl: Label = dd.get("_val", null)
			if vl != null:
				vl.position = Vector2(name_w, ry)
				vl.size = Vector2(band_w - name_w, rh)
				_sh(vl, fs)
				vl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		elif kind == "slider":
			# 排法（用户 2026-10-30 第三版）：[轨道──────[数值框]]。
			# 轨道两端那两颗加减钮**删了**⇒ 轨道直接从名称列铺到控件右界（70%）那条线，
			# 同类里所有轨道仍然严格等长（以前是"两端各让开一颗圆钮"才等长的）。
			# 数值框还是那个滑块：和"开/关"那一档等高（=rh）、值最小贴轨道左端、值最大贴右端、
			# 进度填充填到框的左沿。它从只读的 Panel+Label 换成 LineEdit ⇒ 点它就是输入数字。
			var tkh := rh * 0.52
			if c != null:
				c.position = Vector2(ctl_x, ry + (rh - tkh) * 0.5)
				c.size = Vector2(maxf(ctl_r - ctl_x, vp.x * 0.04), tkh)
			var bh := rh * VAL_BOX_H
			var bw := _val_w(dd, c.size.x if c != null else 0.0, fs)
			var sc := c as SliderBar
			if sc != null:
				# 把"滑块宽"交给轨道：填充前沿要停在框的**左沿**，点击映射也要按框宽留半格
				sc.set_handle(bw)
			var ed: LineEdit = dd.get("_val", null)
			var box: PillStyle.Pill = dd.get("_box", null)
			if box != null:
				# 白环和"开/关"那一档**同一份**：同一个环宽（ring_w）同一个颜色（RING_ON），
				# 圆角也同 RADIUS；底是不透明中性深灰（val_box_fill，见文件头那段反馈链）。
				box.fill = val_box_fill()
				box.border_w = maxi(int(UiTokens.ring_w(vp.y)), 1)
				box.border = UiTokens.RING_ON
			if ed != null:
				# LineEdit 默认"最小宽=10 个字符"（theme constant minimum_character_width），
				# Control.set_size 会被最小尺寸顶回去 ⇒ 窄框会自己涨宽、把滑块对位搞乱。
				ed.add_theme_constant_override("minimum_character_width", 0)
				ed.custom_minimum_size = Vector2.ZERO
				# 字号缩到真能塞进"框宽 − 两道内边距"为止（内边距=居中对齐自然留出的那对 pad）
				var vfs := _fit_fs(dd, Vector2(bw - float(fs) * VAL_BOX_PAD * 2.0, bh), fs)
				ed.add_theme_font_size_override("font_size", vfs)
			dd["_bw"] = bw
			dd["_bh"] = bh
			_place_slide(dd)
		elif kind == "grid":
			# 三列、列间距同曲库；卡片形状沿用 SongCard 的窗口比例规则（≥16:9 出 16:9 卡）
			var cards: Array = dd.get("_cards", [])
			# 列数恒 3（与曲库同一读法）：只有一个包时也不许把卡片拉成通栏大图，
			# 卡片尺寸必须与预排版算滚动范围时用的是同一套数字，否则滑不到底
			var cols := 3
			var cg := GRID_GAP
			var cell_w: float = maxf((band_w - cg * float(cols - 1)) / float(cols), vp.x * 0.08)
			var cell_h: float = cell_w / SongCard.aspect_for_window(get_window().size)
			for i in cards.size():
				var card := cards[i] as SongCard
				card.fit_to_viewport = false
				card.max_size_hint = Vector2(cell_w, cell_h)
				card.update_minimum_size()
				card.position = Vector2(float(i % cols) * (cell_w + cg), ry + float(i / cols) * (cell_h + cg))
				card.size = Vector2(cell_w, cell_h)
			var rows_n := ceili(float(cards.size()) / float(cols))
			var gh: float = float(rows_n) * cell_h + float(maxi(rows_n - 1, 0)) * cg
			if c != null:
				c.size = Vector2(band_w, gh)
			dd["_h"] = gh
		else:
			# 展开式选项（含动作钮）：从 CTRL_R 往左铺，段宽=实测文案+左右内边距，
			# 段与段之间留一道"断层"
			var segs: Array = dd.get("_segs", [])
			var xr := ctl_r
			var sg := rh * SEG_GAP
			for si in range(segs.size() - 1, -1, -1):
				var sb: NeoButton = segs[si]
				var cap := String(sb.caption())
				var tw := ThemeDB.fallback_font.get_string_size(
						cap, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				var sw: float = maxf(tw + rh * SEG_PAD * 2.0, rh * SEG_MIN)
				sb.position = Vector2(xr - sw, ry)
				sb.size = Vector2(sw, rh)
				sb._sync_icon()
				sb.set_font_size(fs)
				xr -= sw + sg
		ry += float(dd.get("_h", rh)) + gap
	# 生效说明钉在内容带底部（不占行区，行多也不会被顶走）
	_hint.position = Vector2(x0, vp.y * 0.955)
	_hint.size = Vector2(band_w, vp.y * 0.035)
	_sh(_hint, int(vp.y * 0.018))

## 这一类里最宽的名称文本（决定名称列宽 → 剩下的都给了滑条）
func _widest_name(rows: Array, fs: int) -> float:
	var f := ThemeDB.fallback_font
	var w := 0.0
	for d in rows:
		w = maxf(w, f.get_string_size(String((d as Dictionary)["n"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	return w

func _place(b: NeoButton, rect: Rect2) -> void:
	b.position = rect.position
	b.size = rect.size
	b._sync_icon()
	b.fit_font()

## 投影偏移跟着字号走：小屏上固定 2px 会糊字，大屏上又压不住亮底
static func _sh(l: Label, fs: int) -> void:
	l.add_theme_font_size_override("font_size", maxi(fs, 8))
	var o := maxi(int(fs * 0.07), 1)
	l.add_theme_constant_override("shadow_offset_x", o)
	l.add_theme_constant_override("shadow_offset_y", o)

## ── 分类内容表 ─────────────────────────────────────────────────────────
## 只列**引擎里真的存在、且真的被应用**的项：每一项都对应 UserPrefs 的一个键，
## 且要么在 `_apply_live` 里当场生效、要么在 chart_stage 开谱时被读取。
## PT 设置页里的血量条/全屏判定/实时排名/资源包切换等，本工程没有对应实现，
## 一律不放（放了就是"功能没做啊"）。
func _spec_for(id: String) -> Dictionary:
	var hint := ""
	var rows: Array = []
	match id:
		"general":
			hint = "自动游玩 / 序号层 / 调试模式 / 暂停详细在下次进入谱面时生效"
			rows = [
				{"k": "autoplay", "n": "自动游玩", "kind": "cycle",
					"opts": ON_OFF},
				{"k": "dbg_overlay", "n": "序号调试层 F12", "kind": "cycle",
					"opts": ON_OFF},
				{"k": "debug_mode", "n": "调试模式", "kind": "cycle",
					"opts": ON_OFF},
				{"k": "pause_detail", "n": "暂停详细", "kind": "cycle",
					"opts": ON_OFF},
				{"n": "恢复默认设置", "kind": "act", "label": "恢复默认"},
			]
		"display":
			hint = "内部分辨率 / 渲染精度 / 音符大小 / 背景项在下次进入谱面时生效"
			rows = [
				{"k": "hi_res", "n": "内部分辨率", "kind": "cycle",
					"opts": [{"v": true, "t": "设备像素"}, {"v": false, "t": "逻辑像素"}]},
				{"k": "low_res", "n": "渲染精度", "kind": "cycle",
					"opts": [{"v": false, "t": "全分辨率"}, {"v": true, "t": "半分辨率"}]},
				{"k": "vsync", "n": "垂直同步", "kind": "cycle",
					"opts": [{"v": 0, "t": "开"}, {"v": 1, "t": "关"}, {"v": 2, "t": "兼容"}]},
				{"k": "fps_cap", "n": "帧率上限", "kind": "cycle",
					"opts": [{"v": 0, "t": "不限"}, {"v": 120, "t": "120"},
						{"v": 90, "t": "90"}, {"v": 60, "t": "60"}]},
				# 选了具体档才出现这一行：上限只是"不许超过"，锁定才是"钉在这一档"
				# （锁定关=Engine.max_fps 归 0，跟随刷新率/vsync；开=把所选值真的设进去）
				{"k": "fps_lock", "n": "锁定帧率", "kind": "cycle", "opts": ON_OFF} \
						if UserPrefs.int_of("fps_cap") != 0 else null,
				{"k": "hdr", "n": "HDR", "kind": "cycle", "opts": ON_OFF},
				{"k": "msaa", "n": "抗锯齿", "kind": "cycle",
					"opts": [{"v": 0, "t": "关"}, {"v": 1, "t": "低"},
						{"v": 2, "t": "中"}, {"v": 3, "t": "高"}]},
				# 噪域掩码的网格密度：这一项直接决定大屏能不能 120
				# （800×500 窗口下 4px 也跑得动，所以默认自动、保留手动档）
				# 彩蛋没开（GameFlags.block_area=false）时噪域整条链都不存在，这一行也不该出现
				{"k": "block_cell", "n": "噪域精度", "kind": "cycle",
					"opts": [{"v": 0, "t": "自动"}, {"v": 4, "t": "高"},
						{"v": 8, "t": "中"}, {"v": 12, "t": "低"}]} if GameFlags.block_area else null,
				{"k": "note_scale", "n": "音符大小", "kind": "slider",
					"min": 0.8, "max": 1.5, "step": 0.01, "fmt": "x2"},
				{"k": "fx_scale", "n": "特效大小", "kind": "slider",
					"min": 0.8, "max": 1.5, "step": 0.01, "fmt": "x2"},
				{"k": "bg_blur", "n": "背景模糊", "kind": "slider",
					"min": 0.0, "max": 2.0, "step": 0.05, "fmt": "x2"},
				{"k": "bg_lum", "n": "背景亮度", "kind": "slider",
					"min": 0.05, "max": 1.0, "step": 0.01, "fmt": "x2"},
				{"k": "fc_ap", "n": "AP/FC 线色指示", "kind": "cycle", "opts": ON_OFF},
				{"k": "line_tex_tint", "n": "线贴图判定染色", "kind": "cycle",
					"opts": [{"v": 0, "t": "自动"}, {"v": 1, "t": "从不"}, {"v": 2, "t": "总是"}]},
				# 取景口径：宽屏（16:9/20:9）比制谱器 3:2 预览多出横向余量，
				# "注重演出"按制谱器画框把框外的表演元素裁掉；"注重游玩"全都画出来。
				{"k": "frame_cull", "n": "取景口径", "kind": "cycle",
					"opts": [{"v": 1, "t": "注重演出"}, {"v": 0, "t": "注重游玩"}]},
			]
		"render":
			hint = "录制=选完谱面后离线逐帧渲染（自动游玩、一帧不落），成片声音直接取自谱包音频。" \
				+ "编码器用系统 ffmpeg，找不到就不录（主菜单输 REC 也能开关）"
			var custom := UserPrefs.int_of("rec_res") == 4
			rows = [
				{"k": "render_rec", "n": "渲染录制", "kind": "cycle", "opts": ON_OFF},
				{"k": "rec_res", "n": "渲染精度", "kind": "cycle",
					"opts": [{"v": 0, "t": "720P"}, {"v": 1, "t": "1080P"}, {"v": 2, "t": "2K"},
						{"v": 3, "t": "4K"}, {"v": 4, "t": "自定义"}]},
				# 预设档固定 16:9（720P=1280×720 … 4K=3840×2160），自定义才是精确像素。
				# 这一行就是"到底会渲成多少像素"。
				{"n": "输出像素", "kind": "text", "v": RenderRecorder.res_label()},
				# 只有"自定义"这一档才摆两个尺寸滑条（选了档位还摆宽高，就是两份真相）
				{"k": "rec_w", "n": "宽", "kind": "slider",
					"min": 480.0, "max": 3840.0, "step": 2.0, "fmt": "px"} \
						if custom else null,
				{"k": "rec_h", "n": "高", "kind": "slider",
					"min": 480.0, "max": 3840.0, "step": 2.0, "fmt": "px"} \
						if custom else null,
				{"k": "rec_fps", "n": "渲染帧率", "kind": "cycle",
					"opts": [{"v": 30, "t": "30"}, {"v": 60, "t": "60"}, {"v": 120, "t": "120"}]},
				{"k": "rec_mbps", "n": "码率", "kind": "slider",
					"min": 1.0, "max": 200.0, "step": 1.0, "fmt": "mbps"},
				{"k": "rec_vcodec", "n": "视频编码", "kind": "cycle",
					"opts": [{"v": 0, "t": "H264"}, {"v": 1, "t": "H265"}]},
				{"k": "rec_acodec", "n": "音频编码", "kind": "cycle",
					"opts": [{"v": 0, "t": "MP3"}, {"v": 1, "t": "AAC"}]},
				{"n": "编码器", "kind": "text",
					"v": ("MediaCodec（进程内）" if RenderRecorder.native_available()
						else ("ffmpeg 可用" if RenderRecorder.has_encoder()
							else "无（缺 ffmpeg / 平台不支持）"))},
				{"n": "输出目录", "kind": "text", "v": RenderRecorder.output_display()},
			]
			# 手机上是 MediaStore 相册条目，没有可"打开"的目录，这一行只在桌面出现
			# （以前用 {} 占位会被行构建器当成真行 → dd["kind"] 取不到 → 整页崩）
			if not OS.has_feature("mobile"):
				rows.append({"n": "打开输出目录", "kind": "act", "label": "打开", "do": "open_video"})
		"volume":
			hint = "主音量当场生效；音乐/打击音量在下次进入谱面时生效"
			rows = [
				{"k": "master_vol", "n": "主音量", "kind": "slider",
					"min": 0.0, "max": 1.0, "step": 0.01, "fmt": "pct"},
				{"k": "music_vol", "n": "音乐音量", "kind": "slider",
					"min": 0.0, "max": 1.0, "step": 0.01, "fmt": "pct"},
				{"k": "hit_vol", "n": "打击音量", "kind": "slider",
					"min": 0.0, "max": 1.0, "step": 0.01, "fmt": "pct"},
				{"k": "loud_norm", "n": "音量标准化", "kind": "cycle", "opts": ON_OFF},
			]
		"play":
			hint = "判定窗口与谱面延迟补偿在下次进入谱面时生效（暂停时的临时调节面板已撤除）"
			rows = [
				{"k": "perfect_ms", "n": "Perfect 窗口", "kind": "slider",
					"min": 5.0, "max": 150.0, "step": 1.0, "fmt": "ms"},
				{"k": "good_ms", "n": "Good 窗口", "kind": "slider",
					"min": 5.0, "max": 300.0, "step": 1.0, "fmt": "ms"},
				{"k": "chart_offset_ms", "n": "谱面延迟补偿", "kind": "slider",
					"min": -600.0, "max": 600.0, "step": 1.0, "fmt": "msx"},
				{"k": "multi_hint", "n": "多押提示", "kind": "cycle", "opts": ON_OFF},
			]
		"skin":
			hint = "皮肤=资源包：点卡片换肤；导入的包落在 user://skins；在线包走 PT 的 customResourceLink 格式"
			# 中间列只剩卡片网格：工具条（网址 + 导入 + 删除）与演示带都是页面级的，
			# 钉在那儿不跟着卡片滚（照用户草图）
			rows = [
				{"k": "skin_pack", "n": "皮肤包", "kind": "grid"},
			]
		"about":
			rows = _about_rows()
		_:
			rows = []
	var kept: Array = []
	for r in rows:
		if r != null:
			kept.append(r)
	return {"hint": hint, "rows": kept}

## 关于页只写**当场算得出来的事实**：引擎/后端/屏幕/曲库/记录数 + 规格来源。
## 没有版本号体系就不编一个（ProjectSettings 里也没有 release 版本字段）。
func _about_rows() -> Array:
	var rec_n := 0
	if FileAccess.file_exists("user://records.json"):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string("user://records.json"))
		if j is Dictionary:
			rec_n = (j as Dictionary).size()
	return [
		{"n": "引擎", "kind": "text", "v": "Godot %s" % str(Engine.get_version_info()["string"])},
		{"n": "渲染后端", "kind": "text", "v": "%s · %s · %s" % [
			RenderingServer.get_current_rendering_method(),
			RenderingServer.get_current_rendering_driver_name(), DisplayServer.get_name()]},
		{"n": "窗口 / 屏幕", "kind": "text", "v": "%d×%d · %.0fHz · %d 核" % [
			get_window().size.x, get_window().size.y,
			DisplayServer.screen_get_refresh_rate(), OS.get_processor_count()]},
		{"n": "曲库", "kind": "text", "v": "%d 个谱面包" % (_count_dirs("user://local") + _count_dirs("user://pz"))},
		{"n": "成绩记录", "kind": "text", "v": "%d 条" % rec_n},
		{"n": "渲染 / 判定规格", "kind": "text", "v": "PhiZone player"},
		{"n": "界面 / 素材规格", "kind": "text", "v": "PhiTogether"},
	]

static func _count_dirs(root: String) -> int:
	var da := DirAccess.open(root)
	if da == null:
		return 0
	var n := 0
	for d in da.get_directories():
		if FileAccess.file_exists(root.path_join(String(d)).path_join("chart.json")):
			n += 1
	return n
