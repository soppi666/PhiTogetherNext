class_name SkinPreview
extends Control

## 皮肤演示带：**就是游玩那套渲染**——一张只有 8 个事件的演示谱喂给真的 `ChartPlayer`，
## 画布尺寸=真实屏幕尺寸，带子只是这块画布正中开的一个窗口（`clip_contents` 裁掉两侧）。
##
## 为什么走到这一步：前四轮我一直在"照着游玩画一个像的"，于是每一轮都有新差异
## （音符大小、双押并排、特效没颜色、粒子出界、下落太快）。用户第四轮定案：
## "演示区域使用真实的播放，宽度也是真实的宽度" ⇒ 别再留第二份实现。
## 现在音符/长条/判定线/命中特效/判定粒子的**全部**画法都来自 chart_player.cpp，
## 演示里看到什么，进歌就是什么。
##
## 节拍与"多押为什么是两条"见 `SkinDemoChart` 的注释。
## 声音是舞台那层的活（player 不出声），所以打击音仍由这里按事件时刻放。

signal info(text: String)

var pack := {}
var hit_volume := 1.0

var _cp: ChartPlayer
var _t := 0.0
var _fired := {}
var _pool: Array[AudioStreamPlayer] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 真实画布比这块带宽得多，两侧必须裁掉（clip_contents 连子节点的绘制一起裁）
	clip_contents = true
	for i in 4:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	_build()


## 建 player + 载入演示谱。换包不用重建（set_pack 只重贴贴图），换屏幕尺寸要重摆。
func _build() -> void:
	if _cp != null and is_instance_valid(_cp):
		_cp.free()
		_cp = null
	# 背景由设置页整页铺（一张完整糊量的底图）；演示带只叠画面，不再自画一张。
	_cp = ChartPlayer.new()
	add_child(_cp)
	_fit_canvas()
	var bytes := JSON.stringify(SkinDemoChart.build()).to_utf8_buffer()
	if not _cp.load_chart_json(bytes):
		info.emit("演示谱载入失败")
		return
	_cp.set_judgment_windows(UserPrefs.num("perfect_ms"), UserPrefs.num("good_ms"))
	# 多押提示这里**强制开**：演示带的职责就是把 *_hl 那批给你看，
	# 而 *_hl 只在 multi 时才用（原生 mm = n.multi && _multiHint）
	_cp.set_multi_hint(true)
	_cp.set_autoplay(true)
	_apply_skin()
	_t = 0.0
	_fired.clear()
	_cp.set_now(0.0)
	_cp.queue_redraw()


## 画布=真实屏幕尺寸，带子居中开窗：这样音符就是进歌后那个尺寸（屏宽/8080×note_scale），
## 而不是"塞进 30% 宽条里的缩小版"。
## ⚠ ChartPlayer 是 **Node2D**（不是 Control）：只有 position，没有 size/anchors。
func _fit_canvas() -> void:
	if _cp == null or not is_instance_valid(_cp):
		return
	var vp := get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	_cp.set_scale(vp.x, vp.y)
	_cp.position = Vector2((size.x - vp.x) * 0.5, (size.y - vp.y) * 0.5)


func set_pack(p: Dictionary) -> void:
	pack = p
	_apply_skin()
	queue_redraw()


## 把当前资源包贴到 player 上：与游玩**同一条链**（SkinPack.apply_to：13 个槽全给 +
## 粒子形状 + 包自带的表现参数）。两边各写一遍就是"演示看着对、进游戏不对"的源头。
func _apply_skin() -> void:
	if _cp == null or not is_instance_valid(_cp):
		return
	SkinPack.apply_to(_cp, pack)
	_cp.set_note_scale(UserPrefs.num("note_scale"))
	_cp.set_fx_user_scale(UserPrefs.num("fx_scale"))


func _process(dt: float) -> void:
	if not is_visible_in_tree() or size.x < 8.0:
		return
	_fit_canvas()
	_t += dt
	if _t >= SkinDemoChart.LOOP:
		# 循环=整局重开：判定态/特效池/音符状态全部归零，否则第二轮不再有命中特效
		_t = fmod(_t, SkinDemoChart.LOOP)
		_fired.clear()
		_cp.reset_play_state()
		_cp.set_now(0.0)
	for ev in SkinDemoChart.sounds():
		var th: float = float(ev[0])
		if _t >= th and not _fired.has(th):
			_fired[th] = true
			for k in int(ev[2]):
				play_hit(String(ev[1]))
	_cp.set_now(_t)
	_cp.queue_redraw()


func _visibility_changed() -> void:
	if not is_visible_in_tree():
		hush()


func _exit_tree() -> void:
	hush()


## 停掉全部在响的打击音（切分类/退出设置都走这里）
func hush() -> void:
	for pl in _pool:
		(pl as AudioStreamPlayer).stop()


static func sound_name(kind: String) -> String:
	match kind:
		"drag":
			return "HitSong1"
		"flick":
			return "HitSong2"
		_:
			return "HitSong0"       # tap 与 hold 头都是 click 音（与舞台 HIT_DEFAULTS 一致）


## 放这个包对应的打击音；包里没有 → 内置音（与游玩时同一条回落链）
func play_hit(name: String) -> void:
	var s := SkinPack.sound(pack, name)
	if s == null:
		var p := "res://assets/skin/hitsounds/%s.ogg" % name
		if ResourceLoader.exists(p):
			s = load(p) as AudioStream
	if s == null:
		info.emit("这个包没有 %s 的打击音" % name)
		return
	for pl in _pool:
		if not pl.playing:
			_play(pl, s)
			return
	_play(_pool[0], s)


## 外部（QA/别处）手动来一声的入口：kind 用音符类型名，与 SkinDemoChart 的编号同源
func hit(kind: String) -> void:
	play_hit(sound_name(kind))


func _play(pl: AudioStreamPlayer, s: AudioStream) -> void:
	pl.stream = s
	pl.volume_db = linear_to_db(maxf(hit_volume, 0.001))
	pl.play()


## QA 用：把时钟一小步一小步推到 t（autoplay 只有在"走过"判定窗时才会真的判出命中，
## 直接 set_now 跳过去会一条都不判——那是定帧 QA 实测过的坑）。推完停在原地等截图。
func debug_seek(t: float) -> void:
	if _cp == null or not is_instance_valid(_cp):
		return
	_cp.reset_play_state()
	_fired.clear()
	var step := 1.0 / 60.0
	var tt := 0.0
	while tt < t:
		_cp.set_now(tt)
		tt += step
	_t = tt
	_cp.set_now(_t)
	_cp.queue_redraw()
	queue_redraw()


## QA 用：命中时刻 t 那条音符的屏幕坐标（走原生 debug_note_worlds，就是它真正画出来的位置）。
## 判据：x=画布中心、y=判定线（画布 70% 高）⇒ 证明"真实画布 + 真实尺寸"这条路是通的。
func debug_note_at(t: float) -> Vector2:
	if _cp == null or not is_instance_valid(_cp):
		return Vector2(-1, -1)
	var vp := get_viewport_rect().size
	for rec in _cp.debug_note_worlds(t):
		var a: Array = rec
		if absf(float(a[4])) < 1.0:      # dist=0 ⇒ 这条正好压在线上了
			return Vector2(float(a[2]), float(a[3]))
	return Vector2(-1, -1) if vp.x > 0.0 else Vector2(-1, -1)


## QA 用：演示谱一共几个音符（多押那四个各 2 条 → 12）
func debug_note_count() -> int:
	return 0 if _cp == null else _cp.get_total_notes()


## QA 用：解析**之后**的音符 [时刻, x, type]。
## 必须读原生 debug_notes 而不是自己再解析一遍 JSON：字段名写成 typeID 时
## JSON 里看着一切正常，只有解析后的 type 才暴露"全变成默认 Tap"。
func debug_notes_dump() -> Array:
	var out: Array = []
	if _cp == null:
		return out
	for rec in _cp.debug_notes():
		var a: Array = rec
		out.append([float(a[2]), float(a[4]), int(a[5])])   # [t, x, type]
	out.sort_custom(func(p, q): return float(p[0]) < float(q[0]))
	return out


## QA 用：当前活着的命中特效数（证明 autoplay 真的判了、特效真的生成了）
func debug_fx_count() -> int:
	return 0 if _cp == null else _cp.debug_fx_count()
