class_name InfoBar
extends Panel
## 显示栏：左端胶囊（圆角=高度一半）、右端直角的不对称圆角面板。

var _sb: StyleBoxFlat

func _ready() -> void:
	_sb = StyleBoxFlat.new()
	_sb.bg_color = UiTokens.SURFACE_PANEL
	_sb.border_width_left = 2
	_sb.border_color = UiTokens.ACCENT
	_sb.shadow_color = UiTokens.SHADOW
	_sb.shadow_size = 8
	_sb.shadow_offset = Vector2(0, 4)
	add_theme_stylebox_override("panel", _sb)
	resized.connect(_apply_radius)
	_apply_radius()

func _apply_radius() -> void:
	var r := int(size.y * 0.5)
	_sb.corner_radius_top_left = r
	_sb.corner_radius_bottom_left = r
	_sb.corner_radius_top_right = 0
	_sb.corner_radius_bottom_right = 0
