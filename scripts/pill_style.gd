class_name PillStyle
extends RefCounted
## 抗锯齿圆角样式盒（9-slice 烘纹理）。
##
## 为什么要烘一张纹理：StyleBoxFlat 的圆角是 canvas 三角填充，**边缘不做抗锯齿**，
## 半径 14 的胶囊两端就是看得见的台阶（用户 2026-10-28："曲库下面的输入框还有毛刺"）。
## 这里按"左右两个圆角端 + 中间 1px 直边"烘成 9-slice 纹理交给 StyleBoxTexture：
## 中间那列只横向拉伸，两端保持原始像素 ⇒ 任意宽度都不糊、不裂、不变形。
## 圆角逐像素用和封面/头像同一套 SDF 覆盖率（SongCard._sdf_coverage）。
##
## 注意 alpha：覆盖率只能**乘**在颜色自己的 alpha 上（c.a *= cov）。写成 c.a = cov
## 会把半透明底变成不透明，登录卡片那四个角就是这么糊出来的。
##
## 超采样（SS）：SDF 的抗锯齿过渡带只有 1 个**纹理像素**，"烘多少画多少"时会被画布的
## 分数缩放（本项目 canvas_items+expand，平板实测 k=1.78）二次插值成 2~3 屏幕像素的软边
## （用户 2026-10-30："滑动条圆角好模糊，数字的也很模糊"）。烘 SS 倍、让 StyleBox 把
## 纹理压回绘制尺寸，双线性下采样正好把过渡带压回一个屏幕像素。
## ⚠ 三个量必须一起动：烘焙尺寸（×SS）、帽在纹理里的宽度（rr×SS）、texture_margin（=rr×SS）。
## 只改烘焙不改 margin ⇒ 9-slice 切到半个圆弧、另半弧被横向拉伸，圆角变怪、描边一圈
## 粗细不匀（用户同一轮："边框变成一个奇怪的形状，它根本就不是一个均匀的粗细了"）。

static var _cache := {}

const SS := 2

## ── 路①：StyleBoxTexture 9-slice（只能 1× 烘焙）──────────────────────
## ⚠ 这条路**不能超采样**：9-slice 的两端帽在绘制时是 1:1 的，缩不了。
## 烘 2× 再把 margin 写 rr×SS ⇒ 帽按 28 绘制像素画（本该 14），环在左右比上下粗一倍；
## margin 写 rr ⇒ 只切到半个圆弧、另半弧被横向拉伸，圆角变怪。两种错用户都抓过
## （"边框变成一个奇怪的形状，它根本就不是一个均匀的粗细了"）。
## 要实的圆角用路②（Pill/draw_pill）。这条路留给需要"主题样式盒"的控件（搜索药丸等）。
static func stylebox(h: float, r: float, fill: Color, bw: int = 0,
		border: Color = Color(0, 0, 0, 0)) -> StyleBoxTexture:
	var hh := maxi(int(ceil(h)), 2)
	var rr := clampi(int(r), 0, int(hh / 2))
	var b := clampi(bw, 0, rr)
	var key := "%d|%d|%d|%s|%s" % [hh, rr, b, fill.to_html(true), border.to_html(true)]
	var tex: Texture2D = _cache.get(key, null)
	if tex == null:
		tex = _bake(hh, rr, b, fill, border, false)
		_cache[key] = tex
	var st := StyleBoxTexture.new()
	st.texture = tex
	st.texture_margin_left = rr
	st.texture_margin_right = rr
	st.texture_margin_top = 0
	st.texture_margin_bottom = 0
	st.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	st.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	# ⚠ StyleBoxTexture 的 content margin 默认是 **-1＝"跟着 texture margin 走"**，
	# 直接交给 LineEdit 会把文字可用宽吃掉两道帽 ⇒ 末尾的字不画（"63 ms"→"63 m"）。
	st.content_margin_left = 0.0
	st.content_margin_right = 0.0
	st.content_margin_top = 0.0
	st.content_margin_bottom = 0.0
	return st

## 只圆**左端**两角的胶囊段（1×，同上路）。进度填充现在走路②，这个留给别处。
static func stylebox_left(h: float, r: float, fill: Color) -> StyleBoxTexture:
	var hh := maxi(int(ceil(h)), 2)
	var rr := clampi(int(r), 0, int(hh / 2))
	var key := "L|%d|%d|%s" % [hh, rr, fill.to_html(true)]
	var tex: Texture2D = _cache.get(key, null)
	if tex == null:
		tex = _bake(hh, rr, 0, fill, Color(0, 0, 0, 0), true)
		_cache[key] = tex
	var st := StyleBoxTexture.new()
	st.texture = tex
	st.texture_margin_left = rr
	st.texture_margin_right = 1
	st.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	st.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	st.content_margin_left = 0.0
	st.content_margin_right = 0.0
	st.content_margin_top = 0.0
	st.content_margin_bottom = 0.0
	return st

## ── 路②：2× 烘焙 + 绘制时把帽缩回 1×（滑条槽/芯、数值底板用这条）────────
## 装饰胶囊控件：纯画、不吃输入。
class Pill extends Control:
	## 圆角半径（绘制像素）；<0 时取 高×radius_frac（0.5=正胶囊）
	var radius := -1.0
	var radius_frac := 0.5
	var fill := Color(0, 0, 0, 0.35)
	var border_w := 0
	var border := Color(0, 0, 0, 0)
	## 右端切直角（进度芯：右端顶在滑块左沿，不露半圆弧）
	var square_right := false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := radius if radius >= 0.0 else size.y * radius_frac
		PillStyle.draw_pill(self, Rect2(Vector2.ZERO, size), r, fill, border_w, border, square_right)

## 三段 blit：左帽 **rr 绘制像素 ← rr×SS 纹理像素**（画布替我们做 2× 下采样，
## SDF 那 1px 过渡带被压回一个屏幕像素 ⇒ 分数缩放下也是实的），中列横向拉伸，
## 右帽同理；square_right 时右端就是中列的直边。
static func draw_pill(ci: CanvasItem, rect: Rect2, r: float, fill: Color,
		bw: int = 0, border: Color = Color(0, 0, 0, 0), square_right := false) -> void:
	var h := rect.size.y
	if h < 2.0 or rect.size.x < 1.0:
		return
	var hh := maxi(int(ceil(h)), 2)
	var rr := clampi(int(r), 0, int(hh / 2))
	var b := clampi(bw, 0, rr)
	var tex: Texture2D = _tex_ss(hh, rr, b, fill, border, square_right)
	var th := float(tex.get_height())
	var tw := float(tex.get_width())
	var cap_dst := float(rr)
	var cap_src := float(rr) * SS
	if cap_dst > 0.5:
		ci.draw_texture_rect_region(tex,
				Rect2(rect.position.x, rect.position.y, cap_dst, h),
				Rect2(0.0, 0.0, cap_src, th))
	var mid_dst_w := rect.size.x - cap_dst - (cap_dst if not square_right else 0.0)
	if mid_dst_w > 0.5:
		ci.draw_texture_rect_region(tex,
				Rect2(rect.position.x + cap_dst, rect.position.y, mid_dst_w, h),
				Rect2(cap_src, 0.0, float(SS), th))
	if not square_right and cap_dst > 0.5:
		ci.draw_texture_rect_region(tex,
				Rect2(rect.end.x - cap_dst, rect.position.y, cap_dst, h),
				Rect2(tw - cap_src, 0.0, cap_src, th))

static func _tex_ss(hh: int, rr: int, b: int, fill: Color, border: Color,
		square_right: bool) -> Texture2D:
	var key := "P|%d|%d|%d|%s|%s|%s" % [hh, rr, b, fill.to_html(true), border.to_html(true), square_right]
	var tex: Texture2D = _cache.get(key, null)
	if tex == null:
		tex = _bake(hh * SS, rr * SS, b * SS, fill, border, square_right)
		_cache[key] = tex
	return tex

## 烘焙：宽 = 左帽(rr×SS) + 中列(SS) + [右帽(rr×SS)]。
## square_right=true 时矩形向右"虚拟无限延伸"：右端两角根本不进图，边是直的。
static func _bake(hh: int, rr: int, b: int, fill: Color, border: Color, square_right: bool) -> Texture2D:
	var cap := rr * SS
	var w := cap + SS + (cap if not square_right else 0)
	w = maxi(w, 2)
	var img := Image.create(w, hh, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	# 虚拟宽度：square_right 时把矩形右端推到图外，SDF 就只圆左边两个角
	var vw := w + (rr * 8 + 64 if square_right else 0)
	if b > 0:
		_paint(img, Rect2i(0, 0, vw, hh), rr, border, square_right)
	_paint(img, Rect2i(b, b, vw - b * (2 if not square_right else 1), hh - b * 2),
			maxi(rr - b, 0), fill, square_right)
	return ImageTexture.create_from_image(img)

## 在 img 上画一个"左上角对齐 rect"的圆角矩形；square_right 时只画左边两个角块，
## 直边带裁到图内（虚拟延伸的部分不落像素）
static func _paint(img: Image, rect: Rect2i, r: int, col: Color, square_right: bool) -> void:
	if rect.size.x < 2 or rect.size.y < 2:
		return
	var bounds := Rect2i(0, 0, img.get_width(), img.get_height())
	var half := Vector2(rect.size.x * 0.5, rect.size.y * 0.5)
	var right_inset := r * (2 if not square_right else 1)
	var mid := Rect2i(rect.position.x + r, rect.position.y, rect.size.x - right_inset, rect.size.y)
	var inter := mid.intersection(bounds)
	if inter.size.x > 0 and inter.size.y > 0:
		img.fill_rect(inter, col)
	var vert := Rect2i(rect.position.x, rect.position.y + r, rect.size.x, rect.size.y - r * 2)
	inter = vert.intersection(bounds)
	if inter.size.x > 0 and inter.size.y > 0:
		img.fill_rect(inter, col)
	if r <= 0:
		return
	var nx := 1 if square_right else 2
	for cy in 2:
		for cx in nx:
			var x0: int = rect.position.x + cx * (rect.size.x - r)
			var y0: int = rect.position.y + cy * (rect.size.y - r)
			for y in r:
				for x in r:
					var px := x0 + x
					var py := y0 + y
					if px < 0 or py < 0 or px >= bounds.size.x or py >= bounds.size.y:
						continue
					# ⚠ p 要落在**整个矩形的左上系**（和 half=rect.size/2 配对），
					# 不是角块自己的局部系——写错时四个角块各自只在自己左上有弧，
					# 渲出来是喇叭口/狗耳朵（2026-10-30 实渲抓过一轮）。
					var p := Vector2(float(px) + 0.5 - rect.position.x,
							float(py) + 0.5 - rect.position.y)
					var cov: float = SongCard._sdf_coverage(p, half, r)
					if cov <= 0.001:
						continue
					var c := col
					c.a *= cov
					img.set_pixel(px, py, c)
