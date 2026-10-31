class_name GlitchFx
extends Control
## fluXis MultiModeSelect「???」按钮故障特效移植（参考 fluxis-src
## Screens/Multiplayer/SubScreens/MultiModeSelect.cs + DrawableExtensions.Shake）：
## 点击未实现功能的按钮 → 按钮抖动（200ms ±15px）+ 全屏红闪（α0.5 → 600ms 灭）+
## glitch/chroma 强度瞬跳峰值、再 600ms OutQuint 衰减（fluXis Styling.TRANSITION_MOVE=600）。
## 本地化改动：1 秒内点满 5 次 → 按钮染色变「Phigrim 独占」同款并禁用，点不下去。
## 接线：game.gd._on_nav 的兜底分支——任何没人处理的 nav id 自动吃到本特效。

const DUR := 0.6                                  # fluXis Styling.TRANSITION_MOVE
const MAX_CLICKS := 5                             # fluXis=10 次，按需求改 1s 内 5 次
const CLICK_WINDOW_MS := 1000
const RED := Color("aa0000")  # fluXis Theme.Red = HSL(0, 1, 2/3)（from_hsv 非常量表达式，换算成 hex）
const SHAKE_DUR := 0.2                            # fluXis Shake(200, 15)
const SHAKE_MAG := 15.0
const SHAKE_BOUNCES := 4
# 峰值强度：fluXis 实测 chroma.StrengthTo(16) / glitch.StrengthTo(1).Strength2To(1).Strength3To(.04)
const CHROMA_PEAK := 16.0
const GLITCH_PEAK := 1.0
const BLOCK_PEAK := 0.04
# 「Phigrim 独占」播放钮同款暗化（song_select._sync_play: modulate = Color(.55,.55,.6,.55)）
const LOCKED_MOD := Color(0.55, 0.55, 0.6, 0.55)
# fluXis 同款错误音：MultiModeButton(Locked) 点击播 Samples/Multiplayer/access-denied
const ERR_SFX := "res://assets/sfx/access-denied.wav"
const SFX_POOL := 3                 # 连点允许重叠（fluXis Sample.Play 每次开新声道）

## 按钮被「按灭」（1s 内连点 5 次上锁）时发射一次。彩蛋门控听这个信号。
signal locked(btn: Control)

var _mat: ShaderMaterial
var _fx_rect: ColorRect
var _flash: ColorRect
var _sfx: Array[AudioStreamPlayer] = []
var _sfx_i := 0
var _vals := {"chroma": 0.0, "glitch_x": 0.0, "glitch_y": 0.0, "block": 0.0}
var _tws := {}                # 参数名 → 运行中 Tween（连点重跳峰值，先杀旧的防双 tween 抢同一参数）
var _shake_tw: Tween
var _shake_base := {}  # 抖动中的按钮 → 原始 position（抖动中再点必须以原始位为基准，否则逐次越漂越歪）
var _flash_tw: Tween
var _click_ms: Array[int] = []
var _locked: Array[Control] = []  # 已按灭的按钮（顺序即上锁顺序）

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := load("res://shaders/glitch_chroma.gdshader") as Shader
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_fx_rect = ColorRect.new()
	_fx_rect.material = _mat
	_fx_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fx_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx_rect.visible = false  # 空闲不采样屏幕纹理
	add_child(_fx_rect)
	_flash = ColorRect.new()
	_flash.color = RED
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.modulate.a = 0.0
	add_child(_flash)
	var st := load(ERR_SFX) as AudioStream
	if st != null:
		for i in SFX_POOL:
			var p := AudioStreamPlayer.new()
			p.stream = st
			add_child(p)
			_sfx.append(p)

## 一次「点了个没实现的按钮」：全套反馈 + 连点计数
func click(btn: Control) -> void:
	if not _sfx.is_empty():
		_sfx[_sfx_i % _sfx.size()].play()  # 轮转池：连点重叠播放，不掐上一声
		_sfx_i += 1
	var now := Time.get_ticks_msec()
	_click_ms.append(now)
	while not _click_ms.is_empty() and now - int(_click_ms[0]) > CLICK_WINDOW_MS:
		_click_ms.pop_front()
	_shake(btn)
	_flash_screen()
	_pulse("chroma", CHROMA_PEAK)
	_pulse("glitch_x", GLITCH_PEAK)
	_pulse("glitch_y", GLITCH_PEAK)
	_pulse("block", BLOCK_PEAK)
	if _click_ms.size() >= MAX_CLICKS:
		_click_ms.clear()
		_lock(btn)

## 强度瞬跳峰值（fluXis dur=0）→ DUR 秒 OutQuint 归零
func _pulse(param: String, peak: float) -> void:
	_fx_rect.visible = true
	if _tws.has(param) and (_tws[param] as Tween).is_valid():
		(_tws[param] as Tween).kill()
	_set_val(param, peak)
	var tw := create_tween()
	tw.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT)
	tw.tween_method(_apply_val.bind(param), peak, 0.0, DUR)
	_tws[param] = tw

# tween_method 只带一个 float 值，bind 的参数排在它后面
func _apply_val(v: float, param: String) -> void:
	_set_val(param, v)

func _set_val(param: String, v: float) -> void:
	_vals[param] = v
	_mat.set_shader_parameter("u_" + param, v)

func _process(_dt: float) -> void:
	if not _fx_rect.visible:
		return
	_mat.set_shader_parameter("u_screen_size", get_viewport_rect().size)
	if _idle():
		_fx_rect.visible = false  # 参数全 0 时输出=原画面，直接收掉

func _idle() -> bool:
	for k in _vals:
		if absf(float(_vals[k])) > 0.0005:
			return false
	return true

## 全屏红闪：fluXis redBox.FadeTo(.5f).FadeOut(600)（跳到 0.5 再线性灭）
func _flash_screen() -> void:
	if _flash_tw != null and _flash_tw.is_valid():
		_flash_tw.kill()
	_flash.modulate.a = 0.5
	_flash_tw = create_tween()
	_flash_tw.tween_property(_flash, "modulate:a", 0.0, DUR)

## fluXis DrawableExtensions.Shake：BOUNCES 个随机偏移 + 回原点，
## 分段时长 = 总长/(bounces+1)，首段 OutSine、中段 InOutSine、末段 InSine。
## 基准 = 首次抖动时记下的原始 position：连点落在抖动周期内（0.12s < 0.2s）时
## 若拿当前 position 当基准，回弹会停在歪的位置上，越点越漂。
func _shake(target: Control) -> void:
	if _shake_tw != null and _shake_tw.is_valid():
		_shake_tw.kill()
	if not _shake_base.has(target):
		_shake_base[target] = target.position
	var base: Vector2 = _shake_base[target]
	var seg := SHAKE_DUR / float(SHAKE_BOUNCES + 1)
	var tw := create_tween()
	for i in SHAKE_BOUNCES:
		var p := base + Vector2(randf_range(-SHAKE_MAG, SHAKE_MAG), randf_range(-SHAKE_MAG, SHAKE_MAG))
		tw.tween_property(target, "position", p, seg).set_trans(Tween.TRANS_SINE)\
		  .set_ease(Tween.EASE_OUT if i == 0 else Tween.EASE_IN_OUT)
	tw.tween_property(target, "position", base, seg).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.finished.connect(func() -> void: _shake_base.erase(target))
	_shake_tw = tw

## 1 秒内点满 5 次：按钮变「Phigrim 独占」同款暗化（渐变 0.3s）并禁用
func _lock(btn: Control) -> void:
	btn.disabled = true
	if not _locked.has(btn):
		_locked.append(btn)
	var tw := create_tween()
	tw.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(btn, "modulate", LOCKED_MOD, 0.3)
	locked.emit(btn)

## 已按灭的按钮数（彩蛋门控用）
func locked_count() -> int:
	return _locked.size()

func is_locked(btn: Control) -> bool:
	return _locked.has(btn)
