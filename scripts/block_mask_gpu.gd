class_name BlockMaskGPU
extends RefCounted
## 噪域（BlockArea）掩码的 GPU 版。
##
## CPU 那份 `ChartPlayer::build_block_mask()` 是逐格扫的（像素数 × 区数），2560×1600 全屏
## 100+ 个区要 ~13ms/帧。这里把 zone 的铺块 + 位移 + 膨胀搬到 GPU，掩码每帧读回成普通贴图
## 交给 block_area 材质（读回的是上一帧，滞后一帧，位移看不出差别）。
##
## 几何：**不用 get_block_quads()**（它的四角在 RPE 标记谱上不是画布坐标，会跑到画布外），
## 而是拿 `debug_blocks()` 的 center/half/rot/ys —— 那正是 CPU 栅格 `bm_raster_rows` 用的
## 同一套归一化几何，按它的映射换算成网格像素：
##     col = (wx + 1) * 0.5 * bw
##     row = (wy * aspect + 1) * 0.5 * bh        (aspect = canvas.x / canvas.y)
##
## ⚠ SubViewport 贴图是**预乘 alpha**：掩码/aux 的 alpha 必须恒 1，否则 a=0 的格子 RGB
##   会被乘成 0（整张掩码读回全黑）。

const SHADER := "res://shaders/block_mask_gpu.gdshader"

var grid := Vector2i(1, 1)
var cell := 4.0
var canvas := Vector2(1, 1)
var zone: SubViewport
var final: SubViewport
var aux: SubViewport
var mask_tex: ImageTexture
var aux_tex: ImageTexture

var _zone_layer: Node2D
var _pool: Array = []
var _pool_pts: Array = []
var _m_add: CanvasItemMaterial
var _m_final: ShaderMaterial
var _m_aux: ShaderMaterial
var _noise: Texture2D
var _dbg := false
var _dbg_n := 0


func setup(host: Node, canvas_size: Vector2, cell_px: float, noise: Texture2D, warp_amp: float) -> bool:
	cell = maxf(cell_px, 1.0)
	canvas = canvas_size
	grid = Vector2i(maxi(int(round(canvas.x / cell)), 1), maxi(int(round(canvas.y / cell)), 1))
	_noise = noise
	_dbg = OS.get_environment("BLOCK_GPU_DBG") != ""
	var sh: Shader = load(SHADER)
	if sh == null:
		return false
	zone = _mk_vp(host, "zone")
	_zone_layer = Node2D.new()
	zone.add_child(_zone_layer)          # 多边形直接用网格像素坐标
	_m_add = CanvasItemMaterial.new()
	_m_add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	final = _mk_vp(host, "final")
	aux = _mk_vp(host, "aux")
	_m_final = _mk_pass(final, sh, 0)
	_m_aux = _mk_pass(aux, sh, 1)
	var blank := Image.create(grid.x, grid.y, false, Image.FORMAT_RGBA8)
	mask_tex = ImageTexture.create_from_image(blank)
	aux_tex = ImageTexture.create_from_image(blank)
	_sync()
	set_warp(warp_amp)
	return true


func _mk_vp(host: Node, nm: String) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = "blkmask_" + nm
	vp.size = grid
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(vp)
	return vp


func _mk_pass(vp: SubViewport, sh: Shader, pass_id: int) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("uPass", pass_id)
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, 1)
	r.size = Vector2(grid)
	r.material = m
	vp.add_child(r)
	return m


func _sync() -> void:
	for m in [_m_final, _m_aux]:
		if m == null:
			continue
		m.set_shader_parameter("uGrid", Vector2(grid))
		m.set_shader_parameter("uZone", zone.get_texture())
		if _noise != null:
			m.set_shader_parameter("uNoise", _noise)
			m.set_shader_parameter("uNoiseSize", Vector2(_noise.get_width(), _noise.get_height()))


func set_warp(amp: float) -> void:
	if _m_final != null:
		_m_final.set_shader_parameter("uWarp", amp)


func _grab() -> void:
	var im: Image = final.get_texture().get_image()
	if im != null:
		im.convert(Image.FORMAT_RGBA8)
		if mask_tex.get_width() != im.get_width() or mask_tex.get_height() != im.get_height():
			mask_tex = ImageTexture.create_from_image(im)
		else:
			mask_tex.update(im)
	var ai: Image = aux.get_texture().get_image()
	if ai != null:
		ai.convert(Image.FORMAT_RGBA8)
		if aux_tex.get_width() != ai.get_width() or aux_tex.get_height() != ai.get_height():
			aux_tex = ImageTexture.create_from_image(ai)
		else:
			aux_tex.update(ai)


## CPU 栅格同一套几何 → 网格像素四角
static func _corners(c: Vector2, h: Vector2, rot_deg: float, ys: float, aspect: float,
		g: Vector2i) -> PackedVector2Array:
	var rad := deg_to_rad(rot_deg)
	var cc := cos(rad)
	var ss := sin(rad)
	var out := PackedVector2Array()
	out.resize(4)
	var lxs := [-h.x, h.x, h.x, -h.x]
	var lys := [-h.y, -h.y, h.y, h.y]
	for k in 4:
		var wx: float = c.x + cc * lxs[k] - ss * lys[k]
		var wy: float = c.y + (ss * lxs[k] + cc * lys[k]) * ys
		out[k] = Vector2((wx + 1.0) * 0.5 * float(g.x), (wy * aspect + 1.0) * 0.5 * float(g.y))
	return out


## 每帧：blocks = ChartPlayer.debug_blocks(t)（含 center/half/rot/ys/phase/alpha）
## 返回 false = 这一帧 GPU 路径表达不了（有 ready 区 / 手指按着），调用方回退 CPU。
func update(blocks: Array, music: float, hover_on: bool) -> bool:
	if hover_on:
		return false
	var aspect := canvas.x / maxf(canvas.y, 1.0)
	_grab()   # 读回上一帧
	var n := blocks.size()
	while _pool.size() < n:
		var p := Polygon2D.new()
		p.material = _m_add
		p.antialiased = false
		p.visible = false
		_zone_layer.add_child(p)
		_pool.append(p)
		_pool_pts.append(PackedVector2Array())
	var used := 0
	for bi in n:
		var d: Dictionary = blocks[bi]
		var ph := int(d["phase"])
		var a := float(d["alpha"])
		if ph == 0 or a <= 0.0:
			continue
		if bool(d.get("ready", false)):
			return false
		var h: Vector2 = d["half"]
		if h.x <= 0.0 or h.y <= 0.0:
			continue
		var c: Vector2 = d["center"]
		var pts := _corners(c, h, float(d["rot"]), float(d["ys"]), aspect, grid)
		# 完全在网格外的跳过
		var minx := minf(minf(pts[0].x, pts[1].x), minf(pts[2].x, pts[3].x))
		var maxx := maxf(maxf(pts[0].x, pts[1].x), maxf(pts[2].x, pts[3].x))
		var miny := minf(minf(pts[0].y, pts[1].y), minf(pts[2].y, pts[3].y))
		var maxy := maxf(maxf(pts[0].y, pts[1].y), maxf(pts[2].y, pts[3].y))
		if maxx < 0.0 or minx > float(grid.x) or maxy < 0.0 or miny > float(grid.y):
			continue
		var poly: Polygon2D = _pool[used]
		var arr: PackedVector2Array = _pool_pts[used]
		if arr.size() != 4:
			arr.resize(4)
		for k in 4:
			arr[k] = pts[k]
		poly.polygon = arr
		_pool_pts[used] = arr
		var sub := bool(d.get("sub", false))
		# 加法混合：只往自己那个通道里加；alpha 恒 1（否则 Godot 会再乘一次）
		# CPU 的减算区固定叠 0.1（不看 opacity），这里必须一致，否则 sub 阈值门会错
		if ph == 2:
			poly.color = Color(0.0, 0.1, 0.0, 1.0) if sub else Color(a, 0.0, 0.0, 1.0)
		else:
			poly.color = Color(0.0, 0.0, 0.0, 0.1) if sub else Color(0.0, 0.0, a, 1.0)
		if not poly.visible:
			poly.visible = true
		used += 1
	for i in range(used, _pool.size()):
		var pl: Polygon2D = _pool[i]
		if pl.visible:
			pl.visible = false
	_dbg_n += 1
	if _dbg:
		var area := 0.0
		for i2 in used:
			var pp: PackedVector2Array = _pool_pts[i2]
			var w := 0.0
			for k2 in 4:
				var q2 := (k2 + 1) % 4
				w += pp[k2].x * pp[q2].y - pp[q2].x * pp[k2].y
			area += absf(w) * 0.5
		# zone / 掩码覆盖率：读回一次
		var cov := -1.0
		var covg := -1.0
		var covm := -1.0
		var only_sub := -1
		var zi: Image = zone.get_texture().get_image()
		if zi != null:
			zi.convert(Image.FORMAT_RGBA8)
			var hit := 0
			var w2 := zi.get_width()
			var h2 := zi.get_height()
			for y2 in range(0, h2, 4):
				for x2 in range(0, w2, 4):
					if zi.get_pixel(x2, y2).r > 0.1:
						hit += 1
			cov = 100.0 * float(hit) / float(maxi((h2 + 3) / 4, 1) * maxi((w2 + 3) / 4, 1))
			var hitg := 0
			for y3 in range(0, h2, 4):
				for x3 in range(0, w2, 4):
					if zi.get_pixel(x3, y3).g > 0.01:
						hitg += 1
			covg = 100.0 * float(hitg) / float(maxi((h2 + 3) / 4, 1) * maxi((w2 + 3) / 4, 1))
			var mi: Image = final.get_texture().get_image()
			if mi != null:
				mi.convert(Image.FORMAT_RGBA8)
				var hitm := 0
				var os := 0
				for y4 in range(0, h2, 4):
					for x4 in range(0, w2, 4):
						if mi.get_pixel(x4, y4).r > 0.1:
							hitm += 1
							if zi.get_pixel(x4, y4).r < 0.04:
								os += 1
				covm = 100.0 * float(hitm) / float(maxi((h2 + 3) / 4, 1) * maxi((w2 + 3) / 4, 1))
				only_sub = os
		print("QA-BMGPOLY 区=", used, "/", blocks.size(), " 网格=", grid,
				" 多边形面积/网格=", "%.2f" % (area / float(maxi(grid.x * grid.y, 1))),
				" zoneR=", "%.1f%%" % cov, " zoneG=", "%.1f%%" % covg,
				" 掩码R=", "%.1f%%" % covm, " 只有减算=", only_sub,
				" q0=", _pool_pts[0] if used > 0 else "none",
				" c0=", (blocks[0] as Dictionary).get("center") if blocks.size() > 0 else "?",
				" half0=", (blocks[0] as Dictionary).get("half") if blocks.size() > 0 else "?")
	if _m_final != null:
		_m_final.set_shader_parameter("uNoiseT", music)
		_m_final.set_shader_parameter("uGrid", Vector2(grid))
	_sync()
	return true


func teardown() -> void:
	for v in [zone, final, aux]:
		if v != null and is_instance_valid(v):
			v.queue_free()
	zone = null
	final = null
	aux = null
	_pool.clear()
	_pool_pts.clear()
	_zone_layer = null
	_m_final = null
	_m_aux = null
