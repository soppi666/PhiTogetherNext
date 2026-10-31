class_name SwipeScroll
extends RefCounted
## 全站统一的"手势滑动"：挂在任意 ScrollContainer 上，鼠标拖、手指拖、触控板双指拨动
## 都能推内容，抬手带一点惯性；滚动条一律隐形（不再要那根条）。
##
## 为什么要抽这一处：曲库带是自己写的（只认触屏、鼠标拖不动）、设置页的容器干脆
## MOUSE_FILTER_IGNORE（内容超出屏幕也滑不到底）、测试页只有自绘细握把——三套迟早各长
## 一个样，而"能不能滑"在手机上就是手感底线。
##
## 接线要求（本项目的既有结论）：4.7 ScrollContainer 没有 force_drag_type，触屏拖拽必须
## 手动；且容器链要全 PASS，事件才会冒泡到这里。触点一律按 `index` 分槽，不用自增 id。

const FLICK_MIN := 90.0        # 抬手速度低于这个（px/s）就不给惯性
const FLICK_DUR := 0.42        # 惯性时长（秒）
const FLICK_THROW := 0.18      # 惯性位移 = 速度 × 这个系数（秒）
const DRAG_SLOP := 4.0         # 小于这个位移不算"拖"，免得点按钮被当成滚动

var _sc: ScrollContainer
var _slot := -1                # 正在拖的触点槽号（-1=没有）
var _mouse := false
var _last := 0.0
var _vel := 0.0
var _t_ms := 0
var _moved := false
var _tw: Tween

## 挂上去：容器改 STOP（否则事件进不来）、滚动条置空（无可绘制即隐形，滚轮照常）。
## 返回的实例由 gui_input 信号持有，容器释放时一起消失。
static func attach(sc: ScrollContainer) -> SwipeScroll:
	var s := SwipeScroll.new()
	s._sc = sc
	sc.mouse_filter = Control.MOUSE_FILTER_STOP
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.gui_input.connect(s._on_gui)
	s.hide_bar(sc)
	return s

## 隐藏 4.7 的默认滚动条：Layout 会把 visible 恢复回去、ScrollBar 也没有 max_width 常量，
## 唯一稳的做法是把两个样式盒置空（song_select 曲库带用的就是这条）。
static func hide_bar(sc: ScrollContainer) -> void:
	var vsb := sc.get_v_scroll_bar()
	vsb.add_theme_stylebox_override("scroll", StyleBoxEmpty.new())
	vsb.add_theme_stylebox_override("scroll_background", StyleBoxEmpty.new())

func enabled() -> bool:
	return _max_scroll() > 0.0

func _max_scroll() -> int:
	var kid := _sc.get_child(0) as Control
	if kid == null:
		return 0
	return maxi(0, int(round(kid.size.y)) - int(_sc.size.y))

func _on_gui(ev: InputEvent) -> void:
	if not enabled():
		return
	var st := ev as InputEventScreenTouch
	if st != null:
		if st.pressed:
			_slot = st.index
			_begin(st.position.y)
		elif st.index == _slot:
			_slot = -1
			_end()
		return
	var sd := ev as InputEventScreenDrag
	if sd != null:
		if sd.index == _slot:
			_move(sd.position.y)
		return
	var mb := ev as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_mouse = true
			_begin(mb.position.y)
		elif _mouse:
			_mouse = false
			_end()
		return
	var mm := ev as InputEventMouseMotion
	if mm != null and _mouse and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_move(mm.position.y)
		return
	var pg := ev as InputEventPanGesture
	if pg != null:
		# 触控板双指拨动：没有"抬手"时刻，直接按增量推，不攒惯性
		_shift(-pg.delta.y * 2.0)

func _begin(y: float) -> void:
	_kill_tw()
	_last = y
	_vel = 0.0
	_moved = false
	_t_ms = Time.get_ticks_msec()

func _move(y: float) -> void:
	var d := _last - y
	var now := Time.get_ticks_msec()
	var dt := maxf(float(now - _t_ms) / 1000.0, 0.001)
	# 速度做一点平滑：单帧抖动（尤其手机上）不该变成一次大甩
	_vel = _vel * 0.55 + (d / dt) * 0.45
	_t_ms = now
	_last = y
	if absf(d) >= DRAG_SLOP:
		_moved = true
	_shift(d)

func _end() -> void:
	if not _moved or absf(_vel) < FLICK_MIN:
		return
	var from := float(_sc.scroll_vertical)
	var to := clampf(from + _vel * FLICK_THROW, 0.0, float(_max_scroll()))
	if to == from:
		return
	_tw = _sc.create_tween()
	_tw.tween_method(_set_v, from, to, FLICK_DUR).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _shift(d: float) -> void:
	_set_v(float(_sc.scroll_vertical) + d)

func _set_v(v: float) -> void:
	_sc.scroll_vertical = int(round(clampf(v, 0.0, float(_max_scroll()))))

func _kill_tw() -> void:
	# 一个属性只能有一个属主：新的拖拽必须先杀掉上一条惯性补间
	if _tw != null and _tw.is_valid():
		_tw.kill()
	_tw = null
