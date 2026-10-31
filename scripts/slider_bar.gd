class_name SliderBar
extends Control
## 设置页的滑条（用户 2026-10-30 定稿的线框版）：
## 轨道=**一根连续的深槽胶囊**（不要 shader 那套星格漂移；"滑动条没有边框" ⇒ 槽不描边），
## 已走过的段=**白色实心**填到滑块的左沿（左端圆角、右端直角，右端顶在滑块底下不露半圆弧），
## 滑块本体是设置页那颗**数值框**（`handle_w` + 外部按 `slide_x()` 摆），所以默认不再画圆点。
## ⚠ 轨道**不许**在滑块底下断开（试过"槽从滑块右沿起画"，实渲就是白芯一根+深槽一根
## 中间一个洞，用户："这个条怎么变成两个条了"）。藏线靠数值框那块不透明底板。
##
## 对外形状与 HSlider 对齐（min_value/max_value/step/value + value_changed），
## 所以设置页那套行逻辑不用为它改分支。

signal value_changed(v: float)

var min_value := 0.0
var max_value := 1.0
var step := 1.0
## 当前值。**只有 set_value() 会改它**（属性不设 setter：GDScript 的 setter 里再赋
## 同名属性就是无限递归），外部读直接读 value。
var value := 0.0
## 滑块宽（像素）。设置页把**数值框**当滑块（用户 2026-10-30 草图：0.8 贴轨道左端、
## 1.5 贴轨道右端），所以滑块行程是 `[0, 轨道宽-滑块宽]`，填充前沿=滑块**左沿**。
## 0 = 没有外部滑块，沿用原来那颗小圆点。
var handle_w := 0.0
## 圆点手柄要不要画：数值框当滑块时必须关掉，否则框底下又冒出一个点
var show_thumb := true
## 未走过的那段：一层深色**槽**（用户 2026-10-30："滑动条没有边框" ⇒ 轨道不再描边）
var track_bg := Color(0, 0, 0, 0.35)
## 已走过的那段：白色实心
var fill_col := UiTokens.RING_ON

var _fill: PillStyle.Pill
var _track: PillStyle.Pill
var _dragging := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_NONE
	# 顺序=层级：**槽在下、白芯在上**（反过来 35% 黑的槽会把白芯染成 65% 灰，实测一眼假）。
	# 整条轨道是**一根连续的胶囊**：数值框坐在它上面，不在它底下开洞
	# （开洞的实渲是"白芯一根+深槽一根"中间一个洞，用户："这个条怎么变成两个条了"）。
	_track = PillStyle.Pill.new()
	add_child(_track)
	# 白芯是**全圆角**胶囊：右端多探出自己半径的一截、整个圆帽藏进数值框底下。
	# 于是露出来的任何一小段（值拉得很低时尤其）都是圆的；值拉低露出一小截方头的
	# 版本被用户抓过："但如果拉的很低的话就不是圆了"。
	_fill = PillStyle.Pill.new()
	add_child(_fill)
	resized.connect(_sync)
	_sync()

## 几何/值→两颗胶囊。用 `PillStyle.Pill`（2× 烘焙 + 绘制时把帽缩回 1×）：
## StyleBoxTexture 的 9-slice 两端帽 1:1 缩不了，超采样在那条路上必坏一种形状。
## 层次靠"白芯 vs 深槽"，不靠描边（用户 2026-10-30："滑动条没有边框"）。
func _sync() -> void:
	var r := size.y * 0.5
	var edge := _edge()
	_track.position = Vector2.ZERO
	_track.size = size
	_track.fill = track_bg
	_track.radius = r
	_fill.visible = edge > 0.5
	_fill.position = Vector2.ZERO
	# 左端半径**恒定=轨道半高**：拉到任何位置，露出的左端都是同一个大半圆、和轨道
	# 端头同曲率（用户："拉到右边它左边是圆角，拉到左边就变成矩形圆角了，形状对不上"）。
	# 右端圆帽探出前沿、整体藏进数值框底下（探针断言 总宽−半径=前沿）。
	var rr_fill := r
	_fill.size = Vector2(edge + rr_fill, size.y)
	_fill.fill = fill_col
	_fill.radius = rr_fill

## 设置页用它给数值框定位：**同一套算式**，别两边各写一遍（各写一遍迟早错位）
func slide_x() -> float:
	return _frac() * maxf(size.x - handle_w, 0.0)

## 换滑块宽（数值框宽度随每行的最宽文本变）：换完要重算填充前沿
func set_handle(w: float) -> void:
	handle_w = maxf(w, 0.0)
	_sync()

func set_value(v: float) -> void:
	var c := clampf(v, min_value, max_value)
	if step > 0.0:
		c = min_value + round((c - min_value) / step) * step
	value = clampf(c, min_value, max_value)
	if is_node_ready():
		_sync()

func _frac() -> float:
	var span := maxf(max_value - min_value, 1e-6)
	return clampf((value - min_value) / span, 0.0, 1.0)

## 填充前沿：有滑块时=滑块左沿，没滑块时=圆点中心
func _edge() -> float:
	if handle_w > 0.0:
		return slide_x()
	var r := size.y * 0.42
	return r + (size.x - r * 2.0) * _frac()

## 填充前沿占轨道宽的比例（探针核对"进度填到滑块的左沿"，不是填到框中间）
func fill_frac() -> float:
	return _edge() / maxf(size.x, 1.0)

## 圆点手柄（只在没有外部滑块时画）
func _draw() -> void:
	if not show_thumb:
		return
	var r := size.y * 0.42
	var x := r + (size.x - r * 2.0) * _frac()
	var c := Vector2(x, size.y * 0.5)
	draw_circle(c, r * 1.15, Color(0, 0, 0, 0.45))
	draw_circle(c, r, UiTokens.ACCENT)
	draw_circle(c, r * 0.42, Color(1, 1, 1, 0.9))

func _gui_input(ev: InputEvent) -> void:
	var p := _point_of(ev)
	if p.x < 0.0:
		return
	if _pressed_here(ev):
		_dragging = true
		accept_event()
		_apply_x(p.x)
	elif _released_here(ev):
		_dragging = false
	elif _dragging and _moved(ev):
		_apply_x(p.x)

static func _pressed_here(ev: InputEvent) -> bool:
	var mb := ev as InputEventMouseButton
	if mb != null:
		return mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed
	var st := ev as InputEventScreenTouch
	if st != null:
		return st.pressed
	return false

static func _released_here(ev: InputEvent) -> bool:
	var mb := ev as InputEventMouseButton
	if mb != null:
		return mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed
	var st := ev as InputEventScreenTouch
	if st != null:
		return not st.pressed
	return false

static func _moved(ev: InputEvent) -> bool:
	return ev is InputEventMouseMotion or ev is InputEventScreenDrag

## 事件坐标：本地系（_gui_input 给的已是本地坐标）；触摸事件同理
func _point_of(ev: InputEvent) -> Vector2:
	var m := ev as InputEventMouse
	if m != null:
		return m.position
	var s := ev as InputEventScreenTouch
	if s != null:
		return s.position
	var d := ev as InputEventScreenDrag
	if d != null:
		return d.position
	return Vector2(-1, -1)

## 外部手势层（数值框上的滑/点判定层）把**全局 x** 喂进来：走和轨道拖拽同一套映射。
## 用户 2026-10-30："如果是滑动就是滑动，如果是点击就是输入"——数值框上滑动要调值。
func apply_global_x(gx: float) -> void:
	_apply_x(gx - get_global_rect().position.x)

func _apply_x(x: float) -> void:
	# 手指落在哪儿，滑块的**中心**就去哪儿（有数值框时按框宽留半格，没框时按圆点半径）
	var inset := handle_w * 0.5 if handle_w > 0.0 else size.y * 0.42
	var span := maxf(size.x - inset * 2.0, 1.0)
	var f := clampf((x - inset) / span, 0.0, 1.0)
	var nv := min_value + f * (max_value - min_value)
	if nv != value:
		set_value(nv)
		value_changed.emit(value)
