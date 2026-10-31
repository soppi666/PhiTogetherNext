class_name UiTokens
extends RefCounted
## 设计 token 层：近黑（非纯黑）底 + 单一粉强调 + 磨砂深紫表面。
## 粉色只用于 hover/选中/边框/关键强调；文字浅灰白；组件只问"意义"，不写字面颜色。

const ACCENT := Color("ff66aa")

# 圆角分级：大面板 20 / 普通按钮 14 / 歌曲卡片 16
const R_PANEL := 20
const R_BUTTON := 14
## 移动端「帧率上限=不限」时向系统声明的目标帧率。
## Godot 4.7 的 DisplayServer 只有 `screen_get_refresh_rate()`（当前档），没有"面板最高支持档"
## 的 getter（extension_api-4.7.json 查过），所以只能自己给一个目标值：
## 面板支持更高档时这是 Swappy 拿去 `ANativeWindow_setFrameRate` 的表态；面板只有 60 时
## vsync 照样把帧压回 60，不会因此变快或变慢。要改这一处即可（game.gd / chart_stage.gd 都读它）。
const MOBILE_TARGET_FPS := 120
const R_CARD := 16
const RADIUS := R_BUTTON  # 兼容旧引用

# 表面：半透明磨砂深紫黑
const SURFACE_FROST := Color(0.105, 0.085, 0.120, 0.78)
const SURFACE_FROST_HI := Color(0.165, 0.125, 0.185, 0.85)
const SURFACE_PANEL := Color(0.095, 0.080, 0.110, 0.72)
const BORDER_FAINT := Color(1, 1, 1, 0.07)
## 按下/选中的高亮：**白色内环**（离形状边缘留一道缝），不再用粉色贴边描边
## （用户 2026-10-28："圆角按钮的圆角边框十分明显，特别是圆形小按钮…改为内边框白色"）
const RING_ON := Color(1, 1, 1, 0.85)
## 内环线宽 = 屏高的 0.5%（用户 2026-10-28 确认："边框半径 0.5% 高度"指的是这条环的粗细）。
## 全站一个值：按钮环、卡片选中环、难度胶囊环都从这里取，粗细不一致会显得不是一套东西。
const RING_W_OF_H := 0.005
static func ring_w(view_h: float) -> float:
	return maxf(maxf(view_h, 1.0) * RING_W_OF_H, 1.0)
const RING_W := 2.0
# 环离边缘的缝：0 = 贴着形状边缘往内画（用户 2026-10-28 指着一张留了 3px 缝的截图说
# "有边框没有的区域"——缝那条带看起来像"边框没盖到的地方"，所以贴边才对）
const RING_INSET := 0.0
const SHADOW := Color(0, 0, 0, 0.35)

# 文字层级（避免大面积纯黑/超粗）
const INK := Color(0.91, 0.90, 0.94)
const INK_SUB := Color(0.64, 0.62, 0.70)
const TITLE_FONT := 40
const H1_FONT := 26
const BODY_FONT := 18
const META_FONT := 14
const BUTTON_FONT := 22

# 组件契约常量
const HOVER_LIFT := 0.10  # hover 粉叠层强度
const PRESS_SCALE := 0.97
const FLASH_STRENGTH := 0.18
const DISABLED_ALPHA := 0.42

# 时长词汇表
const DUR_HOVER_IN := 0.06
const DUR_HOVER_OUT := 0.35
const DUR_PRESS := 0.06
# 回弹：原来 0.45s + TRANS_ELASTIC = 会"啵"地弹两下，用户 2026-10-28 判"会弹也不对，
# 而且不够快"。按下反馈要在 0.1s 量级收干净，所以缩短到 0.12s 且用不带过冲的曲线。
const DUR_RELEASE := 0.12
const DUR_FLASH := 0.2
const ENTER_STAGGER := 0.1

# 转场/级联词汇表（全部「秒」：Tween 每个渲染帧重采样一次，120Hz 屏就得到 120 个中间态。
# 上限压在 0.3s 内——高刷屏上转场比操作慢会被读成"卡了一下"，见 UiMotion）
const DUR_PAGE_IN := 0.26
const DUR_PAGE_OUT := 0.14
const DUR_ITEM := 0.22
const MOTION_POP := 0.94  # 入场起始缩放（相对静止缩放）
const STEP_ITEM := 0.022  # 组内逐项间隔
const STEP_GROUP := 0.05  # 组与组之间的间隔
const STEP_CARD := 0.016  # 曲库卡片级联（30 张 ≈ 0.48s 内落完）
const DUR_DIP := 0.1  # 黑幕落底
const DUR_DIP_OUT := 0.22  # 黑幕揭开（盖住开谱解析/首帧烘焙的耗时）

## level 0 = 最深背景；带一点紫调，非纯黑
static func bg(level: int) -> Color:
	var v: float = 0.075 + 0.04 * float(level)
	return Color.from_hsv(ACCENT.h, 0.16, v)

## 难度等级色（暂定值，等参考图校准）
const TIER_COLORS := {
	"EZ": Color("58c19b"),
	"HD": Color("e8a44b"),
	"IN": Color("d95c6e"),
	"AT": Color("c9a24b"),
}

static func tier_color(code: String) -> Color:
	if TIER_COLORS.has(code):
		var c: Color = TIER_COLORS[code]
		return c
	return ACCENT

## 曲库卡片上"难度小胶囊"的配色（用户 2026-10-28 逐条给的口径，与上面那张旧表**不同**）：
## SP、或等级不在 0..18 → 白；EZ 1~5 青绿 / 6~18 绿；HD 1~10 青 / 11~18 蓝；
## IN 1~15 黄 / 16~18 红；AT 一律紫；其它难度名（NM/EX/IF/LG/自定义…）按等级套同一条梯度。
## 边界按"1到5"含 5 的读法：≤5 归低档。
const PILL_EZ_LOW := Color("3fd8b4")   # 青绿
const PILL_EZ_HI := Color("63db5b")    # 绿
const PILL_HD_LOW := Color("3fc8f0")   # 青
const PILL_HD_HI := Color("5b7cf5")    # 蓝
const PILL_IN_LOW := Color("f5d34a")   # 黄
const PILL_IN_HI := Color("f0504e")    # 红
const PILL_AT := Color("b463e8")       # 紫
const PILL_NONE := Color("ffffff")     # 白（SP / 等级越界 / 认不出）

static func tier_pill_color(code: String, level: int) -> Color:
	var c := code.strip_edges().to_upper()
	if c == "SP" or level < 0 or level > 18:
		return PILL_NONE
	if c == "AT":
		return PILL_AT
	if c == "EZ":
		return PILL_EZ_LOW if level <= 5 else PILL_EZ_HI
	if c == "HD":
		return PILL_HD_LOW if level <= 10 else PILL_HD_HI
	if c == "IN":
		return PILL_IN_LOW if level <= 15 else PILL_IN_HI
	if level <= 5:
		return PILL_EZ_LOW
	if level <= 10:
		return PILL_HD_LOW
	if level <= 15:
		return PILL_IN_LOW
	return PILL_IN_HI

static func text_on(fill: Color) -> Color:
	if fill.get_luminance() > 0.5:
		return Color.from_hsv(fill.h, 0.40, 0.10)
	return INK

## 全局回退字体：ChillRound（Phigros 风圆体）为主，系统字体链兜底（α 等符号 + 中文缺字）
static var _sys_chain: SystemFont
static var _bold: FontFile

static func sys_chain() -> SystemFont:
	if _sys_chain == null:
		_sys_chain = SystemFont.new()
		_sys_chain.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Segoe UI Symbol", "Segoe UI"])
	return _sys_chain

static func install_font() -> Font:
	var f := load("res://fonts/ChillRoundRegular.woff2") as FontFile
	f.fallbacks = [sys_chain()]
	ThemeDB.fallback_font = f
	return f

## 曲名/作曲专用粗体（同一字体家族 Bold + 同兜底链）
static func font_bold() -> Font:
	if _bold == null:
		_bold = load("res://fonts/ChillRoundBold.woff2") as FontFile
		_bold.fallbacks = [sys_chain()]
	return _bold
