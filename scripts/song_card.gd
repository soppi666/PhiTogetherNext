class_name SongCard
extends Control
## 曲目卡片：屏幕比 ≥16:9 → 16:9 卡片，<16:9 → 3:2 卡片。
## 圆角随屏幕短边等比缩放；封面满画面裁切（cover，居中溢出裁掉）；底部 30% 恒定 50% 黑遮罩条。
## 全部用 draw_polygon 完成：圆角=弧采样轮廓，封面=衬底多边形 + SDF 烘焙纹理，遮罩=多边形。

@export var cover: Texture2D
@export var song_title := ""
@export var song_artist := ""
@export var diff_code := ""     # EZ/HD/IN/AT；空 = 不画信息层
@export var diff_level := 0
@export var tiers: Array = []   # 这首曲的全部难度 [{"code","level"}]：左下角彩色小胶囊，一颗一档
@export var bpm := 0
@export var max_size_hint: Vector2 = Vector2(720, 405)   # fit_to_viewport=false 时使用
@export var fit_to_viewport: bool = true                  # 尺寸 = 视口减 padding 后的最大等比内接
@export var viewport_padding: Vector2 = Vector2(160, 200)
@export var radius_scale: float = 0.018                   # 圆角 ≈ 16px @1080p（主观旋钮）
@export var mask_ratio: float = 0.30                      # 遮罩高度占比（主观旋钮）
@export var mask_alpha: float = 0.5                       # 遮罩黑色不透明度（整条恒定，非渐变）
@export var keep_bright := false                          # true=不参与未选中压暗（详情区大卡/放大层用）

signal card_pressed

var _cover_tex: Texture2D
var _cover_key := ""
var _bake_pending := false  # 泵接管模式：true 时 _draw 先跳过，轮到 prewarm_bake 再放开
var _bake_held_ms := 0  # 被泵扣住的时刻：超时自动放开走原来的惰性烘焙（自愈兜底）
var _selected := false
var _hovered := false
var _press_at := Vector2.INF    # 卡片按下的落点：抬起时比对，走远了算拖动不算点击
var _mq: MarqueeLabel

## 跨实例共享的烘焙缓存：网格 30+ 张同尺寸卡只烘一次。
## key 量化（尺寸 32px、圆角 4px 一档）：拖窗口时只跨档才重烘，避免逐帧卡顿
static var _bake_cache: Dictionary = {}
## 烘焙成本计数器（--qaanim 读它）：级联把整批首烘挤进同一段窗口，是最可能爆
## 8.33ms 预算的地方；只读不改变任何行为。分阶段拆开是因为真正的耗时不在圆角算法
## 而在取像素/缩放那两段（对拍数据见 tests/cover_bake_test.gd 与 QAANIM_BAKE 打印）。
static var bake_n := 0
static var bake_us := 0
static var bake_resize_us := 0
static var bake_shape_us := 0
static var bake_tex_us := 0
static var bake_seed_us := 0  # 从登记表拿副本（内存拷贝）
static var bake_conv_us := 0  # convert(FORMAT_RGBA8)：blit_rect 要求同格式，这一步省不掉
static var bake_read_us := 0  # 走 texture.get_image()（显存取回/解码），贵的那条路

## 源图像登记表：烘焙要的是像素，而 texture.get_image() 实测 6.4ms/张，
## 整批首烘的钱几乎全花在这一步（QAANIM_BAKE 分阶段：取像素128 / 缩放18 / 圆角9 / 上传2ms）。
## 封面本来就是我们从 buffer/文件解码出来再建纹理的——那份 Image 已经在手上，
## 登记一下，后续烘焙只做一次内存副本。上限 40 条、按登记序淘汰：
## 一屏曲库（30 张）+ 详情 + 放大层都在窗口内，又不会把整个已下载曲库钉在内存里。
const SRC_CACHE_MAX := 40
static var _src_cache: Dictionary = {}

## 从已解码的 Image 建封面纹理，顺手登记源图（所有曲绘创建点都走这里，别再用裸 create_from_image）。
## 这里就把像素转成 RGBA8：webp/jpeg 解出来是 RGB8，烘焙时 blit_rect 要求同格式，
## 每次烘焙都再 convert 一遍实测 2.7ms/张（改到建纹理时做一次，烘焙侧只剩 no-op）。
## 注意会就地转换传入的 img（各调用点传的都是用完即弃的局部 Image）。
static func make_from_image(img: Image) -> Texture2D:
	img.convert(Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	seed_source(tex, img)
	return tex

## 直接读文件建封面（按路径缓存：同一张占位曲绘原来每张卡都重解码一次）
static var _cover_tex_cache: Dictionary = {}

static func load_cover(path: String) -> Texture2D:
	if _cover_tex_cache.has(path):
		return _cover_tex_cache[path]
	var tex := _decode_cover(path)
	if tex != null:
		_cover_tex_cache[path] = tex
	return tex

static func _decode_cover(path: String) -> Texture2D:
	var img := Image.new()
	# 只给**磁盘上的真文件**（user:// 下载的曲绘）走直接读：res:// 是导入件，
	# Image.load("res://…") 会刷 "Loaded resource as image file, this will not work on export"
	# ——导出包里根本没有源 png，每张卡都白跑一次再回退（一次启动刷 30+ 条）。
	if not path.begins_with("res://") and img.load(path) == OK:
		return make_from_image(img)
	# res://：ResourceLoader 读导入件（cover 的 compress/mode=0 是 lossless ⇒ CPU 侧拿得到像素）
	var t := load(path) as Texture2D
	if t == null:
		return null
	var ci := t.get_image()
	if ci == null or ci.is_empty():
		return null
	return make_from_image(ci)

static func seed_source(tex: Texture2D, img: Image) -> void:
	if tex == null or img == null:
		return
	var id := tex.get_instance_id()
	_src_cache[id] = img
	while _src_cache.size() > SRC_CACHE_MAX:
		# Dictionary 迭代序=插入序，丢掉最早登记的（正在显示的总是最新一批）
		var keys := _src_cache.keys()
		_src_cache.erase(keys[0])

func _ready() -> void:
	if cover == null:
		cover = SongCard.load_cover("res://assets/covers/cover_01.png")
	if cover == null:
		cover = load("res://assets/covers/cover_01.png")
	# canvas_items+expand 拉伸下，逻辑视口只横向扩展；真实屏幕比例必须看 OS 窗口像素。
	# 根 Window 就是根 Viewport（同一对象），size_changed 只连一次
	get_window().size_changed.connect(_on_viewport_resized)
	resized.connect(_sync_pivot)  # 容器给尺寸后要重设缩放支点（入场弹入绕中心，不绕左上角）
	# PASS（非 STOP）：触屏拖拽要能冒泡到外层 ScrollContainer 做惯性滚动，点击仍归本卡
	mouse_filter = Control.MOUSE_FILTER_PASS
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(_on_mouse_hover.bind(true))
	mouse_exited.connect(_on_mouse_hover.bind(false))
	gui_input.connect(_on_gui_input)
	_mq = MarqueeLabel.new()
	_mq.visible = false
	add_child(_mq)
	_apply_state()
	_state_ready = true  # 首帧之后才允许状态补间（_ready 时 pivot/尺寸未定）

func set_selected(v: bool, instant: bool = false) -> void:
	_selected = v
	_apply_state(instant)

## 缩放支点始终 = 卡片中心：容器给完尺寸后（resized）也要跟上，
## 否则入场弹入会绕左上角长，看起来像"从别处飘过来"
func _sync_pivot() -> void:
	pivot_offset = size * 0.5

## 换封面（远端曲绘下载完成后回填）：清烘焙缓存键强制重烘
func set_cover(tex: Texture2D) -> void:
	if tex == null or cover == tex:
		return
	cover = tex
	_cover_tex = null
	_cover_key = ""
	queue_redraw()

## 换页/换批时把封面退回占位图。set_cover(null) 是空操作，所以必须显式给占位图，
## 否则这张卡会一直留着上一页那首歌的图（用户报的"翻到第二页还是第一面的图"就是这个）
func reset_cover(blank: Texture2D) -> void:
	if cover == blank:
		return
	cover = blank
	_cover_tex = null
	_cover_key = ""
	queue_redraw()

func is_selected_card() -> bool:
	return _selected

func _on_mouse_hover(on: bool) -> void:
	_hovered = on
	_apply_state()

func _on_gui_input(ev: InputEvent) -> void:
	# 手指拖着曲库滚动时不该顺手选中一张卡（用户 2026-10-28）。按下不立刻发，
	# 抬指/抬起时才比对落点：走超过一点距离就是"拖"，不发点击。
	# 卡片链是 MOUSE_FILTER_PASS（SwipeScroll 要靠它冒泡收事件），
	# 但 4.7 的按下焦点仍然会把 release 送回按下的那个控件，所以这套判定成立。
	var down := false
	var p := Vector2.INF
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		down = mb.pressed
		p = mb.position
	elif ev is InputEventScreenTouch:
		var st := ev as InputEventScreenTouch
		down = st.pressed
		p = st.position
	else:
		return
	if down:
		_press_at = p
		return
	if _press_at == Vector2.INF:
		return
	var slop: float = maxf(10.0, get_viewport_rect().size.y * 0.018)
	var moved: float = p.distance_to(_press_at)
	_press_at = Vector2.INF
	if moved <= slop:
		card_pressed.emit()

## 选中=粉细边框+轻微放大+提亮；hover 提亮一档；未选中降亮度（克制）。
## 亮度/缩放走补间（状态一改就瞬移是"跳"，不是"变"）；边框是离散态，只重绘一次。
## instant=true 给 relayout 这类"整批重建"用：一次性落位，绝不和页面级联抢 alpha 属主。
var _state_ready := false

func _apply_state(instant: bool = false) -> void:
	var target_mod: float = 1.0 if (keep_bright or _selected or _hovered) else 0.85
	var m := Color(target_mod, target_mod, target_mod, 1.0)
	# 选中不再放大卡片（用户 2026-10-28）：整排卡里有一颗"胖一点"看着像错位，
	# 选中态交给内环 + 提亮就够了
	var sc := Vector2.ONE
	_sync_pivot()
	if instant or not _state_ready:
		modulate = m
		scale = sc
	else:
		# 变亮快、变暗慢：一档压暗用 0.3s 才不显眼（0.85→1 是 0.12s）
		UiMotion.to_modulate(self, m, 0.12 if target_mod > 0.99 else 0.3)
		UiMotion.to_scale(self, sc, 0.16)
	queue_redraw()

func _on_viewport_resized() -> void:
	update_minimum_size()
	queue_redraw()

func _get_minimum_size() -> Vector2:
	return _card_size()

## 真实屏幕尺寸（OS 像素）：这是用户拖窗口时唯一可靠的比例来源
func _screen_size() -> Vector2:
	var ws := get_window().size
	return Vector2(maxi(ws.x, 1), maxi(ws.y, 1))

func _card_aspect() -> float:
	return aspect_for_window(get_window().size)

static func aspect_for_window(ws: Vector2) -> float:
	if ws.x / maxf(ws.y, 1.0) >= 16.0 / 9.0:
		return 16.0 / 9.0
	return 3.0 / 2.0

func _card_size() -> Vector2:
	var box: Vector2 = max_size_hint
	if fit_to_viewport:
		var vp := get_viewport_rect().size
		box = Vector2(maxf(vp.x - viewport_padding.x, 1.0), maxf(vp.y - viewport_padding.y, 1.0))
	var aspect := _card_aspect()
	var w: float = minf(box.x, box.y * aspect)
	return Vector2(w, w / aspect)

func _radius() -> float:
	var vp := get_viewport_rect().size
	return radius_scale * minf(vp.x, vp.y)

## 给测试台诊断行用：游戏"看到"的尺寸 vs 实际卡片形状
func debug_info() -> String:
	var ws := get_window().size
	var aspect := _card_aspect()
	var tag := "16:9" if aspect > 1.6 else "3:2"
	return "win %d×%d · 比例 %s · 卡 %d×%d" % [ws.x, ws.y, tag, int(size.x), int(size.y)]

func _draw() -> void:
	var s := size
	if s.x < 2.0 or s.y < 2.0:
		return
	if _bake_pending:
		if Time.get_ticks_msec() - _bake_held_ms > 600:
			_bake_pending = false  # 泵排丢了：回落到原来的惰性烘焙，绝不让卡片一直空白
		else:
			return
	var r: float = minf(_radius(), minf(s.x, s.y) * 0.5)
	var path := _rounded_path(Rect2(Vector2.ZERO, s), r, false)
	# 衬底：contain 留边处露出的颜色
	if _triangulable(path):
		draw_polygon(path, PackedColorArray([UiTokens.bg(3)]))
	draw_texture_rect(_make_cover(s, r), Rect2(Vector2.ZERO, s), false)
	_draw_mask(s, r)
	_draw_tiers(s)
	_draw_info(s)
	if _selected:
		# 白色**内**环：往里缩一个线宽，整条环落在卡片以内（粉色贴边描边太抢眼）
		var lw: float = UiTokens.ring_w(get_viewport_rect().size.y)
		# 线是"骑"在路径上画的，所以往里缩半个线宽：环的外沿正好压在卡片边缘，不留缝
		var inner := Rect2(Vector2(lw * 0.5, lw * 0.5), s - Vector2(lw, lw))
		var ring := _rounded_path(inner, maxf(r - lw * 0.5, 0.0), false)
		# 卡片比线宽还窄时（布局抖动/极小卡）路径会退化成 0~1 个点，
		# _closed 取 pts[0] 会直接越界，这里先拒掉。
		if ring.size() >= 3:
			draw_polyline(_closed(ring), UiTokens.RING_ON, lw)

## 遮罩带上的信息层：曲名 / 谱师。难度不再写在这里——改成左下角的纯色小胶囊（_draw_tiers）。
func _draw_info(s: Vector2) -> void:
	if song_title == "":
		return
	var bold := UiTokens.font_bold()  # 曲名/作曲用粗体
	var band_top := s.y * (1.0 - mask_ratio)
	var pad := s.y * 0.05
	if song_title != "":
		# ⚠ 必须钳 ≥1：卡片在容器给它尺寸前可能只画到 2~8px 高，int(8*0.115)=0 ⇒
		# MarqueeLabel 带着 0 号字每帧 get_string_size，TextServer 每帧刷
		# "_ensure_cache_for_size(p_size.x <= 0)"（用户：都 3000 次了，游玩还卡）
		var tf := maxi(int(s.y * 0.115), 1)
		# 右侧那颗文字徽章已经拿掉了，曲名/谱师可以铺满整条遮罩带（原来钳在 62% 宽
		# 是给徽章让位的，留着就成了"右边界没变"）
		var avail := s.x - pad * 2.0
		var tw: float = bold.get_string_size(song_title, HORIZONTAL_ALIGNMENT_LEFT, -1, tf).x
		if tw > avail:
			# 超宽曲名：跑马灯子控件循环滚动（clip 在文字区内）
			_mq.visible = true
			_mq.position = Vector2(pad, band_top + s.y * 0.13 - tf * 0.95)
			_mq.size = Vector2(avail, int(tf * 1.25))
			_mq.set_content.call_deferred(song_title, tf, UiTokens.INK)
		else:
			_mq.visible = false
			draw_string(bold, Vector2(pad, band_top + s.y * 0.13), song_title, HORIZONTAL_ALIGNMENT_LEFT, avail, tf, UiTokens.INK)
		if song_artist != "":
			draw_string(bold, Vector2(pad, band_top + s.y * 0.24), song_artist, HORIZONTAL_ALIGNMENT_LEFT, avail, maxi(int(s.y * 0.075), 1), UiTokens.INK_SUB)

## 胶囊几何单独成函数：_draw 和 --qacard 探针读同一份，量出来的才是真画出来的。
## n 是"要画几颗"——一排放不下就等比缩宽度（再收紧间距），**一颗都不能少**
## （用户 2026-10-28：明明 4 个难度只画了 3 颗。原来的"按能放下的颗数截断"就是元凶之一）。
## 布局抖动时 s.x 可能只有十几像素（容器还没给到最终尺寸），这里必须返回"能画"的几何
## 或直接返回空，不能返回会退化的矩形——见下面的等比缩放注释。
static func tier_rects(s: Vector2, mask: float, n: int = 1) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if s.y < 24.0 or mask <= 0.0 or n <= 0:
		return out
	var band_top := s.y * (1.0 - mask)
	var pad := s.y * 0.05
	var ph: float = maxf(s.y * 0.045, 4.0)
	var pw: float = ph * 2.6
	var gap: float = ph * 0.6
	var avail: float = s.x - pad * 2.0
	if avail < gap * float(n - 1) + ph:  # 连最小一颗都放不下：这帧干脆不画
		return out
	if pw * float(n) + gap * float(n - 1) > avail:
		gap = ph * 0.28
		var need: float = pw * float(n) + gap * float(n - 1)
		if need > avail:
			# ⚠ 宽/高/间距必须一起缩。原来只缩宽（pw→ph*0.6），于是 pw < ph，
			# _rounded_path 把半径钳到 pw*0.5 ⇒ 顶边两个角点重合在中心，
			# earcut 对这种退化多边形返回空索引 ⇒
			# "Invalid polygon data, triangulation failed"（用户 2026-10-29 报错）。
			var k: float = maxf(avail / need, 0.0)
			pw *= k
			ph *= k
			gap *= k
	var y: float = band_top - ph - s.y * 0.025
	for i in n:
		out.append(Rect2(pad + float(i) * (pw + gap), y, pw, ph))
	return out

## 难度小胶囊：**只给颜色、不给字**，一颗一档，排在"遮罩以外"的左下角（用户 2026-10-28 草图）。
## 放这里是为了能并排放多个：一首曲在 PZ/PT 上常带 2~4 个难度，原来那颗文字徽章只能显示一档。
## 只在有遮罩带的卡上画（详情区大卡 mask_ratio=0，画上去等于凭空多一排色块）。
func _draw_tiers(s: Vector2) -> void:
	if tiers.is_empty():
		return
	var rects := tier_rects(s, mask_ratio, tiers.size())
	for i in tiers.size():
		if i >= rects.size():
			return  # 这一档的尺寸画不出（卡片还在布局抖动），别拿越界下标定崩溃
		var r: Rect2 = rects[i]
		var pts := _rounded_path(r, r.size.y * 0.5, false)
		if not _triangulable(pts):
			continue
		var t: Dictionary = tiers[i]
		var col: Color = UiTokens.tier_pill_color(String(t.get("code", "")), int(t.get("level", 0)))
		draw_polygon(pts, PackedColorArray([col]))

## 烘焙 cover+圆角 的封面纹理：满画面裁切（缩放到覆盖卡片、居中裁掉溢出），无拉伸。
## 按实际尺寸烘焙：32px 量化会让"烘焙尺寸≠绘制尺寸"，横向纵向缩放不一致=图片被拉伸。
## 不用 draw_polygon UV：2D 默认纹理 repeat，越界 UV 会平铺封面。
func _make_cover(s: Vector2, r: float) -> Texture2D:
	var w := maxi(ceili(s.x), 1)
	var h := maxi(ceili(s.y), 1)
	var rr := maxi(ceili(r / 4.0) * 4, 1)
	var key := _bake_key(w, h, rr)  # 远端纹理无 resource_path，用实例 ID
	if key == _cover_key and _cover_tex != null:
		return _cover_tex
	if _bake_cache.has(key):
		_cover_tex = _bake_cache[key]
		_cover_key = key
		return _cover_tex
	var tex := bake_cover_tex(cover, w, h, rr)
	_cover_tex = tex
	_cover_key = key
	_bake_cache[key] = tex
	return tex

func _bake_key(w: int, h: int, rr: int) -> String:
	return "%dx%d|%d|%d" % [w, h, rr, cover.get_instance_id()]

## 泵接管开关：true → _draw 跳过本卡（不烘焙），等 prewarm_bake 那一帧放开。
## 只在有 BakePump 时使用；泵缺席就是原来的惰性烘焙，行为不变。
func hold_bake(v: bool) -> void:
	if _bake_pending == v:
		return
	_bake_pending = v
	if v:
		_bake_held_ms = Time.get_ticks_msec()
	queue_redraw()

## 提前把当前尺寸的封面烘进共享缓存：_draw 之后走的就是缓存命中，
## 于是"必超预算的一张首烘"由 BakePump 摊到各帧，而不是和级联撞在同一帧
func prewarm_bake() -> bool:
	var s := size
	if s.x < 2.0 or s.y < 2.0 or cover == null:
		_release_bake_hold()  # 尺寸没定/没封面：立刻放开，回落到原惰性烘焙，别把自己扣成空白
		return false
	var r: float = minf(_radius(), minf(s.x, s.y) * 0.5)
	var w := maxi(ceili(s.x), 1)
	var h := maxi(ceili(s.y), 1)
	var rr := maxi(ceili(r / 4.0) * 4, 1)
	var key := _bake_key(w, h, rr)
	if not _bake_cache.has(key):
		_bake_cache[key] = bake_cover_tex(cover, w, h, rr)
	_release_bake_hold()
	return true

func _release_bake_hold() -> void:
	if _bake_pending:
		_bake_pending = false
		queue_redraw()

## 当前尺寸的烘焙尺寸参数（_draw 与预烘必须同一套算法，否则缓存键对不上）
func _bake_dims() -> Array:
	var s := size
	var r: float = minf(_radius(), minf(s.x, s.y) * 0.5)
	var w := maxi(ceili(s.x), 1)
	var h := maxi(ceili(s.y), 1)
	var rr := maxi(ceili(r / 4.0) * 4, 1)
	return [w, h, rr, _bake_key(w, h, rr)]

## 异步预烘：贵的一段（缩放 15–20ms）丢工作线程，回来只做 blit+四角+上传。
## 详情大卡/放大层走这条——它们是"点卡片/双击曲绘"当场就要露脸的，不能等队列。
func prewarm_threaded(pump: BakePump) -> void:
	var s := size
	if s.x < 2.0 or s.y < 2.0 or cover == null:
		_release_bake_hold()
		return
	var d := _bake_dims()
	var key := String(d[3])
	if _bake_cache.has(key):
		_release_bake_hold()
		return
	if pump == null:
		prewarm_bake()
		return
	pump.push_threaded(bake_src.bind(cover, int(d[0]), int(d[1])),
		_apply_baked.bind(key, int(d[0]), int(d[1]), int(d[2])))

## 注意参数顺序：bind 的实参排在回调结果之后
func _apply_baked(src: Image, key: String, w: int, h: int, rr: int) -> void:
	if src != null and not _bake_cache.has(key) and is_instance_valid(self):
		_bake_cache[key] = bake_finish(src, w, h, rr)
	_release_bake_hold()

## 烘焙拆成两段，是为了能把贵的那段丢到工作线程：
## bake_src（取副本+转格式+居中缩放）= 详情大卡/放大层实测 15–20ms，主线程做就是两个 vsync 没了；
## bake_finish（blit + 四角 SDF + 上传）= 亚毫秒，只能留在主线程（碰 RenderingServer）。
## 两段串起来与原来的 bake_cover_tex 逐像素等值（tests/cover_bake_test.gd 对拍守着）。

## 线程侧：只碰纯数据（Image 副本/转换/缩放），返回已缩放到位的源块
static func bake_src(cov: Texture2D, w: int, h: int) -> Image:
	var t0 := Time.get_ticks_usec()
	var sid := cov.get_instance_id()
	var src: Image = null
	if _src_cache.has(sid):
		# 登记过：拿一份内存副本，绝不改动原图（同一张封面还要按别的尺寸再烘）
		src = (_src_cache[sid] as Image).duplicate()
		bake_seed_us += Time.get_ticks_usec() - t0
	else:
		src = cov.get_image()  # 没登记的（导入资源）仍走原路：显存取回，实测 6.4ms/张
		bake_read_us += Time.get_ticks_usec() - t0
	var tc := Time.get_ticks_usec()
	src.convert(Image.FORMAT_RGBA8)  # 登记路径在建纹理时就转过，这里基本是 no-op
	var tr := Time.get_ticks_usec()
	bake_conv_us += tr - tc
	var sc: float = maxf(float(w) / float(src.get_width()), float(h) / float(src.get_height()))
	var iw := maxi(int(float(src.get_width()) * sc), w)
	var ih := maxi(int(float(src.get_height()) * sc), h)
	src.resize(iw, ih)
	bake_resize_us += Time.get_ticks_usec() - tr
	return src

## 主线程侧：blit + 四角 + 上传
static func bake_finish(src: Image, w: int, h: int, rr: int) -> Texture2D:
	var t0 := Time.get_ticks_usec()
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	bake_cover(img, src, (src.get_width() - w) / 2, (src.get_height() - h) / 2, w, h, rr)
	var t1 := Time.get_ticks_usec()
	bake_shape_us += t1 - t0
	var tex := ImageTexture.create_from_image(img)
	bake_tex_us += Time.get_ticks_usec() - t1
	return tex

static func bake_cover_tex(cov: Texture2D, w: int, h: int, rr: int) -> Texture2D:
	var t0 := Time.get_ticks_usec()
	var tex := bake_finish(bake_src(cov, w, h), w, h, rr)
	bake_n += 1
	bake_us += Time.get_ticks_usec() - t0
	return tex

## 圆角封面烘焙（旧写法整张逐像素跑 SDF，30 张卡首烘合计 410ms，把 120fps 打成 30fps）。
## 关键观察：圆角矩形除了四个 r×r 角块以外恒为"全覆盖"，逐像素只须覆盖那 4 个小方块：
## 其余像素由 copy_from 整块 blit 完成，二者与旧写法逐点等值（tests/cover_bake_test.gd 对拍）。
## 圆角外的像素必须显式写透明——blit 会把封面像素带进角块里，不擦就露出方形"耳朵"。
static func bake_cover(img: Image, src: Image, ox: int, oy: int, w: int, h: int, rr: int) -> void:
	# 4.7 Image 只有单参 copy_from（整幅覆盖），带矩形的是 blit_rect
	img.blit_rect(src, Rect2i(ox, oy, w, h), Vector2i(0, 0))
	var side := mini(rr + 1, mini(w / 2, h / 2))
	if side <= 0:
		return
	var half := Vector2(w * 0.5, h * 0.5)
	var rad := float(rr)
	for cy in [0, h - side]:
		for cx in [0, w - side]:
			for y in range(cy, cy + side):
				for x in range(cx, cx + side):
					var cov: float = _sdf_coverage(Vector2(x + 0.5, y + 0.5), half, rad)
					if cov <= 0.001:
						img.set_pixel(x, y, Color(0, 0, 0, 0))
					else:
						var c := src.get_pixel(x + ox, y + oy)
						c.a = cov  # 圆角边缘 1px 覆盖率过渡（抗锯齿）
						img.set_pixel(x, y, c)

## 圆角矩形 SDF → 0..1 覆盖率（1px 过渡带抗锯齿）
static func _sdf_coverage(p: Vector2, half: Vector2, r: float) -> float:
	var q := (p - half).abs() - (half - Vector2(r, r))
	var outside: float = q.max(Vector2.ZERO).length()
	var inside: float = minf(maxf(q.x, q.y), 0.0)
	return clampf(0.5 - (outside + inside - r), 0.0, 1.0)

## 底部 mask_ratio 高度的遮罩条：整条恒定黑色 mask_alpha（非渐变），顶边直角、底边随卡片圆角。
## mask_ratio <= 0 时不画遮罩（纯卡片形态，如选曲页右侧大图）
func _draw_mask(s: Vector2, r: float) -> void:
	if mask_ratio <= 0.0:
		return
	var band_h: float = s.y * mask_ratio
	var band_top := s.y - band_h
	var br: float = minf(r, band_h * 0.5)
	var band := _rounded_path(Rect2(0.0, band_top, s.x, band_h), br, true)
	if not _triangulable(band):
		return
	var colors := PackedColorArray()
	for p in band:
		colors.append(Color(0.0, 0.0, 0.0, mask_alpha))
	draw_polygon(band, colors)

## 简单多边形轮廓（顺时针一次遍历，无重复点）；square_top 时上方两角为直角（底部遮罩条用）
## 半径被钳到 min(w,h)*0.5：窄胶囊/零高遮罩条这类几何会让顶边两点重合，
## 统一过一遍 _dedupe_path，免得把重合点喂给 earcut（它直接返回空索引并报
## "Invalid polygon data, triangulation failed"）。
static func _rounded_path(rect: Rect2, radius: float, square_top: bool) -> PackedVector2Array:
	var r := maxf(minf(radius, minf(rect.size.x, rect.size.y) * 0.5), 0.0)
	var l := rect.position.x
	var t := rect.position.y
	var b := rect.end.y
	var rt := rect.end.x
	var pts := PackedVector2Array()
	if square_top:
		pts.append(Vector2(l, t))
		pts.append(Vector2(rt, t))
	else:
		pts.append(Vector2(l + r, t))
		pts.append(Vector2(rt - r, t))
		_arc(pts, Vector2(rt - r, t + r), r, -PI * 0.5, 0.0)
	pts.append(Vector2(rt, b - r))
	_arc(pts, Vector2(rt - r, b - r), r, 0.0, PI * 0.5)
	pts.append(Vector2(l + r, b))
	_arc(pts, Vector2(l + r, b - r), r, PI * 0.5, PI)
	if not square_top:
		pts.append(Vector2(l, t + r))
		_arc(pts, Vector2(l + r, t + r), r, PI, PI * 1.5)
	return _dedupe_path(pts)

## 丢掉连续重合点（半径=0 的角弧会一次吐出 8 个同一点），首尾重合也去掉末点。
static func _dedupe_path(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var last := Vector2(INF, INF)
	for p in pts:
		if p.distance_squared_to(last) > 0.0001:
			out.append(p)
			last = p
	if out.size() > 1 and out[0].distance_squared_to(out[out.size() - 1]) <= 0.0001:
		out.remove_at(out.size() - 1)
	return out

## 能不能安全 draw_polygon：至少 3 个不重合顶点且围出非零面积。
static func _triangulable(pts: PackedVector2Array) -> bool:
	if pts.size() < 3:
		return false
	var area2 := 0.0
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		area2 += a.x * b.y - b.x * a.y
	return absf(area2) > 0.01

## 弧采样，跳过首点（与上一段直线末点重合）
static func _arc(pts: PackedVector2Array, c: Vector2, r: float, a0: float, a1: float) -> void:
	var steps := 8
	for i in range(1, steps + 1):
		var a: float = lerpf(a0, a1, float(i) / float(steps))
		pts.append(c + Vector2(cos(a), sin(a)) * r)

static func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := pts.duplicate()
	out.append(pts[0])
	return out
