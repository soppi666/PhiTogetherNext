extends Control
## 演示场景：背景 + 标题 + 三个按钮（rest / hover-可交互 / disabled）。

var _buttons: Array[NeoButton] = []

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UiTokens.bg(0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.z_index = -10
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 22)
	center.add_child(col)

	var title := Label.new()
	title.text = "PhiTogether"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", UiTokens.TITLE_FONT)
	title.add_theme_color_override("font_color", UiTokens.text_on(UiTokens.bg(0)))
	col.add_child(title)

	var meta := Label.new()
	meta.text = "NeoButton · rest / hover / press / disabled"
	meta.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	meta.add_theme_font_size_override("font_size", UiTokens.META_FONT)
	var meta_col := UiTokens.text_on(UiTokens.bg(0))
	meta_col.a = 0.55  # 4.7 的 Color 没有 with_alpha()
	meta.add_theme_color_override("font_color", meta_col)
	col.add_child(meta)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 14)
	col.add_child(gap)

	_buttons = [_make_button(col, "开始游戏"), _make_button(col, "练习模式"), _make_button(col, "排行榜（禁用）")]
	_buttons[2].disabled = true  # NeoButton._ready 里会把整颗按钮淡到 DISABLED_ALPHA

	# 入场：错开的淡入 + 微缩放（不 tween position，避免和容器布局抢属性）。
	# Godot 4.7 的 Tween 没有 set_delay/delay_seconds，错峰用 SceneTree timer 实现。
	for idx in _buttons.size():
		var b: NeoButton = _buttons[idx]
		b.modulate.a = 0.0
		b.scale = Vector2(0.94, 0.94)
		var timer := get_tree().create_timer(UiTokens.ENTER_STAGGER * float(idx))
		timer.timeout.connect(_play_entrance.bind(b))

	for b in _buttons:
		b.pressed.connect(_on_pressed.bind(b))

func _play_entrance(b: NeoButton) -> void:
	var tw := b.create_tween()
	tw.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	tw.set_parallel(true)
	tw.tween_property(b, "scale", Vector2.ONE, 0.5)
	var target_alpha: float = UiTokens.DISABLED_ALPHA if b.disabled else 1.0
	tw.tween_property(b, "modulate:a", target_alpha, 0.5)

func _make_button(parent: VBoxContainer, caption: String) -> NeoButton:
	var b := NeoButton.new()
	b.text = caption  # 在 add_child 前赋值，_ready 会同步进内部 Label
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	parent.add_child(b)
	return b

func _on_pressed(b: NeoButton) -> void:
	print("NeoButton pressed: ", b.text)
