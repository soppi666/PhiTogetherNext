class_name UiMotion
extends RefCounted
## 时间驱动的 UI 动画原语层——"必须有 120 帧在跑"的落地点。
##
## 理念三条（写死在接口里，不给调用方留按帧的机会）：
## 1) 所有时长以「秒」定义，中间态交给 Godot Tween 在**每个渲染帧**重新采样：
##    显示器 120Hz 就得到 120 个不同状态，60Hz 得到 60 个。绝不用"每帧 += 常数"，
##    也绝不放 `_physics_process`（4.x 默认 60 tick，会让动画在高刷屏上被量化成 60 帧）。
## 2) 只动 alpha / scale 这类纯 transform+颜色通道，绝不 tween 容器子节点的 position
##    （布局会抢；百分比布局每帧重算就是卡顿源），所以转场是零重排的。
## 3) 单属主纪律：一个节点的 alpha 通道、scale 通道各只允许一条 tween（meta 存句柄，
##    开新的前杀旧的并回到记录的静止基准），与 NeoButton._scale_tw / GlitchFx._tws 同族。
##
## QA 约定：`enabled=false`（任意 --qa* 截图链路里由 game.gd 关掉）时所有原语直接落到
## 静止态，截图/对拍永远拿到稳定帧；`--qaanim` 是专门测动画的窗口，保持开启。

const K_TW := "um_tw"          # alpha 通道正在跑的 Tween
const K_TW_SC := "um_tw_sc"    # scale 通道正在跑的 Tween（与 alpha 互不杀）
const K_REST := "um_rest"      # 静止 modulate（禁用态 0.42 / 独占暗都原样记在里面）
const K_REST_SC := "um_rest_sc"  # 静止 scale（选中卡 1.03 这类基准不是 ONE）

static var enabled := true

static func _kill(n: Node, key: String) -> bool:
	if not n.has_meta(key):
		return false
	var tw: Tween = n.get_meta(key)
	var running := tw != null and tw.is_valid()
	if running:
		tw.kill()
	n.remove_meta(key)
	return running

static func _kill_all(n: Node) -> bool:
	var a := _kill(n, K_TW)
	var b := _kill(n, K_TW_SC)
	return a or b

## 立刻落到静止态（换页、转场被打断、QA 确定性都靠它）
static func snap(n: Control) -> void:
	if not is_instance_valid(n):
		return
	_kill_all(n)
	if n.has_meta(K_REST):
		n.modulate = n.get_meta(K_REST)
		n.scale = n.get_meta(K_REST_SC)

static func snap_all(list: Array) -> void:
	for e in list:
		if e is Control:
			snap(e as Control)

## 开动画前的"接手续"：杀旧 tween → 回到它记录的静止基准 → 以当前静止值立新基准。
## 为什么不复用第一次的快照：换页时 _sync_play()/set_ui_disabled() 会绝对赋值 modulate
## （禁用灰、独占暗），动画必须落在最新静止值上，否则淡入完把该暗的按钮又点亮。
static func _take(n: Control) -> Color:
	var running := _kill_all(n)
	if running and n.has_meta(K_REST):
		n.modulate = n.get_meta(K_REST)
		n.scale = n.get_meta(K_REST_SC)
	else:
		n.set_meta(K_REST, n.modulate)
		n.set_meta(K_REST_SC, n.scale)
	return n.get_meta(K_REST)

## 淡入：alpha 从 base×from_a 起，dur 秒回到 base.a。
## enabled=false 时**什么都不碰**：调用方已经把静止值设好了，入场起始值由本函数提供，
## 所以关动画 = 保持原样（而不是"还原"成某个可能不存在的首帧快照）。
static func fade_in(n: Control, dur: float, delay: float = 0.0, from_a: float = 0.0) -> void:
	if not is_instance_valid(n) or not enabled:
		return
	var base := _take(n)
	n.modulate = Color(base.r, base.g, base.b, base.a * from_a)
	var tw := n.create_tween()
	tw.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	if delay > 0.0:
		tw.tween_interval(delay)  # 4.7 Tween 没有 set_delay，级联只能排成 series 步
	tw.tween_property(n, "modulate:a", base.a, dur)
	n.set_meta(K_TW, tw)

## 入场：淡入 + 以静止缩放为基准从 from_scale 弹到位（pivot 居中，容器抢不走）
static func pop_in(n: Control, dur: float, delay: float = 0.0, from_scale: float = UiTokens.MOTION_POP) -> void:
	if not is_instance_valid(n) or not enabled:
		return
	var base := _take(n)
	var rest_sc: Vector2 = n.get_meta(K_REST_SC)
	n.pivot_offset = n.size * 0.5
	n.modulate = Color(base.r, base.g, base.b, 0.0)
	n.scale = rest_sc * from_scale
	var tw := n.create_tween()
	tw.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	if delay > 0.0:
		tw.tween_interval(delay)
	tw.parallel().tween_property(n, "modulate:a", base.a, dur)
	tw.parallel().tween_property(n, "scale", rest_sc, dur)
	n.set_meta(K_TW, tw)

## 逐渐显示：一组控件按顺序级联。from_scale<0 = 纯淡入（文字类不给缩放，避免字面抖动）
static func cascade(list: Array, dur: float, step: float, delay: float = 0.0,
		from_scale: float = UiTokens.MOTION_POP) -> void:
	var i := 0
	for e in list:
		if e is Control:
			var d := delay + float(i) * step
			if from_scale < 0.0:
				fade_in(e as Control, dur, d)
			else:
				pop_in(e as Control, dur, d, from_scale)
		i += 1

## 退场淡出：落定后先跑 done（一般是 visible=false），再还原静止值——
## 下一次进场的基准才是干净的
static func fade_out(n: Control, dur: float, done: Callable = Callable()) -> void:
	if not is_instance_valid(n):
		if done.is_valid():
			done.call()
		return
	if not enabled:
		_hide_now(n, done)
		return
	var base := _take(n)
	n.modulate = base
	var tw := n.create_tween()
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)  # 退场比入场快，不留"粘住"感
	tw.tween_property(n, "modulate:a", 0.0, dur)
	if done.is_valid():
		tw.tween_callback(done)
	tw.tween_callback(_restore.bind(n))
	n.set_meta(K_TW, tw)

static func _hide_now(n: Control, done: Callable) -> void:
	if done.is_valid():
		done.call()
	_restore(n)

static func _restore(n: Control) -> void:
	snap(n)

## 任意节点（全屏黑幕也走它）alpha 从 a0 → a1，完成后可选回调。
## 不走静止记账：黑幕的 a1=0 就是它的常态，不该被 snap 还原成"入场前的 alpha"。
static func alpha(n: Control, a0: float, a1: float, dur: float,
		trans: Tween.TransitionType, ease: Tween.EaseType, done: Callable = Callable()) -> void:
	if not is_instance_valid(n):
		if done.is_valid():
			done.call()
		return
	_kill(n, K_TW)
	if dur <= 0.0 or not enabled:
		n.modulate.a = a1
		if done.is_valid():
			done.call()
		return
	n.modulate.a = a0
	var tw := n.create_tween()
	tw.set_trans(trans).set_ease(ease)
	tw.tween_property(n, "modulate:a", a1, dur)
	if done.is_valid():
		tw.tween_callback(done)
	n.set_meta(K_TW, tw)

## 状态补间（选中/hover 这类"目标值由状态算出来"的通道）：起点取当前值，天然可打断续接。
## 目标同时写进静止记账——状态的落点就是新的静止态（卡片压暗 0.85 之后，
## 下一次页面级联要淡入到 0.85 而不是把它点亮）。
static func to_modulate(n: Control, target: Color, dur: float) -> void:
	if not is_instance_valid(n):
		return
	_kill(n, K_TW)
	n.set_meta(K_REST, target)
	if not enabled or dur <= 0.0:
		n.modulate = target
		return
	var tw := n.create_tween()
	tw.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	tw.tween_property(n, "modulate", target, dur)
	n.set_meta(K_TW, tw)

static func to_scale(n: Control, target: Vector2, dur: float) -> void:
	if not is_instance_valid(n):
		return
	_kill(n, K_TW_SC)
	n.set_meta(K_REST_SC, target)
	if not enabled or dur <= 0.0:
		n.scale = target
		return
	n.pivot_offset = n.size * 0.5
	var tw := n.create_tween()
	tw.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	tw.tween_property(n, "scale", target, dur)
	n.set_meta(K_TW_SC, tw)
