class_name SplashOverlay
extends Control
## 开场全屏遮罩：标题 + "轻触以开始游戏"，任意点击淡出后自毁。

signal dismissed

var _bg: ColorRect
var _title: Label
var _hint: Label
var _dismissing := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 100  # NeoButton 叠层有正 z_index，遮罩必须更高才盖得住
	# 注意：set_anchors_preset 只动锚点不动尺寸（全项目统一用 and_offsets 版本）
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg = ColorRect.new()
	_bg.color = UiTokens.bg(0)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE  # 否则背景吃掉点击，父级 gui_input 永远收不到
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)
	_title = _make_label("PhiTogetherNext", UiTokens.text_on(UiTokens.bg(0)))
	_hint = _make_label("轻触以开始游戏", UiTokens.text_on(UiTokens.bg(0)))
	_hint.modulate.a = 0.55  # 静止值：入场由 UiMotion 提供起始 0 并补回这里，呼吸动画也以此为峰
	get_viewport().size_changed.connect(_layout)
	_layout()
	gui_input.connect(_on_gui_input)
	_reveal()

## 标题先浮出来，提示晚一拍再出现并开始呼吸——两个动画通道错开，避免同一属性双属主
func _reveal() -> void:
	UiMotion.fade_in(_title, 0.4, 0.0)
	UiMotion.fade_in(_hint, 0.3, 0.22)
	if not UiMotion.enabled:
		_start_pulse()
		return
	var tw: Tween = _hint.get_meta(UiMotion.K_TW)
	if tw != null and tw.is_valid():
		tw.finished.connect(_start_pulse)
	else:
		_start_pulse()

func _start_pulse() -> void:
	var pulse := create_tween().set_loops()
	pulse.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	pulse.tween_property(_hint, "modulate:a", 0.25, 1.1)
	pulse.tween_property(_hint, "modulate:a", 0.7, 1.1)

func _make_label(caption: String, ink: Color) -> Label:
	var l := Label.new()
	l.text = caption
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", ink)
	add_child(l)
	return l

func _layout() -> void:
	var vp := get_viewport_rect().size
	_title.position = Vector2(0, vp.y * 0.36 - vp.y * 0.04)
	_title.size = Vector2(vp.x, vp.y * 0.08)
	_title.add_theme_font_size_override("font_size", int(vp.y * 0.055))
	_hint.position = Vector2(0, vp.y * 0.52)
	_hint.size = Vector2(vp.x, vp.y * 0.05)
	_hint.add_theme_font_size_override("font_size", int(vp.y * 0.024))

func _on_gui_input(ev: InputEvent) -> void:
	if _dismissing:
		return
	var mb := ev as InputEventMouseButton
	var tb := ev as InputEventScreenTouch
	if (mb != null and mb.pressed) or tb != null:
		_dismissing = true
		var tw := create_tween()
		tw.tween_property(self, "modulate:a", 0.0, 0.45).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(_finish)

func _finish() -> void:
	dismissed.emit()
	queue_free()
