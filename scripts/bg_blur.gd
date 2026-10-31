extends RefCounted
## 背景虚化烘焙（player 语义：ctx.filter blur(115·blur px)）。
## 舞台曲绘背景和主菜单/选曲/设置页的全局背景**共用这一条**，否则同一个"背景模糊"设置
## 在菜单里不生效、进谱面才糊，看起来像设置没保存。
##
## 流程：cover 裁剪尺寸 → 降到 560 宽 → GPU 可分离高斯级联（步长几何翻倍、方差相加）
##      → 放大 + 压暗 + ±1.25 级抖动（8bit 渐变不出现层纹）。
## 全部是**一次性**烘焙，结果贴到 TextureRect 上，运行时零开销。

## 一趟 GPU 模糊（或放大）。host 用来挂临时 SubViewport（必须在树里）。
static func gpu_pass(host: Node, tex: Texture2D, step_uv: Vector2, out_size := Vector2i(0, 0),
		shader_path := "res://shaders/blur_dir.gdshader", params := {}) -> Texture2D:
	var vp := SubViewport.new()
	vp.size = out_size if out_size.x > 0 else Vector2i(int(tex.get_width()), int(tex.get_height()))
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var m := ShaderMaterial.new()
	m.shader = load(shader_path)
	m.set_shader_parameter("step_uv", step_uv)
	for k in params.keys():
		m.set_shader_parameter(String(k), params[k])
	var tr := TextureRect.new()
	tr.texture = tex
	tr.material = m
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.size = Vector2(vp.size)
	vp.add_child(tr)
	host.add_child(vp)
	await RenderingServer.frame_post_draw
	var out_img: Image = vp.get_texture().get_image()
	vp.queue_free()
	if out_img == null or out_img.is_empty():
		return null
	return ImageTexture.create_from_image(out_img)

## 同步"近似糊"（纯 CPU、当帧可贴）。真烘焙要等 GPU 若干帧，开屏那一瞬会先看到清晰原图
## ——用户 2026-10-27 "一开始的背景模糊又没有了"。开屏先贴这张，bake() 到货后再替换。
## 降采样系数与舞台的 _cheap_blur_tex 用同一把尺子（115·blur·屏高/900 屏幕像素、/0.29、
## 钳到 [6, 短边]），两处"预览糊"才不会一个是另一个的两倍。
static func cheap_preview(src_img: Image, view_size: Vector2, blur: float) -> Image:
	if src_img == null or src_img.is_empty() or view_size.y <= 1.0 or blur <= 0.001:
		return null
	var img: Image = src_img.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	var ow := img.get_width()
	var oh := img.get_height()
	if ow < 8 or oh < 8:
		return null
	var scale: float = maxf(view_size.x / float(ow), view_size.y / float(oh))
	var rcov: float = 115.0 * blur * view_size.y / 900.0 / maxf(scale, 0.01)
	var f: float = clampf(rcov / 0.29, 6.0, float(mini(ow, oh)))
	img.resize(maxi(int(float(ow) / f), 3), maxi(int(float(oh) / f), 3), Image.INTERPOLATE_BILINEAR)
	img.resize(ow, oh, Image.INTERPOLATE_BILINEAR)
	return img

## src_img 必须已是 RGBA8（调用方负责 convert）。返回烘焙好的 RGBA8 Image，失败返回 null。
## view_size = 画面逻辑尺寸（决定"屏幕像素"的糊径与 cover 缩放）。
static func bake(host: Node, src_img: Image, view_size: Vector2, blur: float, lum: float) -> Image:
	if src_img == null or src_img.is_empty():
		return null
	if view_size.x <= 1.0 or view_size.y <= 1.0:
		return null
	var img: Image = src_img.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	var ow := img.get_width()
	var oh := img.get_height()
	if ow < 8 or oh < 8:
		return null
	var radius: float = 115.0 * maxf(blur, 0.0) * view_size.y / 900.0
	# 先把源图缩到"实际会被画出来的尺寸"（TextureRect 是 KEEP_ASPECT_COVERED，缩放比=max(屏/图)）。
	# 两件事同时被修好：① 糊径换算才是屏幕像素；② 显示时不再缩小采样（双线性缩小会把
	# 刚叠上去的抖动噪声平均掉，层纹回来）。
	var cover: float = maxf(view_size.x / float(ow), view_size.y / float(oh))
	if cover > 0.0 and absf(cover - 1.0) > 0.01:
		ow = maxi(int(ow * cover), 64)
		oh = maxi(int(oh * cover), 64)
		img.resize(ow, oh, Image.INTERPOLATE_BILINEAR)
	# 目标：浏览器 ctx.filter blur(R) = 高斯 σ=R px。降采样后 σ_small=R·ds，
	# 下面用"步长几何翻倍"的可分离高斯级联把 σ 累到 σ_small（方差相加）。
	var ds: float = clampf(560.0 / float(ow), 0.05, 1.0)
	var sw: int = maxi(int(ow * ds), 16)
	var sh: int = maxi(int(oh * ds), 16)
	img.resize(sw, sh, Image.INTERPOLATE_BILINEAR)
	var cur: Texture2D = ImageTexture.create_from_image(img)
	var r_small: float = maxf(radius * ds, 2.0)
	var k := 2.0
	var sig := 0.0
	var passes := 0
	while sig < r_small - 0.5 and k < maxf(float(sw), float(sh)) * 0.25 and passes < 24:
		# 最后一程按"还差多少"给步长，不许翻倍翻过头（σ 目标 36 冲到 62 就是"背景比 PT 糊"）
		var k_step := minf(k, sqrt(maxf(r_small * r_small - sig * sig, 1.0)) / 1.69)
		passes += 1
		cur = await gpu_pass(host, cur, Vector2(k_step / cur.get_width(), 0.0))
		if cur == null:
			print("QA-BLUR aborted at pass ", passes * 2 - 1)
			return null
		passes += 1
		cur = await gpu_pass(host, cur, Vector2(0.0, k_step / cur.get_height()))
		if cur == null:
			print("QA-BLUR aborted at pass ", passes)
			return null
		sig = sqrt(sig * sig + pow(1.69 * k_step, 2.0))
		k *= 2.0
	# 最后一级：放大 + 把压暗(lum)烘进去 + 叠 ±1.25 级噪声。
	# 压暗必须在像素里做：8bit 下 modulate 乘 0.5 会把相邻两级并成一级，渐变台阶翻倍。
	var l := clampf(lum, 0.05, 1.0)
	cur = await gpu_pass(host, cur, Vector2.ZERO, Vector2i(ow, oh),
			"res://shaders/dither.gdshader", { "lum": l })
	if cur == null:
		print("QA-BLUR aborted at upscale")
		return null
	var bimg := cur.get_image()
	if bimg == null:
		return null
	bimg.convert(Image.FORMAT_RGBA8)
	print("QA-BLUR baked passes=", passes, " sigma=", int(sig), " target=", int(r_small),
		" small=", sw, "x", sh, " r=", int(radius))
	return bimg
