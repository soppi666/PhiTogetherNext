class_name SkinPack
extends RefCounted
## 资源包（皮肤）统一层。三种来源在这一处归成同一份元素表 + 打击音表：
##   phira 包  = 扁平 zip/目录：info.yml + click/click_mh/drag/drag_mf/flick/flick_mh/hold/hold_mh/hit_fx.png
##               + click/drag/flick 的 ogg|wav|mp3（字段与校验取自本地 phira+prpr 源码）
##   prpr 包   = 扁平目录：config.txt（"Key: Value"）+ Tap/TapHL/…/HitSong0-2 这套名字
##   PT 在线包 = 一个 URL：GET <url>/meta.json → {name, author, res{…}}，逐元素回源后
##               落到 user://skins/ 里当一个普通包用（skin_online.gd 负责拉，这里只管读）
##   内置      = res://assets/skin（id 传空串，走舞台原有的 load(SKIN[k]) 路径）
##
## 元素键必须和 ChartPlayer::set_skin 那串分支一一对应（多出来的名字没人接）。
## PhiZone 的在线资源包接口在 PT 与 phira 源码里都不存在，规格还没核实，所以这里只留一个
## 入口（_read_pz），拿到规格再填，不猜字段名——猜错=导入静默少文件，比报错难查得多。

const ROOT := "user://skins"
const BUILTIN_ID := ""

const SRC_BUILTIN := "内置"
const SRC_PHIRA := "phira"
const SRC_PRPR := "prpr"
const SRC_PZ := "phizone"
const SRC_ONLINE := "在线"

## 13 个元素键 = 舞台 SKIN 表的键。候选文件名按顺序试，先命中先用（大小写不敏感）。
## phira 那套名字（click/drag/flick/hold + _mh）来自 prpr/src/core/resource.rs 的 load_tex!；
## _mh = 官方 highLight 变体（PT 里叫 TapHL 等）。
const FILES := {
	"line": ["line.png"],
	"tap": ["tap.png", "click.png"],
	"tap_hl": ["taphl.png", "tap_mh.png", "click_mh.png"],
	"drag": ["drag.png"],
	"drag_hl": ["draghl.png", "drag_mh.png"],
	"flick": ["flick.png"],
	"flick_hl": ["flickhl.png", "flick_mh.png"],
	"hold": ["hold.png"],
	"hold_hl": ["holdhl.png", "hold_mh.png"],
	"hold_head": ["holdhead.png", "hold_head.png"],
	# PT 官方包另有 HoldHeadHL.png（多押长条的头）。漏了这一条时，多押 hold 的头会
	# 回落内置那张 HoldHeadHL —— 用户报的"Hold 头还是内置的头，没有换"就是这里。
	"hold_head_hl": ["holdheadhl.png", "hold_head_hl.png", "hold_head_mh.png"],
	"hold_end": ["holdend.png", "hold_tail.png"],
	# 多押尾帽：phira 由 hold_mh.png 的图集切出（见 _slice_atlas），PT 包若直接给文件也认
	"hold_end_hl": ["holdendhl.png", "hold_end_hl.png", "hold_end_mh.png"],
	# PT 的官方包把命中特效叫 clickRaw.png（256×7680 竖排 30 帧，就是我们内置那张 HitFX
	# 的原名）——只认 hit_fx.png 会把整个 Phigros 包判成"缺特效"，整张卡都消失。
	"fx": ["hitfx.png", "hit_fx.png", "clickraw.png", "hitfxraw.png"],
}
## phira 的 hold.png 是竖排图集：**从上到下 = 尾、中、头**，holdAtlas=[尾高, 头高]
## （prpr/src/core/resource.rs:166-181 hold_tail_rect 取 v∈[0, a0/H]、hold_head_rect 取
##  v∈[1−a1/H, 1]；官方文档同句："Hold贴图的尾、头高度"）。
## ⚠ 以前这里把 a[0] 当头从顶上切、a[1] 当尾从底下切——默认包 50/50 对称看不出，
## 用户那包"元·菱简"是 [50, 90]：顶上那 50 行是透明留白 ⇒ 头整个是透明的（"适配失败"）。
const ATLAS_KEYS := ["hold", "hold_hl"]

## 打击音：舞台 HIT_DEFAULTS 认 HitSong0/1/2 这三个名字，phira 包里它们叫 click/drag/flick。
## 与 chart_stage._play_hit 的默认表一致：1/2=Tap·Hold→0，3=Flick→2，4=Drag→1。
const SOUNDS := {
	"HitSong0": ["hitsong0", "click"],
	"HitSong1": ["hitsong1", "drag"],
	"HitSong2": ["hitsong2", "flick"],
}
const HIT_DEFAULTS := {1: "HitSong0", 2: "HitSong0", 3: "HitSong2", 4: "HitSong1"}

## 卡片封面专用：包里有 bg.png 就直接拿它当封面（作者已经画好一张图，别再自己摆）
const COVER_FILES := ["bg.png", "background.png", "cover.png"]

## 导入必需项（phira/src/scene/main.rs:468-497 那份清单；line 贴图不在其中——
## phira 包没有判定线贴图，缺了回落内置才对）
const REQUIRED := ["tap", "tap_hl", "drag", "drag_hl", "flick", "flick_hl",
		"hold", "hold_hl", "fx"]

## meta 里要往包字典上拷的字段：scan / scan_path 共用一份，两条路读出来的包才可能完全同形
const META_KEYS := ["name", "author", "desc", "source", "hold_atlas", "hold_atlas_mh",
		"hit_fx", "hit_fx_scale", "hit_fx_duration", "hit_fx_tinted", "hit_fx_rotate",
		"hide_particles", "hold_repeat", "hold_compact", "hold_keep_head",
		"color_perfect", "color_good", "hit_shape"]

static var _cache := {}

## 扫一个已装包（BUILTIN_ID=内置）。缺文件不报错，只进 missing 列表——
## 表现层的原则是"这一张回落内置"，不是"整包作废"。
static func scan(id: String) -> Dictionary:
	if id == BUILTIN_ID:
		# 内置包也要有一份 res：卡片封面与演示带都从 res 取图，空表会让内置那张卡变成空白
		var bi := _blank(BUILTIN_ID, "", "内置", "PhiTogether pack-1", "随程序发布的默认皮肤", SRC_BUILTIN)
		for k in ChartStage.SKIN:
			(bi["res"] as Dictionary)[k] = String(ChartStage.SKIN[k])
		for sn in SOUNDS:
			(bi["sounds"] as Dictionary)[sn] = "res://assets/skin/hitsounds/%s.ogg" % sn
		return bi
	var dir := ROOT.path_join(id)
	if _cache.has(id):
		return _cache[id]
	if not DirAccess.dir_exists_absolute(dir):
		return {"id": id, "dir": dir, "ok": false, "error": "包目录不存在"}
	var p := _blank(id, dir, id, "", "", SRC_PRPR)
	var have := _lower_index(dir)
	var meta := _read_meta(dir, have)
	for k in META_KEYS:
		if meta.has(k):
			p[k] = meta[k]
	for k in FILES:
		var got := _pick(have, FILES[k] as Array)
		if got != "":
			p["res"][k] = dir.path_join(got)
		elif k in REQUIRED:
			p["missing"].append(k)
	for s in SOUNDS:
		var a := _pick_audio(have, SOUNDS[s] as Array)
		if a != "":
			p["sounds"][s] = dir.path_join(a)
	var cf := _pick(have, COVER_FILES)
	if cf != "":
		p["cover"] = dir.path_join(cf)
	p["ok"] = (p["missing"] as Array).is_empty()
	if not p["ok"]:
		p["error"] = "missing file: %s" % String(p["missing"][0])
	_cache[id] = p
	return p


## 直接扫一个外部目录（QA 的 --qaskin=DIR 与在线包缓存复用这一条）
static func scan_path(dir: String) -> Dictionary:
	var p := _blank(dir, dir, dir.get_file(), "", "", SRC_PRPR)
	var have := _lower_index(dir)
	var meta := _read_meta(dir, have)
	for k in META_KEYS:
		if meta.has(k):
			p[k] = meta[k]
	for k in FILES:
		var got := _pick(have, FILES[k] as Array)
		if got != "":
			p["res"][k] = dir.path_join(got)
	for s in SOUNDS:
		var a := _pick_audio(have, SOUNDS[s] as Array)
		if a != "":
			p["sounds"][s] = dir.path_join(a)
	var cf := _pick(have, COVER_FILES)
	if cf != "":
		p["cover"] = dir.path_join(cf)
	p["ok"] = not (p["res"] as Dictionary).is_empty()
	return p


## 元素键 → 贴图。只放这个包**真的有**的键，缺的舞台自己回落内置。
## 缺 HL 变体时回落到普通图（PT skin.js:61-63 的语义：没有 *_mh 就"高亮态用同一张"，
## 不是"把高亮关掉"）。phira 包里 *_mh 是必需项，所以这条只在在线包/半成品上生效。
static func textures(p: Dictionary) -> Dictionary:
	var out := {}
	# 只看 ok：内置包的 dir 是空串（它在 res:// 里），以前这条把内置包一起挡掉了，
	# 于是"内置"那张卡是空白的
	if not bool(p.get("ok", false)):
		return out
	var res: Dictionary = p["res"]
	var atlas: Array = p.get("hold_atlas", [0, 0])
	var atlas_mh: Array = p.get("hold_atlas_mh", [0, 0])
	for k in res:
		var key := String(k)
		var rp := String(res[key])
		if rp.begins_with("res://"):
			# 内置件直接交回导入件本体：省一次取像素+重建，而且与舞台原来的 load(SKIN[k]) 同一对象
			var bt := load(rp) as Texture2D
			if bt != null:
				out[key] = bt
			continue
		var img := _read_image(rp)
		if img == null:
			continue
		if key in ATLAS_KEYS:
			var a: Array = atlas if key == "hold" else atlas_mh
			var parts := _slice_atlas(img, a, "" if key == "hold" else "_hl")
			if not parts.is_empty():
				for part in parts:
					out[String(part[0])] = ImageTexture.create_from_image(part[1] as Image)
				continue
		out[key] = ImageTexture.create_from_image(img)
	for hl in ["tap_hl", "drag_hl", "flick_hl", "hold_head_hl", "hold_end_hl"]:
		var base := String(hl).trim_suffix("_hl")
		if not out.has(hl) and out.has(base):
			out[hl] = out[base]
	return out


## 打击音名 → AudioStream。缺文件返回 null，调用方回落 res://assets/skin/hitsounds 内置音
## （和舞台 _play_hit 现有语义一致：谱包能覆盖、没覆盖用内置）。
static func sound(p: Dictionary, name: String) -> AudioStream:
	var s: Dictionary = p.get("sounds", {})
	if not s.has(name):
		return null
	var path := String(s[name])
	var exists := ResourceLoader.exists(path) if path.begins_with("res://") else FileAccess.file_exists(path)
	if not exists:
		return null
	# 包里的音源是**散文件**（不是 .import 导入件），load() 认不了，只能按扩展名走各自的口
	var ext := path.get_extension().to_lower()
	match ext:
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"wav":
			return AudioStreamWAV.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)
	return null


static func hit_sound_name(type_: int) -> String:
	return String(HIT_DEFAULTS.get(type_, "HitSong0"))


## 已装包列表（内置永远第一，然后按名字排）
static func list_all() -> Array:
	var out: Array = [scan(BUILTIN_ID)]
	var da := DirAccess.open(ROOT)
	if da == null:
		return out
	# ⚠ 不完整的包**也要出现在列表里**：以前只收 ok 的包，结果用户自己导入的 Phigros 包
	# （fx 那张叫 clickRaw.png）被判缺项后整张卡消失，看起来就是"皮肤没生效"。
	# 缺的元素逐张回落内置，卡片副标题写清楚缺几项。
	var packs: Array = []
	for id in installed_ids():
		packs.append(scan(String(id)))
	# 4.7 的 String 没有 natural_to_lower（实测），按小写名排；数字后缀靠目录名里的 -n 区分
	packs.sort_custom(func(a: Variant, b: Variant) -> bool:
			return String((a as Dictionary)["name"]).to_lower() < String((b as Dictionary)["name"]).to_lower())
	for p in packs:
		out.append(p)
	return out


## 卡片封面：包里有 bg.png 就直接拿它当封面（作者已经画好一张图，别再自己摆）
## aspect = 卡片的真实宽高比（SongCard 在窗口比例 <16:9 时出 3:2 卡）。
## ⚠ 必须按它生成：封面是"满画面居中裁"，画成 16:9 再贴到 3:2 卡上，左右各被裁掉 8%,
## 最左边那颗 tap 就整个没了（用户："卡片只出现了三个音符，应该出现四个"）。
static var _covers := {}

static func cover_image(p: Dictionary, w: float, aspect: float = 16.0 / 9.0) -> Texture2D:
	var key := "%s|%d|%0.3f" % [String(p.get("id", "")), int(w), aspect]
	if _covers.has(key):
		return _covers[key]
	# 作者给了 bg.png ⇒ 封面就是那张图（SongCard 会按卡片比例居中裁切，不拉伸）
	var cover := String(p.get("cover", ""))
	if cover != "" and (ResourceLoader.exists(cover) if cover.begins_with("res://")
			else FileAccess.file_exists(cover)):
		var ct := _load_tex(cover)
		if ct != null:
			_covers[key] = ct
			return ct
	var cw := maxi(int(w), 32)
	var ch := maxi(int(w / maxf(aspect, 0.2)), 24)
	var img := Image.create(cw, ch, false, Image.FORMAT_RGBA8)
	var top := UiTokens.bg(3)
	var bot := UiTokens.bg(0)
	for y in ch:
		img.fill_rect(Rect2i(0, y, cw, 1), top.lerp(bot, float(y) / float(ch)))
	# 没有 bg.png ⇒ 四类音符各画一条**竖着**的，从左到右 tap / drag / flick / hold
	# （用户草图那一排）。竖=贴图转 90°，所以粗细关系是真的、不用猜：
	# drag(989×60) 最细、tap(989×100) 次之、flick(989×200) 最宽，与草图顺序一致。
	var tex := textures(p)
	var area_h := float(ch) * 0.70        # 下面 30% 是卡片信息带（SongCard 的遮罩条）
	var gap0 := float(cw) * 0.055
	# 四个元素都受同一条规则：**顺时针转 90°**，长轴竖起来，宽按贴图自身的比例算。
	# 长条不是"一竖条"，它转完是横着躺的一整根（头在左、尾在右）——用户："只有 hold 是
	# 竖着的，应该与其他音符一样…或者说顺时针旋转90°"，而且"头和尾被拉长了"（帽必须按
	# 自身比例给宽，不许为了凑一块方糖去拉它）。
	var nh0 := area_h * 0.80
	var w_tap := _vaspect(tex, "tap", nh0)
	var w_drag := _vaspect(tex, "drag", nh0)
	var w_flick := _vaspect(tex, "flick", nh0)
	var w_hold := _hold_extent(tex, nh0)
	var total0 := w_tap + w_drag + w_flick + w_hold + gap0 * 3.0
	# 长条天然就长（Hold.png 989×1900），一根可能吃掉整张卡 ⇒ 整组一起缩，
	# 缩的是同一个倍率，四者之间的相对粗细/长短关系不变
	var s := 1.0 if total0 <= 0.0 else minf(1.0, float(cw) * 0.92 / total0)
	var nh := nh0 * s
	var gap := gap0 * s
	var total := total0 * s
	var cx := (float(cw) - total) * 0.5
	var cy := area_h * 0.5
	var keys := ["tap", "drag", "flick"]
	var widths := [w_tap * s, w_drag * s, w_flick * s]
	for i in 3:
		var wi: float = float(widths[i])
		cx += wi * 0.5
		_stamp_v(img, tex, String(keys[i]), cx, cy, nh)
		cx += wi * 0.5 + gap
	cx += w_hold * s * 0.5
	_hold_row(img, tex, cx, cy, w_hold * s, nh)
	var out := ImageTexture.create_from_image(img)
	_covers[key] = out
	if _covers.size() > 24:
		_covers.clear()
		_covers[key] = out
	return out


## 竖着画时一个音符占多宽 = 竖条高 × (墨高/墨宽)（转 90° 之后的真实比例）。
## ⚠ 必须按**墨**（`get_used_rect`）而不是整张贴图算：phira 包的四类音符都画在
## 1080×1080 画布上（墨只有 1030×150），按整张算三颗音符各占一个正方块 ⇒ 四件一起
## 被缩成头发丝（用户："phira 皮肤包卡片与 PT 不一样"）。
## 包里缺这张图就返回 0：那一列空着，比画个假音符诚实。
static func _vaspect(tex: Dictionary, key: String, nh: float) -> float:
	return _ink_w(tex.get(key, null) as Texture2D, nh)


## 一张贴图按"墨"算出来的竖向占宽（转 90° 后）
static func _ink_w(t: Texture2D, nh: float) -> float:
	if t == null:
		return 0.0
	var r := _ink_rect(t)
	return nh * float(r.size.y) / maxf(float(r.size.x), 1.0)


## 贴图里真正有墨的那块（透明边不算）。按贴图对象缓存：封面重建很频繁。
static var _ink := {}

static func _ink_rect(t: Texture2D) -> Rect2i:
	var key := t.get_instance_id()
	if _ink.has(key):
		return _ink[key]
	var r := Rect2i(0, 0, maxi(t.get_width(), 1), maxi(t.get_height(), 1))
	var img := t.get_image()
	if img != null:
		img = img.duplicate()
		img.convert(Image.FORMAT_RGBA8)
		var used := img.get_used_rect()
		if used.size.x > 0 and used.size.y > 0:
			r = used
	_ink[key] = r
	return r


## 卡片右下角那颗"皮肤类型"徽章：说的是这个包按哪套协议读出来的（用户草图里的 "PT Skin"）
static func type_label(p: Dictionary) -> String:
	match String(p.get("source", "")):
		SRC_ONLINE:
			return "PT Skin"
		SRC_PHIRA:
			return "phira"
		SRC_PRPR:
			return "prpr"
		SRC_PZ:
			return "phizone"
		_:
			return SRC_BUILTIN


## 竖着盖一个音符：先转 90°（宽变高），再按"高=nh、宽按转后比例"缩放落笔
static func _stamp_v(img: Image, tex: Dictionary, key: String, cx: float, cy: float, nh: float) -> void:
	var t: Texture2D = tex.get(key, null)
	if t == null:
		return
	var w := _ink_w(t, nh)
	_stamp_rot(img, t, cx - w * 0.5, cy - nh * 0.5, w, nh)


## 把一张贴图顺时针转 90° 后铺进 (x,y,w,h)
static func _stamp_rot(img: Image, t: Texture2D, x: float, y: float, w: float, h: float) -> void:
	if t == null or w <= 0.0 or h <= 0.0:
		return
	var src := t.get_image()
	if src == null:
		return
	src = src.duplicate()
	src.convert(Image.FORMAT_RGBA8)
	var ir := _ink_rect(t)   # 透明留白不参与：否则 1080 画布的音符会被画成一小截
	if ir.size.x > 0 and ir.size.y > 0 and ir != Rect2i(0, 0, src.get_width(), src.get_height()):
		src = src.get_region(ir)
	src.rotate_90(CLOCKWISE)   # 4.7：这参数是全局枚举 ClockDirection（不是 bool），实测 8×4→4×8
	src.resize(maxi(int(w), 1), maxi(int(h), 1), Image.INTERPOLATE_LANCZOS)
	img.blend_rect(src, Rect2i(0, 0, src.get_width(), src.get_height()), Vector2i(int(x), int(y)))


## 长条躺平后的自然宽 = 头 + 身 + 尾 三段各自的"长"（贴图的高）按 nh 缩放后相加。
## 缺哪段就少算哪段（身体缺失=这包不完整，卡片上少一截比画个假身体诚实）。
static func _hold_extent(tex: Dictionary, nh: float) -> float:
	var head: Texture2D = tex.get("hold_head", null)
	if head == null:
		return 0.0
	var w := _vaspect(tex, "hold_head", nh)
	var body: Texture2D = tex.get("hold", null)
	if body != null:
		w += _vaspect(tex, "hold", nh)
	var tail: Texture2D = tex.get("hold_end", null)
	if tail != null:
		w += _vaspect(tex, "hold_end", nh)
	return w


## 长条躺平：整根**顺时针转 90°**（头在左、尾在右、身体在中间）——和别的音符受同一变换，
## 所以它不再是一根竖条（用户："只有 hold 是竖着的…或者说顺时针旋转90°"）。
## 帽的宽按贴图自身比例算（989×50 → 高 nh 时宽 nh·50/989），身体占自己那一段：
## 三段都不许为凑一块方糖被拉变形（用户："hold 头和尾被拉长了"）。
static func _hold_row(img: Image, tex: Dictionary, cx: float, cy: float, w: float, nh: float) -> void:
	var head: Texture2D = tex.get("hold_head", null)
	if head == null:
		return
	var cap := maxf(_vaspect(tex, "hold_head", nh), 1.0)
	var x0 := cx - w * 0.5
	var tail: Texture2D = tex.get("hold_end", null)
	var tc := 0.0 if tail == null else maxf(_vaspect(tex, "hold_end", nh), 1.0)
	var body: Texture2D = tex.get("hold", null)
	if body != null:
		_stamp_rot(img, body, x0 + cap, cy - nh * 0.5, maxf(w - cap - tc, 1.0), nh)
	if tail != null:
		_stamp_rot(img, tail, x0 + w - tc, cy - nh * 0.5, tc, nh)
	_stamp_rot(img, head, x0, cy - nh * 0.5, cap, nh)


static func _blit(img: Image, t: Texture2D, x: float, y: float, w: float, h: float) -> void:
	if w <= 0.0 or h <= 0.0:
		return
	var sub := t.get_image()
	if sub == null:
		return
	sub = sub.duplicate()
	sub.convert(Image.FORMAT_RGBA8)
	sub.resize(maxi(int(w), 1), maxi(int(h), 1), Image.INTERPOLATE_LANCZOS)
	img.blend_rect(sub, Rect2i(0, 0, sub.get_width(), sub.get_height()),
			Vector2i(int(x), int(y)))


## 已装包的目录名（在线包缓存目录不算：它以 "." 开头或叫 _import-* 的都跳过）
static func installed_ids() -> Array:
	var out: Array = []
	var da := DirAccess.open(ROOT)
	if da == null:
		return out
	for d in da.get_directories():
		var id := String(d)
		if id.begins_with("_"):
			continue
		out.append(id)
	return out


## 导入：接一个 zip 或一个目录，校验通过后落到 user://skins/<安全名>[-n]/。
## 错误文案沿用 phira 那几条（"missing info.yml" / "invalid info.yml" /
## "missing file: x" / "failed to load image: x" / "failed to unzip"），
## 作者对着搜能查到同一句话。
static func import_from(src: String) -> Dictionary:
	if src == "":
		return {"ok": false, "error": "没选文件"}
	var tmp := "%s/_import-%d" % [ROOT, Time.get_ticks_msec()]
	_sweep_tmp()
	var got := _import_into(src, tmp)
	rmtree(tmp)
	clear_cache()      # 包变了：封面/元素图/扫描结果全部作废
	return got


## 上一轮崩在半路留下的临时目录（进程被杀时来不及收）
static func _sweep_tmp() -> void:
	var da := DirAccess.open(ROOT)
	if da == null:
		return
	for d in da.get_directories():
		if String(d).begins_with("_import-"):
			rmtree(ROOT.path_join(String(d)))


static func _import_into(src: String, tmp: String) -> Dictionary:
	if _looks_like_zip(src):
		var zr := ZIPReader.new()
		if zr.open(src) != OK:
			return {"ok": false, "error": "failed to unzip"}
		var names: PackedStringArray = zr.get_files()
		# 只有一层公共根时把根去掉（phira 导包 strip_root=false，但作者常从文件夹压）
		var cut := _common_root(names)
		for f in names:
			var rel := String(f).substr(cut)
			if rel == "" or rel.ends_with("/"):
				continue
			var buf: PackedByteArray = zr.read_file(String(f))
			var dst := tmp.path_join(rel)
			_ensure_dir(dst.get_base_dir())
			var w := FileAccess.open(dst, FileAccess.WRITE)
			if w != null:
				w.store_buffer(buf)
				w.close()
		zr.close()
	elif DirAccess.dir_exists_absolute(src):
		_copy_tree(src, tmp)
	else:
		return {"ok": false, "error": "既不是 zip 也不是目录"}
	var have := _lower_index(tmp)
	if not (have.has("info.yml") or have.has("info.yaml") or have.has("config.txt") or have.has("meta.json")):
		return {"ok": false, "error": "missing info.yml"}
	var meta := _read_meta(tmp, have)
	if not bool(meta.get("ok", true)):
		return {"ok": false, "error": String(meta.get("error", "invalid info.yml"))}
	for k in REQUIRED:
		if _pick(have, FILES[k] as Array) == "":
			# 报这一行**这个格式**该有的那个名字：prpr 包说 TapHL.png，phira 包说 click_mh.png
			var cands: Array = FILES[k] as Array
			var idx: int = 0 if String(meta.get("source", SRC_PHIRA)) == SRC_PRPR else cands.size() - 1
			return {"ok": false, "error": "missing file: %s" % String(cands[idx])}
	for k in REQUIRED:
		for cand in FILES[k] as Array:
			if have.has(String(cand)):
				var real := String(have[String(cand)])
				if Image.load_from_file(tmp.path_join(real)) == null:
					return {"ok": false, "error": "failed to load image: %s" % real}
				break
	var id := _dest_id(String(meta.get("name", "skin")))
	rmtree(ROOT.path_join(id))
	_copy_tree(tmp, ROOT.path_join(id))
	rmtree(tmp)
	_cache.clear()
	var got := scan(id)
	got["imported"] = true
	return got


static func uninstall(id: String) -> void:
	if id == BUILTIN_ID:
		return
	rmtree(ROOT.path_join(id))
	clear_cache()


## PhiZone 在线资源包：规格未核实，先留口。填这里就行，列表/导入/预览/舞台都不用改。
static func _read_pz(_payload: Dictionary) -> Dictionary:
	return {"ok": false, "error": "PhiZone 资源包规格未接入"}


# ── 内部 ──────────────────────────────────────────────────────────────

static func _blank(id: String, dir: String, name: String, author: String, desc: String, src: String) -> Dictionary:
	return {"id": id, "dir": dir, "name": name, "author": author, "desc": desc,
			"source": src, "res": {}, "sounds": {}, "missing": [], "cover": "",
			"hold_atlas": [0, 0], "hold_atlas_mh": [0, 0], "hold_repeat": false,
			"hold_compact": false, "hold_keep_head": false,
			"hit_fx": [0, 0], "hit_fx_scale": 1.0, "hit_fx_duration": 0.5,
			"hit_fx_tinted": true, "hit_fx_rotate": false, "hide_particles": false,
			"hit_shape": "circle",
			# 默认判定色=prpr ResPackInfo 的默认值（ARGB 0xe1ffec9f / 0xebb4e1ff）
			# prpr 的默认值是 **ARGB**（0xe1ffec9f / 0xebb4e1ff）；Godot 的 Color("#rrggbbaa")
			# 是 RGBA，直接写字符串会把黄色读成青蓝色（用户："除了 phira 都变成青蓝色了"）
			"color_perfect": Color8(0xff, 0xec, 0x9f, 0xe1),
			"color_good": Color8(0xb4, 0xe1, 0xff, 0xeb), "ok": true}


## 包 → 原生表现参数（一次给全）。fx 帧表 = phira 的 hitFx=[列,行]；没声明的（内置/PT）
## 交回原生按它自己的 256 方帧推，行为与改动前逐位一致。
static func options(p: Dictionary) -> Dictionary:
	var fr: Array = p.get("hit_fx", [0, 0])
	var o := {
		"fx_cols": int(fr[0]) if fr.size() > 0 else 0,
		"fx_rows": int(fr[1]) if fr.size() > 1 else 0,
		"hit_fx_duration": float(p.get("hit_fx_duration", 0.5)),
		"hit_fx_scale": float(p.get("hit_fx_scale", 1.0)),
		"hit_fx_tinted": bool(p.get("hit_fx_tinted", true)),
		"hit_fx_rotate": bool(p.get("hit_fx_rotate", false)),
		"hide_particles": bool(p.get("hide_particles", false)),
		"hold_repeat": bool(p.get("hold_repeat", false)),
		"hold_compact": bool(p.get("hold_compact", false)),
		"hold_keep_head": bool(p.get("hold_keep_head", false)),
		"color_perfect": p.get("color_perfect", Color8(0xff, 0xec, 0x9f, 0xe1)),
		"color_good": p.get("color_good", Color8(0xb4, 0xe1, 0xff, 0xeb)),
		"phira_sizing": String(p.get("source", "")) == SRC_PHIRA,
		# 命中表现也走 prpr 的粒子模型（与 PT 那套大小/范围/颜色都不同）
		"prpr_fx": String(p.get("source", "")) == SRC_PHIRA,
		"mh_width_factor": 1.0,
	}
	# 双押宽倍率（官方文档："播放器宽度参数 × (双押贴图宽度 / 单押贴图宽度)"，prpr 用 click 两张算）
	var res: Dictionary = p.get("res", {})
	var one := String(res.get("tap", ""))
	var two := String(res.get("tap_hl", ""))
	if one != "" and two != "":
		var i1 := _read_image(one)
		var i2 := _read_image(two)
		if i1 != null and i2 != null and i1.get_width() > 0:
			o["mh_width_factor"] = float(i2.get_width()) / float(i1.get_width())
	return o


## 把包贴到 player 上——**唯一**的一条应用链（舞台与演示带共用）。
## 以前两边各写一遍 set_skin 循环，改包时"哪些槽要清"两边理解不一致，
## 于是出现过"换了包还显示上一个包"。13 个槽每次全给：包里有的用它自己的，
## 没有的回落内置（prpr/PT 同语义），绝不许有槽被跳过。
static func apply_to(cp, p: Dictionary) -> void:
	if cp == null or not is_instance_valid(cp):
		return
	var got := textures(p)
	# 自定义包可以故意不带 hold 头/尾帽（PT customRes 的鱼形 hold 就是一整条身体）：
	# 缺这两槽时不再回落内置帽，而是置空 → C++ 只画身体。内置包仍按原样补全。
	var custom := String(p.get("source", SRC_BUILTIN)) != SRC_BUILTIN
	var caps := ["hold_head", "hold_end", "hold_head_hl", "hold_end_hl"]
	for k in ChartStage.SKIN:
		var t: Texture2D = null
		if got.has(k):
			t = got[k]
		elif custom and String(k) in caps:
			t = null
		else:
			t = load(String(ChartStage.SKIN[k]))
		cp.set_skin(k, t)
	cp.set_hit_particle_shape(1 if String(p.get("hit_shape", "")) == "square" else 0)
	cp.set_pack_options(options(p))


## res:// 的内置件在导出包里**没有源文件**（只有 .import + .ctex），只能走 ResourceLoader；
## user:// 的包文件反过来不能被 ResourceLoader 认。两条都在这一个口里分掉。
static func _read_image(path: String) -> Image:
	if path.begins_with("res://"):
		var t := load(path) as Texture2D
		return t.get_image() if t != null else null
	return Image.load_from_file(path)


static var _tex_cache := {}

## 换包/删包/重新导入之后必须作废：否则卡片还挂着上一版的封面与元素图
static func clear_cache() -> void:
	_covers.clear()
	_tex_cache.clear()
	_cache.clear()
	_ink.clear()


static func _load_tex(path: String) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	var img := _read_image(path)
	var t: Texture2D = ImageTexture.create_from_image(img) if img != null else null
	_tex_cache[path] = t
	return t


static func _atlas_rows(a: Array) -> int:
	return maxi(0, int(a[0]) + int(a[1]))


## 竖排 hold 图集 → hold_head / hold(身体) / hold_end。图集不合法就返回空（当普通整图用）。
## 顺序按 prpr：a[0]=尾（贴图**上**边）、a[1]=头（贴图**下**边）、中间=身体。
## 注意：prpr 的 holdRepeat 是把身体那张设成 GL_REPEAT 平铺；我们的原生画 hold 是拉伸，
## 所以带 holdRepeat 的包身体会显得被拉长——已知偏差，要平铺得动 set_skin 那条 C++ 分支。
static func _slice_atlas(img: Image, a: Array, sfx := "") -> Array:
	var out: Array = []
	var tail := maxi(0, int(a[0]))        # 上边=尾
	var head := maxi(0, int(a[1]))        # 下边=头
	var h := img.get_height()
	if head + tail <= 0 or head + tail >= h - 1:
		return out
	var w := img.get_width()
	if head > 0:
		out.append(["hold_head" + sfx, img.get_region(Rect2i(0, h - head, w, head))])
	if tail > 0:
		out.append(["hold_end" + sfx, img.get_region(Rect2i(0, 0, w, tail))])
	# 身体那张就叫 hold / hold_hl（舞台与演示带都按这两个名字取）
	out.append(["hold" + sfx, img.get_region(Rect2i(0, tail, w, h - head - tail))])
	return out


static func _lower_index(dir: String) -> Dictionary:
	var out := {}
	var da := DirAccess.open(dir)
	if da == null:
		return out
	for f in da.get_files():
		var n := String(f).to_lower()
		if not out.has(n):
			out[n] = String(f)
	return out


static func _pick(have: Dictionary, cands: Array) -> String:
	for c in cands:
		var n := String(c).to_lower()
		if have.has(n):
			return String(have[n])
	return ""


static func _pick_audio(have: Dictionary, bases: Array) -> String:
	for b in bases:
		for ext in ["ogg", "wav", "mp3"]:
			var n := "%s.%s" % [String(b).to_lower(), ext]
			if have.has(n):
				return String(have[n])
	return ""


static func _read_meta(dir: String, have: Dictionary) -> Dictionary:
	if have.has("info.yml"):
		return _parse_info_yml(FileAccess.get_file_as_string(dir.path_join(String(have["info.yml"]))))
	if have.has("info.yaml"):
		return _parse_info_yml(FileAccess.get_file_as_string(dir.path_join(String(have["info.yaml"]))))
	if have.has("config.txt"):
		return _parse_config_txt(FileAccess.get_file_as_string(dir.path_join(String(have["config.txt"]))))
	if have.has("meta.json"):
		return _parse_meta_json(FileAccess.get_file_as_string(dir.path_join(String(have["meta.json"]))))
	return {"ok": false, "error": "missing info.yml"}


## phira 的 info.yml：camelCase 扁平键 + 两个 [a,b]（prpr ResPackInfo 的字段表）
static func _parse_info_yml(txt: String) -> Dictionary:
	var m := {"source": SRC_PHIRA, "ok": true}
	for line in txt.split("\n"):
		var l := String(line).strip_edges()
		if l == "" or l.begins_with("#") or not l.contains(":"):
			continue
		var k := String(l.split(":")[0]).strip_edges()
		var v := String(l.substr(l.find(":") + 1)).strip_edges().trim_prefix("\"").trim_suffix("\"")
		match k:
			"name": m["name"] = v
			"author": m["author"] = v
			"description": m["desc"] = v
			"hitFx": m["hit_fx"] = _pair(v)
			"holdAtlas": m["hold_atlas"] = _pair(v)
			"holdAtlasMH": m["hold_atlas_mh"] = _pair(v)
			"hitFxDuration": m["hit_fx_duration"] = v.to_float()
			"hitFxScale": m["hit_fx_scale"] = v.to_float()
			"hitFxTinted": m["hit_fx_tinted"] = v.to_lower() == "true"
			"hitFxRotate": m["hit_fx_rotate"] = v.to_lower() == "true"
			"hideParticles": m["hide_particles"] = v.to_lower() == "true"
			"holdRepeat": m["hold_repeat"] = v.to_lower() == "true"
			"holdCompact": m["hold_compact"] = v.to_lower() == "true"
			"holdKeepHead": m["hold_keep_head"] = v.to_lower() == "true"
			"colorPerfect": m["color_perfect"] = _color_guess(v)
			"colorGood": m["color_good"] = _color_guess(v)
	var nm := String(m.get("name", ""))
	if nm == "":
		m["error"] = "invalid info.yml（empty name）"
		m["ok"] = false
	elif nm.length() > 100:
		m["error"] = "invalid info.yml（name too long）"
		m["ok"] = false
	return m


## prpr 的 config.txt：扁平 "Key: Value"，分号是行内注释
static func _parse_config_txt(txt: String) -> Dictionary:
	var m := {"source": SRC_PRPR, "ok": true}
	for line in txt.split("\n"):
		var l := String(line).strip_edges()
		var sc := l.find(";")
		if sc >= 0:
			l = String(l.substr(0, sc)).strip_edges()
		if l == "" or not l.contains(":"):
			continue
		var k := String(l.split(":")[0]).strip_edges().to_lower()
		var v := String(l.substr(l.find(":") + 1)).strip_edges()
		match k:
			"name": m["name"] = v
			"author": m["author"] = v
			"description": m["desc"] = v
			"holdatlas": m["hold_atlas"] = _pair(v)
			"holdatlas2", "holdatlasnh": m["hold_atlas_mh"] = _pair(v)
			"hitfx": m["hit_fx"] = _pair(v)
			"hitfxduration": m["hit_fx_duration"] = v.to_float()
			"hitfxscale": m["hit_fx_scale"] = v.to_float()
			"hitfxtinted": m["hit_fx_tinted"] = v.to_lower() == "true"
			"hitfxrotate": m["hit_fx_rotate"] = v.to_lower() == "true"
			"holdcompact": m["hold_compact"] = v.to_lower() == "true"
			"holdkeephead": m["hold_keep_head"] = v.to_lower() == "true"
			"colorperfect": m["color_perfect"] = _color_guess(v)
			"colorgood": m["color_good"] = _color_guess(v)
			"hideparticles": m["hide_particles"] = v.to_lower() == "true"
			"holdrepeat": m["hold_repeat"] = v.to_lower() == "true"
	return m


## PT 在线包的 meta.json：{name, author, res{文件名}, holdType, hitEvtType, hitEvtDrawer}
static func _parse_meta_json(txt: String) -> Dictionary:
	var m := {"source": SRC_ONLINE, "ok": true}
	var j: Variant = JSON.parse_string(txt)
	if not (j is Dictionary):
		return {"ok": false, "error": "invalid meta.json"}
	var d: Dictionary = j
	m["name"] = String(d.get("name", ""))
	m["author"] = String(d.get("author", ""))
	m["desc"] = String(d.get("description", d.get("desc", "")))
	if d.has("holdAtlas"):
		m["hold_atlas"] = _pair(str(d["holdAtlas"]))
	# 判定粒子的形状由包自己声明：PT 把绘制代码原样放在 hitEvtDrawer 里交给 canvas 执行
	# （官方 Phigros 包是 `ctx.fillRect(x-r3/2, y-r3/2, r3, r3)`=方块，缺省是 arc=圆）。
	# 只看这段代码画的是什么图形，不猜别的：认不出来的表达式一律按圆处理。
	var drawer := String(d.get("hitEvtDrawer", ""))
	if drawer.contains("fillRect"):
		m["hit_shape"] = "square"
	elif drawer.contains("arc"):
		m["hit_shape"] = "circle"
	elif int(String(d.get("hitEvtType", "0")).to_int()) == 1:
		m["hit_shape"] = "square"
	return m


static func _pair(v: String) -> Array:
	var nums: Array = []
	for part in String(v).trim_prefix("[").trim_suffix("]").split(","):
		nums.append(float(String(part).strip_edges()))
	while nums.size() < 2:
		nums.append(0.0)
	return [int(nums[0]), int(nums[1])]


## prpr parse_color_guess_alpha：>0xffffff 当 ARGB，否则当 RGB
## ⚠ 包写的是**十六进制**（"0xFF827C" / "e1ffec9f"）：is_valid_int() 只认十进制，
## 拿它当门会把一切带字母的颜色整个判成"无效"⇒ 回落白色（元·菱简的 0xFF827C 就是这么丢的）。
static func _color_guess(v: String) -> Color:
	var s := String(v).strip_edges().trim_prefix("#").trim_prefix("0x").trim_prefix("0X")
	if not s.is_valid_hex_number(false):
		return Color.WHITE
	var n := s.hex_to_int()
	if n > 0xffffff:
		return Color.from_rgba8((n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, (n >> 24) & 0xff)
	return Color.from_rgba8((n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, 255)


static func _looks_like_zip(src: String) -> bool:
	if src.to_lower().ends_with(".zip"):
		return true
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null:
		return false
	var b := f.get_buffer(4)
	f.close()
	return b.size() == 4 and b[0] == 0x50 and b[1] == 0x4B and b[2] == 0x03 and b[3] == 0x04


## zip 里所有条目的公共根长度（"pack/click.png" 全都有 "pack/" 前缀 → 返回 5）
static func _common_root(names: PackedStringArray) -> int:
	if names.is_empty():
		return 0
	var first := String(names[0])
	var cut := first.find("/")
	if cut < 0:
		return 0
	for f in names:
		if String(f).find("/") != cut or not String(f).begins_with(first.substr(0, cut)):
			return 0
	return cut + 1


static func _dest_id(name: String) -> String:
	var clean := ""
	for c in name.strip_edges():
		clean += c if not (c in ["/", "\\", ":", "?", "*", "|", "\"", "<", ">", "."]) else "-"
	clean = clean.strip_edges()
	if clean == "":
		clean = "skin"
	var id := clean
	var n := 2
	while DirAccess.dir_exists_absolute(ROOT.path_join(id)):
		id = "%s-%d" % [clean, n]
		n += 1
	return id


static func _ensure_dir(path: String) -> void:
	var da := DirAccess.open("user://")
	if da != null:
		da.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


static func _copy_tree(from: String, to: String) -> void:
	_ensure_dir(to)
	var da := DirAccess.open(from)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.copy_absolute(ProjectSettings.globalize_path(from.path_join(String(f))),
				ProjectSettings.globalize_path(to.path_join(String(f))))
	for d in da.get_directories():
		_copy_tree(from.path_join(String(d)), to.path_join(String(d)))


## ⚠ 4.7 实测：`DirAccess.remove_absolute()` 对**非空**目录返回 FAILED(1) 且整个目录留着
## （不是权限问题——同一路径下建文件都成功）。所以先自己下钻删文件，最后删空壳。
## 公共口：测试夹具与在线拉取都要用同一份，别各处再抄一遍错的删法。
static func rmtree(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	var da := DirAccess.open(abs)
	if da != null:
		da.include_hidden = true
		for f in da.get_files():
			da.remove(String(f))
		for d in da.get_directories():
			rmtree(abs.path_join(String(d)))
	DirAccess.remove_absolute(abs)
