class_name ScrollSpark
extends Control
## 曲库滚动指示：实心竖条（屏宽 1%）被一个 4% 宽高正菱形切开——上下两段条在
## 切口处自然收成朝外的三角尖；洞里浮一个 3% 正菱形。白色，透明度从边缘向内
## 走一半即达 100%（外半线性渐亮、内半全不透明）。整体随滚动上下移动。

var progress := 0.0
var rail_x := 0.0
var rail_top := 0.0
var rail_h := 0.0
var zone_top := 0.0
var zone_h := 0.0
var bar_w := 14.0
var cut_w := 28.0
var dia_w := 21.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_scroll(p: float) -> void:
	var v := clampf(p, 0.0, 1.0)
	if absf(v - progress) < 0.0005:
		return
	progress = v
	queue_redraw()

func _draw() -> void:
	if rail_h <= 0.0:
		return
	var r := cut_w * 0.5
	var half := r + cut_w * 0.15
	var zt := zone_top if zone_h > 0.0 else rail_top
	var zh := zone_h if zone_h > 0.0 else rail_h
	var cy := zt + half + progress * maxf(zh - half * 2.0, 0.0)
	var bw := bar_w * 0.5
	var yv := r - bw  # 菱形边与条侧相交处
	var edge := Color(1.0, 1.0, 1.0, 0.0)
	var mid := Color(1.0, 1.0, 1.0, 1.0)
	var y_top := rail_top
	var y_bot := rail_top + rail_h
	# 四块条：外缘 alpha 0 → 半宽处 alpha 1 → 中心线仍 1（内半全不透明）
	for sgn in [-1.0, 1.0]:
		var ox: float = rail_x + sgn * bw
		var mx: float = rail_x + sgn * bw * 0.5
		var yu := cy - (r + yv) * 0.5
		var yd := cy + (r + yv) * 0.5
		draw_polygon(PackedVector2Array([
			Vector2(ox, y_top), Vector2(mx, y_top), Vector2(rail_x, y_top),
			Vector2(rail_x, cy - r), Vector2(mx, yu), Vector2(ox, cy - yv),
		]), PackedColorArray([edge, mid, mid, mid, mid, edge]))
		draw_polygon(PackedVector2Array([
			Vector2(ox, y_bot), Vector2(mx, y_bot), Vector2(rail_x, y_bot),
			Vector2(rail_x, cy + r), Vector2(mx, yd), Vector2(ox, cy + yv),
		]), PackedColorArray([edge, mid, mid, mid, mid, edge]))
	# 洞里的菱形：内半（50% 缩进）全不透明，外环边缘渐隐到 0
	var dh := dia_w * 0.5
	var tips := PackedVector2Array([
		Vector2(rail_x, cy - dh), Vector2(rail_x + dh, cy),
		Vector2(rail_x, cy + dh), Vector2(rail_x - dh, cy),
	])
	var mids := PackedVector2Array([
		Vector2(rail_x, cy - dh * 0.5), Vector2(rail_x + dh * 0.5, cy),
		Vector2(rail_x, cy + dh * 0.5), Vector2(rail_x - dh * 0.5, cy),
	])
	draw_polygon(mids, PackedColorArray([mid, mid, mid, mid]))
	for i in 4:
		draw_polygon(PackedVector2Array([mids[i], tips[i], tips[(i + 1) % 4], mids[(i + 1) % 4]]),
			PackedColorArray([mid, edge, edge, mid]))
