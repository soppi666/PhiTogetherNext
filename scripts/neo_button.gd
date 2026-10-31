class_name NeoButton
extends Button
## 组件 = 原语的组合 + 状态契约：base fill + hover layer + flash layer。
## rest/hover/press/selected/disabled 是同一棵节点树的不同属性值，不是不同节点。
## 视觉体系：普通态=深紫黑磨砂半透明 + 极淡边框；粉只出现在 hover/选中的边框与轻叠层。

@export var accent: Color = UiTokens.ACCENT
@export var min_size_hint: Vector2 = Vector2(280, 64)        # add_child 前赋值才有效（_ready 读取）
@export var pill: bool = false                               # true=胶囊形（圆角=高度一半；正方形即圆形）
## 图标水平镜像：设置页滑条右端那颗"加大"钮直接复用 back.svg 翻一下，
## 不新增素材（多一个 res:// 文件就要多一次导入，而且两份素材以后会走样）。
@export var icon_flip := false
## 纯图标钮：不要那 24px 的文字内边距（否则空文案时它会把最小宽顶成 48，圆钮变椭圆）
@export var icon_only := false
@export var square_left: bool = false                        # 左端两角直角（贴屏边元素用）
@export var square_right: bool = false                       # 右端两角直角（中心对称于 square_left）
const BTN_BG_A := 0.50   # 按钮底的黑色不透明度（用户 2026-10-28 定 50%；主观旋钮，越大越"实"）
@export var hover_lift: float = UiTokens.HOVER_LIFT          # 悬停粉叠层强度（主观旋钮）
@export var press_scale: float = UiTokens.PRESS_SCALE        # 按下压缩比例
@export var flash_strength: float = UiTokens.FLASH_STRENGTH  # 点击回弹闪光强度
@export var icon_path: String = ""                           # 非空=图标模式：SVG 居中、隐藏文案
@export var icon_ratio: float = 0.45                         # 图标高 = 按钮高 × 该比例

## 面上的进度：**从左到右填充**（0..1；<0=不画）。下载类按钮用它报进度。
## 画成子 Panel：Button 自己的 NOTIFICATION_DRAW 不保证会调到脚本的 _draw()；
## z=0 压在 hover/flash 叠层之下、图标与文字之上（那两层是 1/2，图标 3）。
var progress := -1.0
var _fill: Panel
var _fill_sb: StyleBoxFlat

var _hover_layer: Panel
var _flash_layer: Panel
var _label: Label
var _scale_tw: Tween   # scale 只有一个属主，杀死旧 tween 再开新的，绝不双 tween 抢同一属性
var _hover_tw: Tween
var _radius_sbs: Array[StyleBoxFlat] = []  # 底+两层叠层的样式盒，pill 模式随高度同步半径
var _sb: StyleBoxFlat
var _hovered := false
var _selected := false
var _down := false             # 手指还按着（触屏没有 hover，靠它点亮内环）
var _ring: Panel
var _ring_sb: StyleBoxFlat

func _ready() -> void:
	focus_mode = FOCUS_NONE
	var caption := text  # 必须先在清空前捕获文案
	text = ""
	custom_minimum_size = min_size_hint
	_build_style()
	_build_layers(caption)
	_center_pivot()
	_apply_radius()
	mouse_entered.connect(_on_hover_changed.bind(true))
	mouse_exited.connect(_on_hover_changed.bind(false))
	button_down.connect(_on_press)
	button_up.connect(_on_release)
	resized.connect(_center_pivot)
	resized.connect(_apply_radius)
	if disabled:
		modulate.a = UiTokens.DISABLED_ALPHA
	if icon_path != "":
		_apply_icon(icon_path, icon_ratio)
	if progress >= 0.0:
		set_progress(progress)   # 下载按钮一上来就带填充
	_apply_visuals()  # 内环可见性由状态算：ready 之前 set_selected 过的按钮要补一次

## 文案走这里。_ready 后 Button 原生 text 必须保持空（_ready 已清空自绘通道），
## 再写 text 会让 Button 在内部 Label 之外多画一份白字（双文字 bug）
func set_caption(v: String) -> void:
	if not is_node_ready():
		text = v  # 未 ready：先存原生 text，_ready 会捕获后清空
		return
	_label.text = v

## 当前文案（_ready 后 text 被清空，真实文案在内部 Label 上）
func caption() -> String:
	if _label != null:
		return _label.text
	return text

## 布局驱动的字号（百分比 UI 用：随带高缩放），低于 8px 按 8px
func set_font_size(px: int) -> void:
	_label.add_theme_font_size_override("font_size", maxi(px, 8))

## 按当前 size 定字号：高 42%，或按字数摊宽 92%（CJK 字宽≈字号，4 字按钮不能被撑爆）。
## 开始游戏 / 结算页的继续·重玩 共用这一条，字号规则才不会两边各长一份。
func fit_font() -> void:
	var n := maxi(caption().length(), 1)
	set_font_size(int(minf(size.y * 0.42, size.x / float(n) * 0.92)))

## 文字颜色覆盖（如难度 tier 色）
func set_text_color(c: Color) -> void:
	_label.add_theme_color_override("font_color", c)

## 图标模式：SVG 图标居中、隐藏文案；图标高 = 按钮高 × ratio
var _icon: TextureRect

func set_icon(path: String, ratio: float = 0.45) -> void:
	if is_node_ready():
		_apply_icon(path, ratio)
	else:
		icon_path = path  # 交给 _ready 尾部统一建（避免改树回调里 await 的竞态）
		icon_ratio = ratio

## 图标模式开关：隐藏图标时恢复文案显示（如 Phigrim 独占提示直接写在按钮上）
func set_icon_shown(v: bool) -> void:
	if _icon != null:
		_icon.visible = v
	if _label != null:
		_label.visible = not v

## 图标染色：白色系 SVG 用 modulate 直接调色（删除红 / 收藏黄）
var _icon_tint := Color(1, 1, 1, 1)

func set_icon_tint(c: Color) -> void:
	_icon_tint = c
	if _icon != null:
		_icon.modulate = c

func _apply_icon(path: String, ratio: float) -> void:
	icon_path = ""  # 防止 _ready 重复建
	_label.visible = false
	_label.text = ""  # 双保险：Label 与按钮自绘文字都清掉
	if _icon != null:
		# 换图（收藏空心↔实心）：只换 texture，不重建、不重复连 resized
		_icon.texture = load(path)
		icon_ratio = ratio
		_sync_icon()
		return
	_icon = TextureRect.new()
	_icon.texture = load(path)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# 中心锚点（对边锚点相等）：_sync_icon 要显式写 position/size 做等比居中，
	# 用 FULL_RECT 的话在 _ready 前设 size 会撞 Godot 的
	# "non-equal opposite anchors will have their size overridden after _ready()" 警告
	_icon.set_anchors_preset(Control.PRESET_CENTER)
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.z_index = 3
	_icon.modulate = _icon_tint
	add_child(_icon)
	resized.connect(_sync_icon)
	_sync_icon()

func _sync_icon() -> void:
	if _icon == null:
		return
	_icon.flip_h = icon_flip
	# 等比居中：先定尺寸再定位（锚点是中心，写 position/size 不会被 _ready 后的布局覆盖）
	var side := minf(size.x, size.y) * icon_ratio
	_icon.size = Vector2(side, side)
	_icon.position = (size - Vector2(side, side)) * 0.5

## 进度 0..1；传 -1 收起。填充宽度 = 按钮宽 × f，像进度条一样从左往右长。
func set_progress(f: float) -> void:
	progress = f
	if not is_node_ready():
		return
	_ensure_fill()
	_sync_fill()

func _ensure_fill() -> void:
	if _fill != null:
		return
	_fill = Panel.new()
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill.z_index = 0
	_fill_sb = StyleBoxFlat.new()
	_fill_sb.bg_color = Color(accent.r, accent.g, accent.b, 0.45)
	_fill.add_theme_stylebox_override("panel", _fill_sb)
	add_child(_fill)
	resized.connect(_sync_fill)

func _sync_fill() -> void:
	if _fill == null:
		return
	var on := progress >= 0.0
	_fill.visible = on
	_fill.position = Vector2.ZERO
	_fill.size = Vector2(size.x * clampf(progress, 0.0, 1.0), size.y)
	_apply_fill_radius()

## 填充只圆**左**边（跟随按钮形状），右边是直的——那才是"从左到右填充"
func _apply_fill_radius() -> void:
	if _fill_sb == null:
		return
	var r := _radius()
	var l: int = 0 if square_left else r
	_fill_sb.corner_radius_top_left = l
	_fill_sb.corner_radius_bottom_left = l
	_fill_sb.corner_radius_top_right = 0
	_fill_sb.corner_radius_bottom_right = 0

func set_ui_disabled(v: bool) -> void:
	disabled = v
	if disabled:
		_kill(_hover_tw)
		_hover_layer.modulate.a = 0.0
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "modulate:a", UiTokens.DISABLED_ALPHA if disabled else 1.0, 0.2)

func _build_style() -> void:
	_sb = StyleBoxFlat.new()
	# 底色=**半透明黑**（用户 2026-10-28 先要"透明"，看到全透明后确认"黑色透明度，对了"）：
	# 压一层黑让文字立得住，同时透出背后糊好的画面。原来的 SURFACE_FROST 是 78% 深色磨砂，
	# 等于按钮自己贴了块不透光的板子，"背景模糊"根本没生效。alpha 是主观旋钮（BTN_BG_A）。
	_sb.bg_color = Color(0, 0, 0, BTN_BG_A)
	_sb.set_corner_radius_all(_radius())
	# 左右各 24 的文字内边距只给**有字**的按钮：空文案的纯图标圆钮会被它顶出 48 的最小宽，
	# 于是"给它 42.8 正方圆"实际拿到 48×42.8 的椭圆（设置页滑条两端那两颗就是这么变形的）。
	_sb.content_margin_left = 0.0 if icon_only else 24.0
	_sb.content_margin_right = 0.0 if icon_only else 24.0
	# 那圈 1px 细边彻底不要了（用户："能不能彻底把那特别细的边框去掉"）：常态无边框，
	# 选中/按下才有 4px 白色内环；阴影同理去掉（半透明底上糊一圈脏影）。
	_sb.set_border_width_all(0)
	_sb.shadow_color = UiTokens.SHADOW
	_sb.shadow_size = 0
	_sb.shadow_offset = Vector2.ZERO
	# 所有状态共用同一样式盒：视觉变化全部交给属性突变 + 叠层，避免主题默认态打架
	_radius_sbs.append(_sb)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		add_theme_stylebox_override(state, _sb)
	var empty := StyleBoxEmpty.new()
	add_theme_stylebox_override("focus", empty)

## selected：粉边框 + 稍亮磨砂底（与 hover 同族但常亮）
func set_selected(v: bool) -> void:
	_selected = v
	_apply_visuals()

func _apply_visuals() -> void:
	var on := _hovered or _selected or _down
	# 底色恒定、边框恒无：状态只由"内环 + 悬停叠层"表达
	if _ring != null:
		_ring.visible = on and not disabled

func _build_layers(caption: String) -> void:
	_hover_layer = _make_overlay(Color(accent.r, accent.g, accent.b, hover_lift), 1)
	_flash_layer = _make_overlay(Color(1, 1, 1, 1.0), 2)  # 强度全部交给 modulate，样式盒恒为不透明白
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)  # Button 不是容器，子 Label 需手动铺满
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.text = caption
	_label.add_theme_font_size_override("font_size", UiTokens.BUTTON_FONT)
	_label.add_theme_color_override("font_color", UiTokens.INK)
	_label.z_index = 3  # Label 必须画在两层叠层之上
	add_child(_hover_layer)
	add_child(_flash_layer)
	add_child(_label)
	_ring = Panel.new()
	_ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring_sb = StyleBoxFlat.new()
	_ring_sb.draw_center = false          # 只画边，不挡底下的字
	_ring_sb.set_border_width_all(maxi(int(UiTokens.ring_w(get_viewport_rect().size.y)), 1))
	_ring_sb.border_color = UiTokens.RING_ON
	_ring.add_theme_stylebox_override("panel", _ring_sb)
	_ring.z_index = 3                     # 压在 label 上：环是边缘装饰，不该被字盖住半圈
	_ring.visible = false
	add_child(_ring)
	resized.connect(_sync_ring)
	_sync_ring()

func _make_overlay(fill: Color, z: int) -> Panel:
	var p := Panel.new()
	p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(_radius())  # Panel 才能圆角，ColorRect 会露出方角
	_radius_sbs.append(sb)
	p.add_theme_stylebox_override("panel", sb)
	p.z_index = z
	p.modulate.a = 0.0  # 强度动画走 modulate，样式盒颜色保持常量
	return p

func _center_pivot() -> void:
	pivot_offset = size * 0.5  # Button 无 pivot_offset_size，靠 resized 保持居中

## pill 模式：圆角=高度一半（正方形→圆形，宽矩形→胶囊）。StyleBoxFlat 半径是 int
## 圆角口径：pill=半高（正圆/胶囊），非 pill=设计常量。square_left/right 让贴边那侧保持方角。
## （0.5% 屏高那次改错了：用户 2026-10-28 说"不是圆角"，指的不是这个量。）
func _radius() -> int:
	return int(size.y * 0.5) if pill else UiTokens.RADIUS

func _apply_radius() -> void:
	var r := _radius()
	_sync_ring(r)
	for sb in _radius_sbs:
		sb.set_corner_radius_all(r)
		if square_left:
			sb.corner_radius_top_left = 0
			sb.corner_radius_bottom_left = 0
		if square_right:
			sb.corner_radius_top_right = 0
			sb.corner_radius_bottom_right = 0
	_apply_fill_radius()

## 内环几何：离边缘留 RING_INSET 一道缝，圆角也跟着缩（不然环会自己变成另一个圆角）
## ⚠ 用 offset 不用 position/size：_ring 是全矩形锚点，直接在 _ready 里 set_size 会撞
## Godot 的 "Nodes with non-equal opposite anchors will have their size overridden
## after _ready()"（每个按钮每次 resized 都刷一条，一次启动 200 条刷屏）。
func _sync_ring(r: int = -1) -> void:
	if _ring == null or not is_node_ready():
		return
	var ins: float = UiTokens.RING_INSET
	if _ring.offset_left != ins or _ring.offset_top != ins \
			or _ring.offset_right != -ins or _ring.offset_bottom != -ins:
		_ring.offset_left = ins
		_ring.offset_top = ins
		_ring.offset_right = -ins
		_ring.offset_bottom = -ins
	if r < 0:
		r = _radius()
	_ring_sb.set_border_width_all(maxi(int(UiTokens.ring_w(get_viewport_rect().size.y)), 1))
	var rr: int = maxi(r - int(ins), 0)
	_ring_sb.set_corner_radius_all(rr)
	if square_left:
		_ring_sb.corner_radius_top_left = 0
		_ring_sb.corner_radius_bottom_left = 0
	if square_right:
		_ring_sb.corner_radius_top_right = 0
		_ring_sb.corner_radius_bottom_right = 0

func _on_hover_changed(on: bool) -> void:
	if disabled:
		return
	_hovered = on
	_apply_visuals()
	_kill(_hover_tw)
	_hover_tw = create_tween()
	_hover_tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if on:
		_hover_tw.tween_property(_hover_layer, "modulate:a", 1.0, UiTokens.DUR_HOVER_IN)
	else:
		_hover_tw.tween_property(_hover_layer, "modulate:a", 0.0, UiTokens.DUR_HOVER_OUT)

func _on_press() -> void:
	_down = true
	_apply_visuals()
	_kill(_scale_tw)
	_scale_tw = create_tween()
	_scale_tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_scale_tw.tween_property(self, "scale", Vector2(press_scale, press_scale), UiTokens.DUR_PRESS)

func _on_release() -> void:
	_down = false
	_apply_visuals()
	_kill(_scale_tw)
	_scale_tw = create_tween()
	# 无过冲：elastic 会让按钮回弹两下（"会弹也不对"），CUBIC/OUT 是干净地收回来
	_scale_tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_scale_tw.tween_property(self, "scale", Vector2.ONE, UiTokens.DUR_RELEASE)
	# 闪光：快亮慢灭，灭在 0.2s 区间（慢闪会被读成"卡在按下态"）
	_flash_layer.modulate.a = flash_strength
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(_flash_layer, "modulate:a", 0.0, UiTokens.DUR_FLASH)

func _kill(tw: Tween) -> void:
	if tw != null and tw.is_valid():
		tw.kill()
