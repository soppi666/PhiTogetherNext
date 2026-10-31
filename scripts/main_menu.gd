class_name MainMenu
extends Control
## 主菜单（按手绘规格）：按钮区 = 屏宽 50%→90%、屏高 40% 起。
## 三行各占屏高 12%，行隙 3%；行2/3 右侧为真正方形（宽=高），其余宽度给左侧按钮。
## 行1 单人游戏整行；行2 多人游戏 + 回放；行3 活动 + 设置。头像/显示栏在 PlayerHud（跨页面常驻）。

const X0 := 0.50
const X1 := 0.90
const Y0 := 0.40
const ROW_H := 0.12  # 屏高占比
const GAP_Y := 0.03  # 屏高占比
const GAP_X := 0.03  # 屏高占比（左右按钮之间，与行隙同源）

var _b_single: NeoButton
var _b_multi: NeoButton
var _b_replay: NeoButton
var _b_event: NeoButton
var _b_settings: NeoButton

signal nav(id)

func _ready() -> void:
	_b_single = _btn("单人游戏", "single")
	_b_multi = _btn("多人游戏", "multi")
	_b_replay = _btn("回放", "replay")
	_b_event = _btn("活动", "event")
	_b_settings = _btn("设置", "settings")
	get_viewport().size_changed.connect(_layout)
	_layout()

func button_for(id: String) -> NeoButton:
	match id:
		"single": return _b_single
		"multi": return _b_multi
		"replay": return _b_replay
		"event": return _b_event
		"settings": return _b_settings
	return null

func _btn(caption: String, id: String) -> NeoButton:
	var b := NeoButton.new()
	b.text = caption
	b.min_size_hint = Vector2.ZERO  # 纯百分比定位，不受最小尺寸干扰
	add_child(b)
	b.pressed.connect(func() -> void: nav.emit(id))
	return b

## 入场级联："逐渐显示"——5 个按钮按阅读序逐个浮现（只动 alpha/scale，零重排；
## 时长由秒定义，120Hz 屏上每一帧都是新状态）。被 game.gd 转场调用。
func reveal() -> void:
	UiMotion.cascade([_b_single, _b_multi, _b_replay, _b_event, _b_settings],
		UiTokens.DUR_ITEM, UiTokens.STEP_ITEM, 0.0)

## 退场：整页淡出后由 done 隐藏（页面根是全矩形 Control，淡出期间仍在最上层吃掉输入）
func fade_out(done: Callable) -> void:
	UiMotion.fade_out(self, UiTokens.DUR_PAGE_OUT, done)

func _layout() -> void:
	var vp := get_viewport_rect().size
	var bx := vp.x * X0
	var bw: float = vp.x * (X1 - X0)
	var row_h := vp.y * ROW_H
	var font := int(row_h * 0.42)
	var y := vp.y * Y0
	_place(_b_single, Rect2(bx, y, bw, row_h), font)
	y += row_h + vp.y * GAP_Y
	var sq_w := row_h  # 真正方形：宽=高
	var gap_x := vp.y * GAP_X  # 左右间距同样按屏高百分比
	var flex_w: float = bw - sq_w - gap_x
	var sq_x := bx + bw - sq_w
	_place(_b_multi, Rect2(bx, y, flex_w, row_h), font)
	_place(_b_replay, Rect2(sq_x, y, sq_w, row_h), font)
	y += row_h + vp.y * GAP_Y
	_place(_b_event, Rect2(bx, y, flex_w, row_h), font)
	_place(_b_settings, Rect2(sq_x, y, sq_w, row_h), font)

func _place(b: NeoButton, rect: Rect2, font: int) -> void:
	b.position = rect.position
	b.size = rect.size
	b.set_font_size(font)
