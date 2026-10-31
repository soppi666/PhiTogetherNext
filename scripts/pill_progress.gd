class_name PillProgress
extends Control
## 胶囊底子的进度条：画在文字**下面**（PanelContainer 把每个子节点铺满同一格，
## 所以只要先于 Label add_child 就在下层）。用于 Level 胶囊——经验不再绕成头像环，
## 而是"Level 的背景有进度条"（用户 2026-10-27）。
##
## 画法跟"下载"那根填充**同一套**（NeoButton._ensure_fill）：一个 Panel 子节点 +
## StyleBoxFlat，宽度=frac×满宽，**只圆左边的角、右边保持直角**，才读得出"从左往右填"。
## 早先这里是按弧采样一颗跑道，23% 时宽度不足一个直径就退化成一个圆点，
## 用户判"经验进度表现不对，怎么会是圆形呢"——跑道外轮廓本来就不该由填充自己决定。

@export var frac: float = 0.0 : set = set_frac
@export var fill_color: Color = Color(UiTokens.ACCENT.r, UiTokens.ACCENT.g, UiTokens.ACCENT.b, 0.34)
# 胶囊的 StyleBoxFlat 有内容边距，容器因此把子节点铺在"内缩"的那一格；
# 填充要盖住整颗胶囊，所以按同一份内缩量往外画。
@export var bleed: Vector2 = Vector2.ZERO : set = set_bleed

var _fill: Panel
var _sb: StyleBoxFlat

func set_frac(v: float) -> void:
	var nv := clampf(v, 0.0, 1.0)
	if absf(nv - frac) < 0.0005:
		return
	frac = nv
	_sync()

func set_bleed(v: Vector2) -> void:
	if v.is_equal_approx(bleed):
		return
	bleed = v
	_sync()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill = Panel.new()
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sb = StyleBoxFlat.new()
	_fill.add_theme_stylebox_override("panel", _sb)
	add_child(_fill)
	resized.connect(_sync)
	_sync()

## 供外部改完颜色/尺寸后立刻重算（resized 只在尺寸真的变了才发）
func refresh() -> void:
	_sync()

func _sync() -> void:
	if _fill == null or _sb == null or not is_node_ready():
		return
	var full := size + bleed * 2.0
	_fill.visible = frac > 0.0005 and full.x > 1.0
	_fill.position = -bleed
	_fill.size = Vector2(maxf(full.x * clampf(frac, 0.0, 1.0), 0.0), maxf(full.y, 0.0))
	_sb.bg_color = fill_color
	var r := maxi(int(full.y * 0.5), 0)
	_sb.corner_radius_top_left = r
	_sb.corner_radius_bottom_left = r
	_sb.corner_radius_top_right = 0
	_sb.corner_radius_bottom_right = 0
