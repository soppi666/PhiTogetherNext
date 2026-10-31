class_name AvatarCircle
extends Control
## 头像：正圆形贴图。圆外像素烘成透明（SDF 覆盖率抗锯齿），同尺寸跨实例缓存。
## 经验/等级环已按用户 2026-10-27 的要求取消——经验改画在 Level 胶囊的底子上
## （PillProgress），头像这里只留一颗干净的圆。

@export var source: Texture2D

static var _cache: Dictionary = {}
var _tex: Texture2D
var _tex_key := ""

func _ready() -> void:
	# 不在这里写 mouse_filter：_ready 在 add_child 时才跑，会把调用方在 add_child **之前**
	# 设的 STOP 冲掉（头像正是靠那一次点击开登录卡片）。可点/穿透由使用方决定。
	if source == null:
		source = load("res://assets/avatar/akkarin.webp")  # 默认头像 = Akkarin 线稿（他提供）

## 换头像（PZ /me 的 avatar 到货）。必须走这里：烘好的圆贴图按"尺寸|源图"缓存，
## 直接赋 source 会命中旧缓存键，画出来还是原来那张。
func set_source(tex: Texture2D) -> void:
	if tex == null or tex == source:
		return
	source = tex
	_tex = null
	_tex_key = ""
	queue_redraw()

func _draw() -> void:
	var d := floorf(minf(size.x, size.y))
	if d < 4.0:
		return
	var tex := _bake(int(d))
	var off := (size - Vector2(d, d)) * 0.5
	draw_texture_rect(tex, Rect2(off, Vector2(d, d)), false)

func _bake(d: int) -> Texture2D:
	# 键必须能区分"哪一张源图"：运行时 ImageTexture（PZ 头像、远端曲绘）的 resource_path
	# 是空串，光按 path 键会把所有头像并成同一颗（默认线稿）。
	var sid: String = source.resource_path if source.resource_path != "" \
			else "id%d" % source.get_instance_id()
	var key := "av|%d|%s" % [d, sid]
	if key == _tex_key and _tex != null:
		return _tex
	if _cache.has(key):
		_tex = _cache[key]
		_tex_key = key
		return _tex
	var src := source.get_image()
	src.convert(Image.FORMAT_RGBA8)
	# 头像按 cover 方式裁成正方形再烘圆（4.7 crop 签名是 crop(x,y)，方形居中用 get_region）
	var s := mini(src.get_width(), src.get_height())
	src = src.get_region(Rect2i((src.get_width() - s) / 2, (src.get_height() - s) / 2, s, s))
	src.resize(d, d)
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var half := Vector2(d * 0.5, d * 0.5)
	for y in d:
		for x in d:
			# 圆角半径=半宽的圆角矩形 SDF 即圆形
			var cov: float = SongCard._sdf_coverage(Vector2(x + 0.5, y + 0.5), half, half.x)
			if cov <= 0.001:
				continue
			var c := src.get_pixel(x, y)
			c.a = cov
			img.set_pixel(x, y, c)
	_tex = ImageTexture.create_from_image(img)
	_tex_key = key
	_cache[key] = _tex
	return _tex
