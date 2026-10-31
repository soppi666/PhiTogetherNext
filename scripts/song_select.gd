class_name SongSelect
extends Control
## 单人游戏页：三段式 — 0→16% 导航区、16%→70% 曲库区、70%→100% 详情区。
## 详情列（竖排，按草图）：曲绘（右侧竖排 删除/收藏/游玩配置 小方块，双击曲绘放大）
## → Φ+分数/Acc → 难度胶囊行（每个 5% 高+单个谱师，一行最多 4 个、超出换行、整体居中）
## → 开始游戏。
## 尺寸约定：行堆叠数字=屏高%，曲绘区内的 25/3=曲绘高%。

const SEG_NAV := 0.16
const SEG_LIBRARY := 0.70  # 右侧详情区 30%

# 导航区百分比：x 为屏宽占比、y 为屏高占比
const BACK_RECT := Rect2(-0.01, 0.03, 0.14, 0.10)
const NAV_X0 := 0.02
const NAV_X1 := 0.14
const NAV_ROW_H := 0.08
const NAV_GAP := 0.015
const NAV_Y0 := 0.16  # 返回钮底 13% + 3% 空隙

const ART_TOP_GAP := 0.03  # 曲绘距头像底的空隙（屏高占比）
const ART_H := 0.30        # 曲绘高度（屏高占比）
const SIDE_BTN_W := 0.25   # 侧栏小方块边长（曲绘高占比）
const SIDE_BTN_GAP := 0.03 # 侧栏方块间距（曲绘高占比）
const ROW_STATS_H := 0.20  # Φ 数据条带高（屏高占比）
const CHIP_H := 0.05       # 单个难度胶囊高（屏高占比）
const ROW_PLAY_H := 0.10   # 开始游戏高（屏高占比）
const ROW_GAP := 0.03      # 行间空隙（屏高占比）

## 开始游戏的矩形：横向 83%→101%（右端出血 1%），离地 3%，高 10% 屏高。
## 抽成静态方法给结算页的"继续"复用——同一处布局写两遍迟早走样。
static func play_btn_rect(vp: Vector2) -> Rect2:
	var play_h := vp.y * ROW_PLAY_H
	return Rect2(vp.x * 0.83, vp.y * 0.97 - play_h, vp.x * 0.18, play_h)

const LIB_PAD := 0.01  # 带左右内边距（屏宽占比）
const STRIPE_SHADER := preload("res://shaders/stripes.gdshader")
const TOOL_H := 0.07   # 曲库工具条高 = 翻页胶囊高（屏高占比）
const TOOL_Y := 0.02   # 工具条顶距（屏高占比）
const GRID_BOT := 0.10 # 网格底部留白：盖住 90%→97% 翻页器 + 空隙（屏高占比）

var _stripe: ColorRect
var _right_tint: ColorRect
var _spark: ScrollSpark
var _spark2: ScrollSpark
var _b_back: NeoButton
var _b_local: NeoButton
var _b_fav: NeoButton
var _b_pz: NeoButton
var _b_pt: NeoButton
var _grid_scroll: ScrollContainer
var _grid_margin: MarginContainer
var _fade_t: TextureRect
var _fade_b: TextureRect
var _grid: SongGrid
## 首烘摊平泵（game.gd 建，add_child 前注入）；null 时全部回落惰性烘焙原行为
var bake: BakePump
var _art: SongCard
var _sb_del: NeoButton
var _sb_fav_side: NeoButton
var _sb_cfg: NeoButton
const FAV_YELLOW := Color(1.0, 0.79, 0.05)
const DEL_RED := Color(0.88, 0.33, 0.31)
var _b_play: NeoButton
var _search: LineEdit
var _b_filter: NeoButton
var _b_sort: NeoButton
var _b_load: NeoButton
var _query := ""
var _search_all: Array = []
var _swipe: SwipeScroll
var _diff_max := 18.0
var _has_charts := true
var _sort_field := ""
var _desc := false
var _popup: Control
var _popup_dim: ColorRect
var _popup_panel: Panel
var _popup_kind := ""
var _diff_label: Label
var _diff_slider: HSlider
var _has_charts_box: CheckBox
var _sort_pills: Array[NeoButton] = []
var _dir_pill: NeoButton
const SORT_FIELDS := [["默认", ""], ["难度", "difficulty"], ["曲名", "title"], ["音乐家", "authorName"]]
var _pg_l: NeoButton
var _pg_r: NeoButton
var _pager: Panel
var _pager_sb: StyleBox   # 翻页胶囊：换成烘过的 9-slice 纹理（StyleBoxFlat 圆角有毛刺）
var _pager_l: Label
var _phi: Label
var _rank_img: TextureRect
var _spinner: LoadingSpinner  # osu LoadingSpinner 移植：曲库加载（PZ 翻页/搜索/本地/收藏）时居中显示
var _net_hint: Label  # PZ 拉取失败的一行原因（APK 上看不见 logcat，之前失败=空页面无线索）
var _net_panel: PanelContainer
var _stats_l: Label
var _stats_r: Label
var _chip_p: Array[Panel] = []
var _chip_sb: Array[StyleBoxFlat] = []
var _chip_l: Array[Label] = []
var _chip_tiers: Array[Color] = []
var _cur_charts: Array = []
var _chip_sel := 0
var _chip_name: Label
var _diffs_rect := Rect2()
var _zoom: Control
var _zoom_card: SongCard
var _zoom_from := Vector2.ONE  # 放大层退回曲绘时的目标缩放比（开层时算一次）
var _jump_edit: LineEdit
var _laid := false
var _api: PzApi
var _remote := false
var _sel_song := {}  # 当前选中曲目（空 = 未选中，开始游戏禁用）
var _cur_pz := ""
var _pt: PtApi
var _pt_mode := false
var _pt_all: Array = []
var _pt_page := 0
var _cur_cover_url := ""
# ── 选曲试听（PhiTogether chartselect.vue 的 playPreview 同一套）──
# 选中即播、整曲循环、从 preview_start 起播、5 秒淡入；换歌/离开选曲页立刻收。
var _prev: AudioStreamPlayer
var _prev_tw: Tween
var _prev_loop_tw: Tween   # mp3 没有区间 loop，用它定时把播放头跳回段首
var _prev_dense := {}      # 曲目路径 → AudioComplexity 的 {"t","why","peak","mean"}
var _prev_playing_end := 0.0  # 当前循环段的终点秒（探针读它核对）
var _prev_deadline_ms := 0    # 换歌淡出：下一条最早起播的时刻（ticks msec）
var _prev_seek_n := 0         # 循环段跳回段首的次数（探针核对用）
var _prev_job := 0
var _prev_playing_src := ""
var _prev_seed := ""        # 起播点的稳定种子（曲名）：同一首每次听同一段
var _prev_playing_at := 0.0 # 实际起播秒（--qaprev 探针读它对答案，不参与播放）
var _prev_cache := {}      # 曲目路径 → 已解码的流（最近 4 首；点来点去不重复解）
var _prev_wait_dest := ""  # 远端试听正在拉的那份缓存
var _prev_wait_job := 0
var _default_cover: Texture2D

signal nav(id)
signal import_requested(path)  # 原生资源管理器选定谱面包 → game.gd 导入
signal art_changed(tex: Texture2D)  # 选中曲目的曲绘（整页背景跟着换）
signal download_requested             # 只下载（社区谱面两步走：先下载，再游玩）
signal pz_login_requested             # 未登录点 PhiZone → 请 game 开登录卡片
## game 注入的"是否已登录 PhiZone"探针（不注入=不拦，方便 QA/单测直接进页）
var pz_logged_check: Callable = Callable()

func _notification(what: int) -> void:
	# 离开选曲页（回菜单 / 进谱面 / 进设置）就停试听——PT 也是靠路由切换 audio.stop()
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_stop_preview(0.25)

func _ready() -> void:
	# 曲库带：动态斜条纹层（透明/50% 两档交错 + 发光滚动条光点），垫在所有内容之下
	_stripe = ColorRect.new()
	_stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stripe.z_index = -1
	var sm := ShaderMaterial.new()
	sm.shader = STRIPE_SHADER
	_stripe.material = sm
	add_child(_stripe)
	# 第三部分：直接 50% 黑透明底
	_right_tint = ColorRect.new()
	_right_tint.color = Color(0, 0, 0, 0.5)
	_right_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_right_tint.z_index = -1
	add_child(_right_tint)
	# 曲库滚动指示：切口菱形竖条，分界各一根（导航/曲库、曲库/详情）
	_spark = ScrollSpark.new()
	_spark.z_index = 60
	add_child(_spark)
	_spark2 = ScrollSpark.new()
	_spark2.z_index = 60
	add_child(_spark2)
	_b_back = _btn("返回", "back")
	_b_back.square_left = true  # 贴屏边，左侧直角
	_b_back.set_icon("res://assets/icons/back.svg", 0.3)
	_b_local = _btn("本地谱面", "local")
	_b_fav = _btn("收藏谱面", "fav")
	_b_pz = _btn("PZ 社区", "pz")
	_b_pt = _btn("PT 社区", "pt")
	# 通屏宽的上下遮罩会盖过导航带：导航钮抬到遮罩之上
	for nb in [_b_back, _b_local, _b_fav, _b_pz, _b_pt]:
		nb.z_index = 5
	_grid_scroll = ScrollContainer.new()
	_grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_grid = SongGrid.new()
	_grid.force_cols = 3  # 选曲页恒 3 列 30 张，不随窗口比例
	_grid.bake = bake  # add_child(_grid) 之前注入（泵在 game.gd 里）
	# 卡片左下角的难度胶囊：本地曲库的多档数据在侧表里（不写回条目=避免自引用），
	# 所以把"条目→难度列表"的查表交给网格。远端条目自带 diffs，同一条路也走得通。
	_grid.tiers_lookup = _charts_of
	_grid_margin = MarginContainer.new()
	_grid_margin.mouse_filter = Control.MOUSE_FILTER_PASS
	_grid.mouse_filter = Control.MOUSE_FILTER_PASS  # 容器链全 PASS：触屏拖拽才能冒泡到 ScrollContainer
	_grid_margin.add_child(_grid)
	_grid_scroll.add_child(_grid_margin)
	add_child(_grid_scroll)
	# 触屏滑动滚曲库：卡片 PASS 冒泡 → 容器手扶 ScreenDrag 位移
	# 全站统一手势滑动（鼠标拖/手指拖/触控板 + 惯性，滚动条隐形）：见 swipe_scroll.gd
	_swipe = SwipeScroll.attach(_grid_scroll)
	# 4.7 ScrollContainer 无 value_changed：挂内部 ScrollBar（Range 有该信号）
	_grid_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _update_stripe_progress())
	# 上下渐隐：滚动区全高，卡片滑入/出工具条与翻页器带时淡出而非硬切
	_fade_t = _fade(true)
	_fade_b = _fade(false)
	# 曲库工具条：药丸搜索框 + 圆形 过滤/排序 —— 建在滚动区之后，树序天然盖在其上可点
	_search = LineEdit.new()
	_search.placeholder_text = "搜索"
	var ssb := StyleBoxFlat.new()
	ssb.bg_color = UiTokens.SURFACE_PANEL
	ssb.set_corner_radius_all(999)
	ssb.content_margin_left = 24.0
	ssb.content_margin_right = 24.0
	_search.add_theme_stylebox_override("normal", ssb)
	_search.add_theme_stylebox_override("focus", ssb)
	_search.add_theme_color_override("font_color", UiTokens.INK)
	_search.add_theme_color_override("font_placeholder_color", UiTokens.INK_SUB)
	_search.text_submitted.connect(_on_search)
	_search.text_submitted.connect(_kb_hide)
	_search.focus_entered.connect(_kb_show.bind(_search))
	_search.focus_exited.connect(_kb_hide)
	add_child(_search)
	_b_filter = _cirbtn("过滤", "filter")
	_b_filter.set_icon("res://assets/icons/filter.svg", 0.5)
	_b_sort = _cirbtn("排序", "sort")
	_b_sort.set_icon("res://assets/icons/sort.svg", 0.5)
	_b_filter.pressed.connect(_toggle_filter_pop)
	_b_sort.pressed.connect(_toggle_sort_pop)
	# 导入谱面包：仅本地页可见（收藏/PZ 页不适用）
	_b_load = _cirbtn("导入", "load")
	_b_load.set_icon("res://assets/icons/load.svg", 0.5)
	_b_load.pressed.connect(_pick_pack)
	# 滚动条隐形由 SwipeScroll.attach 统一做（三页一套，不再各处自己置空）
	_art = SongCard.new()
	_art.mask_ratio = 0.0  # 无底部遮罩的纯卡片形态
	_art.fit_to_viewport = false  # 尺寸由 _layout 显式给定
	_art.keep_bright = true
	_default_cover = SongCard.load_cover("res://assets/covers/cover_01.png")
	if _default_cover == null:
		_default_cover = load("res://assets/covers/cover_01.png")  # 读不动就退回导入件（慢路径仍可用）
	_art.cover = _default_cover
	add_child(_art)
	_prev = AudioStreamPlayer.new()
	_prev.volume_db = -80.0
	add_child(_prev)
	_art.gui_input.connect(_on_art_gui)
	# 曲绘右侧竖排小方块：删除 / 收藏 / 游玩配置
	_sb_del = _btn("删除", "art_delete")
	_sb_del.set_icon("res://assets/icons/delete.svg", 0.5)
	_sb_del.set_icon_tint(DEL_RED)
	_sb_fav_side = _btn("收藏", "art_fav")
	_sb_fav_side.set_icon("res://assets/icons/favorite.svg", 0.5)
	_sb_fav_side.set_icon_tint(FAV_YELLOW)
	_sb_cfg = _btn("游玩配置", "art_config")
	_sb_cfg.set_icon("res://assets/icons/modular.svg", 0.5)
	_sb_del.pressed.connect(_delete_selected)
	_sb_fav_side.pressed.connect(_toggle_favorite)
	# 评级带：方盒占满带高；右侧分数上行、Acc 下行，两行共用同一字号（_layout 内摆放）
	# 评级位：没打过=灰色 60% 的 NEW（PhiTogether userScore 约定）；打过 → Rank.png 切片
	_phi = _lbl("NEW", Color(0.64, 0.62, 0.70, 0.6))
	_phi.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_rank_img = TextureRect.new()
	_rank_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rank_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_rank_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rank_img.visible = false
	add_child(_rank_img)
	_stats_l = _lbl("0000000", UiTokens.INK)
	_stats_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_stats_l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_stats_r = _lbl("0.00%", UiTokens.INK_SUB)
	_stats_r.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_stats_r.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_chip_name = _lbl("", UiTokens.INK_SUB)
	_b_play = NeoButton.new()
	_b_play.text = ""
	_b_play.min_size_hint = Vector2.ZERO
	add_child(_b_play)
	_b_play.pressed.connect(_press_play)
	_b_play.square_right = true  # 贴屏右边，与"返回"中心对称
	_b_play.set_icon("res://assets/icons/play.svg", 0.5)
	# 翻页器：胶囊页码 + 两侧圆形翻页钮
	_pg_l = _pgbtn("◀")
	_pg_l.pressed.connect(func() -> void: _goto_page(_grid.page - 1))
	_pg_r = _pgbtn("▶")
	_pg_r.pressed.connect(func() -> void: _goto_page(_grid.page + 1))
	_pager_sb = _frost_sb()
	_pager = _panel(_pager_sb)
	_pager.mouse_filter = Control.MOUSE_FILTER_STOP
	_pager.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_pager.gui_input.connect(_on_pager_gui)
	_pager_l = _lbl("第 1 页", UiTokens.INK)
	# 就地页码输入：点胶囊直接在本体上敲数字回车跳转
	_jump_edit = LineEdit.new()
	_jump_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	for st in ["normal", "focus", "read_only"]:
		var esb := StyleBoxFlat.new()
		esb.bg_color = Color(0, 0, 0, 0)  # 透明底：磨砂胶囊本体就是它的背景
		esb.set_corner_radius_all(999)
		_jump_edit.add_theme_stylebox_override(st, esb)
	_jump_edit.add_theme_color_override("font_color", UiTokens.INK)
	_jump_edit.add_theme_color_override("font_placeholder_color", UiTokens.INK_SUB)
	_jump_edit.add_theme_color_override("font_selected_color", UiTokens.INK)
	_jump_edit.visible = false
	_jump_edit.text_submitted.connect(_submit_jump)
	_jump_edit.text_submitted.connect(_kb_hide)
	_jump_edit.focus_entered.connect(_kb_show.bind(_jump_edit))
	_jump_edit.focus_exited.connect(_kb_hide)
	_jump_edit.focus_exited.connect(close_jump_edit)
	add_child(_jump_edit)
	_grid.page_changed.connect(func(_p: int, _pc: int) -> void: _update_pager())
	_update_pager()
	_grid.song_selected.connect(_on_song_pressed)
	_api = PzApi.new()
	add_child(_api)
	_api.songs_loaded.connect(_on_list)
	_api.chart_list_loaded.connect(_on_list)
	_api.search_done.connect(_on_search_done)
	_api.charts_loaded.connect(_on_charts)
	_api.chart_meta_done.connect(_on_chart_meta)
	_api.cover_loaded.connect(_on_cover)
	_api.raw_file_done.connect(_on_prev_raw)
	_grid.page_changed.connect(_on_page)
	_spinner = LoadingSpinner.new()
	_spinner.z_index = 70  # 盖条纹带/滚动装饰(60)，低于弹窗(90)与放大层(120)
	add_child(_spinner)
	_net_hint = Label.new()
	_net_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_net_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_net_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_net_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_net_hint.add_theme_font_override("font", UiTokens.install_font())
	_net_hint.modulate = Color(1.0, 0.80, 0.74)
	# 必须带底板：直接画在卡面上时字压着曲绘完全读不了（45_nethint.png 实证）
	_net_panel = PanelContainer.new()
	_net_panel.z_index = 71  # spinner(70) 同带之上、弹窗(90)/放大(120)之下
	_net_panel.visible = false
	var nsb := StyleBoxFlat.new()
	nsb.bg_color = Color(0.05, 0.06, 0.08, 0.95)
	nsb.set_corner_radius_all(10)
	nsb.set_border_width_all(1)
	nsb.border_color = Color(1.0, 0.62, 0.55, 0.45)
	nsb.content_margin_left = 14
	nsb.content_margin_right = 14
	nsb.content_margin_top = 9
	nsb.content_margin_bottom = 9
	_net_panel.add_theme_stylebox_override("panel", nsb)
	_net_panel.add_child(_net_hint)
	add_child(_net_panel)
	_api.net_error.connect(_on_net_error)
	_pt = PtApi.new()
	add_child(_pt)
	_pt.songs_loaded.connect(_on_pt_songs)
	_pt.net_error.connect(func(msg: String) -> void:
		_spinner.hide_spin()
		_on_net_error(msg))
	_b_local.pressed.connect(_enter_local)
	_b_pz.pressed.connect(_enter_pz)
	_b_pt.pressed.connect(_enter_pt)
	_load_favs()
	# 本地谱面暂无真实数据源：空曲库起步（mock 示例已删），PZ 社区拉真列表
	_grid.set_remote([], 1, 0)
	_set_charts([])
	_update_pager()
	_sync_play()  # 未选中任何曲 → 开始游戏禁用
	get_viewport().size_changed.connect(_layout)
	_layout()

func grid_ref() -> SongGrid:
	return _grid

## 进入本页（或切页签）时的逐级显示：导航列 → 工具条 → 详情列 → 翻页器。
## 曲库卡片不在这里——它在 set_remote/set_page 换批时自己放波浪，
## 这样 PZ 拉取回来那一刻才是"一张张浮出来"，而不是提前空放一次。
## 全部只动 alpha/scale（不碰 position），所以转场期间零重排、不掉帧。
func reveal() -> void:
	# 详情大卡下一帧就要露出来，插队到曲库 30 张之前（它自己也在淡入，19ms 藏在空帧里）
	if bake != null:
		_art.hold_bake(true)
		bake.push_front(_art.prewarm_bake)
	UiMotion.cascade([_b_back, _b_local, _b_fav, _b_pz, _b_pt],
		UiTokens.DUR_ITEM, UiTokens.STEP_ITEM, 0.0)
	var tools: Array = [_search, _b_filter, _b_sort]
	if _b_load.visible:
		tools.append(_b_load)
	UiMotion.cascade(tools, UiTokens.DUR_ITEM, UiTokens.STEP_ITEM, UiTokens.STEP_GROUP)
	UiMotion.cascade([_art, _sb_del, _sb_fav_side, _sb_cfg, _phi, _rank_img, _stats_l,
		_stats_r, _chip_name, _b_play], UiTokens.DUR_ITEM, UiTokens.STEP_ITEM, UiTokens.STEP_GROUP * 2.0)
	UiMotion.cascade([_pg_l, _pager, _pg_r], UiTokens.DUR_ITEM, UiTokens.STEP_ITEM, 0.12)

## 退场：整页淡出后由 done 隐藏
func fade_out(done: Callable) -> void:
	UiMotion.fade_out(self, UiTokens.DUR_PAGE_OUT, done)

func api() -> PzApi:
	return _api

func art() -> SongCard:
	return _art

func zoom_open() -> bool:
	return _zoom != null

func close_zoom() -> void:
	if _zoom == null:
		return
	# 先摘句柄再淡出：Esc/再次双击判定的是"有没有打开"，不能等动画结束
	var z := _zoom
	var card := _zoom_card
	_zoom = null
	_zoom_card = null
	UiMotion.to_scale(card, _zoom_from, 0.18)
	UiMotion.fade_out(z, 0.16, z.queue_free)

func button_for(id: String) -> NeoButton:
	match id:
		"back": return _b_back
		"local": return _b_local
		"fav": return _b_fav
		"pz": return _b_pz
		"pt": return _b_pt
		"play": return _b_play
		"page_prev": return _pg_l
		"page_next": return _pg_r
		"filter": return _b_filter
		"sort": return _b_sort
		"load": return _b_load
		"art_delete": return _sb_del
		"art_fav": return _sb_fav_side
		"art_config": return _sb_cfg
	return null

## 圆形工具钮：pill+正方形=圆
func _cirbtn(caption: String, id: String) -> NeoButton:
	var b := NeoButton.new()
	b.text = caption
	b.pill = true
	b.min_size_hint = Vector2.ZERO
	add_child(b)
	b.pressed.connect(func() -> void: nav.emit(id))
	return b

func _btn(caption: String, id: String) -> NeoButton:
	var b := NeoButton.new()
	b.text = caption
	b.min_size_hint = Vector2.ZERO
	add_child(b)
	b.pressed.connect(func() -> void: nav.emit(id))
	return b

## 翻页圆钮：不发 nav，行为本地处理
func _pgbtn(caption: String) -> NeoButton:
	var b := NeoButton.new()
	b.text = caption
	b.pill = true
	b.min_size_hint = Vector2.ZERO
	add_child(b)
	return b

func _update_pager() -> void:
	_pager_l.text = "第 %d 页" % (_grid.page + 1)
	_pg_l.set_ui_disabled(_grid.page <= 0)
	_pg_r.set_ui_disabled(_grid.page >= _grid.page_count() - 1)
	_update_stripe_progress.call_deferred()  # 内容高度变化后等布局稳定再取滚动范围

## 滚动进度 → 四角星光点位置
func _update_stripe_progress() -> void:
	if _spark == null:
		return
	var v := _grid_scroll.get_v_scroll_bar()
	var p := 0.0
	# 4.7 ScrollContainer：max_value=内容高，可滚上限实为 max_value-page
	var span := v.max_value - v.page
	if span > 0.0:
		p = clampf(v.value / span, 0.0, 1.0)
	_spark.set_scroll(p)
	_spark2.set_scroll(p)

func pager_global_center() -> Vector2:
	return _pager.get_global_rect().get_center()

func jump_editing() -> bool:
	return _jump_edit.visible

func jump_input(t: String) -> void:
	_submit_jump(t)

func close_jump_edit() -> void:
	if _jump_edit.visible:
		_jump_edit.visible = false
		_jump_edit.text = ""
		_pager_l.visible = true

func _on_pager_gui(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		if _jump_edit.visible:
			return  # 点输入框自身不重开
		if _grid.page_count() > 1:
			_pager_l.visible = false
			_jump_edit.text = ""
			_jump_edit.placeholder_text = "页码"
			_jump_edit.visible = true
			_jump_edit.grab_focus()

func _submit_jump(t: String) -> void:
	var p := clampi(int(t.strip_edges()) if t.strip_edges().is_valid_int() else _grid.page + 1,
		1, _grid.page_count())
	close_jump_edit()
	_goto_page(p - 1)

func _goto_page(i: int) -> void:
	if _pt_mode:
		_apply_pt_slice(i + 1)
	elif _remote:
		_fetch(i + 1)  # page 由列表回填
	else:
		_grid.set_page(i)

## 服务端拉取唯一入口：搜索态走宽搜索合并集（客户端分页），否则走列表端点
func _fetch(page: int) -> void:
	_spinner.show_spin()  # 网络加载起点；_on_list/_on_search_done 收口
	if _query != "":
		if _search_all.is_empty():
			_api.search_charts(_query, _diff_max)
		else:
			_apply_slice(page)
	elif _has_charts:
		_api.load_chart_list(page, _query, _diff_max, _sort_field, _desc)
	else:
		_api.load_songs(page, _query, _sort_field, _desc)

func _on_net_error(msg: String) -> void:
	# 只在 PZ 页提示（本地页与网络无关，别串台）；重进 PZ 页或翻页会自动清掉
	if not _remote:
		return
	_net_hint.text = msg
	_net_panel.visible = true
	_layout()

func _on_search_done(items: Array) -> void:
	_search_all = items
	_apply_slice(1)

func _apply_slice(page1: int) -> void:
	_net_panel.visible = false
	var per := 30
	var pages := maxi(ceili(float(_search_all.size()) / float(per)), 1)
	var idx := clampi(page1 - 1, 0, pages - 1)
	var start := idx * per
	var part: Array = _search_all.slice(start, mini(start + per, _search_all.size()))
	_grid.set_remote(part, pages, idx)
	var uncached: Array = []
	for d in part:
		var url := String(d.get("cover_url", ""))
		var tex := _api.cover_cached(url)
		if tex != null:
			_grid.apply_cover(url, tex)
		else:
			_api.load_cover(url)
			uncached.append(url)
	_page_load_start(uncached, not part.is_empty())
	if not part.is_empty():
		_on_song_pressed(part[0])
	_update_pager()
	_refresh_tool_active()

func _enter_pz() -> void:
	# 只有登录之后才可以连 PZ 社区（用户 2026-10-27）：没登录就把登录卡片要回来，
	# 页签不切、不发起任何请求。
	if pz_logged_check.is_valid() and not bool(pz_logged_check.call()):
		pz_login_requested.emit()
		return
	_stop_preview(0.15)   # 换页签=不在看这一首了，试听立刻收
	_fav_mode = false
	_pt_mode = false
	_remote = true
	_net_panel.visible = false  # 进页先清上一次失败提示，重试成功前也不该挂着旧原因
	_sel_song = {}
	_b_pz.set_selected(true)
	_b_local.set_selected(false)
	_b_fav.set_selected(false)
	_b_pt.set_selected(false)
	_b_load.visible = false  # 导入只属于本地页
	_layout()
	_sync_play()
	_refresh_side()
	_fetch(_grid.page + 1)

## PT 社区谱面库（PTC）：一次拉全量 pt_songs.json，客户端搜索/分页；
## 卡片/难度胶囊直接吃条目自带的 charts[]，不再发第二次"难度列表"请求。
func _enter_pt() -> void:
	_stop_preview(0.15)   # 换页签=不在看这一首了，试听立刻收
	_fav_mode = false
	_pt_mode = true
	_remote = true
	_net_panel.visible = false
	_cur_pz = ""
	_sel_song = {}
	_b_pt.set_selected(true)
	_b_local.set_selected(false)
	_b_fav.set_selected(false)
	_b_pz.set_selected(false)
	_b_load.visible = false
	_layout()
	_sync_play()
	_refresh_side()
	if _pt_all.is_empty():
		_spinner.show_spin()
		_pt.load_songs()
	else:
		_apply_pt_slice(1)

func _on_pt_songs(items: Array) -> void:
	_pt_all = items
	_spinner.hide_spin()
	_apply_pt_slice(1)

func _apply_pt_slice(page1: int) -> void:
	var q := _query.strip_edges().to_lower()
	var src: Array = _pt_all
	if q != "":
		src = []
		for dv in _pt_all:
			var d: Dictionary = dv
			var hay := ("%s %s %s %s %s" % [d.get("title", ""), d.get("artist", ""),
					d.get("designer", ""), d.get("code", ""),
					" ".join(d.get("tags", []) as Array)]).to_lower()
			if hay.contains(q):
				src.append(d)
	var per := 30
	var pages := maxi(ceili(float(src.size()) / float(per)), 1)
	var idx := clampi(page1 - 1, 0, pages - 1)
	var part: Array = src.slice(idx * per, mini((idx + 1) * per, src.size()))
	_pt_page = idx
	_net_panel.visible = false
	_grid.set_remote(part, pages, idx)
	for dv2 in part:
		var url := String((dv2 as Dictionary).get("cover_url", ""))
		if url == "":
			continue
		var tex := _api.cover_cached(url)
		if tex != null:
			_grid.apply_cover(url, tex)
		else:
			_api.load_cover(url)
	if not part.is_empty():
		_on_song_pressed(part[0])
	_update_pager()
	_refresh_tool_active()
	_sync_play()

## 手机软键盘：Godot 的 LineEdit 聚焦不会自己弹输入法，必须显式调
## DisplayServer.virtual_keyboard_show（4.7 实名，旧名 keyboard_show 已不在 API 里）。
## 文本框聚焦=叫起，失焦/提交=收起；插了实体键盘就不弹，免得挡界面。
## 点搜索框以外的任何地方就取消聚焦（Godot 的 LineEdit 只有点到"会抢焦点的控件"上
## 才失焦；点背景/卡片空白处不会 → 手机上键盘一直挂着关不掉）。
## 放在 _input：它先于 GUI 拾取执行，所以"点框内"时 has_focus 还是旧状态不会被误伤。
func _input(ev: InputEvent) -> void:
	if not visible or _search == null or not _search.has_focus():
		return
	var pressed := (ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed) \
			or (ev is InputEventScreenTouch and (ev as InputEventScreenTouch).pressed)
	if not pressed:
		return
	var at := Vector2.ZERO
	if ev is InputEventMouseButton:
		at = (ev as InputEventMouseButton).position
	else:
		at = (ev as InputEventScreenTouch).position
	if _search.get_global_rect().has_point(at):
		return
	if is_instance_valid(_jump_edit) and _jump_edit.visible and _jump_edit.get_global_rect().has_point(at):
		return
	_search.release_focus()

func _kb_show(e: LineEdit) -> void:
	if DisplayServer.has_hardware_keyboard():
		return
	DisplayServer.virtual_keyboard_show(e.text)


func _kb_hide(_t: String = "") -> void:
	DisplayServer.virtual_keyboard_hide()

func _on_search(t: String) -> void:
	_query = t
	_search_all = []
	if _pt_mode:
		_apply_pt_slice(1)  # PT 列表已全量在本地：客户端过滤，不打网络
	elif _remote:
		_fetch(1)
	else:
		_enter_pz()  # 本地空库下搜索 = 直接搜 PZ

func _enter_local() -> void:
	_stop_preview(0.15)   # 换页签=不在看这一首了，试听立刻收
	_load_batch += 1  # 断开上一批网络门控，防旧回调提前收掉本次 flash
	_spinner.flash()  # 同步扫描瞬时完成：MIN_SHOW 保证动画亮一下
	_fav_mode = false
	_pt_mode = false
	_remote = false
	_net_panel.visible = false  # 本地页不放网络失败提示
	_cur_pz = ""
	_cur_cover_url = ""
	_search_all = []
	_sel_song = {}
	_local_items_cache = []  # 重扫：本次会话新下载的 PZ 谱立即出现在本地页
	_b_local.set_selected(true)
	_b_pz.set_selected(false)
	_b_fav.set_selected(false)
	_b_pt.set_selected(false)
	_b_load.visible = true
	# 分段时间：点「单人游戏」那一下是同步跑完的，哪一段在卡要拿数字说话（--qaanim 的 QAANIM_JOB 对得上）
	var t1 := Time.get_ticks_usec()
	_layout()  # 工具条按可见钮数重排（不留空槽）
	_art_cover(_default_cover)
	var t2 := Time.get_ticks_usec()
	var items := _local_items()
	var t3 := Time.get_ticks_usec()
	_grid.set_remote_full(items, 30)  # 本地库全量 + 客户端分页（只给 1 页会永远翻不动）
	var t4 := Time.get_ticks_usec()
	# 冷解析 + 封面解码全部交给泵：一帧一件。以前这两段（2118ms + 429ms）同步跑在
	# 「点单人游戏」那一帧里——动画再顺，前面挡着 2.7 秒冻结也只会被看成"卡一下然后瞬间到位"。
	var t5 := Time.get_ticks_usec()
	var njob := _queue_local_jobs(items)
	_set_charts([])
	_update_pager()
	_sync_play()
	_refresh_side()
	var t6 := Time.get_ticks_usec()
	print("QA-ENTER 摆位=%.1f 列表(缓存+列举)=%.1f 建网格+级联=%.1f 排队作业=%d 详情收尾=%.1f 合计=%.1fms" % [
		float(t2 - t1) / 1000.0, float(t3 - t2) / 1000.0, float(t4 - t3) / 1000.0,
		njob, float(t6 - t5) / 1000.0, float(t6 - t1) / 1000.0])
	_backfill_pe_meta()  # 修复前下载的老 PE 目录没 info.txt → 查服务器补写

## 把「冷解析元数据 + 解封面」丢给工作线程（BakePump），主线程每帧只收割结果；
## 泵缺席时同步执行，行为与改造前一致（QA/兜底路径）
func _queue_local_jobs(items: Array) -> int:
	var n := 0
	if bake != null:
		# 落盘节流后的收尾：队列排空时补写一次，保证这批解析不会丢
		bake.on_idle = ChartMetaCache.force_save
	for p in _meta_pending:
		if bake != null:
			bake.push_threaded(_thread_scan.bind(String(p[0]), String(p[2])),
				_apply_scan.bind(String(p[0]), String(p[1]), p[3] as Array))
		else:
			_resolve_meta(p[0], p[1], p[2], p[3])
		n += 1
	_meta_pending = []
	for it in items:
		var cp := String(it.get("local_cover", ""))
		if cp == "":
			continue
		var cu := String(it["cover_url"])
		if bake != null:
			bake.push_threaded(_thread_load_image.bind(cp), _apply_local_cover.bind(cu))
		else:
			_apply_local_cover(_thread_load_image(cp), cu)
		n += 1
	return n

## 工作线程侧：只读文件/解析 JSON，绝不碰节点、绝不写缓存（回填全在主线程）
func _thread_scan(dir: String, kind: String) -> Array:
	return _scan_entries(dir, kind)

## 按**魔数**解码，不认扩展名。谱包里 ".png 其实是 jpg/webp" 很常见；
## 更常见的是下载失败把 HTML 错误页存成了 bg.png（现场那个只有 181 字节，开头是 <!DOCTYPE html>），
## 那样 `img.load()` 会让引擎反复刷 ERR_FILE_CORRUPT / "Not a PNG file"，图还是拿不到。
## 认不出来就静默返回 null，由调用方回落到默认封面。
func _thread_load_image(path: String) -> Image:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var n := f.get_length()
	if n < 32 or n > 67108864:
		f.close()
		return null
	var head := f.get_buffer(16)
	f.seek(0)
	var buf := f.get_buffer(n)
	f.close()
	var img := Image.new()
	if head[0] == 0x89 and head[1] == 0x50 and head[2] == 0x4E:
		return img if img.load_png_from_buffer(buf) == OK else null
	if head[0] == 0xFF and head[1] == 0xD8:
		return img if img.load_jpg_from_buffer(buf) == OK else null
	if head[0] == 0x52 and head[1] == 0x49 and head[8] == 0x57 and head[9] == 0x45:
		return img if img.load_webp_from_buffer(buf) == OK else null
	return null

## 主线程侧：把解析结果就地合并进已在显示的占位条目（同一批 Dictionary，卡片只重绘）
## 参数顺序：Callable.bind() 把绑定参数排在**实参之后**（glitch_fx 里记过这条），
## 所以后台返回的 fresh 必须是第一个形参，否则 bind 的 dir/fp 会整体错位。
func _apply_scan(fresh: Array, dir: String, fp: String, entries: Array) -> void:
	_merge_entries(entries, fresh)
	ChartMetaCache.put_entries(dir, fp, entries)
	ChartMetaCache.save_if_dirty()
	# 解析完的等级可能让"哪一份是最高难度"换人（占位条目全是 Lv.?、排不出序）：
	# 卡片对象换了就得重建列表，不然卡上的徽章永远停在占位那一档。
	var old_card: Variant = _diffs_by_dir.get(dir, [])
	var new_sorted := _sorted_diffs(entries)
	_diffs_by_dir[dir] = new_sorted
	var new_card: Dictionary = new_sorted[new_sorted.size() - 1] if not new_sorted.is_empty() else {}
	if not (old_card as Array).is_empty() \
			and (old_card as Array)[(old_card as Array).size() - 1] != new_card \
			and not _remote and not _fav_mode:
		_local_items_cache = []
		_refresh_local_grid()
		return
	if _grid != null:
		_grid.refresh_data(dir)  # 只重绘这一目录的卡：全量 redraw 会让每次回填都吃掉一帧
	if not _remote and not _fav_mode and not _sel_song.is_empty():
		for e in entries:
			if String(e.get("local_dir", "")) == String(_sel_song.get("local_dir", "")):
				_refresh_side()
				_sync_stats()
				break

func _apply_local_cover(img: Image, url: String) -> void:
	if img == null or _grid == null:
		return
	_grid.apply_cover(url, SongCard.make_from_image(img))

## 占位条目与解析结果按 local_json（official 一目录多张）对齐后逐键覆盖
func _merge_entries(entries: Array, fresh: Array) -> void:
	for i in entries.size():
		if i >= fresh.size():
			break
		var tgt: Dictionary = entries[i]
		var src: Dictionary = fresh[i]
		if String(tgt.get("local_json", "")) != String(src.get("local_json", "")):
			var hit := -1
			for k in fresh.size():
				if String(fresh[k].get("local_json", "")) == String(tgt.get("local_json", "")):
					hit = k
					break
			if hit < 0:
				continue
			src = fresh[hit]
		for kk in src.keys():
			tgt[kk] = src[kk]

## 冷解析（无泵兜底路径）：同步跑一遍再走同一套应用逻辑
func _resolve_meta(dir: String, fp: String, kind: String, entries: Array) -> void:
	var fresh := _scan_entries(dir, kind)
	if fresh.is_empty():
		return
	_apply_scan(fresh, dir, fp, entries)

## 本地卡列表轻量刷新（回填落盘后用，不重走 _enter_local 避免 spinner 连闪）
func _refresh_local_grid() -> void:
	var items := _local_items()
	_grid.set_remote(items, 1, 0)
	_queue_local_jobs(items)
	_update_pager()

static func _parse_info_txt(txt: String) -> Dictionary:
	var out := {}
	for ln in txt.split("\n"):
		var i := ln.find(":")
		if i <= 0:
			continue
		var k := ln.substr(0, i).strip_edges().to_lower()
		var v := ln.substr(i + 1).strip_edges()
		if String(out.get(k, "")) == "":
			out[k] = v
	return out

## info.txt 的行级读写：只留一份实现（game 下载落盘时的 Level 刷新也走这里），
## 免得两处各写一套"改一行不动其余"的逻辑。
static func info_line(txt: String, key: String) -> String:
	for l in txt.split("\n"):
		var s := String(l).strip_edges()
		if s.begins_with(key + ":"):
			return s.substr(key.length() + 1)
	return ""

static func info_with_level(txt: String, lv: String) -> String:
	var out: Array = []
	for l in txt.split("\n"):
		var s := String(l)
		if s.strip_edges().begins_with("Level:"):
			s = "Level:" + lv
		out.append(s)
	return "\n".join(out)

var _backfill_req := {}

## 给"修复前下载、目录缺 info.txt"的 PZ 谱补元数据（每会话每谱一次）。
## 第二类残留也归它管：旧版 DiffCode 会把自定义难度名截成两字母（Pixel→PI）写进
## info.txt，光改代码不动盘上的文件，他看到的还是 PI。凡是本地记的两字母码
## **不在已知难度码表里**（PI/NA/…）就发一次 /charts/<id> 核对；真码（IN/AT/FA…）不发，
## 免得进一次本地页就打出十几个请求。
func _backfill_pe_meta() -> void:
	var ud := DirAccess.open("user://pz")
	if ud == null:
		return
	for d in ud.get_directories():
		var cid := String(d)
		var dir := "user://pz/" + cid
		if _backfill_req.has(cid):
			continue
		if not FileAccess.file_exists(dir.path_join("chart.json")):
			continue
		if ChartInfo.read_dir(dir).is_empty():
			_backfill_req[cid] = true
			_api.load_chart_meta(cid)
			continue
		var cached := String(ChartInfo.read_dir(dir).get("level", ""))
		if DiffCode.is_unknown_code(cached):
			_backfill_req[cid] = true
			print("QA-BACKFILL 核对可疑难度码 ", cid, " ", cached)
			_api.load_chart_meta(cid)

func _on_chart_meta(cid: String, m: Dictionary) -> void:
	if m.is_empty() or cid == "":
		return
	var dir := "user://pz/" + cid
	if not FileAccess.file_exists(dir.path_join("chart.json")):
		return
	var ip := dir.path_join("info.txt")
	var fresh := str(m.get("level", ""))
	if FileAccess.file_exists(ip):
		# 已有 info.txt：只在"确实是旧规则截出来的码"时改 Level 那一行，其余一律不动
		var old := FileAccess.get_file_as_string(ip)
		var cached := String(info_line(old, "Level"))
		if not DiffCode.is_truncation_of(cached, fresh):
			return
		var fah := FileAccess.open(ip, FileAccess.WRITE)
		if fah == null:
			return
		fah.store_string(info_with_level(old, fresh))
		fah.close()
		# 卡片元数据缓存的指纹只看 chart.json，改了 info.txt 指纹不变 → 不清掉永远显示旧码
		ChartMetaCache.drop(dir)
		print("QA-BACKFILL 刷新 Level ", cached, " → ", fresh, " (", dir, ")")
	else:
		var fa := FileAccess.open(ip, FileAccess.WRITE)
		if fa == null:
			return
		fa.store_string("Name:%s\nArtist:%s\nLevel:%s\nCharter:%s\n" % [
			str(m.get("name", "")), str(m.get("artist", "")), fresh, str(m.get("charter", ""))])
		fa.close()
		print("QA-BACKFILL info.txt -> ", dir, " name=", m.get("name"))
	_local_items_cache = []
	if not _remote and not _fav_mode:
		_refresh_local_grid()

## 本地谱面卡片列表：**只做目录列举 + 缓存查表，绝不解析谱面**。
## 冷启动/新下载的目录走占位条目，真解析由 BakePump 一帧一份补上（见 _resolve_meta）。
## 以前这里每张卡都 read+JSON.parse 整份 chart.json，21 张 = 2118ms 同步冻结在点击那一帧。
var _meta_pending: Array = []  # [[dir, fp, kind, entries], ...]

func _local_items() -> Array:
	if not _local_items_cache.is_empty():
		return _local_items_cache
	var out: Array = []
	_meta_pending = []
	_diffs_by_dir = {}
	# 内置演示谱（res://charts/{dm,ic}）已随包移除，曲库只认下载/导入的本地谱
	# PZ 已下载谱（user://pz/<cid>/）与本地导入谱（user://local/<名>/）都进本地曲库
	var dirs: Array = []
	var arrs := {}
	for root in ["user://pz", "user://local"]:
		var ud := DirAccess.open(root)
		if ud == null:
			continue
		for d in ud.get_directories():
			var dir: String = String(root) + "/" + String(d)
			var kind := "pe" if FileAccess.file_exists(dir.path_join("chart.json")) else "official"
			var arr := _dir_entries(dir, kind)
			if arr.is_empty():
				continue
			dirs.append(dir)
			arrs[dir] = arr
	# 同一首歌的多个难度**可能落在不同目录**（PZ 每张谱一个 cid 目录、PT 每难度一个
	# "PT 曲名 [码 lv]" 目录）。不并卡就是"下两个谱面变成两张卡"（用户 2026-10-26 报的）。
	# 并卡后难度进胶囊：卡片=最高难度那条（活引用），胶囊列表挂到卡片目录的侧表上。
	var groups := {}
	var order: Array = []
	for dir in dirs:
		var key := _song_key_of(String(dir))
		if not groups.has(key):
			groups[key] = []
			order.append(key)
		(groups[key] as Array).append(dir)
	for key in order:
		var gd: Array = groups[key]
		if gd.size() == 1:
			out.append_array(_fold_dir(String(gd[0]), arrs[gd[0]]))
			continue
		var all: Array = []
		for dir in gd:
			_diffs_by_dir[String(dir)] = _sorted_diffs(arrs[dir])
			all.append_array(arrs[dir])
		var sorted := _sorted_diffs(all)
		var top: Dictionary = sorted[sorted.size() - 1]
		var card_dir := String(top.get("local_dir", gd[0]))
		_diffs_by_dir[card_dir] = sorted  # 胶囊 = 合并后的全部难度
		out.append(top)
	_local_items_cache = out
	return out

## 同一首歌的判据：新下载的谱包 info.txt 里写了 SongKey（game 下载时落盘）；
## 老目录没有就退到 PT 目录名的曲名段 / info.txt 的 Name+Artist。
func _song_key_of(dir: String) -> String:
	var ip := dir.path_join("info.txt")
	if FileAccess.file_exists(ip):
		var t := FileAccess.get_file_as_string(ip)
		var k := info_line(t, "SongKey").strip_edges()
		if k != "":
			return k
		var nm := info_line(t, "Name").strip_edges().to_lower()
		if nm != "":
			return "n:" + nm + "|" + info_line(t, "Artist").strip_edges().to_lower()
	var dn := dir.get_file()
	if dn.begins_with("PT "):
		return "pt:" + dn.substr(3).get_slice(" [", 0).strip_edges().to_lower()
	return "d:" + dir

## 同一个目录=同一首歌：official 目录里的 EZ/HD/IN/AT 是**一首歌的几张谱**，
## 必须收成一张卡（用户报"明明是两个谱，结果出现在两个卡片"）。
## 卡对象直接就是"最高难度那份条目"本身（不是副本）——BakePump 的冷解析回填
## 是**就地改这些 Dictionary**（_merge_entries），只有保持对象同一性，
## 解析完刷新卡片徽章才会跟着变；副本文案会永远停在占位值。
## 各难度条目另存侧表 _diffs_by_dir（不写回条目里：那样会让条目自引用，
## ChartMetaCache 序列化 JSON 时直接炸）。
var _diffs_by_dir := {}

## 升序排（最低难度在前，与 PZ 的 Order=difficulty 同形：_set_charts 默认选最后=最高）
static func _diff_rank(e: Dictionary) -> float:
	var lv := int(e.get("level", 0))
	var code := String(e.get("code", ""))
	var ci := DiffCode.KNOWN_CODES.find(code)
	if ci < 0:
		ci = DiffCode.KNOWN_CODES.size()  # 自定义难度名（Pixel…）排在已知码之后
	return float(lv) * 100.0 + float(ci)

func _fold_dir(dir: String, arr: Array) -> Array:
	if arr.is_empty():
		return []
	var sorted := _sorted_diffs(arr)
	_diffs_by_dir[dir] = sorted
	return [sorted[sorted.size() - 1]]  # 卡片=最高难度那份（活引用，回填就地生效）

func _sorted_diffs(arr: Array) -> Array:
	var sorted: Array = arr.duplicate()
	sorted.sort_custom(_diff_rank_cmp)
	return sorted

## 这张目录当前挂在曲库里的卡对象（没收录返回 null）
func _card_of(dir: String) -> Dictionary:
	var arr: Array = _diffs_by_dir.get(dir, [])
	if arr.is_empty():
		return {}
	return arr[arr.size() - 1]

static func _diff_rank_cmp(a: Dictionary, b: Dictionary) -> bool:
	return _diff_rank(a) < _diff_rank(b)

## 这张卡的可选难度：本地目录查侧表，远端/收藏用条目自带的 diffs
func _charts_of(d: Dictionary) -> Array:
	var dir := String(d.get("local_dir", ""))
	if dir != "" and _diffs_by_dir.has(dir):
		return _diffs_by_dir[dir] as Array
	return d.get("diffs", []) as Array

## 目录指纹：谱被替换/重下会变 → 缓存自动失效
func _dir_fp(dir: String, kind: String) -> String:
	if kind == "official":
		var n := 0
		var newest := 0
		for f in _local_json_files(dir):
			n += 1
			newest = maxi(newest, int(FileAccess.get_modified_time(dir.path_join(String(f)))))
		return "o%d|%d" % [n, newest]
	var p := dir.path_join("chart.json")
	if not FileAccess.file_exists(p):
		return "none"
	var fa := FileAccess.open(p, FileAccess.READ)
	var ln := 0
	if fa != null:
		ln = fa.get_length()
		fa.close()
	return "%d|%d" % [int(FileAccess.get_modified_time(p)), ln]

## 命中缓存=零 IO；未命中=占位条目 + 挂一次冷解析作业
func _dir_entries(dir: String, kind: String) -> Array:
	var fp := _dir_fp(dir, kind)
	var ck := ChartMetaCache.get_entries(dir, fp)
	if not ck.is_empty():
		return ck
	var e := _provisional_entries(dir, kind)
	_meta_pending.append([dir, fp, kind, e])
	return e

## 占位条目：只读目录名 / info.txt / sidecar txt（都是几百字节的小文件），不碰谱面 json
func _provisional_entries(dir: String, kind: String) -> Array:
	var out: Array = []
	if kind == "official":
		var info_default := _read_sidecar(dir.path_join("info.txt"))
		for f in _local_json_files(dir):
			var fname := String(f)
			if fname == "extra.json":
				continue
			var base := fname.get_basename()
			var im := _read_sidecar(dir.path_join(base + ".txt"))
			# local_json 一律存**带后缀的文件名**（与 _scan_official 同形）：占位条目这里存过
			# 去后缀的 base，导致从缓存/占位路径进的卡 → play_target.json="IN" → open() 找不到
			# 文件 → 黑一下退回选曲（用户实测"按要求了但无法打开官方谱面"）。
			# 顺带修好 600 行的占位↔冷解析对齐（键不一致时刷新结果永远覆盖不上）。
			out.append(_mk_entry(dir, fname, im, _official_dflt(info_default, base),
				_cover_of(dir, ["illustration", "bg", "cover"])))
		return out
	var i2 := _read_sidecar(dir.path_join("info.txt"))
	var e := _mk_entry(dir, "", {}, i2, _cover_of(dir, ["bg"]))
	e["bpm"] = 0
	out.append(e)  # 漏了这行 = PE/res 目录一条都不返回，整个本地曲库凭空消失（探针抓到的真回归）
	return out

## official 目录级兜底：没有 sidecar 时难度位沿用旧行为 "<文件名> Lv.?"（1057 张官谱夹具依赖这条）
func _official_dflt(info_default: Dictionary, base: String) -> Dictionary:
	var d2: Dictionary = info_default.duplicate()
	if String(d2.get("level", "")) == "":
		d2["level"] = base + " Lv.?"
	return d2

## 一条卡片的公共字段骨架（占位与解析结果同构，便于就地合并）
func _mk_entry(dir: String, json_name: String, im: Dictionary, dflt: Dictionary, cover: String) -> Dictionary:
	var title := str(im.get("name", dflt.get("name", dir.get_file())))
	if title == "":
		# info.txt 里写了 "Name:" 空值时不能把目录名兜底顶掉（旧行为：title 初值=目录名）
		title = String(dir).get_file()
	var lv_raw := str(im.get("level", dflt.get("level", "")))
	if lv_raw == "":
		lv_raw = "IN Lv.?"
	# ChartInfo 把 Composer:/Artist:/Musician: 统一归成 composer，所以兜底链要先看
	# dflt["composer"] 再看旧的 dflt["artist"]（只查 artist 的话，yml 包的曲师会显示空）
	var artist := str(im.get("composer", dflt.get("composer", dflt.get("artist", ""))))
	if artist == "":
		artist = str(im.get("artist", dflt.get("artist", "")))
	var designer := str(im.get("charter", dflt.get("charter", "")))
	var lv_num := 0
	var li := lv_raw.find("Lv.")
	if li >= 0:
		lv_num = int(lv_raw.substr(li + 3).get_slice(" ", 0))
	var e := {
		"pz_id": "",
		"local_dir": dir,
		"local_cover": cover,
		"cover_url": "local:" + dir,
		"title": title,
		"artist": artist,
		"level": lv_num,
		"designer": designer,
		"bpm": 0,
		"code": DiffCode.to_code(lv_raw) if lv_raw.length() >= 2 else lv_raw.left(2),
	}
	if json_name != "":
		e["local_json"] = json_name
	return e

## dir 形态：info.txt / info.yml / info.csv 依次合并（先出现的键赢）
## path 形态（official 的 IN.txt 那种按难度写的 sidecar）：按扩展名单读一份
func _read_sidecar(path: String) -> Dictionary:
	if path.get_extension().to_lower() == "txt" and path.get_file() == "info.txt":
		return ChartInfo.read_dir(path.get_base_dir())
	var fb := FileAccess.open(path, FileAccess.READ)
	if fb == null:
		return {}
	var t := fb.get_as_text()
	fb.close()
	if t.strip_edges().begins_with("{"):
		return ChartInfo.read_file(path)
	return ChartInfo.parse_kv(t)

func _cover_of(dir: String, prefixes: Array) -> String:
	# info 里点名了封面文件（Picture:/Image:，含 RPE 的 <base>-3.png 那类）就先用它，
	# 再退到 bg/cover/illustration 前缀猜测——bad apple 的 black.png、RTX 包的 测试.jpg 都靠这条
	var named := String(ChartInfo.read_dir(dir).get("picture", ""))
	if named != "" and named.contains("."):
		var p0 := dir.path_join(named)
		if FileAccess.file_exists(p0):
			return ProjectSettings.globalize_path(p0)
	for pref in prefixes:
		for ext in ["webp", "png", "jpg", "jpeg"]:
			var p := dir.path_join(String(pref) + "." + String(ext))
			if FileAccess.file_exists(p):
				return ProjectSettings.globalize_path(p)
	return ""

func _local_json_files(dir: String) -> Array:
	var da := DirAccess.open(dir)
	var files: Array = []
	if da == null:
		return files
	da.list_dir_begin()
	var fn := da.get_next()
	while fn != "":
		if not fn.begins_with(".") and fn.get_extension().to_lower() == "json":
			files.append(fn)
		fn = da.get_next()
	da.list_dir_end()
	files.sort()
	return files

## 真正读谱拿元数据（原 _local_items 内联逻辑整段搬来，语义逐条保持）
func _scan_entries(dir: String, kind: String) -> Array:
	var out: Array = []
	if kind == "official":
		return _scan_official(dir)
	var p := dir.path_join("chart.json")
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return out
	var txt := f.get_buffer(f.get_length()).get_string_from_utf8()
	f.close()
	if not txt.begins_with("{"):
		# PE 文本谱没有 META（旧代码就是靠这条判断跳过 JSON 的）：沿用 info.txt/目录名，
		# 并且照样写进缓存——否则每次进页面都要重读一遍这个文件
		return _provisional_entries(dir, kind)
	var j: Variant = JSON.parse_string(txt)
	if typeof(j) != TYPE_DICTIONARY:
		return out
	var meta: Dictionary = (j as Dictionary).get("META", {})
	var bpls: Array = (j as Dictionary).get("BPMList", [])
	var lv_str := String(meta.get("level", ""))
	var im := _read_sidecar(dir.path_join("info.txt"))
	if lv_str == "" and String(im.get("level", "")) != "":
		lv_str = String(im["level"])
	# 只把 META 里"真的有值"的键传进去：_mk_entry 的取值顺序是 META→info.txt→目录名，
	# 空串也算"有值"就会把 info.txt 兜底吃掉（PE 无 META 谱全靠那条兜底显示曲名）
	var meta_im := {}
	if String(meta.get("name", "")) != "":
		meta_im["name"] = String(meta["name"])
	if String(meta.get("composer", "")) != "":
		meta_im["composer"] = String(meta["composer"])
	if String(meta.get("level", "")) != "":
		meta_im["level"] = String(meta["level"])
	if String(meta.get("charter", "")) != "":
		meta_im["charter"] = String(meta["charter"])
	var e2 := _mk_entry(dir, "", meta_im, im, _cover_of(dir, ["bg"]))
	e2["bpm"] = int(roundf(float((bpls[0] as Dictionary).get("bpm", 0)))) if bpls.size() > 0 else 0
	out.append(e2)
	return out

## official（Phigros 原生）谱目录：同目录 <EZ,HD,IN,AT>.json（根含 formatVersion）
## 配 <base>.txt sidecar（Name:/Level: IN Lv.14.7/Song: music.wav/Picture:/Composer:/Charter:）。
## 每个难度 json 出一条卡；native 侧 load_chart_json 按 formatVersion 自分发 official 转换器。
func _scan_official(dir: String) -> Array:
	var out: Array = []
	var cover := _cover_of(dir, ["illustration", "bg", "cover"])
	var info_default := _read_sidecar(dir.path_join("info.txt"))
	for fnameS in _local_json_files(dir):
		var fname := String(fnameS)
		if fname == "extra.json":
			continue
		# 首行含 formatVersion 才算 official（RPE 单文件被规整为 chart.json，走不到这）
		var head := FileAccess.get_file_as_string(dir.path_join(fname))
		if not head.contains("\"formatVersion\""):
			continue
		var j: Variant = JSON.parse_string(head)
		if typeof(j) != TYPE_DICTIONARY:
			continue
		var base := fname.get_basename()
		var im := _read_sidecar(dir.path_join(base + ".txt"))
		var bpm := 0
		var jll: Array = (j as Dictionary).get("judgeLineList", [])
		if jll.size() > 0:
			bpm = int(roundf(float((jll[0] as Dictionary).get("bpm", 0))))
		var e := _mk_entry(dir, fname, im, _official_dflt(info_default, base), cover)
		e["bpm"] = bpm
		out.append(e)
	return out

var _local_items_cache: Array = []

# ── 收藏谱面（user://favorites.json 持久化；本地=目录键，PZ=歌曲 id 键） ──
var _fav_mode := false
var _fav_data := {}
var _fav_order: Array = []
const FAV_FILE := "user://favorites.json"

func _fav_key(d: Dictionary) -> String:
	var ld := String(d.get("local_dir", ""))
	if ld != "":
		# official 多难度目录：键含 json 名，收藏/记录按难度独立
		var jf := String(d.get("local_json", ""))
		return "local:" + ld + ("/" + jf if jf != "" else "")
	var pid := String(d.get("pz_id", ""))
	if pid != "":
		return "pz:" + pid
	return ""

func _load_favs() -> void:
	if not FileAccess.file_exists(FAV_FILE):
		return
	var fa := FileAccess.open(FAV_FILE, FileAccess.READ)
	if fa == null:
		return
	var j: Variant = JSON.parse_string(fa.get_buffer(fa.get_length()).get_string_from_utf8())
	fa.close()
	if typeof(j) != TYPE_DICTIONARY:
		return
	for it in (j as Dictionary).get("items", []):
		if typeof(it) != TYPE_DICTIONARY:
			continue
		var k := _fav_key(it)
		if k == "" or _fav_data.has(k):
			continue
		_fav_data[k] = it
		_fav_order.append(k)

func _save_favs() -> void:
	var arr: Array = []
	for k in _fav_order:
		arr.append(_fav_data[k])
	var fa := FileAccess.open(FAV_FILE, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify({"items": arr}))
	fa.flush()
	fa.close()

func _fav_list() -> Array:
	var out: Array = []
	for k in _fav_order:
		var d: Dictionary = _fav_data[k]
		var ld := String(d.get("local_dir", ""))
		# 本地收藏已失效（被删除）→ 自动不出现在收藏页
		if ld != "" and not DirAccess.dir_exists_absolute(ld):
			continue
		out.append(d)
	return out

func _enter_fav() -> void:
	_stop_preview(0.15)   # 换页签=不在看这一首了，试听立刻收
	_load_batch += 1  # 同 _enter_local：断开旧批门控
	_spinner.flash()  # 收藏列表本地组装：同上亮一下
	_fav_mode = true
	_pt_mode = false
	_remote = false
	_cur_pz = ""
	_cur_cover_url = ""
	_search_all = []
	_sel_song = {}
	_b_fav.set_selected(true)
	_b_local.set_selected(false)
	_b_pt.set_selected(false)
	_b_load.visible = false  # 导入只属于本地页
	_layout()
	_b_pz.set_selected(false)
	_art_cover(_default_cover)
	var list := _fav_list()
	_grid.set_remote(list, 1, 0)
	for it in list:
		var url := String(it.get("cover_url", ""))
		if url.begins_with("local:"):
			# 同 _enter_local：收藏里若有本地谱，解码也丢后台，别在切页签那一帧同步解图
			var cp := String(it.get("local_cover", ""))
			if cp != "":
				if bake != null:
					bake.push_threaded(_thread_load_image.bind(cp), _apply_local_cover.bind(url))
				else:
					_apply_local_cover(_thread_load_image(cp), url)
		else:
			var tex := _api.cover_cached(url)
			if tex != null:
				_grid.apply_cover(url, tex)
			else:
				_api.load_cover(url)
	_set_charts([])
	_update_pager()
	_sync_play()
	_refresh_side()
	if not list.is_empty():
		_on_song_pressed(list[0])

## 收藏/侧钮用的键目标：本地卡收成多难度后，键要跟着选中的胶囊走
## （同一目录的 IN 与 AT 是两条独立收藏，见 _fav_key 的注释）；远端仍用歌曲本体。
func _fav_target() -> Dictionary:
	if String(_sel_song.get("local_dir", "")) != "":
		return _sel_chart()
	return _sel_song

func _toggle_favorite() -> void:
	var tgt := _fav_target()
	var k := _fav_key(tgt)
	if k == "":
		return
	if _fav_data.has(k):
		_fav_data.erase(k)
		_fav_order.erase(k)
	else:
		var snap: Dictionary = (tgt as Dictionary).duplicate(true)
		snap["src"] = "local" if String(snap.get("local_dir", "")) != "" else "pz"
		_fav_data[k] = snap
		_fav_order.append(k)
	_save_favs()
	_refresh_side()
	if _fav_mode:
		var newlist := _fav_list()
		_enter_fav()
		# 保持当前项选中体验：收藏后仍选中它
		for it in newlist:
			if _fav_key(it) == k:
				_on_song_pressed(it)
				break

## 侧钮可见性/染色：删除=仅 user:// 本地谱；收藏=黄——未收藏空心、已收藏内部填满（实心）
func _refresh_side() -> void:
	var ld := String(_sel_song.get("local_dir", ""))
	_sb_del.visible = ld.begins_with("user://")
	var k := _fav_key(_sel_song)
	_sb_fav_side.visible = k != ""
	if k == "":
		return
	var on := _fav_data.has(k)
	_sb_fav_side.set_icon("res://assets/icons/favorite_fill.svg" if on
		else "res://assets/icons/favorite.svg", 0.5)
	_sb_fav_side.set_icon_tint(FAV_YELLOW)

func _delete_selected() -> void:
	var ld := String(_sel_song.get("local_dir", ""))
	if not ld.begins_with("user://"):
		return
	var dlg := AcceptDialog.new()
	dlg.dialog_text = "确定删除该本地谱面？（同时移除已下载的 .pez）"
	dlg.ok_button_text = "删除"
	add_child(dlg)
	dlg.confirmed.connect(_do_delete.bind(ld))
	# 4.7 Window 无 popup_hide：confirmed/canceled 两路都要释放
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	dlg.popup_centered()

## 导入谱面包：Windows/macOS/Linux 用系统原生资源管理器；无原生时退回 Godot FileDialog
var _fd_godot: FileDialog

func _pick_pack() -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		var err := DisplayServer.file_dialog_show(
				"选择谱面包（.pez / .zip / 谱面 json）",
				OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS), "", false,
				DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
				PackedStringArray(["*.pez, *.zip, *.json"]),
				_on_pack_picked)
		if err == OK:
			return
	if _fd_godot == null:
		_fd_godot = FileDialog.new()
		_fd_godot.access = FileDialog.ACCESS_FILESYSTEM
		_fd_godot.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_fd_godot.title = "选择谱面包（.pez / .zip / 谱面 json）"
		_fd_godot.filters = PackedStringArray(
				["*.pez ; PhiTogether 谱面包", "*.zip ; 压缩包", "*.json ; RPE/PE 谱面"])
		_fd_godot.use_native_dialog = true
		_fd_godot.file_selected.connect(func(path: String) -> void: import_requested.emit(path))
		add_child(_fd_godot)
	_fd_godot.popup_centered(Vector2i(860, 580))

func _on_pack_picked(confirmed: bool = false, a: Variant = null, b: Variant = null) -> void:
	# 各平台回调参数不一致（2 参 confirmed+files / 3 参 confirmed+path+files，
	# Windows 4.7 实测传 3 个）：默认参兼容两种，优先取 PackedStringArray 首项
	var arr := PackedStringArray()
	var last_str := ""
	for v in [a, b]:
		if typeof(v) == TYPE_PACKED_STRING_ARRAY and arr.is_empty():
			arr = v
		elif typeof(v) == TYPE_STRING and String(v) != "":
			last_str = String(v)
	var path := String(arr[0]) if arr.size() > 0 else last_str
	if confirmed and path != "":
		import_requested.emit(path)

## 导入完成后刷新（game.gd 调用）：清缓存重扫，正在本地页则立即重排
func refresh_local() -> void:
	_local_items_cache = []
	if not _remote and not _fav_mode:
		_enter_local()

func _do_delete(ld: String) -> void:
	var fa := DirAccess.open(ld)
	if fa != null:
		fa.list_dir_begin()
		var fn := fa.get_next()
		while fn != "":
			if not fa.current_is_dir():
				fa.remove(fn)
			fn = fa.get_next()
		fa.list_dir_end()
	DirAccess.remove_absolute(ld)
	var pz_dir := DirAccess.open("user://pz")
	if pz_dir != null:
		pz_dir.remove(ld.get_file() + ".pez")
	var k := "local:" + ld
	var erased := false
	for fk in _fav_data.keys():
		# 目录删除连带该目录全部难度键（official 一目录多 json）
		if String(fk) == k or String(fk).begins_with(k + "/"):
			_fav_data.erase(fk)
			_fav_order.erase(fk)
			erased = true
	if erased:
		_save_favs()
	_local_items_cache = []
	_sel_song = {}
	_cur_pz = ""
	_cur_cover_url = ""
	_set_charts([])
	_art_cover(_default_cover)
	_sync_play()
	if _fav_mode:
		_enter_fav()
	else:
		_grid.set_remote(_local_items(), 1, 0)
		for it in _local_items():
			var img := Image.new()
			if img.load(String(it["local_cover"])) == OK:
				_grid.apply_cover(String(it["cover_url"]), SongCard.make_from_image(img))
		_update_pager()
		_refresh_side()

## 当前**选中难度**对应的条目：一张卡收成多难度后，所有"这一首的键/记录/ json"
## 都要跟着胶囊走，不能继续用卡片本身（卡片=最高难度那份，切到 EZ 会打错谱）。
## 远端还没回难度列表时 _cur_charts 为空 → 退回卡片自己。
func _sel_chart() -> Dictionary:
	if _cur_charts.is_empty() or _chip_sel < 0 or _chip_sel >= _cur_charts.size():
		return _sel_song
	return _cur_charts[_chip_sel] as Dictionary

## 开始游戏目标：{} = 未选中（按钮已禁用）；{kind:"local",dir} / {kind:"pz",song,chart}
func play_target() -> Dictionary:
	if _sel_song.is_empty():
		return {}
	var ld := String(_sel_song.get("local_dir", ""))
	if ld != "":
		# 页签一致性硬校验：PZ 页绝不回落到本地目标
		if _remote:
			return {}
		# official 目录一目录多难度：json 文件名并入目标（记录/收藏键同规格）。
		# 取**选中胶囊**那条的 json：卡片是最高难度，切到别的难度必须换文件。
		var sc := _sel_chart()
		var jf := String(sc.get("local_json", ""))
		if jf == "":
			jf = String(_sel_song.get("local_json", ""))
		# 并卡后不同难度可能在不同目录：以**选中那条**的目录为准
		var cd := String(sc.get("local_dir", ""))
		if cd != "":
			ld = cd
		return {"kind": "local", "dir": ld, "json": jf}
	if _pt_mode and not _cur_charts.is_empty():
		return {"kind": "pt", "song": _sel_song, "chart": _cur_charts[_chip_sel]}
	if (_remote or _fav_mode) and not _cur_charts.is_empty():
		return {"kind": "pz", "song": _sel_song, "chart": _cur_charts[_chip_sel]}
	return {}

var _play_excl := false
var _need_dl := false      # 当前选中的社区谱还没下到本地 → 按钮是"下载"
var _dl_waiting := false   # 正在下（按钮面上画进度环）

## 当前选中谱面的游玩记录（键与 game.gd 启动舞台时一致）；未选中/没打过 = {}
func _current_record() -> Dictionary:
	var tgt := play_target()
	if tgt.is_empty():
		return {}
	if String(tgt.get("kind", "")) == "local":
		var jf := String(tgt.get("json", ""))
		return PlayRecords.get_record("local:" + String(tgt["dir"]) + ("/" + jf if jf != "" else ""))
	var ch: Dictionary = tgt["chart"]
	if String(tgt.get("kind", "")) == "pt":
		return PlayRecords.get_record("local:" + PtApi.local_dir(tgt["song"], ch))
	return PlayRecords.get_record("pzc:" + String(ch.get("id", "")))

## 把评级方盒 + 分数 + Acc 刷成当前谱面记录态（布局测量前调用）
func _sync_stats() -> void:
	var rec := _current_record()
	var has := not rec.is_empty()
	_rank_img.visible = has
	_phi.visible = not has
	if has:
		_rank_img.texture = PlayRecords.rank_texture(PlayRecords.rank_index(int(rec.get("score", 0))))
		_stats_l.text = "%07d" % int(rec.get("score", 0))
		_stats_r.text = "%.2f%%" % (float(rec.get("acc", 0.0)) * 100.0)
	else:
		_stats_l.text = "0000000"
		_stats_r.text = "0.00%"

## 打完一局回选曲页：刷新记录显示（game.gd._close_player 调）
func refresh_records() -> void:
	if _laid:
		_layout()
	else:
		_sync_stats()

func _sync_play() -> void:
	var tgt := play_target()
	var ok := not tgt.is_empty()
	var excl := false
	_need_dl = false
	if ok and String(tgt.get("kind", "")) in ["pz", "pt"]:
		var ch: Dictionary = tgt["chart"]
		if not bool(ch.get("playable", true)):
			ok = false
			excl = true
		else:
			_need_dl = not _is_downloaded(tgt)
	_b_play.disabled = not ok
	_b_play.modulate = Color(1, 1, 1, 1.0) if ok else Color(0.55, 0.55, 0.6, 0.55)
	_play_mode(excl)
	# 社区谱面两步走：没下载 → 下载图标（点一下只下载）；下好了 → 播放图标
	if ok and not excl:
		_b_play.set_icon("res://assets/icons/download.svg" if _need_dl
				else "res://assets/icons/play.svg", 0.5)

## 这枚目标是否已经在本地下好（PZ 看 pz/<id>/chart.json，PT 看它自己的本地目录）
func _is_downloaded(tgt: Dictionary) -> bool:
	var kind := String(tgt.get("kind", ""))
	var ch: Dictionary = tgt.get("chart", {})
	if kind == "pz":
		var cid := String(ch.get("id", ""))
		return cid != "" and FileAccess.file_exists("user://pz/%s/chart.json" % cid)
	if kind == "pt":
		var dir: String = PtApi.local_dir(tgt.get("song", {}), ch)
		return FileAccess.file_exists(dir.path_join("chart.json"))
	return true

func _press_play() -> void:
	if _b_play.disabled:
		return
	if _need_dl and not _dl_waiting:
		_dl_waiting = true
		_b_play.set_progress(0.0)
		download_requested.emit()
		return
	nav.emit("play")

func set_download_progress(f: float) -> void:
	if not _dl_waiting:
		return
	_b_play.set_progress(clampf(f, 0.0, 1.0))

func on_download_finished(_dir: String) -> void:
	_dl_waiting = false
	_b_play.set_progress(-1.0)
	_sync_play()   # 下好了：按钮切成播放

func on_download_failed(msg: String) -> void:
	_dl_waiting = false
	_b_play.set_progress(-1.0)
	_sync_play()
	push_warning("下载失败：" + msg)

## 独占时收起播放图标，把警示直接写在开始游戏按钮上；文案按按钮实测宽度缩放
func _play_mode(excl: bool) -> void:
	if excl == _play_excl:
		return
	_play_excl = excl
	_b_play.set_icon_shown(not excl)
	if excl:
		_b_play.set_caption("Phigrim独占")
		var f: Font = ThemeDB.fallback_font
		var px: int = int(_b_play.size.y * 0.42)
		var want: float = _b_play.size.x * 0.82
		while px > 9 and f.get_string_size("Phigrim独占", HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > want:
			px -= 1
		_b_play.set_font_size(px)
		_b_play.set_text_color(Color(1, 0.45, 0.45, 0.95))
	else:
		_b_play.set_caption("")  # 常态只留播放图标，不写文案
	_b_play._sync_icon()

func _on_page(p: int, _pc: int) -> void:
	if _pt_mode:
		return  # PT 列表已全量在本地：绝不回落到 PZ 的 _fetch
	if _remote:
		_fetch(p + 1)
		return
	# 本地页翻了页：自动选中本页第一首。以前这里什么都不做，于是详情列/播放钮还停在上页那首、
	# 卡片一张都没高亮——用户看到的就是"翻页显示是错的"。
	# 走卡片的点击入口：高亮（_sel）和 song_selected（详情列）一起对齐
	if not _grid._data_at(0).is_empty():
		_grid._on_card_pressed(0)
	_update_pager()
	_sync_play()

func _on_list(page: int, songs: Array, pages: int) -> void:
	if not _remote or _fav_mode:
		return
	_net_panel.visible = false  # 拉回来了就把上一次的失败提示收掉
	_grid.set_remote(songs, pages, page - 1)
	var uncached: Array = []
	for d in songs:
		var url := String(d.get("cover_url", ""))
		var tex := _api.cover_cached(url)
		if tex != null:
			_grid.apply_cover(url, tex)
		else:
			_api.load_cover(url)
			uncached.append(url)
	_page_load_start(uncached, not songs.is_empty())  # spinner 等全部曲绘+难度，收口见 _maybe_hide_spin
	if not songs.is_empty():
		_on_song_pressed(songs[0])  # 列表到位 = 自动选中首曲，详情列同步
	_update_pager()
	_refresh_tool_active()

func _refresh_tool_active() -> void:
	_b_filter.set_selected(_diff_max < 18.0 or not _has_charts)
	_b_sort.set_selected(_sort_field != "")

# ── 过滤/排序弹窗 ──
func popup_open() -> bool:
	return _popup != null

func close_popup() -> void:
	if _popup == null:
		return
	# 句柄立刻置空（Esc 逐层收/再次点击都不会重复关同一个弹窗），节点交给淡出后自毁
	var p := _popup
	_popup = null
	_popup_panel = null
	_popup_kind = ""
	_sort_pills.clear()
	_dir_pill = null
	_diff_label = null
	_diff_slider = null
	_has_charts_box = null
	UiMotion.fade_out(p, UiTokens.DUR_PAGE_OUT, p.queue_free)

func filter_global_center() -> Vector2:
	return _b_filter.get_global_rect().get_center()

func sort_global_center() -> Vector2:
	return _b_sort.get_global_rect().get_center()

func search_global_center() -> Vector2:
	return _search.get_global_rect().get_center()

func set_diff_max(v: float) -> void:
	_diff_max = clampf(v, 0.0, 18.0)
	_fetch(1)

func set_sort(field: String, desc: bool) -> void:
	_sort_field = field
	_desc = desc
	_fetch(1)

func _toggle_filter_pop() -> void:
	var was := _popup_kind == "filter"
	close_popup()
	if not was:
		_build_popup("filter")

func _toggle_sort_pop() -> void:
	var was := _popup_kind == "sort"
	close_popup()
	if not was:
		_build_popup("sort")

func _build_popup(kind: String) -> void:
	_popup_kind = kind
	_popup = Control.new()
	_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_popup.z_index = 90
	var dim := ColorRect.new()
	_popup_dim = dim
	dim.color = Color(0.0, 0.0, 0.0, 0.5)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(_on_popup_dim)
	_popup.add_child(dim)
	_popup_panel = Panel.new()
	var sb := _frost_sb()
	sb.set_corner_radius_all(UiTokens.R_PANEL)
	sb.set_border_width_all(0)  # 弹窗不要描边（白边）
	_popup_panel.add_theme_stylebox_override("panel", sb)
	_popup.add_child(_popup_panel)
	var vp := get_viewport_rect().size
	var m := vp.y * 0.018
	var w := vp.x * 0.16
	var rh := vp.y * 0.04
	if kind == "filter":
		_popup_panel.size = Vector2(w, rh * 3.0 + m * 2.0)
		_diff_label = _pop_label("难度上限 %d" % int(_diff_max))
		_diff_label.position = Vector2(m, m)
		_diff_label.size = Vector2(w - m * 2.0, rh)
		_diff_slider = HSlider.new()
		_diff_slider.min_value = 0.0
		_diff_slider.max_value = 18.0
		_diff_slider.step = 1.0
		_diff_slider.value = _diff_max
		_diff_slider.position = Vector2(m, m + rh)
		_diff_slider.size = Vector2(w - m * 2.0, rh)
		_diff_slider.value_changed.connect(_on_diff_changed)
		_has_charts_box = CheckBox.new()
		_has_charts_box.text = "只看有谱面"
		_has_charts_box.button_pressed = _has_charts
		_has_charts_box.position = Vector2(m, m + rh * 2.0)
		_has_charts_box.size = Vector2(w - m * 2.0, rh)
		_has_charts_box.toggled.connect(_on_has_charts)
		_popup_panel.add_child(_diff_label)
		_popup_panel.add_child(_diff_slider)
		_popup_panel.add_child(_has_charts_box)
	else:
		_popup_panel.size = Vector2(w, rh * float(SORT_FIELDS.size() + 1) + m * 2.0)
		_sort_pills.clear()
		for i in SORT_FIELDS.size():
			var b := NeoButton.new()
			b.text = String(SORT_FIELDS[i][0])
			b.min_size_hint = Vector2.ZERO
			b.pressed.connect(_on_sort_pick.bind(String(SORT_FIELDS[i][1])))
			_popup_panel.add_child(b)
			b.position = Vector2(m, m + rh * float(i))
			b.size = Vector2(w - m * 2.0, rh * 0.86)
			_sort_pills.append(b)
		_dir_pill = NeoButton.new()
		_dir_pill.text = "降序" if _desc else "升序"
		_dir_pill.min_size_hint = Vector2.ZERO
		_dir_pill.pressed.connect(_on_dir_toggle)
		_popup_panel.add_child(_dir_pill)
		_dir_pill.position = Vector2(m, m + rh * float(SORT_FIELDS.size()))
		_dir_pill.size = Vector2(w - m * 2.0, rh * 0.86)
	_refresh_popup_state.call_deferred()  # 新建 NeoButton 的 _ready（内部结构）晚于本函数
	var anchor := _b_filter if kind == "filter" else _b_sort
	var ps := _popup_panel.size
	_popup_panel.position = Vector2(
		clampf(anchor.position.x + anchor.size.x - ps.x, 8.0, vp.x - ps.x - 8.0),
		maxf(anchor.position.y - ps.y - vp.y * 0.015, vp.y * 0.02))
	add_child(_popup)

func _pop_label(t: String) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text = t
	l.add_theme_color_override("font_color", UiTokens.INK)
	return l

func _on_popup_dim(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.pressed:
		close_popup()

func _on_diff_changed(v: float) -> void:
	_diff_max = v
	if _diff_label != null:
		_diff_label.text = "难度上限 %d" % int(v)
	_search_all = []
	_fetch(1)
	_refresh_tool_active()

func _on_has_charts(on: bool) -> void:
	_has_charts = on
	_search_all = []
	_fetch(1)
	_refresh_tool_active()

func _on_sort_pick(field: String) -> void:
	_sort_field = field
	_fetch(1)
	_refresh_popup_state()
	_refresh_tool_active()

func _on_dir_toggle() -> void:
	_desc = not _desc
	_fetch(1)
	_refresh_popup_state()

func _refresh_popup_state() -> void:
	for i in _sort_pills.size():
		_sort_pills[i].set_selected(String(SORT_FIELDS[i][1]) == _sort_field)
	if _dir_pill != null:
		_dir_pill.set_caption("降序" if _desc else "升序")

func _on_cover(url: String, tex: Texture2D) -> void:
	_grid.apply_cover(url, tex)
	if url == _cur_cover_url:
		_art_cover(tex)
	_load_wait.erase(url)
	_maybe_hide_spin()

# ── 页加载门控：spinner 收到"本页全部曲绘 + 选中曲难度(charts)"都到位为止 ──
var _load_wait := {}        # 在途曲绘 url 集合
var _load_charts := false   # 在途：选中曲的难度列表（/songs/{id}/charts）
var _load_batch := 0        # 批次号：超时兜底只收自己那批的口

func _page_load_start(urls: Array, wants_charts: bool) -> void:
	_load_batch += 1
	var b := _load_batch
	_load_wait.clear()
	for u in urls:
		_load_wait[String(u)] = true
	_load_charts = wants_charts
	_maybe_hide_spin()
	if wants_charts or not _load_wait.is_empty():
		# cover 解码失败/网络黑洞不发信号 → 8s 兜底收口，防 spinner 永挂
		get_tree().create_timer(8.0).timeout.connect(func() -> void:
			if b == _load_batch:
				_load_wait.clear()
				_load_charts = false
				_spinner.hide_spin())

func _maybe_hide_spin() -> void:
	if _load_wait.is_empty() and not _load_charts:
		_spinner.hide_spin()

## ── 试听（循环段=音频里最复杂的那 12 秒；淡入/停止口径参照 osu! 选曲试听与 PT playPreview）──
## 选中就停掉上一条 → 取音频 → 定位到"最复杂的 12 秒"→ 淡入起播 → **只循环这一段**。
## 换歌/离开选曲页淡出收。解码在主线程同步做（整曲 ogg 实测 30~80ms），最近 4 首留缓存。

## 试听旋钮（主观量集中一处）：
## FADE_IN：PT 原来是 5 秒淡入（gainrateToTime:5），实测前两秒基本听不见
##          （dB 线性从 −80 起，1.5s 才 −56dB）——用户 2026-10-29"淡入时间太长了"。
## WINDOW：循环段长度。用户 2026-10-29："还是要有循环" + "预览为什么不试试最密集的12秒片段呢"
##          → 不是整曲循环，是把最复杂的那 12 秒圈起来反复听。
const PREV_FADE_IN := 0.5
const PREV_WINDOW := 12.0
const PREV_FADE_OUT := 0.6
## 换歌时的交叉量：原来传的是 0.0（= 立刻掐），所以"没有淡出"（用户 2026-10-29）。
## 注意这条淡出**不 stop**——同一个 player 马上要被新曲子接管，stop 反而会抢在新曲起播后
## 把新曲掐掉；改成"只把音量拉下去 + 记一个起播截止时间"，新曲等淡出走完再 play。
const PREV_CROSS := 0.12
## 起播点的兜底带：只有音频本身拿不到复杂度时（CBR 的 mp3、曲子比窗口还短）才用它
const PREV_BAND := Vector2(0.25, 0.75)

## "H:MM:SS" / "MM:SS" / "12.5" → 秒
static func _preview_secs(txt: String) -> float:
	var t := txt.strip_edges()
	if t == "":
		return 0.0
	var parts := t.split(":")
	if parts.size() == 3:
		return maxf(float(parts[0]) * 3600.0 + float(parts[1]) * 60.0 + float(parts[2]), 0.0)
	if parts.size() == 2:
		return maxf(float(parts[0]) * 60.0 + float(parts[1]), 0.0)
	return maxf(float(parts[0]), 0.0)

## 起播点（秒）。**不许从 0 起播**——用户 2026-10-29："都是从开头开始播放的"，
## 而 --qaprev 实测本地 44 首里 0 首在 info 里标了 preview_time，等于首首从静音前奏开。
## ① 谱包标了 preview_time → 用作者的点（权威）；
## ② 否则用 dense（= AudioComplexity 从音频字节里算出的"最复杂 12 秒"的起点，用户要的就是这个）；
## ③ 连 dense 都没有（CBR mp3 那种码率恒定的）→ 在时长 [25%,75%] 带里按曲名 hash 取一档，
##    同一首每次听同一段，不同首不挤在同一处。
static func preview_start(declared: float, len: float, seed_txt: String, dense := -1.0) -> float:
	if len <= 1.0:
		return 0.0
	if declared > 0.0:
		return clampf(declared, 0.0, maxf(len - 0.25, 0.0))
	if dense >= 0.0:
		return clampf(dense, 0.0, maxf(len - PREV_WINDOW, 0.0))
	var lo: float = len * PREV_BAND.x
	var hi: float = len * PREV_BAND.y
	var idx := absi(seed_txt.hash()) % 8
	var t: float = lerpf(lo, hi, (float(idx) + 0.5) / 8.0)
	var need: float = minf(PREV_WINDOW, len * 0.5)
	if len - t < need:
		t = maxf(len - need, 0.0)
	return clampf(t, 0.0, maxf(len - 0.25, 0.0))

func _play_preview(d: Dictionary) -> void:
	_prev_job += 1
	var job := _prev_job
	_prev_seed = String(d.get("title", ""))
	_cross_out_prev(PREV_CROSS)
	var dir := String(d.get("local_dir", ""))
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		_play_preview_remote(d, job)
		return
	var im := ChartInfo.read_dir(dir)
	var path := audio_in_dir(dir, im)
	if path == "":
		push_warning("试听跳过：谱包里找不到音频 " + dir)
		return
	var off := _preview_secs(String(im.get("preview_time", "")))
	_start_preview_file(path, off, job)

## 谱包目录里挑那条音频：info 的 song 字段优先，否则按扩展名排序取第一个。
## 抽成静态是给 --qaprev 探针共用——探针要能逐首报"为什么没声"，不能只学播放路径。
static func audio_in_dir(dir: String, im: Dictionary) -> String:
	var song := String(im.get("song", ""))
	if song != "":
		var p0 := dir.path_join(song)
		if FileAccess.file_exists(p0):
			return p0
	var da := DirAccess.open(dir)
	if da == null:
		return ""
	var cands: Array = []
	for f in da.get_files():
		if f.get_extension().to_lower() in AUDIO_EXTS:
			cands.append(f)
	cands.sort()
	if cands.is_empty():
		return ""
	return dir.path_join(String(cands[0]))

## 认哪些扩展名当音频。**必须和 ChartStage.audio_magic 能认的容器一致**，
## 多出来的（m4a/aac/opus）Godot 运行时解不了，扫到了也只是把真音频挤掉。
const AUDIO_EXTS := ["ogg", "mp3", "wav", "flac"]

## 社区谱（还没下到本地）：先把音频拉到 user://cache/preview/，拉完直接播。
## PhiTogether 的 playPreview 也是"拿到整曲再 play"，不流式。
func _play_preview_remote(d: Dictionary, job: int) -> void:
	var url := String(d.get("song_file", ""))
	if url == "":
		# 原来这里静默 return ⇒ "某些音乐无法播放"根本无从查起。清单没给直链就明说，
		# 是数据侧问题还是我们没映射，看这条日志就知道。
		push_warning("试听跳过：这条谱面没有音频直链（%s / %s）" % [
				String(d.get("title", "")), String(d.get("pz_id", String(d.get("pt_id", ""))))])
		return
	if not url.begins_with("http"):
		push_warning("试听跳过：音频直链不是 http（%s）" % url.left(60))
		return
	var ext := url.get_extension().to_lower()
	if ext == "" or ext.length() > 5:
		ext = "ogg"
	var dst := "user://cache/preview/%s.%s" % [url.md5_text(), ext]
	if FileAccess.file_exists(dst):
		_start_preview_file(dst, 0.0, job)
		return
	DirAccess.make_dir_recursive_absolute("user://cache/preview")
	_prev_wait_dest = dst
	_prev_wait_job = job
	_select_api_download_raw(url, dst)

func _select_api_download_raw(url: String, dst: String) -> void:
	_api.download_raw(url, dst)

func _on_prev_raw(dest: String, ok: bool) -> void:
	if dest != _prev_wait_dest:
		return
	_prev_wait_dest = ""
	if ok:
		_start_preview_file(dest, 0.0, _prev_wait_job)
	else:
		push_warning("试听拉取失败：" + dest.get_file())

## 解码 + 算复杂度段 + 播放（主线程；缓存最近 4 首）
func _start_preview_file(path: String, off: float, job: int) -> void:
	_prev_playing_src = path
	# 直接在主线程解码：整曲 ogg 实测 30~80ms（点一下的代价），但省掉"后台线程创建的
	# 资源在退出时释放"那条坑（实测过 WorkerThreadPool 版会 SIGSEGV）。
	var st: AudioStream = _prev_cache.get(path, null)
	if st == null:
		var buf := FileAccess.get_file_as_bytes(path)
		st = ChartStage.stream_from_bytes(buf, path) if not buf.is_empty() else null
		if st != null:
			_prev_cache[path] = st
			# 复杂度曲线和流一起算：同一份字节只读一次；走 Ogg 页表 / MP3 帧头只要几毫秒，
			# 结果和流一起进缓存（同一首反复点不重算）
			_prev_dense[path] = AudioComplexity.best_start(
					buf, ChartStage.audio_magic(buf), st.get_length(), PREV_WINDOW)
			if _prev_cache.size() > 4:
				var k: Variant = _prev_cache.keys()[0]
				_prev_cache.erase(k)
				_prev_dense.erase(k)
	_on_preview_loaded(job, st, off)

## 换歌：把正在播的那条淡出（不 stop），并记下"下一条最早可以起播的时刻"
func _cross_out_prev(f: float) -> void:
	if _prev == null or not _prev.playing or f <= 0.01:
		return
	if _prev_tw != null:
		_prev_tw.kill()
		_prev_tw = null
	if _prev_loop_tw != null:
		_prev_loop_tw.kill()
		_prev_loop_tw = null
	_prev_tw = create_tween()
	_prev_tw.tween_property(_prev, "volume_db", -80.0, f)
	_prev_deadline_ms = Time.get_ticks_msec() + int(f * 1000.0)

func _on_preview_loaded(job: int, st: AudioStream, off: float) -> void:
	if job != _prev_job or st == null or _prev == null:
		return
	var left := float(_prev_deadline_ms - Time.get_ticks_msec()) / 1000.0
	if left > 0.0:
		# 上一条的淡出还没走完：等它。闭包对局部是**按值拷贝**（见 toolchain 笔记），
		# 所以这里把 job/st/off 都当参数绑进来，靠 job 号在真正起播时再校验一次。
		get_tree().create_timer(left).timeout.connect(
				func() -> void: _start_play(job, st, off))
		return
	_start_play(job, st, off)

func _start_play(job: int, st: AudioStream, off: float) -> void:
	if job != _prev_job or st == null or _prev == null:
		return
	_prev.stream = st
	_prev.volume_db = -80.0
	# 起播点 = 音频里最复杂的那一段（44 首本地谱一首都没标 preview_time，照原写法首首从静音前奏开），
	# 并且**只圈这一段循环**：wav 用流自带的采样区间 loop（无缝）；ogg/mp3 没有区间 loop，
	# 靠 _arm_loop 里那条定时器把播放头跳回段首。
	var len_s: float = st.get_length()
	var dd: Dictionary = _prev_dense.get(_prev_playing_src, {})
	var t := preview_start(off, len_s, _prev_seed, float(dd.get("t", -1.0)))
	var seg_end := minf(t + PREV_WINDOW, maxf(len_s - 0.02, t))
	_prev_playing_at = t
	_prev_playing_end = seg_end
	_prev_loop_tw = _arm_loop(st, t, seg_end)
	_prev.play(t)
	var mv := UserPrefs.num("music_vol")
	var target := linear_to_db(mv) if mv > 0.001 else -80.0
	_prev_tw = create_tween()
	_prev_tw.tween_property(_prev, "volume_db", target, PREV_FADE_IN)

## 把"只循环 [t, seg_end]"落到具体的流上；返回 null=流自己能无缝区间循环，不需要我们跳播放头
func _arm_loop(st: AudioStream, t: float, seg_end: float) -> Tween:
	if st is AudioStreamWAV:
		var wv := st as AudioStreamWAV
		wv.loop_mode = AudioStreamWAV.LOOP_FORWARD
		# loop_begin/end 的单位是"帧"（一帧=各声道一个样本），不是字节
		wv.loop_begin = int(t * float(wv.mix_rate))
		wv.loop_end = int(seg_end * float(wv.mix_rate))
		return null
	# ⚠ 4.7 实测：AudioStreamOggVorbis **没有 loop_end**（赋值直接 "Invalid assignment of
	# property or key 'loop_end'"），它只有 loop + loop_offset，语义是"从 offset 循环到文件尾"；
	# AudioStreamMP3 更是只有整曲 loop。所以 ogg/mp3 都靠一条无限重复的 interval+seek
	# 把播放头按回段首——段长是准的，代价是接缝处可能有一丁点可闻的切点。
	if st is AudioStreamOggVorbis:
		(st as AudioStreamOggVorbis).loop = false
	if st is AudioStreamMP3:
		(st as AudioStreamMP3).loop = false
	var tw := create_tween()
	tw.set_loops(0)
	tw.tween_interval(maxf(seg_end - t, 0.5))
	tw.tween_callback(_seek_loop_back.bind(t))
	return tw

## 循环段跳回段首。计数器是给 --qaprev 看的：ogg/mp3 的 get_playback_position() 会不会
## 跟着 seek 走，实测才知道（探针不能靠"位置没涨"就判死）。
func _seek_loop_back(t: float) -> void:
	if _prev == null or not _prev.playing:
		return
	_prev.seek(t)
	_prev_seek_n += 1

func _stop_preview(fade := 0.35) -> void:
	if _prev == null:
		return
	if _prev_tw != null:
		_prev_tw.kill()
		_prev_tw = null
	if _prev_loop_tw != null:
		_prev_loop_tw.kill()  # 段循环的跳表头定时器必须一起停，不然会把下一条歌跳回上一首的段首
		_prev_loop_tw = null
	if not _prev.playing:
		return
	if fade <= 0.01:
		_prev.stop()
		return
	_prev_tw = create_tween()
	_prev_tw.tween_property(_prev, "volume_db", -80.0, fade)
	_prev_tw.tween_callback(_prev.stop)

## 换详情大卡封面：交泵**插队**优先预烘（下一帧就轮它），期间 _draw 扣住不画。
## 点卡片切歌是本页最高频的交互，详情图那张 740×493 首烘实测 ~19ms，
## 不该正好砸在用户刚点下去的那一帧上。泵缺席时保持原惰性烘焙行为不变。
func _art_cover(tex: Texture2D) -> void:
	var changed := tex != null and tex != _art.cover
	_art.set_cover(tex)
	# 整页背景跟着选中的曲子走（默认占位图不换：刚进页什么都没选，底图应保持主菜单那张）
	if tex != null and tex != _default_cover:
		art_changed.emit(tex)
	if changed and bake != null:
		_art.hold_bake(true)
		_art.prewarm_threaded(bake)  # 缩放段在后台线程，主线程只收结果（15–20ms 不再吃掉两帧）

func _on_song_pressed(d: Dictionary) -> void:
	_sel_song = d
	if _dl_waiting:
		_dl_waiting = false
		_b_play.set_progress(-1.0)
	_play_preview(d)
	_update_detail(d)
	_sync_play()
	if _laid:
		_layout()  # 换选中谱 → 评级/分数/Acc 行重测重摆（_layout 内 _sync_stats 拉记录）
	_cur_cover_url = String(d.get("cover_url", ""))
	if String(d.get("local_dir", "")) != "":
		var li := Image.new()
		var lp := String(d.get("local_cover", ""))
		var err := li.load(lp)
		if err == OK:
			_art_cover(SongCard.make_from_image(li))
		_refresh_side()
		return
	if _cur_cover_url != "":
		var tex := _api.cover_cached(_cur_cover_url)
		if tex != null:
			_art_cover(tex)
		else:
			_api.load_cover(_cur_cover_url)
	var pid := String(d.get("pz_id", ""))
	if pid != "" and (_remote or _fav_mode):
		_cur_pz = pid
		_api.load_charts(pid)  # 只有 /songs/{id}/charts 返回各难度 file 直链
	_refresh_side()

func _on_charts(song_id: String, charts: Array) -> void:
	if song_id != _cur_pz or charts.is_empty():
		return
	_set_charts(charts)  # 全量难度：一行最多 4 个，超出排第二行
	_sync_play()
	if _laid:
		_layout()
	_load_charts = false
	_maybe_hide_spin()

func _lbl(caption: String, col: Color) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = true  # 百分比布局下文字必须锁在条内，越界即裁
	l.text = caption
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", col)
	add_child(l)
	return l

## 磨砂条：样式盒由调用方先建好传入（_layout 里改半径要持有引用）
func _frost_sb() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiTokens.SURFACE_PANEL
	sb.set_corner_radius_all(UiTokens.R_BUTTON)
	sb.set_border_width_all(1)
	sb.border_color = UiTokens.BORDER_FAINT
	return sb

func _panel(sb: StyleBoxFlat) -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", sb)
	add_child(p)
	return p

## 边缘渐隐条：bg(0)→全透明线性渐变，与页面底色无缝
func _fade(top: bool) -> TextureRect:
	var g := Gradient.new()
	var solid := UiTokens.bg(0)
	var clear := solid
	clear.a = 0.0
	g.colors = [solid, clear] if top else [clear, solid]
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_LINEAR
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	tex.width = 2
	tex.height = 96
	var tr := TextureRect.new()
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture = tex
	add_child(tr)
	return tr

func _update_detail(d: Dictionary) -> void:
	var charts: Array = []
	for c in _charts_of(d):
		var cd: Dictionary = (c as Dictionary).duplicate()
		if String(cd.get("designer", "")) == "":
			cd["designer"] = String(d.get("designer", ""))
		charts.append(cd)
	if charts.is_empty() and String(d.get("code", "")) != "":
		charts = [d]  # 远端列表徽章：谱面详情未回前先占位
	_set_charts(charts)
	if _laid:
		_layout()  # 换曲后重排：胶囊宽度要按新文案实测

## 难度胶囊池：可点选（粉框=选中）；选中难度的谱师单独第三行、只显示一个
func _set_charts(charts: Array) -> void:
	_cur_charts = charts
	_chip_sel = maxi(charts.size() - 1, 0)  # 默认最高难度
	for n in _chip_p + _chip_l:
		(n as Node).queue_free()
	_chip_p.clear()
	_chip_sb.clear()
	_chip_l.clear()
	_chip_tiers.clear()
	for i in charts.size():
		var cd := charts[i] as Dictionary
		var code := String(cd.get("code", ""))
		var lvl := int(cd.get("level", 0))
		# 与曲库卡片左下角那排纯色胶囊同一套口径（用户 2026-10-28："选择难度也跟胶囊颜色一致"）
		var tier := UiTokens.tier_pill_color(code, lvl)
		var sb := StyleBoxFlat.new()
		sb.set_border_width_all(1)
		sb.border_color = UiTokens.BORDER_FAINT
		var p := Panel.new()
		p.mouse_filter = Control.MOUSE_FILTER_STOP
		p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		p.add_theme_stylebox_override("panel", sb)
		p.gui_input.connect(_on_chip_gui.bind(i))
		add_child(p)
		_chip_p.append(p)
		_chip_sb.append(sb)
		_chip_tiers.append(tier)
		_chip_l.append(_lbl(code if lvl <= 0 else "%s %d" % [code, lvl], tier))
	_refresh_chips()
	# 换曲/换难度=胶囊整批重建：逐颗浮现（面板与其文字成对，读起来是一颗一颗）
	var items: Array = []
	for i in _chip_p.size():
		items.append(_chip_p[i])
		items.append(_chip_l[i])
	UiMotion.cascade(items, 0.16, 0.028, 0.0, -1.0)

func _on_chip_gui(ev: InputEvent, i: int) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		_chip_sel = i
		_refresh_chips()
		_sync_play()
		# 本地一张卡多难度：收藏键/记录键都跟着难度走，切胶囊必须重刷侧钮
		_refresh_side()
		_sync_stats()
		if _laid:
			_layout()  # 换难度胶囊=换谱面：评级行跟着重刷（含 _layout_diffs）

func _refresh_chips() -> void:
	for i in _chip_sb.size():
		var on := i == _chip_sel
		var tier: Color = _chip_tiers[i]
		var sb := _chip_sb[i]
		sb.bg_color = Color(tier.r, tier.g, tier.b, 0.5)
		# 未选中不留那圈 1px 细边；选中才给白色内环（与按钮同一口径）
		sb.set_border_width_all(maxi(int(UiTokens.ring_w(get_viewport_rect().size.y)), 1) if on else 0)
		sb.border_color = UiTokens.RING_ON
	_chip_name.text = ""
	if not _cur_charts.is_empty():
		_chip_name.text = String((_cur_charts[_chip_sel] as Dictionary).get("designer", ""))

## 胶囊排布：一行最多 4 个、放不下换第二行；选中难度的谱师在第三行；整块居中
func _layout_diffs(vp: Vector2) -> void:
	var h := vp.y * CHIP_H
	var f := ThemeDB.fallback_font
	var pfs := int(h * 0.52)
	var nfs := int(h * 0.44)
	var pgap := vp.y * 0.02
	var rows: Array = []
	var cur: Array = []
	var rw := 0.0
	for i in _chip_p.size():
		_chip_l[i].add_theme_font_size_override("font_size", pfs)
		var tw: float = f.get_string_size(_chip_l[i].text, HORIZONTAL_ALIGNMENT_LEFT, -1, pfs).x
		var w: float = tw + h * 1.2
		if cur.size() >= 4 or (not cur.is_empty() and rw + pgap + w > _diffs_rect.size.x):
			rows.append(cur)
			cur = []
			rw = 0.0
		cur.append({"i": i, "w": w})
		rw += w + pgap
	if not cur.is_empty():
		rows.append(cur)
	var vgap := vp.y * 0.01
	var total_h: float = float(rows.size()) * (h + vgap) + h  # 末行 vgap 兼作谱师行距
	var y0 := _diffs_rect.position.y + (_diffs_rect.size.y - total_h) * 0.5
	for r in rows.size():
		var row: Array = rows[r]
		var row_w := pgap * float(row.size() - 1)
		for e in row:
			row_w += e["w"]
		var x := _diffs_rect.position.x + (_diffs_rect.size.x - row_w) * 0.5
		var yy: float = y0 + float(r) * (h + vgap)
		for e in row:
			var i: int = e["i"]
			_chip_p[i].position = Vector2(x, yy)
			_chip_p[i].size = Vector2(e["w"], h)
			_round(_chip_sb[i], int(h * 0.5))
			_place_label(_chip_l[i], Rect2(x, yy, e["w"], h), pfs)
			x += e["w"] + pgap
	_place_label(_chip_name, Rect2(_diffs_rect.position.x,
		y0 + float(rows.size()) * (h + vgap), _diffs_rect.size.x, h), nfs)

func _on_art_gui(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click:
		if _zoom == null:
			_open_zoom()
		else:
			close_zoom()

func _open_zoom() -> void:
	_zoom = Control.new()
	_zoom.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_zoom.z_index = 120  # 盖过 HUD(z 50)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.86)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_zoom.add_child(dim)
	_zoom_card = SongCard.new()
	_zoom_card.cover = _art.cover
	_zoom_card.mask_ratio = 0.0
	_zoom_card.fit_to_viewport = false
	_zoom_card.keep_bright = true
	_zoom.add_child(_zoom_card)
	dim.gui_input.connect(_on_zoom_click)
	_zoom_card.gui_input.connect(_on_zoom_click)
	add_child(_zoom)
	_layout_zoom()
	if bake != null:
		# 放大层这张 740×493 的缩放段 ~16ms：丢后台线程，本层从 alpha 0 起淡入正好盖住
		_zoom_card.hold_bake(true)
		_zoom_card.prewarm_threaded(bake)
	# 共享元素转场：从曲绘那块位置放大到全屏（起始缩放=曲绘/放大层尺寸比，
	# 支点落在曲绘中心对应的本地点），dim 同时淡入——眼睛能跟上"同一张图变大"，
	# 而不是凭空出现一张全屏图
	var ag := _art.get_global_rect()
	var cs := _zoom_card.size
	_zoom_from = Vector2(maxf(ag.size.x, 1.0) / maxf(cs.x, 1.0), maxf(ag.size.y, 1.0) / maxf(cs.y, 1.0))
	_zoom_card.pivot_offset = ag.get_center() - _zoom_card.global_position
	_zoom_card.scale = _zoom_from
	UiMotion.fade_in(_zoom, 0.14)
	UiMotion.to_scale(_zoom_card, Vector2.ONE, 0.24)

func _on_zoom_click(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		close_zoom()

func _layout_zoom() -> void:
	var vp := get_viewport_rect().size
	var box := Vector2(vp.x * 0.82, vp.y * 0.82)
	var aspect := SongCard.aspect_for_window(get_window().size)
	var cw: float = minf(box.x, box.y * aspect)
	var ch := cw / aspect
	_zoom_card.max_size_hint = Vector2(cw, ch)
	_zoom_card.update_minimum_size()
	_zoom_card.position = (vp - Vector2(cw, ch)) * 0.5
	_zoom_card.size = Vector2(cw, ch)

func _layout() -> void:
	var vp := get_viewport_rect().size
	# 层摆位：条纹=16%→70% 曲库带，暗底=70%→100% 详情带；交错周期=屏高 5%
	_stripe.position = Vector2(vp.x * SEG_NAV, 0)
	_stripe.size = Vector2(vp.x * (SEG_LIBRARY - SEG_NAV), vp.y)
	_stripe.material.set_shader_parameter("band_px", vp.y * 0.05)
	_right_tint.position = Vector2(vp.x * SEG_LIBRARY, 0)
	_right_tint.size = Vector2(vp.x * (1.0 - SEG_LIBRARY), vp.y)
	_place(_b_back, Rect2(vp.x * BACK_RECT.position.x, vp.y * BACK_RECT.position.y,
		vp.x * BACK_RECT.size.x, vp.y * BACK_RECT.size.y))
	var row_h := vp.y * NAV_ROW_H
	var y := vp.y * NAV_Y0
	for b in [_b_local, _b_fav, _b_pz, _b_pt]:
		_place(b, Rect2(vp.x * NAV_X0, y, vp.x * (NAV_X1 - NAV_X0), row_h))
		y += row_h + vp.y * NAV_GAP
	# 曲库网格：16%→70% 带内，垂直滚动
	var pad := vp.x * LIB_PAD
	var lib_x := vp.x * SEG_NAV + pad
	var lib_w: float = vp.x * (SEG_LIBRARY - SEG_NAV) - pad * 2.0
	# 工具条：右端 过滤/排序 圆钮，搜索药丸吃余宽；网格上下留白防遮挡
	var th := vp.y * TOOL_H
	var ty := vp.y * TOOL_Y
	var tg := vp.x * 0.008
	# 圆钮从右往左排：导入（仅本地页）/排序/过滤；钮间与搜索右端各留一个 tg 空隙
	var slots: Array = []
	if _b_load.visible:
		slots = [_b_load, _b_sort, _b_filter]
	else:
		slots = [_b_sort, _b_filter]
	var k := 0.0
	for b in slots:
		k += 1.0
		_place(b, Rect2(lib_x + lib_w - th * k - tg * (k - 1.0), ty, th, th))
	_search.position = Vector2(lib_x, ty)
	_search.size = Vector2(lib_w - th * k - tg * k, th)
	# 搜索药丸同理：corner_radius_all(999) 在 StyleBoxFlat 上是"半高的硬边圆"
	var _ssb := PillStyle.stylebox(th, th * 0.5, UiTokens.SURFACE_PANEL)
	_ssb.content_margin_left = 24.0
	_ssb.content_margin_right = 24.0
	for _state in ["normal", "focus", "read_only"]:
		_search.add_theme_stylebox_override(_state, _ssb)
	_search.add_theme_font_size_override("font_size", int(th * 0.42))
	var grid_top: float = ty + th + vp.y * 0.02
	_grid_scroll.position = Vector2(lib_x, 0)
	_grid_scroll.size = Vector2(lib_w, vp.y)
	# 空白=内容内边距：卡片仍会滚到工具条/翻页器底下，由渐隐条收尾
	_grid_margin.add_theme_constant_override("margin_top", int(grid_top))
	_grid_margin.add_theme_constant_override("margin_bottom", int(vp.y * GRID_BOT))
	# 上下渐隐条盖的是**整条曲库带**——跟斜纹层 _stripe 同一段（SEG_NAV→SEG_LIBRARY）。
	# 先按 lib_x/lib_w 收窄过一次整屏，但那两个量还各自扣了一道 pad，于是带子左右
	# 各留一条不糊的空隙（用户 2026-10-28："左右两边还有一点空隙"）。
	var fade_x := vp.x * SEG_NAV
	var fade_w: float = vp.x * (SEG_LIBRARY - SEG_NAV)
	_fade_t.position = Vector2(fade_x, 0)
	_fade_t.size = Vector2(fade_w, grid_top)
	_fade_b.position = Vector2(fade_x, vp.y * (1.0 - GRID_BOT))
	_fade_b.size = Vector2(fade_w, vp.y * GRID_BOT)
	# 滚动指示：竖条通屏（允许进安全区），4% 切口菱形+3% 内菱形只在 10%~90% 行程
	for s in [_spark, _spark2]:
		s.position = Vector2.ZERO
		s.size = vp
		s.rail_x = vp.x * (SEG_LIBRARY if s == _spark else SEG_NAV)
		s.rail_top = 0.0
		s.rail_h = vp.y
		s.zone_top = vp.y * 0.10
		s.zone_h = vp.y * 0.80
		s.bar_w = vp.x * 0.01
		s.cut_w = vp.x * 0.04
		s.dia_w = vp.x * 0.03
		s.queue_redraw()
	_update_stripe_progress()
	_grid.custom_width = lib_w
	_grid.relayout()
	# 翻页器：91.5%→98.5% 屏高胶囊（宽 10% 屏宽）居中曲库带，两侧隔 1% 屏宽圆形钮
	var pg_h := vp.y * 0.07
	var pg_y := vp.y * 0.915
	var pg_w := vp.x * 0.10
	var cx: float = lib_x + lib_w * 0.5
	_pager.position = Vector2(cx - pg_w * 0.5, pg_y)
	_pager.size = Vector2(pg_w, pg_h)
	# 胶囊底改用 PillStyle：StyleBoxFlat 的圆角是硬边，两端全是台阶
	# （用户 2026-10-28："曲库下面的输入框还有毛刺"）。半径沿用原来 _round 给的"半高=正胶囊"，
	# 那一行已经删掉（_round 只吃 StyleBoxFlat）。高度只有这里知道，所以随布局重建。
	# 描边给 0：那圈 1px 细边和按钮上的一样会被看见（用户 2026-10-28："还有细边框"）
	_pager_sb = PillStyle.stylebox(pg_h, pg_h * 0.5, UiTokens.SURFACE_PANEL)
	_pager.add_theme_stylebox_override("panel", _pager_sb)
	var _jump_sb := PillStyle.stylebox(pg_h, pg_h * 0.5, Color(0, 0, 0, 0))
	for _st in ["normal", "focus", "read_only"]:
		_jump_edit.add_theme_stylebox_override(_st, _jump_sb)
	_place_label(_pager_l, Rect2(_pager.position, _pager.size),
		_fit_fs(_pager_l.text, pg_w * 0.8, int(pg_h * 0.42)))
	_jump_edit.position = _pager.position
	_jump_edit.size = _pager.size
	_jump_edit.add_theme_font_size_override("font_size", int(pg_h * 0.4))
	var gx := vp.x * 0.01
	_place(_pg_l, Rect2(cx - pg_w * 0.5 - gx - pg_h, pg_y, pg_h, pg_h))
	_place(_pg_r, Rect2(cx + pg_w * 0.5 + gx, pg_y, pg_h, pg_h))
	# ── 右侧详情列 ── 70%→100% 带
	var band_x := vp.x * SEG_LIBRARY + pad
	var band_w: float = vp.x * (1.0 - SEG_LIBRARY) - pad * 2.0
	var art_h := vp.y * ART_H
	# 头像下沿让位：AV_TOP_M 现在是**屏宽**占比（Cytoid 口径），直径仍是屏高占比
	var art_y := vp.x * PlayerHud.AV_TOP_M \
			+ vp.y * (PlayerHud.AV_D * PlayerHud.SELECT_SCALE + ART_TOP_GAP)
	# 曲绘占满详情带；三个小方块叠在曲绘右缘内侧（25/3 按曲绘高）
	var col_w := art_h * SIDE_BTN_W
	var sg := art_h * SIDE_BTN_GAP
	var art_w: float = band_w
	_art.max_size_hint = Vector2(art_w, art_h)
	_art.update_minimum_size()
	_art.position = Vector2(band_x, art_y)
	_art.size = Vector2(art_w, art_h)
	var sy := art_y + (art_h - (col_w * 3.0 + sg * 2.0)) * 0.5
	for b in [_sb_del, _sb_fav_side, _sb_cfg]:
		_place(b, Rect2(band_x + band_w - sg - col_w, sy, col_w, col_w))
		sy += col_w + sg
	# 评级带（20%）：方盒=带高（Rank 切片已按墨迹裁方，徽章撑满盒、不再空）；
	# 分数/Acc 用游戏内 HUD 同字号（设计系 1350×900 的 46/22、行距 45，见 chart_stage._build_hud），
	# 右对齐到带右缘、整组垂直居中——宽屏下右侧不留大空隙
	var band_h := vp.y * ROW_STATS_H
	_sync_stats()
	var f := ThemeDB.fallback_font
	var band_top := art_y + art_h + vp.y * ROW_GAP
	var fs_score := int(vp.y * 46.0 / 900.0)
	var fs_acc := int(vp.y * 22.0 / 900.0)
	var pitch := vp.y * 45.0 / 900.0
	var pas_a: float = f.get_ascent(fs_acc) + f.get_descent(fs_acc)
	var stack_h: float = pitch + pas_a
	var box_side := band_h * 0.96
	var box_top := band_top + (band_h - box_side) * 0.5
	if _rank_img.visible:
		_rank_img.position = Vector2(band_x, box_top)
		_rank_img.size = Vector2(box_side, box_side)
	else:
		var nfs := _fit_fs("NEW", box_side * 0.9, int(box_side * 0.6))
		var npas: float = f.get_ascent(nfs) + f.get_descent(nfs)
		_place_label(_phi, Rect2(band_x, box_top + (box_side - npas) * 0.5, box_side, npas), nfs)
	var baseline := band_top + band_h  # 下方难度胶囊区起点对齐带底
	var col_x: float = band_x + box_side + band_h * 0.06
	var rest: float = band_x + band_w - col_x
	# 宽度兜底：极窄面板/超长分数时按列宽降字号（正常情况下就是 46/22）
	var fs2: int = mini(fs_score, _fit_fs(_stats_l.text, rest, fs_score))
	var fa2: int = mini(fs_acc, _fit_fs(_stats_r.text, rest, fs_acc))
	var pas2: float = f.get_ascent(fs2) + f.get_descent(fs2)
	var pa2: float = f.get_ascent(fa2) + f.get_descent(fa2)
	var stack_top := band_top + (band_h - stack_h) * 0.5
	# 右对齐：矩形铺满文字列，Label 自身 RIGHT 对齐（sw/aw 不再参与摆位）
	_place_label(_stats_l, Rect2(col_x, stack_top + (pitch - pas2) * 0.5, rest, pas2), fs2)
	_place_label(_stats_r, Rect2(col_x, stack_top + pitch + (pas_a - pa2) * 0.5, rest, pa2), fa2)
	# 难度胶囊区：分数底 +3% 起，到开始游戏顶（留 3%，与谱师名紧贴）为止，整块居中
	var play_h := vp.y * ROW_PLAY_H
	var play_y: float = vp.y * 0.97 - play_h  # 离地 3%，与返回顶边 3% 中心对称
	_diffs_rect = Rect2(band_x, baseline + vp.y * ROW_GAP, band_w,
		play_y - (baseline + vp.y * ROW_GAP))
	_layout_diffs(vp)
	# 开始游戏：矩形与字号规则的唯一定义在 play_btn_rect / NeoButton.fit_font（结算页共用）
	_place(_b_play, play_btn_rect(vp))
	# 加载 spinner：曲库带（16%→70%W）水平居中，垂直取卡区中部
	var sp_side := clampf(vp.y * 0.09, 56.0, 110.0)
	_spinner.position = Vector2(vp.x * SEG_NAV + (vp.x * (SEG_LIBRARY - SEG_NAV) - sp_side) * 0.5,
			vp.y * 0.52 - sp_side * 0.5)
	_spinner.size = Vector2(sp_side, sp_side)
	# 网络失败提示：卡带底部一条横幅（卡区到 84%H 为止，翻页器 90%→97%）。
	# 宽度给**标签**当 custom_minimum_size，autowrap 才有确定宽度可量；面板再 reset_size()
	# 按内容自取高度。直接写面板 size 会让标签拿到 0 高、文字整条被裁掉（46 截图实证）。
	var hw: float = vp.x * (SEG_LIBRARY - SEG_NAV) * 0.92
	var nfs := maxi(int(vp.y * 0.024), 13)
	_net_hint.add_theme_font_size_override("font_size", nfs)
	_net_hint.custom_minimum_size = Vector2(maxf(hw - 28.0, 40.0), 0)
	_net_panel.reset_size()
	_net_panel.position = Vector2(vp.x * SEG_NAV + (vp.x * (SEG_LIBRARY - SEG_NAV) - _net_panel.size.x) * 0.5,
			vp.y * 0.845)
	if _zoom != null:
		_layout_zoom()
	_laid = true

func _round(sb: StyleBoxFlat, r: int) -> void:
	sb.set_corner_radius_all(r)

func _place(b: NeoButton, rect: Rect2) -> void:
	b.position = rect.position
	b.size = rect.size
	b._sync_icon()  # 直调兜底：本页面手动改 size，不依赖 resized 信号
	b.fit_font()    # 字号双约束（高 42% / 按字数摊宽 92%）在 NeoButton 里，结算页共用同一规则

func _place_label(l: Label, rect: Rect2, fs: int) -> void:
	l.position = rect.position
	l.size = rect.size
	l.add_theme_font_size_override("font_size", maxi(fs, 8))

## 实测文本宽：从 max_fs 逐级降到塞进 max_w（下限 8px）
func _fit_fs(t: String, max_w: float, max_fs: int) -> int:
	var f := ThemeDB.fallback_font
	var fs := max_fs
	while fs > 8 and f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
		fs -= 1
	return fs

## 按行高（ascent+descent）限字号：评级墨迹必须收进 20% 方盒，否则会挤爆下面的行
func _fit_fs_h(t: String, max_h: float, max_fs: int) -> int:
	var f := ThemeDB.fallback_font
	var fs := max_fs
	while fs > 8 and f.get_ascent(fs) + f.get_descent(fs) > max_h:
		fs -= 1
	return fs
