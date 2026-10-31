class_name SongGrid
extends GridContainer
## 曲库网格：默认 ≥16:9 → 4列×8=32，否则 3列×10=30；force_cols 可固定列数。
## 内置 mock 曲目数据（真实曲库接入前）；点击卡片 = 单选，发出 song_selected(data)。
## 拖窗口用 150ms 防抖，避免拖动过程中反复重建/重烘。

const SIDE_MARGIN := 96.0  # 与测试台页面左右 margin 对齐
const TOTAL := 90  # mock 曲库总量：3 列×10/页 = 3 页

const NAMES := ["Neon Circuit", "Afterglow Flux", "Iridescent", "Pulse Driver", "Yuki No Ato", "Fracture Point", "Solaris", "Kansen Line", "Lumen", "After the Rain"]

@export var gap: float = 14.0
## 网格间距的唯一权威值（皮肤页等外挂网格必须引用这个，别自己写 14 也别用屏宽比例——
## 两处各写一份就会"皮肤页卡片布局和选曲页对不上"，2026-10-31 用户抓过）。
const GAP_DEFAULT := 14.0
@export var cover: Texture2D
@export var custom_width: float = 0.0  # >0 时列宽按此可用宽计算（嵌入分栏页面用），否则全屏减 margin
@export var force_cols: int = 0  # >0 时固定列数（如选曲页恒 3 列），忽略窗口比例规则

signal song_selected(data)
signal page_changed(page: int, pages: int)

var _cards: Array[SongCard] = []
## 首烘摊平泵（game.gd 建、经 SongSelect 传下来；add_child 前赋值）。
## 不挂在自己名下：Container 的孩子会参与网格布局，多个 Node 就打乱 3 列。
var bake: BakePump
var _debouncing := false
var _sel := 0
var page := 0
var remote: Array = []  # 非空 = 服务端数据（PhiZone，一页即一批，j 直接索引）
var remote_pages := 1
var remote_full := false   # true = remote 是全量列表，按 remote_per 切片（本地库）
var remote_per := 30
var external_mode := false  # set_remote 过即外部数据源：空列表=真空曲库，不回退 mock
## 查"这张卡有哪几档难度"的注入函数（入参=条目字典，返回 [{"code","level"},…]）。
## 本地曲库的难度条目存在 song_select 的侧表里（写回条目会造成自引用），所以由外面给。
var tiers_lookup: Callable = Callable()
const ARTISTS := ["A. Nakase", "B-Lazy", "Cyanotype", "Drexel", "Ember Field", "Fathom", "Gale", "Halcyon", "Ives", "Juno K."]
const CODES := ["EZ", "HD", "IN", "AT"]
const BASE_LEVEL := [5, 9, 12, 14]

static func _cols_for(ws: Vector2) -> int:
	return 4 if ws.x / maxf(ws.y, 1.0) >= 16.0 / 9.0 else 3

func _rows() -> int:
	return 8 if columns == 4 else 10

func debug_info() -> String:
	return "网格 %d列×%d行=%d张" % [columns, _rows(), _cards.size()]

static func diffs_for(i: int) -> Array:
	var out := [
		{"code": "EZ", "level": 5 + i % 3},
		{"code": "HD", "level": 9 + i % 3},
		{"code": "IN", "level": 12 + i % 3},
	]
	if i % 4 == 3:
		out.append({"code": "AT", "level": 14 + i % 3})
	return out

static func song_data(i: int) -> Dictionary:
	var ci := (i * 3 + i / 10) % 4
	return {
		"title": NAMES[i % NAMES.size()],
		"artist": ARTISTS[i % ARTISTS.size()],
		"code": CODES[ci],
		"level": BASE_LEVEL[ci] + i % 3,
		"bpm": 128 + (i * 11) % 90,
		"notes": 480 + (i * 137) % 900,
		"designer": "PT-%03d" % (i + 1),
		"diffs": diffs_for(i),
	}

func card_at(i: int) -> SongCard:
	if i >= 0 and i < _cards.size():
		return _cards[i]
	return null

## 这张卡该画几颗胶囊：注入表 → 条目自带 diffs → 至少画当前徽章那一档（不留空）。
func _tiers_of(d: Dictionary) -> Array:
	var arr: Array = []
	if tiers_lookup.is_valid():
		arr = tiers_lookup.call(d) as Array
	if arr.is_empty():
		arr = d.get("diffs", []) as Array
	if arr.is_empty():
		var code := String(d.get("code", ""))
		if code == "":
			return []
		return [{"code": code, "level": int(d.get("level", 0))}]
	# 顺序按难度升序：简单的在左、难的在右（远端接口给的顺序是 API 原样，会乱排）
	var out: Array = arr.duplicate()
	out.sort_custom(SongSelect._diff_rank_cmp)
	return out

func _ready() -> void:
	add_theme_constant_override("h_separation", int(gap))
	add_theme_constant_override("v_separation", int(gap))
	get_window().size_changed.connect(_on_window_resized)
	relayout()

func _on_window_resized() -> void:
	if _debouncing:
		return
	_debouncing = true
	var timer := get_tree().create_timer(0.15)
	timer.timeout.connect(_debounced_relayout)

func _debounced_relayout() -> void:
	_debouncing = false
	relayout()

func relayout() -> void:
	var ws := get_window().size
	var cols := force_cols if force_cols > 0 else _cols_for(Vector2(ws.x, ws.y))
	var count := cols * (8 if cols == 4 else 10)
	columns = cols
	while _cards.size() > count:
		var extra: SongCard = _cards.pop_back()  # pop_back 返回 Variant，必须显式标注
		remove_child(extra)
		extra.queue_free()
	while _cards.size() < count:
		var j := _cards.size()
		var card := SongCard.new()
		if cover != null:
			card.cover = cover
		add_child(card)
		card.card_pressed.connect(_on_card_pressed.bind(j))
		_cards.append(card)
	page = clampi(page, 0, page_count() - 1)
	for j in _cards.size():
		var d := _data_at(j)
		var card := _cards[j]
		# 末页不足一屏：按实际数量显示，多余的卡隐藏而不是复制填充
		card.visible = not d.is_empty()
		if d.is_empty():
			continue
		card.song_title = d["title"]
		card.song_artist = d["artist"]
		card.diff_code = d["code"]
		card.diff_level = d["level"]
		card.tiers = _tiers_of(d)
		card.bpm = d["bpm"]
		card.set_selected(page * count + j == _sel, true)  # 整批重建=瞬时落位，不与页面级联抢 alpha
		card.queue_redraw()
	_sync_covers()   # 换页/换批：每张卡按当前数据重贴封面（没有的退回占位图）
	var avail_w: float = custom_width if custom_width > 0.0 else get_viewport_rect().size.x - SIDE_MARGIN
	var cell_w: float = maxf((avail_w - gap * float(cols - 1)) / float(cols), 40.0)
	var cell_h: float = cell_w / SongCard.aspect_for_window(Vector2(ws.x, ws.y))
	for card in _cards:
		card.fit_to_viewport = false
		card.max_size_hint = Vector2(cell_w, cell_h)
		card.update_minimum_size()
	update_minimum_size()

## 只回填文案/徽章（元数据冷解析完成时用）：不重建、不改尺寸、不重放波浪。
## only_dir 非空时只刷那一个目录的卡——每次回填都全量 redraw 会自己造出一帧卡顿
func refresh_data(only_dir: String = "") -> void:
	var count := _cards.size()
	for j in count:
		var d := _data_at(j)
		if d.is_empty():
			continue
		if only_dir != "" and String(d.get("local_dir", "")) != only_dir:
			continue
		var card := _cards[j]
		card.song_title = String(d.get("title", ""))
		card.song_artist = String(d.get("artist", ""))
		card.diff_code = String(d.get("code", ""))
		card.diff_level = int(d.get("level", 0))
		card.tiers = _tiers_of(d)
		card.bpm = int(d.get("bpm", 0))
		card.queue_redraw()

func _on_card_pressed(j: int) -> void:
	var idx := page * _cards.size() + j
	_sel = idx
	for k in _cards.size():
		_cards[k].set_selected(page * _cards.size() + k == _sel)
	song_selected.emit(_data_at(j))

func page_count() -> int:
	if external_mode:
		return remote_pages
	return maxi(ceili(float(TOTAL) / float(maxi(_cards.size(), 1))), 1)

func set_remote(list: Array, pages: int, page_idx: int) -> void:
	external_mode = true
	remote_full = false
	remote = list
	remote_pages = maxi(pages, 1)
	page = clampi(page_idx, 0, remote_pages - 1)
	relayout()
	reveal_cascade()

## 全量列表 + 客户端分页（本地曲库：一次给出全部，翻页只换切片）。
## 与 set_remote 的区别：remote 存全量、_data_at 按 page*per 取。
func set_remote_full(list: Array, per: int = 30) -> void:
	external_mode = true
	remote_full = true
	remote_per = maxi(per, 1)
	remote = list
	remote_pages = maxi(ceili(float(list.size()) / float(remote_per)), 1)
	page = 0
	relayout()
	reveal_cascade()

## 曲库"逐渐显示"：按网格序逐张淡入（30 张 × 0.012s ≈ 0.36s 波浪）。
## 只在内容真正换批时放（set_remote / set_page），拖窗口触发的 relayout 绝不重放。
## 同时把首烘交给泵按帧摊开：波浪刚开始的那一刻正是眼睛最亮的时候，
## 21 张 ×9ms 挤在一帧=190ms 的"卡一下"，实测就是这么来的。
func reveal_cascade(step: float = UiTokens.STEP_CARD, dur: float = UiTokens.DUR_ITEM,
		delay: float = 0.0) -> void:
	var vis: Array = []
	var jobs: Array = []
	for c in _cards:
		if c.visible:
			vis.append(c)
			jobs.append(c.prewarm_bake)
	UiMotion.cascade(vis, dur, step, delay, -1.0)  # 纯淡入：整屏卡片同时缩放会读成"抖"
	# 有泵才扣住 _draw：泵会一帧一张放开并烘焙；没泵就维持原来的惰性烘焙，行为不变
	if bake != null:
		for vc in vis:
			(vc as SongCard).hold_bake(true)
		bake.flush(jobs)

## 已解码的封面按 url 缓存：**这一页没显示也要留着**。
## 以前只回填"当前页里 url 对得上的卡"，别的页的图解码完就被丢掉；翻过去时又没人重新贴，
## 卡片就停在上一页的图上（用户："翻到第二页图片还是第一面的"）。
var _covers := {}
var _blank_cover: Texture2D = null

func _blank() -> Texture2D:
	if _blank_cover == null:
		_blank_cover = SongCard.load_cover("res://assets/covers/cover_01.png")
	return _blank_cover

func apply_cover(url: String, tex: Texture2D) -> void:
	if url == "" or tex == null:
		return
	_covers[url] = tex
	for j in _cards.size():
		if String(_data_at(j).get("cover_url", "")) == url:
			_cards[j].set_cover(tex)

## 按**当前页的数据**把每张卡的封面重贴一遍：有缓存的直接用，没有的退回占位图。
## 放在 relayout 末尾（换页/换数据都会走它），所以翻页不可能再显示上一页的图。
func _sync_covers() -> void:
	for j in _cards.size():
		var card: SongCard = _cards[j]
		if card == null or not card.visible:
			continue
		var d := _data_at(j)
		var url := String(d.get("cover_url", "")) if not d.is_empty() else ""
		var tex: Texture2D = _covers.get(url, null) if url != "" else null
		if tex != null:
			card.set_cover(tex)
		else:
			card.reset_cover(_blank())

func _data_at(j: int) -> Dictionary:
	if external_mode:
		var idx := page * remote_per + j if remote_full else j
		if idx >= 0 and idx < remote.size():
			return remote[idx]
		return {}
	return song_data(page * _cards.size() + j)

func set_page(p: int) -> void:
	var np := clampi(p, 0, page_count() - 1)
	if np == page:
		return
	page = np
	relayout()
	reveal_cascade()  # 换页=换一批内容，同样放一次波浪
	page_changed.emit(page, page_count())
