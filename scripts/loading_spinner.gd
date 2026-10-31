class_name LoadingSpinner
extends Control
## osu!lazer LoadingSpinner 移植（osu.Game/Graphics/UserInterface/LoadingSpinner.cs，MIT）。
## 机制照搬：CircleNotch 缺环恒速自转（3150ms/圈）+ 每拍"蹬" +90°（InQuart InOut）；
## osu 的拍源是菜单曲，这里无轨可同步 → 固定 500ms 步长（120BPM 观感）。
## 出入场：scale 0.6↔1 + 淡入 500ms / 淡出 250ms OutQuint（osu TRANSITION_DURATION=500）。
## with_box：黑色 70% 圆角盒（半径=宽/4，osu withBox 形态）。
## MIN_SHOW：本地/收藏这类瞬时同步扫描也给一眼动画（对应 osu 加载屏最短展示思路）。

const SPIN_PERIOD := 3.15      # 恒速自转一圈秒数（osu spin_duration=3150）
const KICK_STEP := 0.5         # 蹬拍周期秒（osu: 每拍 +90°，拍长下限 600ms）
const KICK_ANGLE := 90.0       # 每次蹬的增量角度
const TRANSITION := 0.5        # osu TRANSITION_DURATION
const MIN_SHOW := 0.35         # 最短展示：到点即完的加载也不闪没
const NOTCH_DEG := 62.0        # CircleNotch 缺口张角（目测字形）

@export var with_box := true
@export var inverted := false  # 黑环白底反色（osu inverted 参数）

var _spin := 0.0
var _kick_from := 0.0
var _kick_target := 0.0
var _kick_t := 0.0
var _shown := false
var _shown_msec := 0
var _tw: Tween

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	modulate.a = 0.0
	scale = Vector2(0.6, 0.6)
	if with_box:
		var p := Panel.new()
		p.z_index = -1  # 盒画在本节点 _draw 的圆环之下
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0.7) if not inverted else Color(1, 1, 1, 0.7)
		p.add_theme_stylebox_override("panel", sb)
		p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(p)
		_box_sb = sb

var _box_sb: StyleBoxFlat

func _process(delta: float) -> void:
	pivot_offset = size * 0.5
	if with_box and _box_sb != null:
		_box_sb.set_corner_radius_all(int(size.x * 0.25))  # osu: CornerRadius = 宽/4
	if modulate.a <= 0.01 and not _shown:
		return  # 完全隐藏时不空转
	_spin = fmod(_spin + delta * 360.0 / SPIN_PERIOD, 360.0)
	_kick_t += delta / KICK_STEP
	if _kick_t >= 1.0:
		_kick_from = _kick_target
		_kick_target += KICK_ANGLE
		_kick_t = 0.0
	queue_redraw()

## InOutQuart（osu Easing.InOutQuart 同族：p<0.5 段 8p⁴，否则 1-|-2p+2|⁴/2）
static func _inout_quart(p: float) -> float:
	if p < 0.5:
		return 8.0 * p * p * p * p
	var q := -2.0 * p + 2.0
	return 1.0 - q * q * q * q / 2.0

func _draw() -> void:
	if size.x < 4.0:
		return
	var c := size * 0.5
	var d := minf(size.x, size.y) * (0.62 if with_box else 1.0)  # osu: Scale 0.6（带盒时）
	var r := d * 0.34
	var w := d * 0.15
	var rot := deg_to_rad(_spin + lerpf(_kick_from, _kick_target, _inout_quart(clampf(_kick_t, 0, 1))))
	var col := Color(1, 1, 1) if not inverted else Color(0, 0, 0)
	var gap := deg_to_rad(NOTCH_DEG)
	var a0 := rot + gap * 0.5
	var a1 := rot + TAU - gap * 0.5
	draw_arc(c, r, a0, a1, 72, col, w, true)
	# 圆头端点（Font Awesome CircleNotch 是圆角缺口，用端帽圆点近似）
	draw_circle(c + Vector2.from_angle(a0) * r, w * 0.5, col)
	draw_circle(c + Vector2.from_angle(a1) * r, w * 0.5, col)

func show_spin() -> void:
	_shown = true
	_shown_msec = Time.get_ticks_msec()
	visible = true
	if _tw != null and _tw.is_valid():
		_tw.kill()
	_tw = create_tween()
	_tw.set_parallel(true)
	_tw.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT)
	_tw.tween_property(self, "modulate:a", 1.0, TRANSITION)
	_tw.tween_property(self, "scale", Vector2.ONE, TRANSITION)

## 瞬时加载（本地/收藏同步扫描）：亮一下就走，MIN_SHOW 保证看得见、不闪没
func flash() -> void:
	show_spin()
	hide_spin()

func hide_spin() -> void:
	if not _shown:
		return
	_shown = false
	var wait: float = maxf(0.0, MIN_SHOW * 1000.0 - float(Time.get_ticks_msec() - _shown_msec)) / 1000.0
	if _tw != null and _tw.is_valid():
		_tw.kill()
	if wait > 0.0:
		# 还在 MIN_SHOW 保护期内：先钉成全亮再等再淡出——否则 kill 掉进行中的
		# show tween 会把 α 永远停在 0（flash() 曾因此整条链路不可见）
		modulate.a = 1.0
		scale = Vector2.ONE
	_tw = create_tween()
	if wait > 0.0:
		_tw.tween_interval(wait)
	_tw.set_parallel(true)
	_tw.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT)
	_tw.tween_property(self, "modulate:a", 0.0, TRANSITION / 2.0)
	_tw.tween_property(self, "scale", Vector2(0.6, 0.6), TRANSITION)
	_tw.chain().tween_callback(func() -> void:
		if not _shown:
			visible = false)
