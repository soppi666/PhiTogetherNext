class_name NoiseSkinRenderer
extends RefCounted
## 噪域层皮肤渲染管线（协议 = rpe-next src/core/noise-skin.mjs + src/ui/noise-skin-renderer.mjs）
## 目录结构（<skin_dir> 见 find_skin_dir）：
##   main.glsl      ：主 pass（也是参数/default 的声明处，见 `// %...%` 与 `uniform ... // @texture path`）
##   config.json    ：{version:1, author?, targets:{name:{format,filter,scaleX,scaleY,noClear}},
##                     passes:[{shader,inputs,constants,output}], lowPerformance?}
##   *.glsl / 图片  ：pass 引用的着色器与贴图
## 运行时自动 uniform：screenTexture/blockMask/screenSize/targetSize/targetTexelSize/time/
##   touchCount/touchPoints；input/target/贴图各自的 <name>Size。
## 说明：Godot 的 canvas SubViewport 会用 MIX 混合写入（存成预乘），所以读回一层时统一
##   `ns_read()` 反预乘；最终回贴用预乘混合材质。component 写入（目标只写某通道）由临时
##   视口 + 混合着色器实现（= WebGL colorMask）。

const MAX_TEXTURES := 32
const TOUCH_SLOTS := 32

var ok := false
var error := ""
var root := ""
var dir := ""
var params_def: Array = []      # [{name,type,value}]
var textures_def: Array = []    # [{name,path,wrap,filter,colorspace,alphaMode}]
var targets_def := {}           # name -> {format,filter,scaleX,scaleY,noClear}
var passes: Array = []          # [{shader,inputs,constants,output,component}]

var _node: Node = null
var _sizes := Vector2i.ZERO
var _copy_sv: SubViewport = null
var _pass_sv: Array = []        # 每个 pass 一个输出视口（按 pass 顺序入树）
var _pass_tmp: Array = []       # component pass 的临时全 RGBA 输出（与其输出视口同尺寸）
var _normal_def := {}
var _low_def := {}
var _channel := "normal"
var straight := false             # 有 component 写入的皮肤：全程直通 alpha 存储（见 _gdshader）
var _pass_mats := {}            # "sv_key" -> {sv, cr, mat, code}
var _images := {}
var _codes := {}                # rel path -> gdshader code
var _uniforms := {}             # rel path -> Array[String]
var _warned_component := false


static func find_skin_dir(skin_path: String, chart_dir: String) -> String:
	var nm := skin_path.strip_edges().replace("\\", "/")
	if nm.begins_with("shader/"):
		nm = nm.substr(7)
	nm = nm.get_file()
	var cands := [
		chart_dir.path_join("noise").path_join(nm),
		"user://noise_skins".path_join(nm),
		"res://assets/noise_skins".path_join(nm),
	]
	for c in cands:
		if FileAccess.file_exists(c.path_join("main.glsl")):
			return c
	return ""


func load_skin(skin_path: String, chart_dir: String) -> bool:
	dir = find_skin_dir(skin_path, chart_dir)
	if dir == "":
		error = "找不到皮肤目录：%s" % skin_path
		return false
	var cfg_txt := _read(dir.path_join("config.json"))
	var main_src := _read(dir.path_join("main.glsl"))
	if main_src == "":
		error = "缺少 main.glsl"
		return false
	var cfg := {}
	if cfg_txt != "":
		var v: Variant = JSON.parse_string(cfg_txt)
		if v is Dictionary:
			cfg = v
	if int(cfg.get("version", 1)) != 1:
		error = "只支持 version=1"
		return false
	# 参数：uniform <type> <name>; // %默认,...%  （main.glsl 里）
	var rx_param := RegEx.create_from_string("uniform\\s+(float|vec2|vec4)\\s+(\\w+)\\s*;[^\\n]*?//\\s*%([^%\\n]+)%")
	for m in rx_param.search_all(main_src):
		var ty := m.get_string(1)
		var nm := m.get_string(2)
		var vals: PackedStringArray = m.get_string(3).split(",")
		var value: Variant = float(vals[0].strip_edges()) if ty == "float" else []
		if ty != "float":
			var arr: Array = []
			for x in vals:
				arr.append(float(x.strip_edges()))
			value = arr
		params_def.append({"name": nm, "type": ty, "value": value})
	# 贴图：uniform sampler2D <name>; // @texture <path> [wrap=..] [filter=..] ...
	var rx_tex := RegEx.create_from_string("uniform\\s+sampler2D\\s+(\\w+)\\s*;[^\\n]*?//\\s*@texture\\s+(\\S+)([^\\n]*)")
	for m in rx_tex.search_all(main_src):
		var t := {"name": m.get_string(1), "path": m.get_string(2), "wrap": "clamp", "filter": "linear",
			"colorspace": "linear", "alphaMode": "straight"}
		for opt in m.get_string(3).strip_edges().split(" ", false):
			var kv := opt.split("=")
			if kv.size() == 2 and t.has(kv[0]):
				t[kv[0]] = kv[1]
		textures_def.append(t)
	# targets / passes（normal + 可选的 lowPerformance 通道）
	_normal_def = _parse_channel(cfg)
	var low: Variant = cfg.get("lowPerformance", null)
	if low is Dictionary:
		_low_def = _parse_channel(low)
		if (_low_def["targets"] as Dictionary).is_empty():
			_low_def["targets"] = _normal_def["targets"]  # low 只写 passes 时沿用顶层 targets
	straight = false
	for d0 in [_normal_def, _low_def]:
		if d0.is_empty():
			continue
		for p0 in d0["passes"]:
			if String(p0.get("component", "")) != "":
				straight = true
	set_channel(_channel)
	# 预编译两个通道用到的全部 pass 着色器
	var seen := {}
	for d in [_normal_def, _low_def]:
		if d.is_empty():
			continue
		for p in d["passes"]:
			var sh: String = String(p["shader"])
			if seen.has(sh):
				continue
			seen[sh] = true
			var src := _read(dir.path_join(sh))
			if src == "":
				error = "缺少 pass 着色器：" + sh
				return false
			var code := _gdshader(src)
			if code == "":
				error = "无法转译：" + sh
				return false
			_codes[sh] = code
	ok = true
	return true


func _parse_channel(c: Dictionary) -> Dictionary:
	var ps: Array = []
	for p in c.get("passes", []):
		if not (p is Dictionary) or not p.has("output"):
			continue
		var outp := String(p["output"])
		var comp := ""
		if outp.contains("."):
			comp = outp.get_slice(".", 1)
			if not "rgba".contains(comp) or comp.length() != 1:
				comp = ""
		ps.append({
			"shader": String(p.get("shader", "main.glsl")),
			"inputs": p.get("inputs", {}),
			"constants": p.get("constants", {}),
			"output": outp,
			"component": comp,
		})
	return {"targets": c.get("targets", {}), "passes": ps}


func set_channel(ch: String) -> void:
	_channel = ch
	var d := _low_def if (ch == "low" and not _low_def.is_empty()) else _normal_def
	if d.is_empty():
		d = _normal_def
	if d.is_empty():
		return
	targets_def = d["targets"]
	passes = d["passes"]
	_sizes = Vector2i.ZERO  # 通道切换要重建视口


func _read(p: String) -> String:
	if not FileAccess.file_exists(p):
		return ""
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


func _gdshader(src: String) -> String:
	var main_at := src.find("void main")
	if main_at < 0:
		return ""
	var open := src.find("{", main_at)
	if open < 0:
		return ""
	var depth := 0
	var close := -1
	for i in range(open, src.length()):
		var ch := src[i]
		if ch == "{":
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0:
				close = i
				break
	if close < 0:
		return ""
	var head := src.substr(0, main_at)
	var body := src.substr(open + 1, close - open - 1)
	var decls := ""
	var helpers := ""
	var rx_uniform := RegEx.create_from_string("uniform\\s+(?:(?:lowp|mediump|highp)\\s+)?(\\w+)\\s+(\\w+)(\\s*\\[[^\\]]*\\])?\\s*;")
	var wrapped: Array = []
	var tex_names: Array = []
	for t in textures_def:
		tex_names.append(String(t["name"]))
	for line in head.split("\n"):
		var s2 := line.strip_edges()
		if s2 == "" or s2.begins_with("//"):
			continue
		if s2.begins_with("#version") or s2.begins_with("# version") or s2.begins_with("precision"):
			continue
		if s2.begins_with("varying"):
			continue
		var mu := rx_uniform.search(s2)
		if mu != null:
			var ty := mu.get_string(1)
			var nm := mu.get_string(2)
			var arr := mu.get_string(3)
			if ty == "sampler2D":
				if nm != "screenTexture" and nm != "blockMask" and not tex_names.has(nm):
					wrapped.append(nm)   # pass 输入 / 目标采样器：读回反预乘
				elif nm == "screenTexture":
					wrapped.append(nm)
				elif nm == "blockMask":
					wrapped.append(nm)
				var hint := "filter_nearest"
				if nm == "screenTexture":
					hint = "filter_linear"
				elif tex_names.has(nm):
					var td := _tex_def(nm)
					hint = "filter_nearest" if String(td.get("filter", "linear")) == "nearest" else "filter_linear"
					if String(td.get("wrap", "clamp")) == "repeat":
						hint += ", repeat_enable"
				decls += "uniform sampler2D %s : %s;\n" % [nm, hint]
			else:
				decls += "uniform %s %s%s;\n" % [ty, nm, arr]
			continue
		helpers += line + "\n"
	# 采样：目标/屏幕/遮罩读回时反预乘；皮肤自带图片保持原样
	body = body.replace("texture2D(", "texture(")
	body = body.replace("textureLod(", "textureLod(")
	for nm in (wrapped if not straight else []):
		var n2 := String(nm)
		body = body.replace("texture(%s," % n2, "ns_read_%s(" % n2)
		body = body.replace("textureLod(%s," % n2, "ns_read_lod_%s(" % n2)
	body = body.replace("gl_FragColor", "COLOR")
	body = body.replace("varying", "")
	# component 写入必须直通存储：canvas 默认混合会把 RGB 乘 alpha 再进 RT，
	# 先写 .r（alpha=0）再写 .a 的皮肤会在第一步丢掉颜色。直通模式下所有
	# 中间 RT 都是 straight RGBA，读回也不再反预乘。
	var out := "shader_type canvas_item;\nrender_mode unshaded%s;\n" % (", blend_disabled" if straight else "")
	out += decls
	if not straight:
		for nm in wrapped:
			var n3 := String(nm)
			out += "vec4 ns_read_%s(vec2 p){vec4 c=texture(%s,p);return c.a>0.0001?vec4(c.rgb/c.a,c.a):c;}\n" % [n3, n3]
			out += "vec4 ns_read_lod_%s(vec2 p, float l){vec4 c=textureLod(%s,p,l);return c.a>0.0001?vec4(c.rgb/c.a,c.a):c;}\n" % [n3, n3]
	out += helpers
	out += "void fragment() {\n"
	out += "vec2 uv = UV;\n"
	out += body
	out += "\n}\n"
	# 标识符 uv → UV（避免把 "uv" 出现在变量名里替换掉）
	var rxv := RegEx.create_from_string("\\buv\\b")
	# 已经声明了局部 uv，这里不再替换；保留局部变量即可
	return out


func _tex_def(nm: String) -> Dictionary:
	for t in textures_def:
		if String(t["name"]) == nm:
			return t
	return {}


func ensure(node: Node, px: Vector2i) -> void:
	_node = node
	if _sizes == px and _pass_sv.size() == passes.size() and _pass_tmp.size() == passes.size():
		return
	_sizes = px
	_teardown()
	# 顺序 = 拷贝 → 各 pass（SubViewport 按树序渲染，后面的才能读到前面的本帧纹理）
	_copy_sv = _make_sv("copy", px)
	_pass_sv.clear()
	_pass_tmp.clear()
	for i in passes.size():
		var out_name := String(passes[i]["output"])
		var base := out_name.get_slice(".", 0)
		var sz := px
		if base != "$screen" and targets_def.has(base):
			var spec: Dictionary = targets_def[base]
			sz = Vector2i(maxi(1, int(round(px.x * float(spec.get("scaleX", 1.0))))),
					maxi(1, int(round(px.y * float(spec.get("scaleY", 1.0))))))
		var comp := String(passes[i]["component"])
		_pass_tmp.append(_make_sv("t%d" % i, sz) if comp != "" else null)
		_pass_sv.append(_make_sv("p%d" % i, sz))
	_images.clear()
	for t in textures_def:
		_images[String(t["name"])] = _load_tex(t)

func _make_sv(key: String, sz: Vector2i) -> SubViewport:
	var sv := SubViewport.new()
	sv.size = sz
	sv.transparent_bg = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.disable_3d = true
	var cr := ColorRect.new()
	cr.color = Color(0, 0, 0, 0)
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cr.size = Vector2(sz)
	var mat := ShaderMaterial.new()
	cr.material = mat
	sv.add_child(cr)
	_node.add_child(sv)
	return sv


func _load_tex(t: Dictionary) -> Texture2D:
	var p: String = dir.path_join(String(t["path"]))
	if not FileAccess.file_exists(p):
		return null
	var img := Image.load_from_file(p)
	if img == null:
		return null
	if String(t.get("colorspace", "linear")) == "srgb":
		img.srgb_to_linear()
	if String(t.get("alphaMode", "straight")) == "premult":
		img.convert(Image.FORMAT_RGBA8) # 保持原字节（canvas 侧按直线 alpha 读）
	var tex := ImageTexture.create_from_image(img)
	return tex


func _clear(sv: SubViewport) -> void:
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	(sv.get_child(0) as ColorRect).visible = false


func _draw(key: String, sv: SubViewport, code: String, uniforms: Dictionary) -> void:
	var cr := sv.get_child(0) as ColorRect
	cr.visible = true
	cr.size = Vector2(sv.size)
	var mat: ShaderMaterial = cr.material
	var sh: Shader = mat.shader
	if sh == null or sh.code != code:
		sh = Shader.new()
		sh.code = code
		mat.shader = sh
	for k in uniforms.keys():
		mat.set_shader_parameter(k, uniforms[k])
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _teardown() -> void:
	if is_instance_valid(_copy_sv):
		_copy_sv.queue_free()
	_copy_sv = null
	for sv in _pass_sv:
		if is_instance_valid(sv):
			sv.queue_free()
	_pass_sv.clear()
	for sv in _pass_tmp:
		if sv != null and is_instance_valid(sv):
			sv.queue_free()
	_pass_tmp.clear()

var _empty: ImageTexture = null

func _empty_texture() -> Texture2D:
	if _empty == null:
		var im := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		im.fill(Color(0, 0, 0, 0))
		_empty = ImageTexture.create_from_image(im)
	return _empty

func render(screen_tex: Texture2D, mask_tex: Texture2D, time_sec: float, layer_params: Dictionary,
		touches: PackedVector4Array = PackedVector4Array(), touch_count: int = 0) -> Texture2D:
	if not ok or _copy_sv == null or _pass_sv.size() != passes.size() \
			or _pass_tmp.size() != passes.size():
		return null
	# 1) 场景拷贝（源是预乘画面）。直通模式的中间 RT 存 straight，所以这一步反预乘。
	var copy_code := "\n".join(PackedStringArray([
		"shader_type canvas_item;",
		"render_mode unshaded%s;" % (", blend_disabled" if straight else ""),
		"uniform sampler2D src : filter_linear;",
		"vec4 ns_read_src(vec2 p){vec4 c=texture(src,p);return c.a>0.0001?vec4(c.rgb/c.a,c.a):c;}",
		"void fragment(){COLOR=ns_read_src(UV);}",
	]))
	_draw("copy", _copy_sv, copy_code, {"src": screen_tex})
	var cur_screen := _copy_sv
	var target_last := {}
	# 2) pass 链（每个 pass 输出到自己的视口，树序保证本帧可读）
	for i in passes.size():
		var p: Dictionary = passes[i]
		var out_name := String(p["output"])
		var base := out_name.get_slice(".", 0)
		var comp := String(p["component"])
		var out_sv: SubViewport = _pass_sv[i]
		var code: String = _codes.get(String(p["shader"]), "")
		if code == "":
			continue
		var u := {}
		u["screenTexture"] = cur_screen.get_texture()
		u["blockMask"] = mask_tex
		u["screenSize"] = Vector2(_sizes)
		u["targetSize"] = Vector2(out_sv.size)
		u["targetTexelSize"] = Vector2(1.0 / maxf(out_sv.size.x, 1.0), 1.0 / maxf(out_sv.size.y, 1.0))
		u["time"] = time_sec
		u["touchCount"] = touch_count
		u["touchPoints"] = touches
		u["screenTextureSize"] = Vector2(_sizes)
		u["blockMaskSize"] = Vector2(mask_tex.get_width(), mask_tex.get_height()) if mask_tex != null else Vector2.ONE
		for k in (p["inputs"] as Dictionary).keys():
			var srcn := String(p["inputs"][k])
			var tex: Texture2D = cur_screen.get_texture() if srcn == "$screen" else (target_last[srcn].get_texture() if target_last.has(srcn) else null)
			u[String(k)] = tex
			if tex != null:
				u[String(k) + "Size"] = Vector2(tex.get_width(), tex.get_height())
		for t in textures_def:
			var tx: Texture2D = _images.get(String(t["name"]))
			if tx != null:
				u[String(t["name"])] = tx
				u[String(t["name"]) + "Size"] = Vector2(tx.get_width(), tx.get_height())
		for pd in params_def:
			u[String(pd["name"])] = layer_params.get(String(pd["name"]), pd["value"])
		for k in (p["constants"] as Dictionary).keys():
			u[String(k)] = p["constants"][k]
		if comp != "":
			# component 写入（output = target.r / .a …）：pass 先画进临时全 RGBA，
			# 再只把指定通道混进目标已有内容（= WebGL colorMask 语义）。
			var tmp: SubViewport = _pass_tmp[i]
			_draw("pass", tmp, code, u)
			var prev_tex: Texture2D = _empty_texture()
			if base == "$screen":
				prev_tex = cur_screen.get_texture()
			elif target_last.has(base):
				prev_tex = target_last[base].get_texture()
			var cm := Vector4(0, 0, 0, 0)
			match comp:
				"r": cm.x = 1.0
				"g": cm.y = 1.0
				"b": cm.z = 1.0
				"a": cm.w = 1.0
			_draw("comp", out_sv, _comp_code, {
				"prev": prev_tex, "src": tmp.get_texture(), "comp": cm,
			})
		else:
			_draw("pass", out_sv, code, u)
		if base == "$screen":
			cur_screen = out_sv
		else:
			target_last[base] = out_sv
	return cur_screen.get_texture()

var _comp_code := "\n".join(PackedStringArray([
	"shader_type canvas_item;",
	"render_mode unshaded, blend_disabled;",
	"uniform sampler2D prev : filter_linear;",
	"uniform sampler2D src : filter_linear;",
	"uniform vec4 comp;",
	"void fragment(){",
	"  COLOR=mix(texture(prev,UV),texture(src,UV),comp);",
	"}",
]))
