class_name BgDeco
extends Control
## 极淡背景装饰：从封面提取的几何斜线。透明度压到 3–5%，不喧宾夺主。

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)

func _draw() -> void:
	var s := size
	if s.x < 2.0:
		return
	var line := Color(UiTokens.ACCENT.r, UiTokens.ACCENT.g, UiTokens.ACCENT.b, 0.05)
	draw_line(Vector2(s.x * 0.52, 0), Vector2(s.x * 0.84, s.y), line, s.y * 0.004)
	draw_line(Vector2(s.x * 0.66, 0), Vector2(s.x * 0.98, s.y), Color(line.r, line.g, line.b, 0.035), s.y * 0.002)
	draw_line(Vector2(0, s.y * 0.72), Vector2(s.x * 0.34, s.y), Color(line.r, line.g, line.b, 0.03), s.y * 0.002)
	# Φ 大字水印按用户 2026-10-28 的要求去掉：主菜单背景上那个巨大的 Φ 一眼就能看见，
	# "极淡"只是我以为。斜线那三根留着（它们不成字，不会被读成"水印"）。
