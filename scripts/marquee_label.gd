class_name MarqueeLabel
extends Control
## 超宽文字无缝跑马灯：文本 + 尾部留空 + 再一份文本 连续滚动，
## 滚完不回跳——第二份接在空档后滚入，形成循环。仅在文本超出时由 SongCard 显示。

@export var speed: float = 30.0  # 滚动速度 px/s（主观旋钮）

var text := ""
var font_size := 16
var col := Color.WHITE

var _phase := 0.0

func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_content(t: String, fs: int, c: Color) -> void:
	fs = maxi(fs, 1)   # 0 号字会让 TextServer 每帧报 _ensure_cache_for_size
	if t == text and fs == font_size and c == col:
		return
	text = t
	font_size = fs
	col = c
	_phase = 0.0
	queue_redraw()

func _gap() -> float:
	return font_size * 4.0  # 尾部留空约四个字宽再接开头

func _loop_len(tw: float) -> float:
	return tw + _gap()

func _process(delta: float) -> void:
	var tw: float = _text_w()
	if tw <= size.x:
		return
	_phase = fmod(_phase + delta * speed, _loop_len(tw))
	queue_redraw()

func _text_w() -> float:
	if font_size <= 0:
		return 0.0
	return ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

func _draw() -> void:
	if font_size <= 0:
		return
	var f := ThemeDB.fallback_font
	var asc: float = f.get_ascent(font_size)
	var base_y: float = (size.y + asc) * 0.5
	var tw: float = _text_w()
	f.draw_string(get_canvas_item(), Vector2(-_phase, base_y), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
	if tw > size.x:
		# 第二份：滚完第一段后从空档右侧无缝续上
		f.draw_string(get_canvas_item(), Vector2(-_phase + _loop_len(tw), base_y), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
