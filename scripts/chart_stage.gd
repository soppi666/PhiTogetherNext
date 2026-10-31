extends Control
class_name ChartStage
## 谱面游玩舞台：模糊曲绘背景 + ogg 音频 + 原生 ChartPlayer（GDExtension 渲染/判定）
## + 界面控件层（暂停/combo/分数/精度/曲名/等级/进度条，位置按 player GameUI 规格）。

signal finished
## 自然打完：把 PT 结算页需要的数据交给 game。继续（回选曲）/重玩（重开本谱）都由 game 处理，
## 因为只有它知道"刚才从哪一页进来"。发这条就不发 finished，舞台继续活着当结算页的底。
signal results_ready(payload: Dictionary)
## 曲绘（含烘焙完的模糊版）：宽画布两侧带要用同一张图，game 收到后换掉它的底图
signal background_ready(tex: Texture2D)

var _cp: ChartPlayer

var _csv: SubViewport            # 内容离屏层（bg+线+HUD）：特效链的干净底图，杜绝逐帧反馈
var _lsv: SubViewport            # 游戏层（仅判定线+音符，透明底）：非 global 特效的作用对象（player Game.ts:853）
var _lout: TextureRect           # 非 global 链结果贴回 _csv（z40：bg 之上、HUD 之下）
var _host: Control               # 全部内容节点的父级（在 _csv 内）
var _content_out: TextureRect    # 主屏上显示 _csv 纹理
var _fx_root: Control            # 非 global 链 pass 视口池（须在 _csv 之前更新：gout 在 _host 里消费它）
var _fx_units: Control           # 单元（幽灵层）SubViewport 容器——树序最先，链池在其后
var _fx_post: Control            # global 链容器（_csv 之后更新）+ _fx_out
var _fx_sv: Array = []                # 链式特效的离屏 SubViewport 池（非 global）
var _fx_quads: Array = []             # 每个离屏视口里的全屏 ColorRect
var _gx_sv: Array = []                # global 链视口池（输入=_csv 合帧，须晚于 _csv 更新）
var _gx_quads: Array = []
var _gx_age: Array = []
var _fx_pending := false           # 本帧链上有首渲染视口被扣着没贴 → 暂停/冻结态也要续跑预热
var _fx_age: Array = []               # 池视口已渲染帧数（0=首帧 RT 未初始化，不得采样显示）
var _fx_mats := {}                    # shader 键 → ShaderMaterial（参数每帧覆写）
var _fx_fparams := {}                 # shader 键 → 该 shader 真有的 float uniform 集合
var _fx_ssize := {}                   # shader 键 → 转译注入的 fx_screen_size 是否存在
var _fx_out: TextureRect              # 最终叠加层（盖在 HUD 上=player 相机级滤镜语义）
var _fx_custom := {}                  # glsl 文件路径 → 运行时转译的 Shader
var _dir := ""                   # 谱面目录（找谱内自带 .glsl 用）
# —— 官方谱 blockArea（噪域）：彩蛋门控 GameFlags.block_area（主菜单四钮全按灭）才建层 ——
# C++ 只出几何/相位/触点语义（KaedePhi 语义），合成与表现在这一层：
# 表现 = 移植 Phira-Pro/prpr 的官方管线：C++ build_block_mask() 每帧算 1/4 屏效果网格
# （六层栅格 → 减算阈值窗 XOR → BlockNoise1 位移 warp → 9 邻域膨胀出 Edge/Glow 环），
# shader 只做颜色合成。低预设（F10，render_scale<1）走 GPU 近似：掩码改用 SubViewport+
# Polygon2D 现画（只有覆盖，没有 warp/膨胀环），喂同一个 shader。
# 层级照官方：Active = 后处理（盖住音符与 HUD），Disabled = 背景层（判定线之前，纯加色）。
var _bsv: SubViewport            # GPU 近似路径的掩码视口（树序须在 _csv 之前）
var _blk_white: ImageTexture
var _blk_zero: ImageTexture
var _bmg: BlockMaskGPU              # GPU 掩码（zone→final→aux + 读回）
var _blayer: Node2D              # 掩码池父节点
var _bpool: Array = []           # Polygon2D 池（列表序 = 合成序）
var _bout: ColorRect             # Active 层（由 game.gd 提到 game 层 z52）
var _bdis: ColorRect             # Disabled 层（_host 内 z5，判定线之前）
var _bmat: ShaderMaterial        # Active 材质（uLayer=3）
var _bdmat: ShaderMaterial       # Disabled 材质（uLayer=0）
var _norm_mat: CanvasItemMaterial
var _sub_mat: CanvasItemMaterial
var _bmask_img: Image            # CPU 掩码纹理（RGBA8）
var _baux_img: Image
var _bmask_tex: ImageTexture
var _baux_tex: ImageTexture
# 逐区配色（RPE 标记线的 colorEvents → prpr block_color.rs 的调色板）：只有存在
# 非默认区色的谱才会建这两张，官方红谱一个像素都不多读。
var _bcol_img: Array = [null, null]   # 0=Active 1=Disabled
var _bcol_tex: Array = [null, null]
# ── 噪域层（rpe-next noiseAreaLayers）：N>1 时每层一对 dis/act 全屏层 ──
var _blayer_defs: Array = []
var _blayer_nodes: Array = []   # [{act, dis, ma, md, img, aimg, tex, atex, cimg:[..], ctex:[..]}]
var _skin_root: Control = null  # 噪域皮肤 pass 的 SubViewport 容器（树序在 _csv 之后）
var _skin_disps: Array = []     # 各层皮肤回贴 TextureRect（清理用）
var _has_skin_layer := false
var _bcol_empty: ImageTexture         # 1×1 空纹：uColored=0 时占住采样器（prpr EMPTY_TEX）

# ── 噪域特效链（targetRange 深度 16）──
# 作者把 effects 的 targetRange 指到 16，噪域 Active 层就进离屏、被这条链扫，
# 链完再按预乘回贴到它原来的层位（game 层 z=52，HUD 之上、相机滤镜之下）。
# 未被认领时**一行都不走**：_bout 仍旧直接挂在 game 层，与改动前逐像素一致。
# 为什么单独一条池而不塞进 _units：单元的更新序在 _csv 之前（gout 要在画布内回贴），
# 而噪域要采的现场就是 _csv ⇒ 链必须排在 _csv 之后，否则场内的背景永远晚一帧。
const BgBlur := preload("res://scripts/bg_blur.gd")  # 背景虚化烘焙（舞台 / 菜单共用）

const BLOCK_DEPTH := 16.0
var _bx_rt: SubViewport            # Active 层的离屏目标（透明，画布尺寸）
var _bx_sv: Array = []             # 链 pass 池（复用 _fx_pass(pool=2)）
var _bx_quads: Array = []
var _bx_age: Array = []
var _blk_out: TextureRect          # 链输出回贴（预乘 alpha），与 _bout 二选一提到 game 层
var _blk_chained := false          # 本帧 Active 层是否在离屏里
var _bx_rt_age := 0              # 刚进离屏的预热帧数（SubViewport 本帧末才渲染）
var _blk_tail_sv: SubViewport    # 链尾复位的离屏（见 _blk_tail）
var _blk_tail_mat: ShaderMaterial
var _blocks_on := false
var _blk_cpu := true             # false = GPU 近似路径（低预设）
var _bover_warned := false
var _blk_mask_us := 0            # CPU 掩码构建耗时（µs/帧，压力谱要看这个）
var _blk_n := 0
var _blk_skip_tick := 0            # 掩码隔帧更新的节拍
var _blk_gpu_n := 0
var _blk_skip := 0               # "全空且与上一帧相同"被跳过的帧数（性能诊断）
const BLOCK_POOL := 64           # ハテ IN 实测同时可见峰值 59（全谱 781 块）
const BLOCK_DIS_Z := 5
const BLOCK_ACT_Z := 20          # 舞台内基准值；进舞台后 game.gd 会提到 game 层 z52
# 官方材质参数滑杆（主观量按 [[feedback-expose-subjective-tuning]] 暴露成实时可调，
# 默认值 = block_shader.rs 的原值）
@export_range(0.0, 2.0) var block_edge_opacity: float = 0.8:  # _EdgeOpacity
	set(v):
		block_edge_opacity = v
		_bset("_EdgeOpacity", v)
@export_range(0.0, 2.0) var block_glow: float = 0.8:          # _GlowIntensity
	set(v):
		block_glow = v
		_bset("_GlowIntensity", v)
@export_range(0.0, 2.0) var block_fill_strength: float = 0.667:  # 火花混进填充的比例
	set(v):
		block_fill_strength = v
		_bset("_FillStrength", v)
## 默认取官方导出值 0.667。对帧实测过：官方 122409 边界内侧 = (77,0,0)，即
## 0.333×0.667 的背景透过 + fill(43,3,3)——那里曲绘本就是黑的。我方一度"发白"是
## 因为同一时刻我方背景是亮的曲绘，不是 alpha 不够（抬到 0.92 反而比官方案件更闷）。
@export_range(0.0, 2.0) var block_fill_opacity: float = 0.667:   # 本体不透明度（_FillOpacity）
	set(v):
		block_fill_opacity = v
		_bset("_FillOpacity", v)
@export_range(0.0, 12.0) var block_spark_map: float = 5.69:      # _SparkMapOpacity
	set(v):
		block_spark_map = v
		_bset("_SparkMapOpacity", v)
@export_range(0.0, 1.0) var block_displace: float = 0.15:        # _DisplaceStrength（UV 单位）
	set(v):
		block_displace = v
		_bset("_DisplaceStrength", v)
@export_range(1.0, 24.0) var block_pixel_scale: float = 6.0:     # _BackgroundPixelScale（几屏幕像素一格）
	set(v):
		block_pixel_scale = v
		_bset("_BackgroundPixelScale", v)
@export_range(0.0, 2.0) var block_warp: float = 1.0:             # 掩码位移幅度（1.0=官方 0.1UV；0=边缘只抖动不推移）
	set(v):
		block_warp = v
		if _cp != null:
			_cp.set_block_warp(v)
@export_range(0.0, 1.0) var block_alpha: float = 1.0:            # 整层透明度（叠加在官方值上）
	set(v):
		block_alpha = v
		_bset("uAlphaMul", v)
## 预警红块的不透明度。用户定义："给一个大红色块，告诉你马上要在某处出现无法判定的区域"，
## 并且"就像噪域、只是没有边界没有动态、透明度为一半" → 默认 0.5。
@export_range(0.0, 1.0) var block_warn_opacity: float = 0.4:
	set(v):
		block_warn_opacity = v
		_bset_warn(v)

# —— 噪域听感（官方 block_audio.rs）：有手指被 Active 域「感染」期间，给**乐曲**挂
# 1500Hz 低通；第一次进入是 0 秒（瞬切），之后每次进入/退出用 0.1 秒过渡。
# ── 响度标准化（设置页「音量→音量标准化」）──
# 运行时没有"把整首 ogg 解成样本"的 API（AudioStreamOggVorbis 不给 PCM），
# 所以走 Godot 给的这条路：乐曲单独一条总线 + AudioEffectCapture 抓总线输出，
# 开局前 LOUD_SECS 秒累计平方和 → RMS → 一次性把增益回补到目标响度，之后不再动
# （不做逐帧 AGC，游玩中途音量来回泵会被当成 bug）。
# LUFS 的 K 计权与门限不在运行时做，这里用 RMS dBFS 近似，目标 −14。
var _music_bus: StringName = &""
var _cap: AudioEffectCapture = null
var _loud_sum := 0.0
var _loud_n := 0
var _norm_db := 0.0
var _loud_done := false
const LOUD_TARGET_DB := -14.0
const LOUD_SECS := 5.0

var _blk_lp: AudioEffectLowPassFilter
var _blk_lp_i := -1      # 低通所在总线序号
var _blk_lp_ei := -1     # 低通在该总线上的 effect 序号（真旁路时要关的就是它）
var _blk_noise_sz := Vector2i.ZERO   # 喂给 C++ 的位移图尺寸（0=没喂上，边界会变直线）
# 噪域 Active 层的矩形=整屏，而游玩画布只是中间那块 16:9：把画布矩形喂给 shader，
# 宽屏（>16:9）时红场不再铺到左右曲绘带上（用户 2026-10-08 报）。16:9 时恒等 ⇒ 零影响。
var _blk_field := Vector4(0.0, 0.0, 1.0, 1.0)   # 画布在整屏 UV 里的矩形 x,y,w,h
var _blk_screen_px := Vector2.ZERO              # 整屏设备像素（背景快照吸附用）
var _blk_field_px := Vector2.ZERO               # 画布设备像素（场内位移噪声吸附用）
var _blk_lp_on := false      # 当前目标是否为「已压低」
var _blk_lp_used := false    # 是否曾经进入过（决定 0s / 0.1s）
var _blk_lp_cur := 22050.0

## 「全频」目标的天花板。写死 22050 是个移动端口坑：Android 上很常见的 44100 混音率下
## 22050 **正好等于奈奎斯特**，Godot 的 AudioFilterSW 把 cutoff 钳到 mix_rate*0.5 后
## ω=π ⇒ α=sin(π)/(2Q)≈0 ⇒ 双极点压在 z=-1、传递函数 0/0，二阶低通当场退化。
## 用户实测的表现就是"手指离开噪域后整条音乐没了"（按下时 1500Hz 反而正常）。
## 留 10% 余量取 0.45×混音率，并且在扫频结束后直接把 effect 摘出链路（真旁路），
## 双保险：既不会退化，也不用为了"不压低"而一直跑一个滤波器。
func _blk_full_hz() -> float:
	var mr := float(AudioServer.get_mix_rate())
	if mr <= 8000.0:
		return 3500.0
	return clampf(minf(22050.0, mr * 0.45), 1500.0, 22050.0)

func _all_block_mats() -> Array:
	var out: Array = [_bmat, _bdmat]
	for L in _blayer_nodes:
		if L["ma"] != null:
			out.append(L["ma"])
		if L["md"] != null:
			out.append(L["md"])
	return out

func _bset(k: String, v: float) -> void:
	for m in _all_block_mats():
		if m != null:
			m.set_shader_parameter(k, v)

## 预警不透明度只属于 Disabled 那一层（官方常量 uDisabledFillOpacity=0.4）。
## 它和 Active 的 _FillOpacity 是两个不同的量，绝不能同名喂给 _bset：
## 那等于用一根滑杆同时改两条 pass，官方值一动就对不上参考实现了。
func _bset_warn(v: float) -> void:
	for m in _all_block_mats():
		if m != null and m != _bmat:
			m.set_shader_parameter("uDisabledFillOpacity", v)
# —— targetRange 深度路由（player ShaderPipeline.ts:305 / Game.ts:857）——
# 每个"范围组"一个渲染单元：幽灵 ChartPlayer（set_state_source 共享主实例全部状态，
# 判定/触点/特效队列全在主实例算，幽灵只按 keep 桶绘制）+ 镜像容器 + 链 + 回贴 gout。
var _units: Array = []
var _use_seq := 0
var _qa_fx_dump := false              # --qafxpng：只在 QA 启动时给每个单元抄一份诊断快照（热路径不建字典）
var _line_depths: Array = []          # 每条线的深度桶（线序=文件序）
var _note_depths: Array = []          # 音符容器深度桶（去重升序）
var _fx_depths: Array = []            # 命中特效容器深度桶
var _hud_home := {}                   # Control → 认领时的原父节点（归还用）
# player GameUI 组件深度（8..15）：targetRange ≥8 认领的是 HUD
const HUD_Z := {
	"_btn_pause": 8.0, "_lbl_combo": 9.0, "_lbl_combo_tag": 10.0,
	"_lbl_score": 11.0, "_lbl_acc": 12.0, "_bar": 13.0,
	"_lbl_title": 14.0, "_lbl_level": 15.0,
}
var block_cell := 0             # 噪域掩码网格单元（画布 px）：0=自动
var line_tex_tint_mode := 0      # 线贴图判定色：0=自动(白灰蒙版染色) 1=从不(player 一致) 2=总是
var _attach_holders := {}        # ui 名 → {holder, els, a0}：attachUI 线带动的 HUD 组
const ATTACH_MAP := {
	"score": ["_lbl_score", "_lbl_acc"],
	"combonumber": ["_lbl_combo"],
	"combo": ["_lbl_combo_tag"],
	"name": ["_lbl_title"],
	"level": ["_lbl_level"],
	"pause": ["_btn_pause"],
	"bar": ["_bar"],
}
var _audio: AudioStreamPlayer
var _clock := 0.0
var _clock_last := 0.0
# 音频头可信度（见 _lock_clock）：拔耳机/换默认输出后 pos 会钉住，得能从"锁相"退到"帧时"
const AUDIO_STALL_SEC := 0.35
var _pos_prev := 0.0
var _pos_stall := 0.0
var _revive_wait := 0.0
var _audio_started := false
var _touches := {}
var _saw_touch := false  # 见到过真实 InputEventScreenTouch ⇒ 其后的 MouseButton 是 touch
						  # 合成出来的（emulate_mouse_from_touch 在 Android 上必须开，UI 靠它）
var _is_mobile := OS.has_feature("mobile")  # 手机没有真鼠标：鼠标通道一律不进判定
var _paused := false
var _bg: TextureRect
var _dbg: DebugOverlay  # F12 线/音符序号调试层（默认关）
var _dbg_lbl: Label     # 设置页「调试模式」：游玩中常驻的帧率/线程读数
var _bg_sharp: Texture2D  # 未模糊的原图：PT 结算页曲绘卡用的就是 app.bgImage（ResultPage.ts:26）
var _baking := false
## 背景虚化是**异步**烘焙（2~12 轮可分离高斯，每轮等一次 frame_post_draw ⇒ 4~24 帧）。
## 用户 2026-10-08 要求"等背景虚化完成再开始播放谱面"：不然开头看到的是清晰曲绘、
## 半秒后"啪"地糊掉。这里只把**落拍**（_audio.play）推迟，布局/信号照常立刻装好，
## 这样 QA 脚本里 start() 之后紧接 freeze_at() 的写法不受影响。
var _bg_blur_pending := false
var _audio_start_pending := false
var _audio_start_deadline := 0
# —— 打击音效（player createHitsound：仅 Perfect/Good 触发；hitsound 属性→谱面包资源）——
var _hit_pool: Array = []
var _hit_idx := 0
## 打击音声部按"音"分组：同一种音的 3 个 AudioStreamPlayer 在**创建时就挂好流**，
## 播放路径上不再出现 set_stream。
## 为什么非这样不可（perfR 真机 µs 读数）：打击音这一栏在 autoplay 下要 0.31~0.90ms/帧，
## 而一次 `play()` 在这台手机的音频驱动上本来就 ~1ms（见 _hit_cap 注释）；同一个播放器
## 反复 set_stream 会把这条播放停掉再重建 playback，等于把重建摊到每一响上。
## 轮转取下一部：同音连发时不互相掐断（8 部轮转的老语义保留，只是每部不再改流）。
var _hit_groups := {}
var _hit_rr := {}
const HIT_VOICES := 3
var _chart_sounds := {}
var _song_stream: AudioStream = null   # 本局乐曲流（录制器据此取"音乐开头→结尾"的时长）
var _sfx_cache := {}
@export_range(0.0, 1.0) var hit_sound_volume: float = 0.5:
	set(v):
		hit_sound_volume = v
		for p in _hit_pool:
			p.volume_db = linear_to_db(v) if v > 0.001 else -80.0

## player 语义 = 一次性烘焙高斯模糊（ctx.filter blur 115·blur px）。
## 这里：降采样 → GPU 可分离高斯多次迭代 → 双线性放回原尺寸。
func _cheap_blur_tex(tex: Texture2D) -> Texture2D:
	var img := tex.get_image()
	if img == null or img.is_empty():
		return null
	img.convert(Image.FORMAT_RGBA8)
	var ow := img.get_width()
	var oh := img.get_height()
	# open() 是同步调这里的，此时舞台常常**还没进树** ⇒ get_viewport_rect() 会报
	# "Condition !is_inside_tree() is true"（产品路径实测）。退到窗口尺寸，只需要个近似值。
	var vs := get_viewport_rect().size if is_inside_tree() \
			else Vector2(DisplayServer.window_get_size())
	if ow < 8 or oh < 8 or vs.x <= 1.0:
		return null
	# 糊径换算到曲绘像素：背景是 KEEP_ASPECT_COVERED，缩放比 = max(屏/图)
	var scale: float = maxf(vs.x / float(ow), vs.y / float(oh))
	var rcov: float = 115.0 * background_blur * vs.y / 900.0 / maxf(scale, 0.01)
	var f: float = clampf(rcov / 0.29, 6.0, float(mini(ow, oh)))
	img.resize(maxi(int(float(ow) / f), 3), maxi(int(float(oh) / f), 3), Image.INTERPOLATE_BILINEAR)
	# 压暗也烘进像素：显示时再乘一次 modulate 会把 8bit 的层级腰斩（见 _bake_bg_blur 那条注释）。
	# 近似图与最终图共用同一个 modulate 通道，两边都烘进去才不会在交换那一帧跳亮度。
	# 放在**放大之前**：这张小图只有几百像素见方，逐像素循环才便宜。
	_dim_inplace(img, clampf(background_luminance, 0.05, 1.0))
	img.resize(ow, oh, Image.INTERPOLATE_BILINEAR)
	return ImageTexture.create_from_image(img)

func _bake_bg_blur(tex: Texture2D) -> void:
	if _baking:
		return
	if tex == null:
		_bg_blur_done()
		return
	_baking = true
	var img := tex.get_image()
	if img == null:
		_baking = false
		_bg_blur_done()
		return
	img.convert(Image.FORMAT_RGBA8)
	# 像素活全在 BgBlur 里（和主菜单/选曲页共用同一条高斯级联）
	var bimg: Image = await BgBlur.bake(self, img, get_viewport_rect().size, background_blur,
			background_luminance)
	if bimg == null:
		_baking = false
		_bg_blur_done()
		return
	if is_instance_valid(_bg):
		_bg.texture = ImageTexture.create_from_image(bimg)
		_bg.modulate = Color(1, 1, 1)   # 亮度已在像素里，再乘一次就是双重压暗
		background_ready.emit(_bg.texture)  # 两侧的宽画布带跟着换成模糊版
		for a in OS.get_cmdline_user_args():
			if String(a).begins_with("--qashot="):
				bimg.save_png("user://qa/51_bg_baked.png")  # QA：核对烘焙结果
				break
	_baking = false
	_bg_blur_done()

## 逐像素压暗（4.7 的 Image 既没有 multiply 也没有 adjust_range，实测只有
## premultiply_alpha 那类）。只在近似图那一条同步路径上跑，而且是**放大之前**的小图，
## 循环量只有几百像素见方。
static func _dim_inplace(img: Image, lum: float) -> void:
	if absf(lum - 1.0) < 0.004:
		return
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(c.r * lum, c.g * lum, c.b * lum, c.a))


## 烘焙收尾（成功和每条失败分支都要走这里）：放开"等虚化再开演"的那道门。
## 兜底在 _process 开头（deadline 到点强行放行），所以这里就算永远没被调用也不会把谱面锁死。
func _bg_blur_done() -> void:
	_bg_blur_pending = false
	if not _audio_start_pending:
		return
	_audio_start_pending = false
	if _paused or _audio == null or _audio.stream == null:
		return  # 已经暂停/无乐曲：resume_live() 那条路自己会把音频接上
	_audio.play()
	_audio_started = true
	_pos_watch_reset(0.0)

## 单程 GPU pass。out_size 给 (0,0) 就沿用输入尺寸；shader 默认是高斯那一支，
## 最后一级放大换成 dither.gdshader（8bit 下平滑渐变的层纹靠它打散）。
# HUD（chart 单位定位，每帧按屏幕换算）
var _lbl_combo: Label
var _lbl_combo_tag: Label
var _lbl_score: Label
var _lbl_acc: Label
var _lbl_title: Label
var _lbl_level: Label
var _bar: TextureRect
var _btn_pause: Button
var _pause_sb: StyleBoxFlat   # 只用来撑"内容矩形"=图标尺寸，按钮本体是它的 2 倍热区
var _pause_pad := 0.0
# ── 暂停层（PhiTogether 1:1 复刻，规格见 _build_pause_menu 上方注释）──
var _pm_dim: ColorRect  # 定格画面之上的纯黑 alpha 0.6
var _pm_time: Label  # 左上 mm:ss/mm:ss(Paused)
var _pm_lbl_name: Array = []  # 6 行判定统计的左列
var _pm_lbl_val: Array = []  # 6 行判定统计的右列
var _pm_dsp: Label
var _pm_avg: Label
var _pm_back: Button  # return.png 1.5S
var _pm_retry: Button  # replay.png 1.25S
var _pm_resume: Button  # play.png 1.5S
var _cd_lbl: Label  # 中央 2S 大白字 3→2→1
var _cd_n := 0
var _cd_busy := false
var _ptap_ms := 0  # PT SpecialClick 的 300ms 计时双击
var _dim_tween: Tween

const PT_COMBO_TEXTS := ["Perfect:", "Good:", "Early:", "Late:", "Bad:", "Miss:"]
const PT_COMBO_COLORS := ["#f0ed69", "#0ac3ff", "#0ac3ff", "#0ac3ff", "#fe7b93", "#999999"]

# 背景可调参数（player: blur = 115·backgroundBlur px, 压暗 = 1−luminance）
@export var background_blur := 1.0
@export var background_luminance := 0.5

const SKIN := {
	"line": "res://assets/skin/line.png",
	"tap": "res://assets/skin/Tap.png",
	"drag": "res://assets/skin/Drag.png",
	"flick": "res://assets/skin/Flick.png",
	"hold_head": "res://assets/skin/HoldHead.png",
	"hold": "res://assets/skin/Hold.png",
	"hold_end": "res://assets/skin/HoldEnd.png",
	# 多押长条的尾帽：phira 从 hold_mh.png 切；PT/内置没这一槽，回落普通尾帽
	"hold_end_hl": "res://assets/skin/HoldEnd.png",
	"fx": "res://assets/skin/HitFX.png",
	"tap_hl": "res://assets/skin/TapHL.png",
	"drag_hl": "res://assets/skin/DragHL.png",
	"flick_hl": "res://assets/skin/FlickHL.png",
	"hold_head_hl": "res://assets/skin/HoldHeadHL.png",
	"hold_hl": "res://assets/skin/HoldHL.png",
}

# QA/实验：皮肤目录覆盖（绝对路径，文件名同 SKIN 值；缺的文件回落内置）
var skin_dir := ""
# 当前生效的资源包（scan/scan_path 的结果）：打击音与配色都从这份读
var _skin_pack := {}
# official（Phigros 原生）谱目录：一目录多难度（IN.json+IN.txt sidecar），
# 无 chart.json —— 由选库把具体文件名传进来（native 按 formatVersion 自分发）
var chart_file := ""
## 本局最终选定的乐曲文件（谱目录内的相对/工程路径）。渲染录制拿它当音轨直接喂编码器，
## 不在游戏里混音——离线逐帧时内容钟与墙钟不成比例，混出来的音对不上帧号。
var song_file := ""

func open(dir_path: String) -> bool:
	_dir = dir_path
	# 每次开谱都是那份包自己的元数据：上一首的曲名/乐曲/封面/打击音绝不能带过来
	_info_name = ""
	_info_level = ""
	_info_song = ""
	_info_picture = ""
	_chart_sounds.clear()
	var cf := FileAccess.open(dir_path.path_join(chart_file if chart_file != "" else "chart.json"), FileAccess.READ)
	if cf == null and chart_file != "":
		# sidecar Chart: 指错时回落 chart.json
		cf = FileAccess.open(dir_path.path_join("chart.json"), FileAccess.READ)
	if cf == null:
		push_warning("chart_stage: cannot open chart.json in " + dir_path)
		return false
	var bytes := cf.get_buffer(cf.get_length())
	cf.close()
	# 运行时目录（user:// 或 res://）：先收图/音频；图的选择放到解析谱面之后——
	# 线贴图与背景必须区分（Echoes of Memoria 的"背景总用 175.png"就是取了目录首图）
	var bg_tex: Texture2D = null
	var song_stream: AudioStream = null
	var da := DirAccess.open(dir_path)
	var imgs := PackedStringArray()
	var auds := PackedStringArray()
	var song_path := ""
	if da != null:
		for f in da.get_files():
			var ext := f.get_extension().to_lower()
			if ext in ["webp", "jpg", "jpeg", "png", "gif", "apng"]:
				imgs.append(f)
			elif ext in ["ogg", "mp3", "wav"]:
				auds.append(f)
				# song.* = 曲目音频；其余按谱面包自定义打击音效收录（player asset-<name> 语义）
				if f.get_basename().to_lower() == "song" and song_path == "":
					song_path = dir_path.path_join(f)
				else:
					_chart_sounds[f.get_basename().to_lower()] = dir_path.path_join(f)
	_read_info(dir_path)  # 提前读：乐曲归属要用 info 里点名的 Song/Music
	# 乐曲归属优先级与"从打击音表里摘掉"都抽进静态 pick_song，headless 能逐条断言
	song_path = pick_song(dir_path, song_path, _info_song, chart_file, auds, _chart_sounds)
	song_file = song_path  # 渲染录制要把原曲直接交给编码器（见 render_record.gd）
	_cp = ChartPlayer.new()
	_cp.position = Vector2.ZERO
	# 皮肤=资源包：skin_dir 是 QA 的目录覆盖（--qaskin），平时读 prefs 里的包 id。
	# 包里有的元素用它自己的，缺的回落内置（prpr/PT 都是这个语义，不是整包作废）。
	apply_skin_pack()
	if not _cp.load_chart_json(bytes):
		return false
	# 线贴图：把线引用的图片注入原生（player asset-<Texture> 语义，line.png 也可被谱包覆盖）
	_load_prefs()
	_register_chart_fonts(dir_path)
	var need: Array = _cp.get_line_textures()
	for f in imgs:
		if need.has(f):
			var lext := f.get_extension().to_lower()
			if lext in ["gif", "apng"]:
				# player getSpritesheet(isGif)：动图线贴图 → ffmpeg 拆帧竖排条带 + fps 注入
				var an := _load_anim_strip(dir_path.path_join(f))
				if an.size() == 3:
					_cp.set_line_texture(f, an[0], false, an[1], an[2])
					continue
				continue  # 解码失败：player 会回退 asset-line.png，这里同语义（不注入）
			var t := _load_image_any(dir_path.path_join(f))
			if t != null:
				_cp.set_line_texture(f, t, _tex_is_tintable(t))
	_cp.set_line_tex_tint_mode(line_tex_tint_mode)
	_apply_judge_prefs()  # 判定窗口/判定补偿/多押提示（user://prefs.json）推进原生
	# 背景优先级：META.background > bg.*/cover.*/illustration.* > 首张未被线引用的图
	var bg_path := ""
	var mb: String = _cp.get_meta_background()
	if mb != "" and mb in imgs:
		bg_path = dir_path.path_join(mb)
	if bg_path == "":
		for pref in ["bg", "cover", "illustration"]:
			for f in imgs:
				if f.get_basename().to_lower() == pref:
					bg_path = dir_path.path_join(f)
					break
			if bg_path != "":
				break
	if bg_path == "":
		for f in imgs:
			if not need.has(f):
				bg_path = dir_path.path_join(f)
				break
		if bg_path == "" and imgs.size() > 0:
			bg_path = dir_path.path_join(imgs[0])
	if bg_path != "":
		bg_tex = _load_image_any(bg_path)
	# 噪域掩码视口：树序必须在 _csv 之前（嵌入式 SubViewport 更新序=树序，
	# _bout 在 _csv 内采样它的【本帧】纹理，晚一步就恒定落后一帧）
	_setup_blocks()
	# 内容离屏层：特效链的干净底图。若特效直接采样主屏，上一帧的特效叠加会进下一帧链首
	# → 逐帧反馈（Echoes 1:19 三色糊屏案）。player 是相机级滤镜作用于当帧合成，等价做法
	# = 全部内容（bg/线/音符/HUD）渲到 _csv，链从它的本帧纹理起。
	_csv = SubViewport.new()
	_csv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_csv.transparent_bg = false
	add_child(_csv)
	# 关键顺序：_sv_set 必须在 add_child 之后——override/stretch 进树前设置只对
	# Control 布局生效，对自定义 _draw 的画布缩放不生效（F10 取证：unit 进树后
	# 设置→音符 76px 正确；_lsv 进树前设置→音符 152px 原生大小 = 屏幕 2× 案）
	_sv_set(_csv, size)
	_host = Control.new()
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_host.size = size
	_csv.add_child(_host)
	_content_out = TextureRect.new()
	_content_out.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content_out.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_content_out.stretch_mode = TextureRect.STRETCH_SCALE
	_content_out.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content_out.texture = _csv.get_texture()
	add_child(_content_out)
	var bg := TextureRect.new()
	var final_tex: Texture2D = bg_tex if bg_tex != null else load("res://assets/covers/cover_01.png")
	bg.texture = final_tex
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 压暗 = player 的 rgba(0,0,0,1-luminance) 覆盖。A/B 实测（ab_run t=30 背景条）：
	# 本项目 2D 输出是字节空间直乘（modulate=m → 显示=m·p），与浏览器 canvas 同构。
	# （旧 pow(lum,2.2) 是按线性管线假设推的，实测暗一倍。）
	# ⚠ 但**不要**真的用 modulate 去乘：8bit 下乘 0.5 会把相邻两级并成一级，渐变台阶
	# 直接翻倍（实测烘焙图同值游程 14px、走 modulate 的渲染图 34~54px）——那正是"层纹"。
	# 所以 lum 烘进像素（近似图 _dim_inplace、最终图 dither 那一级），modulate 恒为 1。
	var lum: float = clampf(background_luminance, 0.05, 1.0)
	bg.modulate = Color(1, 1, 1)
	_bg = bg
	_bg_sharp = final_tex
	_host.add_child(bg)
	if bg_tex != null:
		# 烘焙要 4~24 帧（实测 ≈280ms），这段时间屏幕上是**清晰**曲绘 ⇒ 用户仍看见"前几帧没虚化"。
		# 先同步贴一张"降采样再双线性放回"的近似糊图（盒式 σ≈0.29F，取 F=糊径/0.29 即同一量级；
		# 比最终高斯略糊，但绝不是清晰），烘焙完成后无缝换掉。
		var approx := _cheap_blur_tex(bg_tex)
		if approx != null:
			bg.texture = approx
			background_ready.emit(bg.texture)  # 两侧宽画布带同一帧起就是糊的
		_bg_blur_pending = true  # 同步置位：call_deferred 要等本帧末尾才跑，start() 可能先来
		_bake_bg_blur.call_deferred(bg_tex)
	# 游戏层单独一个透明视口：非 global 特效只吃它（player 语义），背景/HUD 不受染指
	_lsv = SubViewport.new()
	_lsv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_lsv.transparent_bg = true
	add_child(_lsv)
	_sv_set(_lsv, size)  # 同 _csv：进树后再设 override，否则 _cp 自定义绘制不被缩放
	_lsv.add_child(_cp)
	# 浏览器 uv 约定 y 向上（player beam 从屏幕顶开始扫）；Godot UV y 向下。
	# 游戏层内容镜像进链空间，_lout 再镜像回来 → 自定义着色器的几何方向与 player 一致
	_cp.scale = Vector2(1, -1)
	_cp.position = Vector2(0, size.y)
	_lout = TextureRect.new()
	_lout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lout.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_lout.stretch_mode = TextureRect.STRETCH_SCALE
	_lout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lout.z_index = 40
	# 链 RT 存的是预乘数据（MIX onto cleared transparent），终合成必须用 Premultiplied Alpha：
	# invis 的 (0,0,0,0) 透出背景、cpow 的 (rgb,1) 整块替换、beam 的部分 alpha 正确混——全对
	var lmat := CanvasItemMaterial.new()
	lmat.set("blend_mode", 4)  # 4=Premultiplied Alpha（4.7 GDScript 不暴露常量名）
	_lout.material = lmat
	_lout.texture = _lsv.get_texture()
	_lout.pivot_offset = _lout.size * 0.5
	_lout.scale = Vector2(1, -1)  # 镜像回正（见 _lsv 处的 y 翻转说明）
	_lout.resized.connect(func() -> void: _lout.pivot_offset = _lout.size * 0.5)
	_host.add_child(_lout)
	_setup_blocks_out()  # 噪域表现层（z20：曲绘之上、_lout 的游戏元素之下）
	# extra.json（后期特效）：可选，存在则交给原生解析（player 语义）
	var exf := dir_path.path_join("extra.json")
	if FileAccess.file_exists(exf):
		var ef := FileAccess.open(exf, FileAccess.READ)
		if ef != null:
			_cp.load_extra(ef.get_buffer(ef.get_length()))
			ef.close()
	# targetRange 深度桶清单（HUD/背景深度常量在 GDScript 侧）
	_line_depths = _cp.get_line_depths()
	_note_depths = _cp.get_note_depths()
	_fx_depths = _cp.get_fx_depths()
	# 手机填充率有限：压力谱（千线级，如 bad apple 3.4 万线）自动降半分辨率
	# （= 桌面 F10 低预设同一路径，特效链/掩码 SubViewport 全部跟降）；普通谱保持全清。
	if OS.has_feature("mobile") and _line_depths.size() > 2000:
		set_render_scale(0.5)
	_setup_effects()
	_build_hud()
	_setup_videos(dir_path)
	_audio = AudioStreamPlayer.new()
	if song_path != "":
		song_stream = _load_audio_any(song_path)
		print("QA-AUDIO file=", song_path.get_file(), " ok=", song_stream != null)
	_song_stream = song_stream
	if song_stream != null:
		_audio.stream = song_stream
		# 乐曲音量走设置页的 music_vol（线性→dB）+ 响度标准化的回补量；
		# 打击音在下面的音效池里各按 hit_vol
		_ensure_music_bus()
		_apply_music_gain()
		_audio.connect("finished", _on_song_finished)
		add_child(_audio)
	else:
		_audio = null
	# 音效声部不再开机建固定 8 部：见 _hit_groups（按 key 懒建，每个声部只挂一种流）
	return true


# PT 打击音映射：tap/hold 头→HitSong0(click)，drag→HitSong1，flick→HitSong2（RPE type 3=flick 4=drag）
const HIT_DEFAULTS := {1: "HitSong0", 2: "HitSong0", 3: "HitSong2", 4: "HitSong1"}


## 皮肤=资源包：重读 prefs 里选中的包，把它整个贴到当前 player 上。
## ⚠ 以前这一步只在建谱时跑一次，于是"在设置页换了包，回到游戏还是上一个包"
## （用户："从 phigros 资源包换到 PT 资源包怎么显示一直是 phigros 资源包"）。
## 现在设置页关闭时也会调一次，包与音效当场跟着换。
func apply_skin_pack() -> void:
	_skin_pack = SkinPack.scan_path(skin_dir) if skin_dir != "" else SkinPack.scan(UserPrefs.str_of("skin_pack"))
	SkinPack.apply_to(_cp, _skin_pack)
	# 换包必须连打击音一起换：_sfx_cache 的键只有音名，不清就会继续播旧包的采样；
	# 声部池里每一部又都绑死了那一条流（见 _hit_groups），所以两边一起丢掉重建。
	_sfx_cache = {}
	for k in _hit_groups:
		for q in _hit_groups[k]:
			if is_instance_valid(q):
				q.stop()
	_hit_groups = {}
	_hit_rr = {}

## 打击音到底用哪个文件：谱包自定义 → 皮肤包自带 → 内置。
## _play_hit（实跑）与渲染录制的离线混音共用这一条，免得"听到的"和"录出来的"不是同一个音。
func hit_sound_path(type_: int, sname: String) -> String:
	var key := sname.to_lower() if sname != "" else "type:%d" % type_
	if sname != "" and _chart_sounds.has(key):
		return String(_chart_sounds[key])
	var dflt := String(HIT_DEFAULTS.get(type_, "HitSong0"))
	if not _skin_pack.is_empty():
		var sp: Dictionary = _skin_pack.get("sounds", {})
		var p0 := String(sp.get(dflt, ""))
		if p0 != "" and (ResourceLoader.exists(p0) if p0.begins_with("res://")
				else FileAccess.file_exists(p0)):
			return p0
	for e in ["ogg", "wav", "mp3"]:
		var p := "res://assets/skin/hitsounds/%s.%s" % [dflt, e]
		if ResourceLoader.exists(p):
			return p
	return ""

func _play_hit(type_: int, sname: String) -> void:
	if record_mode:
		# 录制态不出声（整局静音），但这一响要按**内容时间**记下来：
		# 成片里的打击音由录制器离线混进音轨（见 render_record.gd 的 _hits_stem）
		# 上限 8000 条：撞墙谱一秒钟几十响，攒到几万条时 _build_hits 会变成上亿次累加
		# （实测能把整机拖死）。超过之后不再记录，成片里打击音会变稀，但不会再拖崩
		if rec_hits.size() < 8000:
			rec_hits.append([_clock, type_, sname])
		return
	# 缓存键必须按类型分域：空 sname 全用 "" 键会把首个命中的音（如 flick）
	# 缓存给所有类型复用——PTN"什么都像flick/发尖"的根因
	var key := sname.to_lower() if sname != "" else "type:%d" % type_
	var stream: AudioStream = null
	if _sfx_cache.has(key):
		stream = _sfx_cache[key]
	else:
		var hp := hit_sound_path(type_, sname)
		stream = null
		# 先试内置三支旁边的 48k 立体声 f32 旁车（录制早就用它了）：见 wav_from_f32 的注释，
		# 这一步是把"每响 ~3ms 的 Vorbis 播放对象重建"从游玩热路径上摘掉。
		# 皮肤包/谱包自带的真实文件没有旁车，仍走原生解码（那类音我们改不了）。
		var sp := hit_sound_pcm(type_, sname)
		if sp.ends_with(".f32"):
			var f := FileAccess.open(sp, FileAccess.READ)
			if f != null:
				var raw := f.get_buffer(f.get_length())
				f.close()
				stream = wav_from_f32(raw)
		if stream == null and hp != "":
			stream = _load_audio_any(hp)
		_sfx_cache[key] = stream
		print("QA-HITSOUND ", key, " 源=", sp if stream != null and sp != "" else hp,
				" 类型=", stream.get_class() if stream != null else "null",
				" 时长=%.3fs" % (stream.get_length() if stream != null else 0.0))
	if stream == null:
		return
	var grp: Array = _hit_groups.get(key, [])
	if grp.is_empty():
		for i in HIT_VOICES:
			var q := AudioStreamPlayer.new()
			q.volume_db = linear_to_db(hit_sound_volume) if hit_sound_volume > 0.001 else -80.0
			q.stream = stream
			add_child(q)
			_hit_pool.append(q)
			grp.append(q)
		_hit_groups[key] = grp
		_hit_rr[key] = 0
	var p: AudioStreamPlayer = grp[int(_hit_rr[key]) % grp.size()]
	_hit_rr[key] = (int(_hit_rr[key]) + 1) % grp.size()
	if p.stream != stream:
		p.stream = stream      # 只有换皮/换包后才会走到，正常一响一分钱不花
	p.play()

func _load_image_any(path: String) -> Texture2D:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var buf := f.get_buffer(f.get_length())
	f.close()
	var img := Image.new()
	# 先看魔数：下载失败留下的 HTML 错误页（伪装成 bg.png）不该再去喂解码器，
	# 那会刷一堆 "Not a PNG file"。认不出就直接当没有图
	if buf.size() < 32:
		return null
	var m0 := buf[0]
	var m1 := buf[1]
	var is_png := m0 == 0x89 and m1 == 0x50
	var is_jpg := m0 == 0xFF and m1 == 0xD8
	var is_webp := m0 == 0x52 and m1 == 0x49 and buf[8] == 0x57
	if not is_png and not is_jpg and not is_webp:
		return null
	var ext := path.get_extension().to_lower()
	# 先按扩展名精确解码，失败再全链兜底（旧写法对每个 PNG 都先试一次 webp，
	# 每次开谱刷一排无害但刺眼的 ERR_FILE_CORRUPT）
	var err: int = ERR_PARSE_ERROR
	if ext == "jpg" or ext == "jpeg":
		err = img.load_jpg_from_buffer(buf)
	elif ext == "png":
		err = img.load_png_from_buffer(buf)
	elif ext == "webp":
		err = img.load_webp_from_buffer(buf)
	if err != OK:
		err = img.load_png_from_buffer(buf)
	if err != OK:
		err = img.load_jpg_from_buffer(buf)
	if err != OK:
		err = img.load_webp_from_buffer(buf)
	if err != OK:
		return null
	img.generate_mipmaps()  # 散景 shader 的 textureLod 宽抽样需要
	return ImageTexture.create_from_image(img)

## gif/apng → ffmpeg 拆帧（PNG 序列）→ 竖排条带纹理，返回 [tex, frames, fps]。
## 对应 player getSpritesheet(isGif)；逐帧可变延时按平均帧率近似（已知简化）。
## 解码结果缓存于 user://giftmp/<md5>/（strip.png + meta.txt），二次开谱零成本。
func _load_anim_strip(path: String, max_frames: int = 256) -> Array:
	var tmp := "user://giftmp/" + path.md5_text()
	var meta_f := tmp.path_join("meta.txt")
	var strip_p := tmp.path_join("strip.png")
	var frames := 0
	var fps := 0.0
	if FileAccess.file_exists(meta_f) and FileAccess.file_exists(strip_p):
		var lines := FileAccess.get_file_as_string(meta_f).split("\n")
		if lines.size() >= 2:
			frames = int(lines[0].strip_edges())
			fps = float(lines[1].strip_edges())
	if frames <= 0 or fps <= 0.0 or not FileAccess.file_exists(strip_p):
		DirAccess.make_dir_recursive_absolute(tmp)
		var out: Array[String] = []
		var rc := OS.execute("ffmpeg", PackedStringArray(["-hide_banner", "-loglevel", "error", "-y",
			"-i", ProjectSettings.globalize_path(path), "-fps_mode", "passthrough", "-frames:v", str(max_frames),
			ProjectSettings.globalize_path(tmp.path_join("f_%04d.png"))]), out, true)
		if rc != 0:
			push_warning("gif decode failed: " + path)
			return []
		var fd := DirAccess.open(tmp)
		if fd == null:
			return []
		var names: Array[String] = []
		for fn in fd.get_files():
			if fn.begins_with("f_") and fn.ends_with(".png"):
				names.append(fn)
		names.sort()
		frames = names.size()
		if frames == 0:
			return []
		fps = _anim_fps(path)
		if fps <= 0.0:
			fps = 10.0
		var first := Image.load_from_file(tmp.path_join(names[0]))
		if first == null:
			return []
		var w := first.get_width()
		var h := first.get_height()
		var strip := Image.create(w, h * frames, false, Image.FORMAT_RGBA8)
		var yi := 0
		for fn in names:
			var im := first if fn == names[0] else Image.load_from_file(tmp.path_join(fn))
			if im == null:
				continue
			im.convert(Image.FORMAT_RGBA8)
			if im.get_width() != w or im.get_height() != h:
				im.resize(w, h)
			strip.blit_rect(im, Rect2i(0, 0, w, h), Vector2i(0, yi * h))
			yi += 1
		strip.save_png(strip_p)
		var mf := FileAccess.open(meta_f, FileAccess.WRITE)
		if mf != null:
			mf.store_string("%d\n%.6f\n" % [frames, fps])
			mf.close()
		for fn in names:
			fd.remove(fn)
	var img := Image.load_from_file(strip_p)
	if img == null:
		return []
	img.generate_mipmaps()
	return [ImageTexture.create_from_image(img), frames, fps]

func _anim_fps(path: String) -> float:
	var out: Array[String] = []
	var rc := OS.execute("ffprobe", PackedStringArray(["-v", "error", "-select_streams", "v:0",
		"-show_entries", "stream=r_frame_rate,avg_frame_rate", "-of", "default=nw=1:nk=1",
		ProjectSettings.globalize_path(path)]), out, true)
	if rc != 0 or out.is_empty():
		return 0.0
	for fr in out[0].split("\n"):
		var s := String(fr).strip_edges()
		if s == "" or s == "0/0":
			continue
		if s.contains("/"):
			var ps := s.split("/")
			var den := float(ps[1])
			if den > 0.0 and float(ps[0]) > 0.0:
				return float(ps[0]) / den
		elif float(s) > 0.0:
			return float(s)
	return 0.0

## 贴图是否"白/灰蒙版"类（数字、图案线）：不透明像素抽样，通道差小且亮度高 → 乘判定色无损信息。
func _tex_is_tintable(t: Texture2D) -> bool:
	var it := t as ImageTexture
	if it == null:
		return false
	var img := it.get_image()
	if img == null:
		return false
	var w := img.get_width()
	var h := img.get_height()
	var step_x: int = maxi(1, w / 64)
	var step_y: int = maxi(1, h / 64)
	var n := 0
	var sum_l := 0.0
	var sum_spread := 0.0
	for y in range(0, h, step_y):
		for x in range(0, w, step_x):
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				continue
			n += 1
			sum_l += (c.r + c.g + c.b) / 3.0
			sum_spread += maxf(maxf(absf(c.r - c.g), absf(c.r - c.b)), absf(c.g - c.b))
	if n < 8:
		return false
	return sum_l / n > 0.55 and sum_spread / n < 0.08

## 偏好持久化。字段对齐 player Preferences（src/lib/types.ts:60）：
## perfectJudgment / goodJudgment（判定窗口 ms）、chartOffset（判定补偿 ms，可负）、
## simultaneousNoteHint（多押提示）、fcApIndicator（线染色）。默认值取 player constants
## （DEFAULT_PERFECT_JUDGMENT_MS=80 / DEFAULT_GOOD_JUDGMENT_MS=180，offset 0，hint 开）。
## **读写口在 UserPrefs**（设置页在舞台之外改同一批键），这里只留"本舞台要用的那几项"的镜像。
var perfect_ms := 80.0
var good_ms := 180.0
var chart_offset_ms := 0.0
var multi_hint := true
var frame_cull := true    # 取景口径：开=注重演出（裁掉制谱器画框外的表演），关=注重游玩（框外也画）
var music_volume := 1.0     # 乐曲音量（线性，进 _audio.volume_db）
var fc_ap := true           # player fcApIndicator：AP/FC 判定线染色
var autoplay_on := false    # 开谱时的自动播放初值（唯一入口=设置页"自动游玩"）
var dbg_on := false         # F12 序号调试层的初值
var note_scale := 1.0       # 音符大小（原生只缩放贴图，位置/判定不动）
var debug_mode := false     # 游玩中常驻显示帧率/线程读数
var pause_detail := true    # 暂停层的判定详细/时间详细
var loud_norm := false      # 响度标准化（目标 −14 LUFS）
var fps_lock := false       # 帧率上限是否真的钉住（关=不设上限）

func _load_prefs() -> void:
	# 值全部来自 UserPrefs（含默认与范围夹取）；这里只补舞台特有的耦合下限
	line_tex_tint_mode = UserPrefs.int_of("line_tex_tint")
	block_cell = UserPrefs.int_of("block_cell")
	perfect_ms = UserPrefs.num("perfect_ms")
	good_ms = maxf(UserPrefs.num("good_ms"), _good_min())
	chart_offset_ms = UserPrefs.num("chart_offset_ms")
	multi_hint = UserPrefs.flag("multi_hint")
	_fps_cap = UserPrefs.int_of("fps_cap")
	# 垂直同步：0=开（引擎默认）1=关 2=宽松。手机上"主循环 117 帧、上屏只有 60"这种
	# 只能现场 A/B 才分得清的猜测，就靠这一档开关 + 下面的上屏计数落结论。
	# 这里只读值：`_load_prefs` 跑在入树之前，get_window() 还是 null，落到 start() 才生效。
	_vsync = UserPrefs.int_of("vsync")
	hi_res = UserPrefs.flag("hi_res")
	background_blur = UserPrefs.num("bg_blur")
	background_luminance = UserPrefs.num("bg_lum")
	hit_sound_volume = UserPrefs.num("hit_vol")
	music_volume = UserPrefs.num("music_vol")
	fc_ap = UserPrefs.flag("fc_ap")
	autoplay_on = UserPrefs.flag("autoplay")
	dbg_on = UserPrefs.flag("dbg_overlay")
	note_scale = UserPrefs.num("note_scale")
	debug_mode = UserPrefs.flag("debug_mode")
	pause_detail = UserPrefs.flag("pause_detail")
	loud_norm = UserPrefs.flag("loud_norm")
	fps_lock = UserPrefs.flag("fps_lock")
	frame_cull = UserPrefs.int_of("frame_cull") != 0

## player Preferences.svelte 的窗口耦合约束：G ≥ max(P+5, 1.125P)（minJudgment=5）
func _good_min() -> float:
	return maxf(perfect_ms + 5.0, perfect_ms * 1.125)

## 把本舞台当前值回写进 UserPrefs（一次落盘；键名与设置页完全同一份表）
func _save_prefs() -> void:
	UserPrefs.set_many({
		"line_tex_tint": line_tex_tint_mode,
		"perfect_ms": perfect_ms,
		"good_ms": good_ms,
		"chart_offset_ms": chart_offset_ms,
		"multi_hint": multi_hint,
		"fps_cap": _fps_cap,
		"vsync": _vsync,
		"hi_res": hi_res,
	})

## 把三个可调项推给原生判定管线（player：windows() 每次现读 preferences，我们推值）
func _apply_judge_prefs() -> void:
	if _cp == null:
		return
	# 帧率上限：用户定案默认"不锁"（game.gd 里 max_fps=0 + vsync 跟随刷新率）。
	# 这里只是把它做成可实时切的开关——Android 上 Swappy 会拿 Engine.max_fps 去调
	# ANativeWindow_setFrameRate，写 0 = 不表态 = 系统可能把应用按在 60Hz 基础模式，
	# 所以"120 帧但卡卡的"必须能在真机上一按就验证，而不是我替他改默认值。
	Engine.max_fps = _fps_cap if fps_lock else 0
	# 不锁 ≠ 不表态：移动端把目标帧率显式声明出去（和 game.gd 开机那条同规则、同一个常量）。
	# ⚠ 不能用 screen_get_refresh_rate() 单独决定：平板实测系统正停在 60Hz 模式，那个调用
	# 就返回 60，于是"不锁"被实现成"钉死 60"（Godot 没有"面板最高档"的 getter，见 UiTokens）。
	if Engine.max_fps == 0 and OS.has_feature("mobile"):
		Engine.max_fps = maxi(int(DisplayServer.screen_get_refresh_rate()),
				UiTokens.MOBILE_TARGET_FPS)
	_cp.set_judgment_windows(perfect_ms, good_ms)
	_cp.set_chart_offset_ms(chart_offset_ms)
	_cp.set_multi_hint(multi_hint)
	_cp.set_frame_cull(frame_cull)
	_cp.set_note_scale(note_scale)
	_cp.set_fx_user_scale(UserPrefs.num("fx_scale"))
	# player fcApIndicator：无 colorEvents 的线按判定态染色（全 Perfect 淡黄 / 全连淡蓝 / 断线白）
	_cp.set_fc_ap_indicator(fc_ap)
	_apply_block_cell()

func set_judgment_windows(p: float, g: float) -> void:
	perfect_ms = clampf(p, 5.0, 150.0)
	good_ms = clampf(g, _good_min(), 300.0)
	_apply_judge_prefs()
	_save_prefs()

func set_chart_offset(ms: float) -> void:
	chart_offset_ms = clampf(ms, -600.0, 600.0)
	_apply_judge_prefs()
	_save_prefs()

func set_multi_hint(on: bool) -> void:
	multi_hint = on
	_apply_judge_prefs()
	_save_prefs()

## 噪域掩码网格单元（画布 px）。成本≈网格面积×可见区数：
## 2560×1600 + 109 区时 4px 要 42ms（~57fps）、12px 才能 120fps。
## 自动 = 按画布宽取整（约 30k 格），1350 宽 → 6px、2560 宽 → 12px。
func _block_cell_px() -> float:
	if block_cell > 0:
		return float(block_cell)
	# 2560 宽 → 6px（4px 的成本在大屏上换不来帧率，6px 与 8px 同帧率但边缘更细）
	return maxf(4.0, round(maxf(size.x, 1.0) / 430.0))


func _apply_block_cell() -> void:
	if _cp != null:
		_cp.set_block_cell(_block_cell_px())


func set_block_cell(v: int) -> void:
	block_cell = maxi(v, 0)
	_apply_block_cell()
	_save_prefs()


func set_line_tex_tint_mode(m: int) -> void:
	line_tex_tint_mode = clampi(m, 0, 2)
	if _cp != null:
		_cp.set_line_tex_tint_mode(line_tex_tint_mode)
	_save_prefs()

## 乐曲归属：包自己点名的 song.* > info(Song:/Music:) > 与谱同名的音频 > 目录里唯一一首。
## 后两条取 player lib/services/chartGrouping.ts 的判据（song = audios.find(同 id) ?? audios[0]）；
## RTX 20000 那种「测试.json + 测试.mp3 + info.csv」的包以前一条都对不上，进去就全程静音。
## 被认成乐曲的那份必须从打击音表里摘掉，否则同一文件既当伴奏又当 hitsound 播两遍。
static func pick_song(dir_path: String, chosen: String, info_song: String, chart_f: String,
		auds: PackedStringArray, sounds: Dictionary) -> String:
	var song_path := chosen
	if song_path == "" and info_song != "":
		var sp := dir_path.path_join(info_song)
		if FileAccess.file_exists(sp):
			song_path = sp
	if song_path == "":
		var stem := (chart_f if chart_f != "" else "chart.json").get_basename().to_lower()
		for a in auds:
			if String(a).get_basename().to_lower() == stem:
				song_path = dir_path.path_join(String(a))
				break
	if song_path == "" and auds.size() == 1:
		song_path = dir_path.path_join(String(auds[0]))
	if song_path != "":
		sounds.erase(song_path.get_file().get_basename().to_lower())
	return song_path

## 按**真实容器**认音频，不看扩展名：现实包里 song.mp3 装的是 FLAC（RTX 20000 那份就是
## fLaC 头）、xxx.ogg 装 MP3 都存在。扩展名骗人时 AudioStreamMP3 会把"解不开"一路推到
## play() 才报，`.stream` 照样非空 ⇒ 页面显示正常却全程静音（这个假阳性骗过我一次），
## 所以宁可在装载这里就按内容判死并如实警告。
static func audio_magic(buf: PackedByteArray) -> String:
	if buf.size() < 12:
		return ""
	var head := buf.slice(0, 4).get_string_from_ascii()
	if head == "fLaC":
		return "flac"
	if head == "OggS":
		return "ogg"
	if head == "RIFF" and buf.slice(8, 12).get_string_from_ascii() == "WAVE":
		return "wav"
	if head == "CMSF" or (buf[0] == 0x49 and buf[1] == 0x44 and buf[2] == 0x33):
		return "mp3"  # "ID3" 标签（AACA 是 MF 容器，另算）
	if head == "ftyp" or head == "M4A ":
		return "aac"
	# 裸 MPEG 帧同步：11 个 1 后接任意，第二字节高 3 位全 1
	if buf[0] == 0xFF and (buf[1] & 0xE0) == 0xE0:
		return "mp3"
	return ""

## 字节 → AudioStream：容器由 audio_magic 判，不看扩展名。
## 拆成静态是因为这条必须能在不开窗口、不建舞台的情况下被断言（tests/info_format_test.gd）。
## 裸 48k 立体声 float32 → AudioStreamWAV(16bit)。
## 为什么"活着的时候"也要这份旁车：真机 perfT 读数 `AudioStreamPlayer.play()` 一次
## 3.0~3.8ms，因为流是 .ogg —— 每一响都要新建一条 Vorbis 解码播放并把状态推到混音线程；
## 而 WAV 播放只是一条采样游标。autoplay 一局要响几十次/秒，这一项就直接吃掉 120Hz 的
## 8.33ms 预算大半。转成 s16 是一次性的（_sfx_cache 缓存），音量/时长口径不变。
static func wav_from_f32(p_buf: PackedByteArray) -> AudioStreamWAV:
	var n := p_buf.size() / 4
	if n < 8:
		return null
	var out := PackedByteArray()
	out.resize(n * 2)
	for i in n:
		out.encode_s16(i * 2, clampi(int(p_buf.decode_float(i * 4) * 32767.0), -32768, 32767))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = 48000
	w.stereo = true
	w.data = out
	return w

static func stream_from_bytes(buf: PackedByteArray, path: String) -> AudioStream:
	var kind := audio_magic(buf)
	if kind == "":
		# 认不出容器才回退扩展名（老 wav 变种等），失败也只是静音，不假装成功
		push_warning("chart_stage: 无法识别音频容器（按扩展名试）" + path.get_file())
		kind = path.get_extension().to_lower()
	match kind:
		"mp3":
			var mp3 := AudioStreamMP3.new()
			mp3.data = buf
			return mp3
		"wav":
			return _load_wav(buf)
		"ogg":
			return AudioStreamOggVorbis.load_from_buffer(buf)
		"flac":
			# Godot 运行时不解 FLAC（只有编辑器导入 res:// 时解），所以谱包里的 FLAC 必须走
			# 原生 dr_flac。drflac 输出的就是交织小端 int16，正是 AudioStreamWAV 16_BITS 要的裸 PCM。
			var dec: Dictionary = ChartPlayer.decode_flac(buf)
			var ch := int(dec.get("channels", 0))
			if dec.is_empty() or (ch != 1 and ch != 2):
				# 解不开、或 >2 声道（AudioStreamWAV 只有单/双声道）都如实报，绝不给一条假流
				push_warning("chart_stage: FLAC 解码不可用（声道=%d）⇒ 无伴奏：%s" % [ch, path.get_file()])
				return null
			var w := AudioStreamWAV.new()
			w.format = AudioStreamWAV.FORMAT_16_BITS
			w.mix_rate = int(dec.get("rate", 44100))
			w.stereo = ch == 2
			w.data = PackedByteArray(dec.get("pcm", PackedByteArray()))
			return w
		_:
			push_warning("chart_stage: 不支持的音频容器 " + kind + "（" + path.get_file() + "）⇒ 无伴奏")
			return null
	return null

func _load_audio_any(path: String) -> AudioStream:
	if path == "":
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		# 导出包里 res:// 只有 .import + 导入产物，源文件根本不存在 ⇒ FileAccess 必失败。
		# 内置打击音（assets/skin/hitsounds/*.ogg）就死在这：PC 上有声、APK 上全哑。
		# 走资源加载器拿已导入的流（AudioStreamOggVorbis / AudioStreamWAV）即可。
		if path.begins_with("res://"):
			return load(path) as AudioStream
		return null
	var buf := f.get_buffer(f.get_length())
	f.close()
	return stream_from_bytes(buf, path)

## RIFF 遍历解 WAV → AudioStreamWAV。Godot 的 .data 要裸 PCM（文件字节直塞会把头当声音，
## 且不设 mix_rate/stereo 必错速）；24bit/float32/8bit 统一折成 16bit PCM。
static func _load_wav(buf: PackedByteArray) -> AudioStreamWAV:
	if buf.size() < 12 or buf.slice(0, 4).get_string_from_ascii() != "RIFF" \
			or buf.slice(8, 12).get_string_from_ascii() != "WAVE":
		push_warning("chart_stage: WAV 缺 RIFF/WAVE 魔数")
		return null
	var pos := 12
	var channels := 0
	var rate := 0
	var bits := 0
	var fmt_tag := 1
	var sub_tag := 0
	var pcm := PackedByteArray()
	while pos + 8 <= buf.size():
		var id := buf.slice(pos, pos + 4).get_string_from_ascii()
		var sz := buf.decode_u32(pos + 4)
		var body := pos + 8
		if id == "fmt ":
			fmt_tag = buf.decode_u16(body)
			channels = buf.decode_u16(body + 2)
			rate = buf.decode_u32(body + 4)
			bits = buf.decode_u16(body + 14)
			if sz >= 40:  # WAVE_FORMAT_EXTENSIBLE：真格式在 GUID 首 u16（24bit wav 常见）
				sub_tag = buf.decode_u16(body + 24)
		elif id == "data":
			pcm = buf.slice(body, mini(body + sz, buf.size()))
		pos = body + sz + (sz & 1)  # chunk 偶数对齐
	if fmt_tag == 65534 and sub_tag != 0:
		fmt_tag = sub_tag
	if pcm.is_empty() or rate <= 0:
		return null
	if channels != 1 and channels != 2:
		push_warning("chart_stage: WAV 声道数不支持 %d" % channels)
		return null
	if fmt_tag == 1 and bits == 16:
		pass
	elif fmt_tag == 3 and bits == 32:  # IEEE float32 → s16
		var n := pcm.size() / 4
		var out := PackedByteArray()
		out.resize(n * 2)
		for i in n:
			var v: float = pcm.decode_float(i * 4)
			out.encode_s16(i * 2, clampi(int(v * 32767.0), -32768, 32767))
		pcm = out
	elif fmt_tag == 1 and bits == 8:  # 无符号 8bit → s16
		var out8 := PackedByteArray()
		out8.resize(pcm.size() * 2)
		for i in pcm.size():
			out8.encode_s16(i * 2, (pcm[i] - 128) * 256)
		pcm = out8
	elif fmt_tag == 1 and bits == 24:  # 24bit LE → s16（丢低位）
		var n24 := pcm.size() / 3
		var out24 := PackedByteArray()
		out24.resize(n24 * 2)
		for i in n24:
			var v := pcm[i * 3] | (pcm[i * 3 + 1] << 8) | (pcm[i * 3 + 2] << 16)
			if v & 0x800000:
				v -= 0x1000000
			out24.encode_s16(i * 2, v >> 8)
		pcm = out24
	else:
		push_warning("chart_stage: WAV 格式不支持 tag=%d bits=%d" % [fmt_tag, bits])
		return null
	var w := AudioStreamWAV.new()
	w.mix_rate = rate
	w.stereo = channels == 2
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.data = pcm
	return w

func _build_hud() -> void:
	var font := UiTokens.install_font()
	_btn_pause = Button.new()
	_btn_pause.text = ""
	_btn_pause.icon = load("res://assets/icons/pause.svg")
	_btn_pause.expand_icon = true  # 图标撑满"内容矩形"（=按钮减去下面的内边距）
	# 手机端命中区：图标边长只有画布 3.1%（D700 上≈78 设备像素≈28dp），低于 Android
	# 48dp 的最小可点目标 ⇒ 用户实测"很大概率点不到暂停"。用 draw_center=false 的空
	# stylebox 把内容矩形往里缩，按钮本体放大一倍当**不可见热区**，图标像素位置不变。
	_pause_pad = 0.0   # 实际边长在 _hud_layout 里按画布宽算（窗口会缩放）
	_pause_sb = StyleBoxFlat.new()
	_pause_sb.draw_center = false
	_btn_pause.add_theme_stylebox_override("normal", _pause_sb)
	_btn_pause.add_theme_stylebox_override("hover", _pause_sb)
	_btn_pause.add_theme_stylebox_override("pressed", _pause_sb)
	_btn_pause.add_theme_stylebox_override("disabled", _pause_sb)
	_btn_pause.add_theme_stylebox_override("focus", _pause_sb)
	_btn_pause.pressed.connect(_on_pause_tap)
	_btn_pause.z_index = HUD_Z_TOP
	_btn_pause.z_as_relative = false
	_host.add_child(_btn_pause)
	_lbl_combo = _lbl(63)
	_lbl_combo_tag = _lbl(22)
	_lbl_combo_tag.text = "COMBO"
	_lbl_score = _lbl(46)
	_lbl_acc = _lbl(22)
	_lbl_acc.modulate = Color(1, 1, 1, 0.7)
	_lbl_title = _lbl(34)
	_lbl_title.text = _meta_or(_cp.get_song_name(), _info_name, hint_name)
	_lbl_level = _lbl(34)
	_lbl_level.text = _meta_or(_cp.get_level(), _info_level, hint_level)
	print("QA-HUD name=", _lbl_title.text, " level=", _lbl_level.text)
	_bar = TextureRect.new()
	_bar.texture = load("res://assets/skin/Progress.png")
	_bar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bar.stretch_mode = TextureRect.STRETCH_SCALE
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.z_index = HUD_Z_TOP
	_bar.z_as_relative = false
	_host.add_child(_bar)
	_build_pause_menu()
	# F12 序号调试层：挂在舞台本身（不在 _host 里 → 不进特效链、不被暂停黑幕染色），
	# z=88 在 HUD/特效之上、判定面板(90)与暂停层(94+)之下
	_dbg = DebugOverlay.new()
	_dbg.z_index = 88
	_dbg.visible = dbg_on  # 设置页"通用→序号调试层"的初值；游玩中 F12 随时可切
	_dbg.setup(_cp)
	add_child(_dbg)
	# 调试模式（设置页「通用」）：帧率/线程落核的读数从"只有暂停面板里看得到"
	# 变成游玩中常驻——真机上要边打边看，不能每回都暂停一次。
	_dbg_lbl = Label.new()
	_dbg_lbl.add_theme_font_override("font", UiTokens.install_font())
	_dbg_lbl.add_theme_color_override("font_color", Color(0.72, 1.0, 0.78, 0.9))
	_dbg_lbl.add_theme_font_size_override("font_size", maxi(int(size.x * 13.0 / 1350.0), 9))
	_dbg_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dbg_lbl.z_index = 89
	_dbg_lbl.visible = debug_mode
	_dbg_lbl.position = Vector2(size.x * 0.012, size.y * 0.05)
	add_child(_dbg_lbl)

## 帧率 / 内部分辨率的偏好值：设置页是**唯一**入口（暂停时的临时调节面板已按用户要求撤除），
## 这里只负责读盘、开谱时应用，以及上屏帧率的采样变量。
var _fps_cap := 0  # Engine.max_fps 偏好：0=不限（用户定案默认）
var _vsync := 0            # Window.VSyncMode：0=开 1=关 2=兼容，开谱时应用
var _post_n := 0           # 本秒内 frame_post_draw 次数 = **真的上屏了多少帧**
var _perf_pps := 0.0
var _perf_t := 0.0
var _perf_prev := {}       # 上次 /proc 采样的 {tid: ticks}
var _perf_line := ""
# ── 本局帧率统计（调试模式）：最大/平均/最小瞬时帧率，实时在调试层、打完进结算页 ──
# ⚠ 一次卡帧就会把最小值打下去——这正是"最低 119"要的行为，不许做滑动平均遮羞。
# 统计窗口 = 从音频真正响到 _on_song_finished：前面的加载/虚化等待和打完后的
# 结算背景都不计入（否则建谱首帧的 shader 编译会把最小值一脚踹到个位数）。
## ⚠ 采的是**呈现节拍**（相邻两次 frame_post_draw 的间隔），不是主循环 delta：
## 三缓冲下循环可以跑在合成前面（实测主循环能到 155/s），玩家看到的帧率只由上屏决定。
var _fps_n := 0
var _fps_sum := 0.0
var _fps_min := 1e9
var _fps_max := 0.0
var _post_prev_us := 0   # 上一次 frame_post_draw 的时刻（µs）
var _song_done := false
var hi_res := true         # 舞台内部按设备像素算（false=退回逻辑像素，省填充）
var _k := 1.0              # 设备像素 ÷ 逻辑像素（舞台内部单位 = 逻辑 × _k，靠 scale=1/_k 缩回）
var _lrect := Rect2()      # 游玩画布在**父级/逻辑**空间里的矩形（给挂在 game 层的东西用）

# ── 真机帧率 / 线程落核诊断 ────────────────────────────────────────────

func _on_post_draw() -> void:
	# 整条呈现节拍的统计（帧率三值 + Performance 计数器 + 分区累加）只在调试模式跑：
	# 正常游玩一个字节都不采，logcat 也不再每秒冒 QA-MON/QA-SPLIT 行。
	if not debug_mode:
		return
	_post_n += 1
	# 帧率统计的取样点：**这一帧真的交给系统合成了**（相邻两次的间隔=玩家看到的节拍）。
	# 主循环 delta 不能当帧率用——三缓冲下它能跑在合成前面（实测 155/s）。
	var now_us := Time.get_ticks_usec()
	if _audio_started and not _song_done and not _paused and _post_prev_us > 0:
		_fps_track(float(now_us - _post_prev_us) / 1000000.0)
	_post_prev_us = now_us

## 调试读数：prefs 口径(0=开 1=关 2=兼容) → 引擎实际档位。
## 两者不一致就是"没写进去"：4.7 之前这里写的是 Window.set("vsync_mode",…)，桌面实测那条静默失败，## 只靠这行读数才看得出来。引擎侧 0=DISABLED 1=ENABLED 2=ADAPTIVE 3=MAILBOX。
const _VS_FMT := "档%d→实际%d"


func _vsync_apply() -> void:
	# prefs 的编号→DisplayServer 的枚举（0=开→ENABLED，1=关→DISABLED，2=兼容→ADAPTIVE）
	DisplayServer.window_set_vsync_mode(UserPrefs.vsync_ds(_vsync))

func _fps_reset() -> void:
	_fps_n = 0
	_fps_sum = 0.0
	_fps_min = 1e9
	_fps_max = 0.0
	_post_prev_us = 0
	_song_done = false

## 逐帧统计（只在真正开演、没暂停、没打完时采，调用处负责门控）
func _fps_track(delta: float) -> void:
	if delta <= 0.0:
		return
	_fps_n += 1
	_fps_sum += delta
	var f := 1.0 / delta
	if f < _fps_min:
		_fps_min = f
	if f > _fps_max:
		_fps_max = f

## 结算页要的帧率字典（空 = 本局没采到，页面上就不画）
func fps_stats() -> Dictionary:
	if _fps_n <= 0 or _fps_sum <= 0.0:
		return {}
	return {"max": _fps_max, "avg": float(_fps_n) / _fps_sum,
			"min": _fps_min, "n": _fps_n}

## 建（或复用）乐曲总线并挂上抓样效果：只有开了响度标准化才需要这条路。
## capture 挂在总线上而不是播放器上——4.7 的 AudioStreamPlayer 没有 add_effect
## （个人效果只在 AudioStreamPlayerInternal 那条链上暴露），与噪域低通同一个套路。
func _ensure_music_bus() -> void:
	if not loud_norm or _audio == null:
		return
	_music_bus = &"PTN_Music"
	var bi := AudioServer.get_bus_index(_music_bus)
	if bi < 0:
		bi = AudioServer.get_bus_count()
		AudioServer.add_bus(bi)
		AudioServer.set_bus_name(bi, _music_bus)
		AudioServer.set_bus_send(bi, "Master")
	var found: AudioEffectCapture = null
	for i in AudioServer.get_bus_effect_count(bi):
		var e := AudioServer.get_bus_effect(bi, i) as AudioEffectCapture
		if e != null:
			found = e
	if found == null:
		found = AudioEffectCapture.new()
		found.buffer_length = 0.5
		AudioServer.add_bus_effect(bi, found)
	_cap = found
	_audio.bus = _music_bus
	_loud_sum = 0.0
	_loud_n = 0
	_loud_done = false
	_norm_db = 0.0

## 乐曲最终增益 = 用户音乐音量 + 标准化回补量（关了标准化就只有前者）
func _apply_music_gain() -> void:
	if _audio == null:
		return
	var db := linear_to_db(music_volume) if music_volume > 0.001 else -80.0
	if loud_norm:
		db += _norm_db
	_audio.volume_db = db

## 开局前 5 秒累计平方和 → RMS → 一次性回补，之后不再动（不做逐帧 AGC）
func _loud_tick() -> void:
	if _cap == null or _loud_done or _audio == null or not loud_norm:
		return
	if not _audio.is_playing() or _audio.stream_paused:
		return
	var fa := _cap.get_frames_available()
	if fa <= 0:
		return
	for v in _cap.get_buffer(fa):
		var s: float = (v.x + v.y) * 0.5
		_loud_sum += s * s
		_loud_n += 1
	if _loud_n < int(AudioServer.get_mix_rate() * LOUD_SECS):
		return
	_loud_done = true
	var rms := sqrt(_loud_sum / maxf(float(_loud_n), 1.0))
	var measured := linear_to_db(maxf(rms, 1e-6))
	# 抓到的是"已经过用户音乐音量"的电平，先扣掉它再算回补量
	var music_db := linear_to_db(maxf(music_volume, 0.001))
	_norm_db = clampf(LOUD_TARGET_DB - (measured - music_db), -12.0, 6.0)
	_apply_music_gain()
	print("QA-LOUD 实测=", measured, " 扣用户增益=", measured - music_db,
			" 回补=", _norm_db, " dB (目标 ", LOUD_TARGET_DB, " LUFS) 帧=", _loud_n)

## 每秒结算一次上屏节拍；面板开着时才去读 /proc（几十个文件，没必要每帧都翻）
func _perf_tick(delta: float) -> void:
	if not debug_mode:
		return
	_perf_t += delta
	if _perf_t < 1.0:
		return
	_perf_pps = float(_post_n) / _perf_t
	_post_n = 0
	_perf_t = 0.0
	# 只有设置页开了「调试模式」才采（/proc 几十个文件，没必要每帧翻）
	if not debug_mode:
		return
	var s: Dictionary = PerfProbe.sample(_perf_prev)
	_perf_prev = s["ticks"]
	_perf_line = PerfProbe.fmt_rows(s["rows"], 4)
	if is_instance_valid(_dbg_lbl):
		_dbg_lbl.visible = true
		# hdr/msaa 一起上屏：HDR(开) 会把 2D 画布切到线性空间，整条按字节空间标定的链
		# 会整体变暗 + 红色去饱和（实测见 PHIZONE_GAP），"预警变白"这类问题第一眼要看它。
		_dbg_lbl.text = "帧率 最大 %.0f · 平均 %.1f · 最小 %.0f（本局 n=%d）\n上屏 %.1f/s · 循环 %.1f/s · 屏 %.0fHz · vsync档→实际=%s · max_fps=%d · hdr=%s · msaa=%d\n%s%s" % [
			_fps_max, (float(_fps_n) / _fps_sum if _fps_sum > 0.0 else 0.0), _fps_min, _fps_n,
			_perf_pps, Engine.get_frames_per_second(), DisplayServer.screen_get_refresh_rate(),
			_VS_FMT % [_vsync, DisplayServer.window_get_vsync_mode()], Engine.max_fps, str(get_viewport().get("use_hdr_2d")),
			int(get_viewport().msaa_2d), _perf_line, _dbg_block_line()]
	print("QA-PERF 上屏=%.1f/s 循环=%.1f/s 屏=%.0fHz vsync档→实际=%s max_fps=%d 本局帧率[最大=%.0f 平均=%.1f 最小=%.0f n=%d]%s | %s" % [
		_perf_pps, Engine.get_frames_per_second(), DisplayServer.screen_get_refresh_rate(),
		_VS_FMT % [_vsync, DisplayServer.window_get_vsync_mode()], Engine.max_fps, _fps_max,
		(float(_fps_n) / _fps_sum if _fps_sum > 0.0 else 0.0), _fps_min, _fps_n,
		_dbg_block_line().replace("\n", " / "), _perf_line])

## 噪域链路的实时读数（只在开了「调试模式」时上屏）。这条链在手机上出过两次
## "屏外看不出来"的问题——位移图在导出包里取不到（边界成直线）、感染锁卡死
## （点过噪域后一直压着音乐=听感没声音），所以把四个关键量直接写在他眼前：
## 混音率、当前截止、感染手数、位移图尺寸、effect 是否还在链路上。
## 他只要念一行「感染=1 链路=在」我就能定案，不用他跑 adb。
func _dbg_block_line() -> String:
	if not _blocks_on:
		return ""
	var lp_on := _blk_lp_on and _blk_lp_i >= 0 and _blk_lp_ei >= 0 \
			and AudioServer.is_bus_effect_enabled(_blk_lp_i, _blk_lp_ei)
	return "\n噪域 位移=%dx%d · 抑制=%s · 截止=%.0fHz(全频%.0f/混音%.0f) · 感染=%d · 触点=%d" % [
		_blk_noise_sz.x, _blk_noise_sz.y, "开" if lp_on else "关", _blk_lp_cur,
		_blk_full_hz(), AudioServer.get_mix_rate(),
		_cp.blocked_touch_count() if _cp != null else 0, _touches.size()]

## HUD 与特效层(40/41)/游戏层(_lout z40)同屏：HUD 必须在游戏层**之上**（player GameUI
## 是相机的最后一段）。以前 Label 默认 z=0，音符从上往下滚过顶部时会把 combo 数字盖掉
## （用户报的"combonumber 消失"就是这个）；attach holder 早就是 55，这里统一。
const HUD_Z_TOP := 55
func _lbl(pu: float) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", UiTokens.install_font())
	l.set_meta("pu", pu)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.z_index = HUD_Z_TOP
	l.z_as_relative = false
	_host.add_child(l)
	return l

## player GameUI 三尺度：p() 按宽/1350（字号/偏移/尺寸全用它），w() 定位 x，h() 定位 y
func _pw(v: float) -> float: return size.x * v / 1350.0
func _wx(x: float) -> float: return size.x * (x / 1350.0 + 0.5)
func _hy(y: float) -> float: return size.y * (0.5 - y / 900.0)

## 按 player 锚点+origin 放置一个 Label：cx/cy=chart 位置，ox/oy=p() 偏移，font=p() 字号
func _hud_label(l: Label, cx: float, cy: float, ox: float, oy: float, font: float, orgx: float, orgy: float) -> void:
	var vp := size
	var ax := _wx(cx) + _pw(ox)
	var ay := _hy(cy) + _pw(oy)
	var fs := maxi(int(_pw(font)), 8)
	l.add_theme_font_size_override("font_size", fs)
	var f: Font = l.get_theme_font("font")
	var th: float = f.get_ascent(fs) + f.get_descent(fs)
	if orgx <= 0.0:
		l.position.x = ax
		l.size = Vector2(vp.x - ax, th)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	elif orgx >= 1.0:
		l.position.x = 0
		l.size = Vector2(ax, th)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	else:
		l.position.x = 0
		l.size = Vector2(vp.x, th)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if orgy >= 1.0:
		l.position.y = ay - th
	elif orgy <= 0.0:
		l.position.y = ay
	else:
		l.position.y = ay - th * 0.5
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

func _hud_layout() -> void:
	var vp := size
	# 进度条：照 player GameUI.resize 那两条式子——
	#   scaleX=p(1350)/8000、scaleY=p(1080)/8000（**两个都除以贴图宽**，所以任何屏幕比例下
	#   贴图都不被压扁：画出来宽=屏宽、高=0.007·屏宽），origin(1,0.2) ⇒ 顶部 20% 伸出屏幕外，
	#   x=p(prog·1350) ⇒ 整条按 8000→屏宽 固定画好，靠"滑动"露出进度，右端就是进度点。
	# 以前我们把它压成 (prog·W, 1%·H)：贴图随进度横向挤压（越到后面越扁），
	# 高又按屏高算 ⇒ 宽屏上细成一条线、看着像没铺满顶部（用户报的两条都是这一个根因）。
	var bar_h := vp.x * 0.007
	_bar.size = Vector2(vp.x, bar_h)
	_bar.position = Vector2((_hud_prog - 1.0) * vp.x, -bar_h * 0.2)
	# 暂停：player svg 128×128，resize 到 p(0.325) → 0.0308·W 见方，锚点 w(-648),h(425)+p(5)
	var pside := _pw(0.325) * 128.0
	# 图标尺寸/位置一个像素都不动，只把按钮矩形向四周各扩 0.5×边长当不可见热区：
	# D700 上 41.6 画布像素≈28dp，低于 Android 48dp 最小可点目标（用户"很大概率点不到暂停"）。
	_pause_pad = pside * 0.5
	for m in ["content_margin_left", "content_margin_right", "content_margin_top", "content_margin_bottom"]:
		_pause_sb.set(m, _pause_pad)
	_btn_pause.size = Vector2(pside + _pause_pad * 2.0, pside + _pause_pad * 2.0)
	_btn_pause.position = Vector2(_wx(-648.0) - _pause_pad, _hy(425.0) + _pw(5.0) - _pause_pad)
	_layout_pause_menu()
	# 连击数 w(0),h(437) origin(0.5,0) font p(63)
	_hud_label(_lbl_combo, 0.0, 437.0, 0.0, 0.0, 63.0, 0.5, 0.0)
	# COMBO w(0),h(437) +offset p(61) font p(22)
	_hud_label(_lbl_combo_tag, 0.0, 437.0, 0.0, 61.0, 22.0, 0.5, 0.0)
	# 分数 w(643),h(428) origin(1,0) font p(46)
	_hud_label(_lbl_score, 643.0, 428.0, 0.0, 0.0, 46.0, 1.0, 0.0)
	# Acc w(643),h(428) +offset p(45) origin(1,0) font p(22)
	_hud_label(_lbl_acc, 643.0, 428.0, 0.0, 45.0, 22.0, 1.0, 0.0)
	# 曲名 w(-643),h(-428) origin(0,1) font p(34)；难度 w(643),h(-428) origin(1,1) font p(34)
	_hud_label(_lbl_title, -643.0, -428.0, 0.0, 0.0, 34.0, 0.0, 1.0)
	_hud_label(_lbl_level, 643.0, -428.0, 0.0, 0.0, 34.0, 1.0, 1.0)

func start() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)  # 满屏锚会把 16:9 矩形顶回去，这里自己摆
	# 诊断：上屏节拍只能数 frame_post_draw（一次信号=一帧真的交给系统合成了），
	# Engine.get_frames_per_second() 数的是主循环圈数，两者不等就说明被 vsync/刷新率挡了
	if not RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		RenderingServer.connect("frame_post_draw", _on_post_draw)
	_vsync_apply()  # 偏好里的 vsync 要等入树后才拿得到 window
	# 自动播放初值来自设置页（游玩中不再有 A 键开关：自动演示会顶掉真打，判为误触）
	if autoplay_on and _cp != null:
		_cp.set_autoplay(true)
	_resized()
	resized.connect(_resized)
	if _audio != null and _audio.stream != null:
		if _bg_blur_pending:
			# 背景还没糊完 ⇒ 先不落拍（见 _bake_bg_blur / _bg_blur_done）
			_audio_start_pending = true
			_audio_start_deadline = Time.get_ticks_msec() + 3000
		else:
			_audio.play()
			_audio_started = true
			_pos_watch_reset(0.0)

func _resized() -> void:
	_fit_play_rect()
	if _cp != null:
		_cp.set_scale(size.x, size.y)
		_apply_block_cell()   # 自动档跟着分辨率走
		_hud_layout()
	if _csv != null:
		_sv_set(_csv, size)
	if _lsv != null:
		_sv_set(_lsv, size)
	if _bsv != null:
		_sv_set(_bsv, size)
	if _bout != null:
		# 噪域 Active 层挂在 game 层（父级是逻辑空间），要用逻辑尺寸
		_bout.size = _lrect.size
	# 预警层**不在这里改尺寸**：它只在 _setup_blocks_out 里按创建时的 size 摆一次，
	# 这是用户裁定"以 warn_only6.png 为准"的那个状态。我上一轮加的 `_bdis.size = size`
	# 会让它在每次 _resized 后跟着新尺寸重铺（等于把红纱铺满整屏），已经删掉。
	if _cp != null:
		_cp.position = Vector2(0, size.y)  # 镜像原点跟随高度
	if _host != null:
		_host.size = size
	if is_instance_valid(_dbg):
		# 调试层与舞台同系（逻辑×_k 的设备像素）：size 决定字号和"可见线段"求交边界
		_dbg.size = size
	if is_instance_valid(_dbg_lbl):
		_dbg_lbl.position = Vector2(size.x * 0.012, size.y * 0.05)
		_dbg_lbl.add_theme_font_size_override("font_size", maxi(int(size.x * 13.0 / 1350.0), 9))
	for u in _units:
		_sv_set(u["sv"], size)
		var mc: Control = u["mc"]
		mc.size = Vector2(size.x, size.y)
		mc.pivot_offset = mc.size * 0.5

## F10 低预设：物理尺寸=逻辑×render_scale，size_2d_override 保持逻辑坐标
## （子节点/输入坐标不变，输出侧 TextureRect 本来就近邻放大回全屏）
var render_scale := 1.0

## 游玩画布最宽 16:9（PT renderer/index.ts:99-104：canvasos.width=min(宽, 高×16/9)，
## 更宽的屏幕左右留黑）。实现方式=**把舞台自己摆成这个矩形**，而不是逐个改内部数学：
## 这样 size / _pw / _wx / _hy / 各 SubViewport / 挂在舞台下的覆盖层全部自动按画布走，
## 之前对过帧的渲染数学一行都不用动。代价只有输入坐标要在边界平移一次（见 _input）。
## 手动摆位必须先把锚设回 TOP_LEFT，否则 FULL_RECT 锚会在下一次布局pass把矩形顶回去。
## 舞台内部单位 = 逻辑像素 × _k（设备像素），整个 Control 再用 scale=1/_k 缩回逻辑空间。
## 这样离屏缓冲/原生绘制/字体取整全部自动升到设备分辨率，模糊的根源（1610×900 的缓冲被
## 拉到 2544×1422 显示）就没有了，而所有百分比布局一行都不用改。
## （试过另一条路：把 SubViewport 开大 + size_2d_override(+stretch) 让 engine 放大内容——
##   2700×1800 实跑两种组合都只按 1:1 画在 buffer 左上角，这个方向的缩放 engine 不给。）
func _fit_play_rect() -> void:
	var vs := get_viewport_rect().size
	if vs.x <= 0.0 or vs.y <= 0.0:
		return
	var pw := minf(vs.x, vs.y * 16.0 / 9.0)

	var want_pos := Vector2((vs.x - pw) * 0.5, 0.0)
	var want_sz := Vector2(pw, vs.y)
	## 舞台内部一律按**设备像素**算（_k×逻辑），再把整个 Control 用 scale=1/_k 缩回逻辑空间：
	## 离屏缓冲、原生绘制、字体取整全部随之升到设备分辨率，而所有百分比布局/判定坐标换算
	## 的语义一个字都不用改。
	_k = _px_scale()
	_lrect = Rect2(want_pos, want_sz)
	_blk_field = Vector4(want_pos.x / vs.x, want_pos.y / vs.y, want_sz.x / vs.x, want_sz.y / vs.y)
	_blk_screen_px = vs * _k
	_blk_field_px = want_sz * _k
	var want_draw := want_sz * _k
	if position == want_pos and size == want_draw and scale.x == 1.0 / _k:
		return  # 已经是目标矩形（自己触发的那次 resized 会走到这里返回）
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = want_pos
	scale = Vector2(1.0 / _k, 1.0 / _k)
	size = want_draw

func _sv_set(sv: SubViewport, logical: Vector2) -> void:
	var rs := render_scale
	sv.size = Vector2i(maxi(int(logical.x * rs), 2), maxi(int(logical.y * rs), 2))
	if rs >= 0.999:
		sv.size_2d_override = Vector2i.ZERO
		sv.size_2d_override_stretch = false
	else:
		sv.size_2d_override = Vector2i(int(logical.x), int(logical.y))
		sv.size_2d_override_stretch = true  # 4.7 实名（ClassDB 实证）；写 size_2d_stretch 会中途报错，半尺寸 buffer 没 override 就只剩左上 1/4

## 设备像素 ÷ 逻辑像素：舞台内部就按这个倍率放大来算（见 _fit_play_rect）。
## 下限 1.0：窗口比逻辑尺寸还小时不跟着降（F10 有专门的低预设）。
## 全谱音符数：并行档位拿它当"这张谱有多大"的判据（大谱一个进程就吃 2GB 量级）
func note_total() -> int:
	return _cp.get_total_notes() if _cp != null else 0

func _px_scale() -> float:
	if not hi_res:
		return 1.0
	var w := get_window()
	if w == null:
		return 1.0
	# 渲染录制走离屏：这时"视口"就是那块 SubViewport（尺寸=录制尺寸），
	# 根本不存在"逻辑×DPI"这一层，再按窗口比一乘就会白渲染 2 倍像素再缩回去
	if get_viewport() != w:
		return 1.0
	var vs := get_viewport_rect().size
	if vs.x <= 0.0 or w.size.x <= 0:
		return 1.0
	return maxf(float(w.size.x) / vs.x, 1.0)

## 取一张「要读像素」的 res:// 图。顺序很重要：
## 1) ResourceLoader——编辑器与导出包都能拿到（导出包里走 .godot/imported 的 .ctex）；
## 2) Image.load_from_file——只剩散文件跑（未导入的临时素材）时才用得上。
## 只写 2) 的代价见 _setup_blocks：导出包里没有源 png，手机上静默拿到 null。
## 返回的 Image 可能是压缩格式，调用方自己 convert()。
func _load_cpu_image(path: String) -> Image:
	var t := load(path) as Texture2D
	if t != null:
		var im := t.get_image()
		if im != null and not im.is_empty():
			return im
	return Image.load_from_file(path)

## 噪域掩码层：一个 Polygon2D 池，按 blockAreaList 列表序摆（顺序画家语义靠树序+GPU 混合）。
## 只在彩蛋门控开着且谱面真有噪域时建；否则整条链一个节点都不多。
func _setup_blocks() -> void:
	if not GameFlags.block_area:
		return
	if _cp == null or not _cp.has_blocks():
		return
	_blocks_on = true
	_cp.set_block_warp(block_warp)
	# 强制走 CPU 精确路径。原先低预设（F10，render_scale<1）会切到 SubViewport+Polygon2D
	# 的 GPU 近似版，但那条路径的掩码纹理里 G/B 是 Polygon2D 的白色叠加、并不是官方的
	# Edge/Glow 通道，预警层读 .a 也会读到白色多边形 —— 出图与 CPU 路径完全不同且从未被
	# 截图验证过（用户报"实际截图全是白色透明格"最像这个）。CPU 路径实测 14355 块也只有
	# 0.6~2.7ms/帧，不值得为半分辨率再养第二套真相。
	_blk_cpu = true
	# 位移图喂给 C++（BlockNoise1 的 R 通道；prpr 上传前 flip_vertical，翻转在 C++ 里等价做）
	# 必须走 ResourceLoader：导出的包里**没有源 png**，只有 .import 和它派生的
	# .godot/imported/*.ctex（APK 实测），`Image.load_from_file("res://…png")` 在手机上
	# 直接返回 null → CPU 掩码整段退化成"不置换"，用户看到的就是"噪域边界变成直线"，
	# 而且可见区比逻辑判定区整整少了噪声推移的那 ~7% 屏宽（判定区域对不上）。
	# 这张图的导入参数是 lossless（compress/mode=0、vram_texture=false），
	# 所以 get_image() 拿到的就是 RGBA8 原图，与编辑器里 F5 完全同一份像素。
	var ni := _load_cpu_image("res://assets/blockarea/BlockNoise1.png")
	if ni == null:
		push_warning("QA-BLOCK 噪域位移图缺失：走不置换路径（边界会是直线）")
	else:
		# Image.convert() 是 void：只能转完再验格式。导入件若是 VRAM 压缩格式，
		# get_data() 的步长就不是 4 字节/像素，喂进去会拿错位内存当噪声
		# （宁可不置换，也别画出一堆随机块）。
		ni.convert(Image.FORMAT_RGBA8)
		if ni.get_format() != Image.FORMAT_RGBA8:
			push_warning("QA-BLOCK 噪域位移图无法转 RGBA8（格式=%d）：不喂位移图"
					% int(ni.get_format()))
		else:
			_cp.set_block_noise(ni.get_data(), ni.get_width(), ni.get_height())
			_blk_noise_sz = Vector2i(ni.get_width(), ni.get_height())
	# 触摸 hover 精灵（官方 Round10_Blur4）：同样必须走 ResourceLoader（导出包无源 png）
	var hv := _load_cpu_image("res://assets/blockarea/TouchHover.png")
	if hv == null:
		push_warning("QA-BLOCK 缺 TouchHover.png：触摸特效不显示")
	else:
		hv.convert(Image.FORMAT_RGBA8)
		if hv.get_format() == Image.FORMAT_RGBA8:
			_cp.set_block_hover(hv.get_data(), hv.get_width(), hv.get_height())
		else:
			push_warning("QA-BLOCK TouchHover.png 转不到 RGBA8：不喂")
	# GPU 掩码：四个小视口（网格尺寸），每帧把可见区当加法多边形铺一遍再走两趟 shader。
	# 用户口径："别调参数了，直接移到 GPU 算"——CPU 是逐格扫，成本≈面积×区数。
	if _blk_cpu:
		_bmask_img = Image.create(4, 4, false, Image.FORMAT_RGBA8)
		_baux_img = Image.create(4, 4, false, Image.FORMAT_RGBA8)
		_bmask_tex = ImageTexture.create_from_image(_bmask_img)
		_baux_tex = ImageTexture.create_from_image(_baux_img)
		print("QA-BLOCK on: 噪域=", _cp.has_blocks(), " 路径=CPU 掩码复刻")
		return
	# GPU 近似：掩码视口 + Polygon2D 池（列表序=合成序，norm 覆盖 / SUB 擦除）
	_bsv = SubViewport.new()
	_bsv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_bsv.transparent_bg = true
	add_child(_bsv)
	_sv_set(_bsv, size)  # 同 _csv：进树后再设 override
	_blayer = Node2D.new()
	_bsv.add_child(_blayer)
	_norm_mat = CanvasItemMaterial.new()
	_sub_mat = CanvasItemMaterial.new()
	_sub_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_SUB
	for i in BLOCK_POOL:
		var p := Polygon2D.new()
		p.material = _norm_mat
		p.color = Color(1, 1, 1, 1)
		p.antialiased = false  # 硬像素边（马赛克质感，不要抗锯齿糊边）
		p.visible = false
		_blayer.add_child(p)
		_bpool.append(p)
	print("QA-BLOCK on: 路径=GPU 近似（低预设）")

## 噪域表现层：Active（后处理，官方盖住音符与 HUD）+ Disabled（背景层，判定线之前，加色）
func _setup_blocks_out() -> void:
	if not _blocks_on:
		return
	_bmat = ShaderMaterial.new()
	_bmat.shader = load("res://shaders/block_area.gdshader")
	_bdmat = ShaderMaterial.new()
	# 预警层是官方 shader 的另一条分支（uLayer=0）：和 Active **同一条管线**
	# （采现场 + 像素吸附 + 噪声位移 + 火花），只是换一套暗砖红常量、并且不读 Edge/Glow。
	# 以前这里写的是"平涂纯红、不读现场、加色"——那是我自己加的写法，不是参考实现；
	# 而且复用 Active 那份 shader + 开关时，overlay/HSV 会把预警抬成白色（用户连报三轮）。
	# 现在按 Phira-Pro/Phira-Pro 的 prpr/src/core/block_shader.rs 逐常量移植。
	_bdmat.shader = load("res://shaders/block_area_disabled.gdshader")
	_bout = ColorRect.new()
	_bout.color = Color(1, 1, 1, 1)
	_bout.material = _bmat
	_bout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bout.z_index = BLOCK_ACT_Z
	_bout.size = size
	_host.add_child(_bout)
	_bdis = ColorRect.new()
	_bdis.color = Color(1, 1, 1, 1)
	_bdis.material = _bdmat
	_bdis.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bdis.z_index = BLOCK_DIS_Z
	# ⚠ 必须用锚点铺满，不能 `_bdis.size = size`：这一层是在 _ready 里建的，
	# 那一刻舞台的 size 还不是最终画布尺寸（实测 global rect = S:(0,0) → 预警层
	# 从头到尾一个像素都没画出来）。_bout 之所以一直正常，是因为它后来被
	# place_block_overlay 挂到 game 层时重设了 FULL_RECT 锚点。
	_host.add_child(_bdis)
	_bdis.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sync_block_tex()
	var disp_tex := load("res://assets/blockarea/BlockNoise1.png")
	var spark_tex := load("res://assets/blockarea/PointNoise.png")
	for m in [_bmat, _bdmat]:
		m.set_shader_parameter("uDisplaceTex", disp_tex)
		m.set_shader_parameter("uSparkTex", spark_tex)
	# 指尖层的活动细胞噪声（官方 uNoiseTex = FD_Noise_00000，Mirror + Nearest；
	# Godot 侧没开 repeat，Mirror 由 shader 里的 mirror_fold 代做）。只有 Active 层有这条 pass。
	if _bmat != null:
		_bmat.set_shader_parameter("uNoiseTex", load("res://assets/blockarea/FD_Noise_00000.png"))
	# 滑杆初值推进材质（setter 在材质存在前跑过，值都在成员里）
	_bset("_EdgeOpacity", block_edge_opacity)
	_bset("_GlowIntensity", block_glow)
	_bset("_FillStrength", block_fill_strength)
	_bset("_FillOpacity", block_fill_opacity)
	_bset("_SparkMapOpacity", block_spark_map)
	_bset("_DisplaceStrength", block_displace)
	_bset("_BackgroundPixelScale", block_pixel_scale)
	_bset("uAlphaMul", block_alpha)
	_bset_warn(block_warn_opacity)
	_build_block_layer_nodes()

## 噪域层节点：layer 0 沿用 _bout/_bdis/_bmat/_bdmat 与主掩码缓冲；
## layer 1..N-1 各自复制一份材质（参数来自基础材质）并维护独立掩码/配色纹理。
func _build_block_layer_nodes() -> void:
	for L0 in _blayer_nodes:
		var a0: Variant = L0.get("act")
		if a0 != null and is_instance_valid(a0) and a0 != _bout:
			(a0 as Node).queue_free()
			var d0: Variant = L0.get("dis")
			if d0 != null and is_instance_valid(d0):
				(d0 as Node).queue_free()
	_blayer_nodes.clear()
	_blayer_defs = _cp.get_block_layers()
	_has_skin_layer = false
	for d0 in _blayer_defs:
		if String(d0.get("skin", "")) != "":
			_has_skin_layer = true
			break
	if _blayer_defs.size() <= 1 and not _has_skin_layer:
		return
	for i in _blayer_defs.size():
		var L := {}
		if i == 0:
			L = {"act": _bout, "dis": _bdis, "ma": _bmat, "md": _bdmat,
				"img": null, "aimg": null, "tex": null, "atex": null,
				"cimg": [null, null], "ctex": [null, null]}
		else:
			var ma: ShaderMaterial = _bmat.duplicate()
			var md: ShaderMaterial = _bdmat.duplicate()
			var act := ColorRect.new()
			act.color = Color(1, 1, 1, 1)
			act.material = ma
			act.mouse_filter = Control.MOUSE_FILTER_IGNORE
			act.z_index = BLOCK_ACT_Z + i
			act.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			act.visible = false
			_host.add_child(act)
			var dis := ColorRect.new()
			dis.color = Color(1, 1, 1, 1)
			dis.material = md
			dis.mouse_filter = Control.MOUSE_FILTER_IGNORE
			dis.z_index = BLOCK_DIS_Z + i
			dis.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			dis.visible = false
			_host.add_child(dis)
			L = {"act": act, "dis": dis, "ma": ma, "md": md,
				"img": null, "aimg": null, "tex": null, "atex": null,
				"cimg": [null, null], "ctex": [null, null]}
		_blayer_nodes.append(L)
		_setup_layer_skin(i, L, _blayer_defs[i])
	print("QA-BLOCKLAYERS n=", _blayer_defs.size())

## 噪域层皮肤：加载 `shader/<name>`（目录见 NoiseSkinRenderer.find_skin_dir），成功则用
## 皮肤回贴层替换该层的官方材质层。加载失败回落到官方材质。
func _setup_layer_skin(i: int, L: Dictionary, def: Dictionary) -> void:
	var skin: String = String(def.get("skin", ""))
	L["params"] = def.get("parameters", {})
	L["channel"] = String(def.get("channel", "normal"))
	if skin == "":
		return
	var r := NoiseSkinRenderer.new()
	if not r.load_skin(skin, _dir):
		push_warning("噪域皮肤加载失败 %s：%s（回落官方材质）" % [skin, r.error])
		return
	if _skin_root == null:
		_skin_root = Control.new()
		_skin_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_skin_root.size = size
		add_child(_skin_root)  # 必须晚于 _csv：pass 视口要采到本帧画布
	var disp := TextureRect.new()
	disp.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	disp.stretch_mode = TextureRect.STRETCH_SCALE
	disp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disp.z_index = BLOCK_ACT_Z + i
	disp.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var pm := CanvasItemMaterial.new()
	pm.set("blend_mode", 0 if r.straight else 4)  # component 皮肤是 straight 数据，其余是预乘
	disp.material = pm
	disp.visible = false
	_host.add_child(disp)
	_skin_disps.append(disp)
	r.set_channel(String(def.get("channel", "normal")))
	L["skin_r"] = r
	L["skin_disp"] = disp
	L["mask_img"] = null
	L["mask_tex"] = null
	print("QA-NOISESKIN layer=", i, " skin=", skin, " params=", (L["params"] as Dictionary).size(),
			" passes=", r.passes.size())

## 逐层刷新：掩码（30Hz）+ 配色 + 显隐；uTime 每帧都推。
func _update_blocks_layered() -> void:
	_blk_skip_tick += 1
	var skip := (_blk_skip_tick & 1) == 1
	for i in _blayer_nodes.size():
		var L: Dictionary = _blayer_nodes[i]
		var ma: ShaderMaterial = L["ma"]
		var md: ShaderMaterial = L["md"]
		if ma != null:
			ma.set_shader_parameter("uTime", _clock)
		if md != null:
			md.set_shader_parameter("uTime", _clock)
		var skin_r: NoiseSkinRenderer = L.get("skin_r")
		if skip:
			if skin_r != null and skin_r.ok:
				_render_skin_layer(i, L, skin_r)
			continue
		if skin_r != null and skin_r.ok:
			_render_skin_layer(i, L, skin_r)
			continue
		var r: Array = _cp.build_block_mask_layer(i)
		if r.is_empty():
			(L["act"] as ColorRect).visible = false
			(L["dis"] as ColorRect).visible = false
			continue
		var w: int = int(r[0])
		var h: int = int(r[1])
		if i == 0:
			# layer0 与旧路径共用 _bmask_img/_baux_tex/_bmat/_bdmat
			if _bmask_img == null or _bmask_img.get_width() != w or _bmask_img.get_height() != h:
				_bmask_img = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, r[2])
				_baux_img = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, r[3])
				_bmask_tex = ImageTexture.create_from_image(_bmask_img)
				_baux_tex = ImageTexture.create_from_image(_baux_img)
			else:
				_bmask_img.set_data(w, h, false, Image.FORMAT_RGBA8, r[2])
				_bmask_tex.update(_bmask_img)
				_baux_img.set_data(w, h, false, Image.FORMAT_RGBA8, r[3])
				_baux_tex.update(_baux_img)
			_sync_block_colors(r)
			_sync_block_tex()
			(L["act"] as ColorRect).visible = int(r[8]) == 1
			(L["dis"] as ColorRect).visible = int(r[9]) == 1
			continue
		var img: Image = L["img"]
		var aimg: Image = L["aimg"]
		if img == null or img.get_width() != w or img.get_height() != h:
			L["img"] = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, r[2])
			L["aimg"] = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, r[3])
			L["tex"] = ImageTexture.create_from_image(L["img"])
			L["atex"] = ImageTexture.create_from_image(L["aimg"])
		else:
			img.set_data(w, h, false, Image.FORMAT_RGBA8, r[2])
			(L["tex"] as ImageTexture).update(img)
			aimg.set_data(w, h, false, Image.FORMAT_RGBA8, r[3])
			(L["atex"] as ImageTexture).update(aimg)
		_sync_layer_tex(i)
		_sync_layer_colors(i, r)
		(L["act"] as ColorRect).visible = int(r[8]) == 1
		(L["dis"] as ColorRect).visible = int(r[9]) == 1

## 皮肤层：blockMask = C++ 打好的 6bit（R 通道），pass 链输出预乘纹理回贴。
func _render_skin_layer(i: int, L: Dictionary, r: NoiseSkinRenderer) -> void:
	var bits: Array = _cp.build_block_mask_bits(i)
	var disp: TextureRect = L["skin_disp"]
	if bits.is_empty():
		disp.visible = false
		(L["act"] as ColorRect).visible = false
		(L["dis"] as ColorRect).visible = false
		return
	var w := int(bits[0])
	var h := int(bits[1])
	var img: Image = L.get("mask_img")
	if img == null or img.get_width() != w or img.get_height() != h:
		L["mask_img"] = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bits[2])
		L["mask_tex"] = ImageTexture.create_from_image(L["mask_img"])
	else:
		img.set_data(w, h, false, Image.FORMAT_RGBA8, bits[2])
		(L["mask_tex"] as ImageTexture).update(img)
	r.ensure(_skin_root, Vector2i(maxi(1, int(size.x)), maxi(1, int(size.y))))
	var tp := _skin_touch_points(i, L)
	var final: Texture2D = r.render(_csv.get_texture(), L["mask_tex"], _clock, L.get("params", {}), tp, tp.size())
	if final == null:
		disp.visible = false
		return
	disp.texture = final
	disp.visible = true
	(L["act"] as ColorRect).visible = false
	(L["dis"] as ColorRect).visible = false

var _skin_releases := {}   # layer -> [[x, y, t_release], ...]

## 皮肤触点：当前按下的手指 + touchReleaseDuration 内保留的抬起点。
func _skin_touch_points(i: int, L: Dictionary) -> PackedVector4Array:
	var out := PackedVector4Array()
	var now := _clock
	var dur := float((L.get("params", {}) as Dictionary).get("touchReleaseDuration", 0.0))
	var rels: Array = _skin_releases.get(i, [])
	var cur := []
	for p in _cp.get_touches():
		var v := Vector2(float(p[0]), float(p[1]))
		cur.append(v)
	# 先登记"这一帧新抬起的点"（位置在上一帧有、这一帧没有），再补余晖——
	# 否则松手那一帧 rels 还是空的，余晖要晚一帧才出现。
	var prev: Array = _skin_prev_touches.get(i, [])
	for p in prev:
		var pp := Vector2(float(p[0]), float(p[1]))
		var alive := false
		for c in cur:
			if c.distance_to(pp) < 24.0:
				alive = true
				break
		if not alive:
			rels.append([pp.x, pp.y, now])
	if dur > 0.0:
		var still := []
		for r in rels:
			var rp := Vector2(float(r[0]), float(r[1]))
			var alive := false
			for c in cur:
				if c.distance_to(rp) < 24.0:
					alive = true
					break
			if alive:
				continue
			if now - float(r[2]) <= dur:
				still.append(r)
			else:
				continue
			if out.size() < 32:
				out.append(Vector4(rp.x, rp.y, 0.0, 0.0))
		rels = still
	else:
		rels.clear()
	for p in cur:
		out.append(Vector4(p.x, p.y, 1.0, 0.0))
	_skin_prev_touches[i] = cur
	_skin_releases[i] = rels
	return out

var _skin_prev_touches := {}  # layer -> 上一帧触点

## 谱包自带字体（textEvents[].font）：按文件名/去扩展名注册，找不到回落内置字体。
func _register_chart_fonts(dir_path: String) -> void:
	var da := DirAccess.open(dir_path)
	if da == null:
		return
	for f in da.get_files():
		var ext := f.get_extension().to_lower()
		if ext not in ["ttf", "otf", "woff", "woff2"]:
			continue
		var bytes := FileAccess.get_file_as_bytes(dir_path.path_join(f))
		if bytes.is_empty():
			continue
		var ff := FontFile.new()
		ff.data = bytes
		_cp.set_named_font(f, ff)
		_cp.set_named_font(f.get_basename(), ff)
		print("QA-FONT ", f)

func _sync_layer_tex(i: int) -> void:
	var L: Dictionary = _blayer_nodes[i]
	var tex: Texture2D = L["tex"]
	var atex: Texture2D = L["atex"]
	var img: Image = L["img"]
	var v := Vector4(1.0 / max(img.get_width(), 1), 1.0 / max(img.get_height(), 1),
			img.get_width(), img.get_height())
	for m in [L["ma"], L["md"]]:
		if m == null:
			continue
		m.set_shader_parameter("uMasks", tex)
		m.set_shader_parameter("uAuxMasks", atex)
		m.set_shader_parameter("uETS", v)
		var which := 1 if m == L["md"] else 0
		m.set_shader_parameter("uDisabledColors" if which == 1 else "uActiveColors",
				(L["ctex"] as Array)[which] if (L["ctex"] as Array)[which] != null else _bcol_empty)

func _sync_layer_colors(i: int, r: Array) -> void:
	var L: Dictionary = _blayer_nodes[i]
	var colored := int(r[6]) == 1
	for m in [L["ma"], L["md"]]:
		if m != null:
			m.set_shader_parameter("uColored", 1 if colored else 0)
	if L["ma"] != null:
		(L["ma"] as ShaderMaterial).set_shader_parameter("uReadyExtra", float(int(r[7])))
	if not colored:
		return
	var w := int(r[0])
	var h := int(r[1])
	var cimg: Array = L["cimg"]
	var ctex: Array = L["ctex"]
	for layer in 2:
		var bytes: PackedByteArray = r[4 + layer]
		if cimg[layer] == null or cimg[layer].get_width() != w or cimg[layer].get_height() != h:
			cimg[layer] = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)
			ctex[layer] = ImageTexture.create_from_image(cimg[layer])
		else:
			cimg[layer].set_data(w, h, false, Image.FORMAT_RGBA8, bytes)
			ctex[layer].update(cimg[layer])
	_sync_layer_tex(i)

func _sync_block_tex() -> void:
	if _bcol_empty == null:
		# 1×1 全透明：uColored=0 时占住采样器，prpr 用同一张 EMPTY_TEX 喂五个空槽
		var e := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		e.fill(Color(0, 0, 0, 0))
		_bcol_empty = ImageTexture.create_from_image(e)
	var masks: Texture2D = _bmask_tex
	var aux: Texture2D = _baux_tex
	var ets := Vector4(1.0 / max(_bmask_img.get_width(), 1), 1.0 / max(_bmask_img.get_height(), 1),
			_bmask_img.get_width(), _bmask_img.get_height())
	if _bmg != null:
		# 直接绑视口贴图：读回副本（mask_tex）实测会停在上一版（final 中心已是 1，副本还是 0）
		# 用读回副本（普通 ImageTexture）：ViewportTexture 直接绑给材质时采样结果与
		# get_image() 看到的不一致（白掩码实验证明材质确实在消费 uMasks）
		masks = _bmg.final.get_texture()
		aux = _bmg.aux.get_texture()
		# 隔离：aux 全零（hover/ready 都不亮）→ 判断整屏发红是不是 aux 交付的问题
		if OS.get_environment("BLK_ZERO_AUX") != "":
			if _blk_zero == null:
				var zi2 := Image.create(1, 1, false, Image.FORMAT_RGBA8)
				zi2.fill(Color(0, 0, 0, 0))
				_blk_zero = ImageTexture.create_from_image(zi2)
			aux = _blk_zero
		# 隔离实验（BLK_WHITE_MASK=1）：把 uMasks 换成 1×1 白，验证着色器是否真的在消费这张图
		if OS.get_environment("BLK_WHITE_MASK") != "":
			if _blk_white == null:
				var wi := Image.create(1, 1, false, Image.FORMAT_RGBA8)
				wi.fill(Color(1, 1, 1, 1))
				_blk_white = ImageTexture.create_from_image(wi)
			masks = _blk_white
		ets = Vector4(1.0 / max(float(_bmg.grid.x), 1.0), 1.0 / max(float(_bmg.grid.y), 1.0),
				_bmg.grid.x, _bmg.grid.y)
	elif not _blk_cpu and _bsv != null:
		masks = _bsv.get_texture()
		aux = _bsv.get_texture()
		ets = Vector4(1.0 / max(size.x, 1), 1.0 / max(size.y, 1), size.x, size.y)
	for m in [_bmat, _bdmat]:
		if m == null:
			continue
		m.set_shader_parameter("uMasks", masks)
		m.set_shader_parameter("uAuxMasks", aux)
		m.set_shader_parameter("uETS", ets)
		# 调色板没建的时候喂 1×1 空纹（prpr 的 EMPTY_TEX 同语义：uColored=0 ⇒ 纹理不参与）。
		# 两张各自只喂给读它的那条 pass——给 shader 里不存在的 uniform 名 set_parameter 会刷警告。
		var which := 1 if m == _bdmat else 0
		m.set_shader_parameter("uDisabledColors" if which == 1 else "uActiveColors",
				_bcol_tex[which] if _bcol_tex[which] != null else _bcol_empty)


## 逐区配色纹理：C++ 每帧算好两张 RGBA8（Active/Disabled），只在"这帧确实在配色"时上传。
## 尺寸变了要重建纹理（效果网格随窗口大小变）。
func _sync_block_colors(r: Array) -> void:
	var colored := int(r[6]) == 1
	for m in [_bmat, _bdmat]:
		if m != null:
			m.set_shader_parameter("uColored", 1 if colored else 0)
	if _bmat != null:
		# Recorder 的 ready 分支要再叠一遍高光（prpr:705，官方案恒 0）；只有 Active 层读它
		_bmat.set_shader_parameter("uReadyExtra", float(int(r[7])))
	if not colored:
		return
	var w := int(r[0])
	var h := int(r[1])
	for layer in 2:
		var bytes: PackedByteArray = r[4 + layer]
		if _bcol_img[layer] == null or _bcol_img[layer].get_width() != w \
				or _bcol_img[layer].get_height() != h:
			_bcol_img[layer] = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)
			# Nearest 由 shader 侧的 `uniform sampler2D ... : filter_nearest` 决定
			# （ImageTexture.filter 在 4.7 是只读的，别在这儿赋值）
			_bcol_tex[layer] = ImageTexture.create_from_image(_bcol_img[layer])
		else:
			_bcol_img[layer].set_data(w, h, false, Image.FORMAT_RGBA8, bytes)
			_bcol_tex[layer].update(_bcol_img[layer])
	_sync_block_tex()

## 每帧：CPU 路径重算效果网格并上传纹理；GPU 近似路径填 Polygon2D 池
func _ensure_bmg() -> void:
	if not UserPrefs.flag("block_gpu") or _blk_noise_sz.x <= 0:
		return
	if size.x < 8.0 or size.y < 8.0:
		return
	var cell := 4.0
	var envc := OS.get_environment("BLOCK_GPU_CELL")
	if envc != "":
		cell = maxf(float(envc), 2.0)
	var want := Vector2i(maxi(int(round(size.x / cell)), 1), maxi(int(round(size.y / cell)), 1))
	if _bmg != null and _bmg.grid == want:
		return
	if _bmg != null:
		_bmg.teardown()
		_bmg = null
	_bmg = BlockMaskGPU.new()
	if not _bmg.setup(self, size, cell, load("res://assets/blockarea/BlockNoise1.png"), block_warp):
		_bmg = null
		return
	print("QA-BLOCK 掩码=GPU 网格=", _bmg.grid, " 单元=", cell)


func _update_blocks() -> void:
	if not _blocks_on:
		return
	if _blayer_nodes.size() > 1 or _has_skin_layer:
		_update_blocks_layered()
		return
	_ensure_bmg()
	var done := false
	if _bmg != null:
		var blk: Array = _cp.debug_blocks(_clock)
		var hov: bool = _cp.block_hover_active() if _cp.has_method("block_hover_active") else false
		if _bmg.update(blk, _clock, hov):
			_blk_gpu_n += 1
			done = true
	if done:
		_sync_block_tex()
	elif _blk_cpu:
		# 掩码隔帧更新（30Hz）：位移/覆盖率差一帧看不出来，CPU 成本直接砍半；
		# 这一帧沿用上一张掩码，只把材质时间推进一格。
		_blk_skip_tick += 1
		if (_blk_skip_tick & 1) == 1:
			for m in [_bmat, _bdmat]:
				if m != null:
					m.set_shader_parameter("uTime", _clock)
			return
		var t0 := Time.get_ticks_usec()
		var r: Array = _cp.build_block_mask()
		_blk_mask_us = int(Time.get_ticks_usec() - t0)
		if r.is_empty():
			# 原生判"与上一帧相同（全空）"⇒ 不重传纹理。ハTE 约 60% 的帧走这条。
			_blk_skip += 1
			if _bout != null:
				_bout.visible = false
			if _bdis != null:
				_bdis.visible = false
		else:
			var w: int = int(r[0])
			var h: int = int(r[1])
			if _bmask_img.get_width() != w or _bmask_img.get_height() != h:
				_bmask_img = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, r[2])
				_baux_img = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, r[3])
				_bmask_tex = ImageTexture.create_from_image(_bmask_img)
				_baux_tex = ImageTexture.create_from_image(_baux_img)
				_sync_block_tex()
			else:
				_bmask_img.set_data(w, h, false, Image.FORMAT_RGBA8, r[2])
				_bmask_tex.update(_bmask_img)
				_baux_img.set_data(w, h, false, Image.FORMAT_RGBA8, r[3])
				_baux_tex.update(_baux_img)
			# 逐区配色 + line2area 开关（RPE 标记噪域才有；官方红谱这里把 uColored 归 0）
			_sync_block_colors(r)
			# 覆盖率开关：R/A 全零的那一层直接不画（官方谱经常只有一层在动，省掉整屏 shader）
			if _bout != null:
				_bout.visible = int(r[8]) == 1
			if _bdis != null:
				_bdis.visible = int(r[9]) == 1
			_blk_n += 1
			if _paused or (_blk_n % 120) == 0:  # 覆盖率诊断：两条路径出图不一致时先看这行（R=Active 覆盖，A=Disabled）
				var b: PackedByteArray = r[2]
				var nr := 0
				var na := 0
				for i in range(0, b.size(), 4):
					if b[i] > 0:
						nr += 1
					if b[i + 3] > 0:
						na += 1
				# 8 段平均 µs：搬线程之前要先知道钱花在六段里的哪一段
				var ph: Array = _cp.debug_block_phases()
				print("QA-BLOCKMASK t=%.2f 网格=%dx%d R=%d%% A=%d%% 构建=%dµs 跳过=%d/%d" % [
					_clock, w, h, nr * 100 / max(b.size() / 4, 1), na * 100 / max(b.size() / 4, 1),
					_blk_mask_us, _blk_skip, _blk_n + _blk_skip])
				print("QA-BLOCKPHASE 完整构建=%d帧 hover=%.0f 清零=%.0f 栅格=%.0f 前缀=%.0f 配色=%.0f 位移=%.0f 膨胀=%.0f 打包=%.0f (µs)" % [
					int(ph[8]), ph[0], ph[1], ph[2], ph[3], ph[4], ph[5], ph[6], ph[7]])
	else:
		var quads: Array = _cp.get_block_quads()
		var n: int = quads.size()
		if n > _bpool.size() and not _bover_warned:
			_bover_warned = true
			print("QA-BLOCK 同屏可见块 ", n, " 超池 ", _bpool.size(), "，多余的不画")
		for i in _bpool.size():
			var poly: Polygon2D = _bpool[i]
			if i >= n:
				if poly.visible:
					poly.visible = false
				continue
			var q: Dictionary = quads[i]
			var pts: Array = q["p"]
			var arr := PackedVector2Array()
			arr.resize(pts.size())
			for k in pts.size():
				arr[k] = pts[k]
			poly.polygon = arr
			poly.material = _sub_mat if bool(q["sub"]) else _norm_mat
			# 近似路径也要吃逐区颜色（官方管线里配色只是查表，不改覆盖/减算）
			var zc: Vector3 = q.get("color", Vector3(1, 1, 1))
			poly.color = Color(zc.x, zc.y, zc.z, float(q["alpha"]))
			if not poly.visible:
				poly.visible = true
	for m in [_bmat, _bdmat]:
		if m != null:
			m.set_shader_parameter("uTime", _clock)
			m.set_shader_parameter("uScreen", size)
	# Active 层被 place_block_overlay 提到了 game 层并 FULL_RECT 铺满整屏，所以它要额外知道
	# 画布矩形（uField）把整屏 UV 折回画布 UV；现场快照/位移噪声都按**画布**像素吸附
	# （官方 uScene 就是 chart_target，不是 backbuffer）。Disabled 层在 _host 内、本来就与
	# 画布同矩形 ⇒ uField 恒等，与改动前逐像素一致。
	if _bmat != null:
		# 现场 = 游玩画布离屏图。_setup_blocks() 跑在 _csv 建出来之前，所以这里每帧喂
		# （也是噪域能进特效链的前提：离屏里拿不到 hint_screen_texture）
		if _csv != null:
			_bmat.set_shader_parameter("uSceneTex", _csv.get_texture())
		if is_instance_valid(_bx_rt) and _bout.get_parent() == _bx_rt:
			# 在离屏里：本层矩形==画布矩形 ⇒ uField 恒等，吸附全按画布像素
			var cpx := _blk_field_px if _blk_field_px.x > 1.0 else size
			_bmat.set_shader_parameter("uScreen", cpx)
			_bmat.set_shader_parameter("uFieldScreen", cpx)
			_bmat.set_shader_parameter("uField", Vector4(0.0, 0.0, 1.0, 1.0))
		else:
			_bmat.set_shader_parameter("uScreen", _blk_screen_px if _blk_screen_px.x > 1.0 else size)
			_bmat.set_shader_parameter("uFieldScreen", _blk_field_px if _blk_field_px.x > 1.0 else size)
			_bmat.set_shader_parameter("uField", _blk_field)
		_sync_block_touch()

## 把噪域 Active 层提到"盖住 HUD"的那一层（官方实证：ActiveBlock 是 sprites/notes/HUD
## 之后的后处理）。game.gd 进舞台时调、QA 定帧脚本也调**同一个函数**——以前这段只写在
## game.gd 里，导致我截图（噪域在音符下）和他 F5 实机（噪域在最上）看到的不是同一个东西。
## 官方 BlockAudio::sync_with：cutoff=1500Hz，Q=1/√2，二阶最大平坦（12dB/oct）。
## Unity 的 resonance 不是可移植的 DSP 系数，参考实现自己也注明只取「无增益峰的二阶」，
## 所以这里 resonance 给 0.7071（Butterworth）而不是拉满。
func _sync_block_audio(delta: float) -> void:
	if not _blocks_on or _audio == null:
		return
	if _blk_lp == null:
		# 4.7 的 AudioStreamPlayer 没有 add_effect（个人效果只在 AudioStreamPlayerInternal
		# 那条链上暴露）——所以走总线：给乐曲单独开一条 bus，滤波器挂在 bus 上。
		# 官方也是"挂在曲源上、不碰命中音效总线"（block_audio.rs 头注）。
		# 响度标准化已经建了乐曲总线时，低通就直接挂在那条上——同一曲源只该有一条总线，
		# 再开一条会把 _audio.bus 从 capture 底下挪走，标准化测量当场失效。
		var BUS: StringName = _music_bus if _music_bus != &"" else &"PTN_BlockMusic"
		var bi := AudioServer.get_bus_index(BUS)
		if bi < 0:
			# 4.7 实名：add_bus / get_bus_count / add_bus_effect（没有 AudioServer.add_effect）
			bi = AudioServer.get_bus_count()
			AudioServer.add_bus(bi)
			AudioServer.set_bus_name(bi, BUS)
			AudioServer.set_bus_send(bi, "Master")
		# 复用总线上**已存在**的那只低通。以前这里是"发现有了就跳过 add_bus_effect"，
		# 却仍然把新建的对象记在自己成员里——那只新低通根本不在链路上，于是第一次
		# 暂停/重开之后整套「噪域压低音乐」静默失效（改 cutoff 改的是孤儿）。
		var got: AudioEffectLowPassFilter = null
		for i in AudioServer.get_bus_effect_count(bi):
			var e := AudioServer.get_bus_effect(bi, i) as AudioEffectLowPassFilter
			if e != null:
				got = e
				_blk_lp_ei = i
		if got == null:
			# 只数"有没有低通"，不能数"总线空不空"：开了响度标准化的总线上已经挂着 capture，
			# 按空判断会让低通静默不挂→噪域压低音效整个失效。
			got = AudioEffectLowPassFilter.new()
			AudioServer.add_bus_effect(bi, got)
			_blk_lp_ei = AudioServer.get_bus_effect_count(bi) - 1
		_blk_lp = got
		_blk_lp.db = 1            # 12 dB/oct（二阶）
		_blk_lp.resonance = 0.7071
		_blk_lp.cutoff_hz = _blk_lp_cur
		_blk_lp_i = bi
		_audio.bus = BUS
		# 没在压低的时候不该留滤波器在链路上（开局挂好就摘掉，等 want 翻 true 再启用）
		AudioServer.set_bus_effect_enabled(_blk_lp_i, _blk_lp_ei, _blk_lp_on)
	var want := _cp != null and _cp.blocked_touch_count() > 0
	if want == _blk_lp_on:
		return
	# 首次进入 0 秒（Unity 是先启用一个已存 1500Hz 的禁用滤波器），之后 0.1 秒
	var secs := 0.0 if (want and not _blk_lp_used) else 0.1
	_blk_lp_used = _blk_lp_used or want
	_blk_lp_on = want
	_blk_lp_secs = secs
	_blk_lp_from = _blk_lp_cur
	_blk_lp_t = 0.0
	if want:
		# 上一轮扫到全频时已经把 effect 摘了，进噪域第一件事是把它放回链路
		AudioServer.set_bus_effect_enabled(_blk_lp_i, _blk_lp_ei, true)

var _blk_lp_secs := 0.1
var _blk_lp_from := 22050.0
var _blk_lp_t := 0.0

func _step_block_audio(delta: float) -> void:
	if _blk_lp == null or _blk_lp_i < 0 or _blk_lp_ei < 0:
		return
	var full := _blk_full_hz()
	var target := 1500.0 if _blk_lp_on else full
	if _blk_lp_secs <= 0.0:
		_blk_lp_cur = target
	elif _blk_lp_t < _blk_lp_secs:
		_blk_lp_t += delta
		var k := clampf(_blk_lp_t / _blk_lp_secs, 0.0, 1.0)
		# 频率按对数插值才听得出匀速扫频（线性插值会在一开始就“糊”下去）
		_blk_lp_cur = exp(log(_blk_lp_from) + (log(target) - log(_blk_lp_from)) * k)
	else:
		_blk_lp_cur = target
	_blk_lp.cutoff_hz = _blk_lp_cur
	# 回到全频 = 把 effect 整个摘出链路。cutoff 开到天顶也不是"真旁路"，还会撞上
	# 奈奎斯特退化（见 _blk_full_hz：44100 混音率的手机上 22050 正是那个点），
	# 松手后必须一点滤波都不留，否则表现就是"手指离开噪域声音整个没了"。
	if not _blk_lp_on and _blk_lp_cur >= full - 1.0:
		AudioServer.set_bus_effect_enabled(_blk_lp_i, _blk_lp_ei, false)

## 暂停/重开时官方会 reset 再 sync(false)：0.1 秒扫回全频
func suspend_block_audio() -> void:
	_blk_lp_used = false
	_blk_lp_on = false
	# 这里**不能**再把 _blk_lp 置 null 去"下次重挂"：低通挂在总线上、总线是全局单例，
	# 置 null 只会让下一轮 new() 出一只不在链路上的孤儿（真回归见 _sync_block_audio）。
	# 对象留着，链路开关由 _step_block_audio 与下一帧的 want 对齐负责。
	_blk_lp_from = _blk_lp_cur
	_blk_lp_secs = 0.1
	_blk_lp_t = 0.0

var _blk_host: Node = null           # place_block_overlay 给的宿主（game 根）与层位
var _blk_host_z := 52

func place_block_overlay(host: Node, z: int = 52) -> bool:
	if not _blocks_on or _bout == null:
		return false
	_blk_host = host
	_blk_host_z = z
	for i in range(1, _blayer_nodes.size()):
		var L: Dictionary = _blayer_nodes[i]
		var dsp: TextureRect = L.get("skin_disp")
		if dsp != null and is_instance_valid(dsp) and dsp.visible:
			if dsp.get_parent() != host:
				dsp.reparent(host, false)
			dsp.z_index = z + i
			if host is Control:
				dsp.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			else:
				dsp.position = Vector2.ZERO
				dsp.size = (host as Viewport).get_visible_rect().size
		var act: ColorRect = L["act"]
		if act == null or not is_instance_valid(act):
			continue
		if act.get_parent() != host:
			act.reparent(host, false)
		act.z_index = z + i
		if host is Control:
			act.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		else:
			act.position = Vector2.ZERO
			act.size = (host as Viewport).get_visible_rect().size
	# 被特效链认领时提的是**链输出回贴层**，不是 _bout（_bout 那时在离屏里）
	if _blk_chained and is_instance_valid(_blk_out):
		if _blk_out.get_parent() != host:
			_blk_out.reparent(host, false)
		_blk_out.z_index = z
		_blk_place()
		return true
	# 只提 Active 这一层。预警层**故意留在 _host 里（z5，判定线之前）**：用户 2026-10-07
	# 对着 warn_only6.png 裁定"修之前那张是对的"——预警就该是被链上内容压住的一层红纱，
	# 不是盖住 HUD 的实心红带（我上一轮把它一起提到 game 层，方向反了，已回退）。
	if _bout.get_parent() != host:
		_bout.reparent(host, false)  # add_child 对已有父节点会静默失败（QA 实证）
	_bout.z_index = z
	if host is Control:
		_bout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:  # SceneTree 直开的 QA 路径：host 是 Window，Control 锚点对它不生效，显式铺满
		_bout.position = Vector2.ZERO
		# get_viewport_rect() 是 CanvasItem 的方法，Window/Viewport 上不存在（4.7 实名 get_visible_rect）
		_bout.size = (host as Viewport).get_visible_rect().size
	return true

## 链输出贴回**画布矩形**（_blk_field = 画布在宿主 UV 里的位置）：宽屏时噪域仍旧只属于
## 中间那块 ≤16:9 的画布，两侧曲绘带不被覆盖。
func _blk_place() -> void:
	if not is_instance_valid(_blk_out) or not is_instance_valid(_blk_out.get_parent()):
		return
	var hs := Vector2.ZERO
	var p := _blk_out.get_parent()
	if p is Control:
		hs = (p as Control).size
	elif p is Viewport:
		hs = (p as Viewport).get_visible_rect().size
	if hs.x <= 1.0 or hs.y <= 1.0:
		return
	_blk_out.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_blk_out.position = Vector2(_blk_field.x * hs.x, _blk_field.y * hs.y)
	_blk_out.size = Vector2(_blk_field.z * hs.x, _blk_field.w * hs.y)

## 噪域特效链：effects 的 targetRange 命中 BLOCK_DEPTH ⇒ Active 层进离屏、被这条链扫，
## 链完再预乘回贴到它原来的层位。没被认领时一行都不做（_bout 直贴，与改动前逐像素一致）。
func _update_block_chain(nong: Array) -> void:
	if not _blocks_on or _bout == null or not is_instance_valid(_bx_rt):
		_blk_chained = false
		return
	if _blayer_nodes.size() > 1:
		# 多层噪域暂不与 Active 层特效链叠加（链只认领 _bout，会把 layer0 单独拖进离屏）
		_blk_chained = false
		return
	var chain: Array = []
	for i in nong.size():
		var e: Dictionary = nong[i]
		if float(e["rmin"]) <= BLOCK_DEPTH and BLOCK_DEPTH < float(e["rmax"]):
			chain.append(i)
	chain.sort_custom(_chain_inner_first.bind(nong))
	_blk_chained = not chain.is_empty()
	if not _blk_chained:
		for j in _bx_sv.size():
			(_bx_quads[j] as ColorRect).material = null
		_blk_out.visible = false
		_bx_rt.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_bx_rt_age = 0
		if _bout.get_parent() == _bx_rt:
			# 链结束：把 _bout 交还直贴路径（place_block_overlay 会重设 FULL_RECT 锚点）
			place_block_overlay(_blk_host, _blk_host_z)
		return
	_bx_rt.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var moved := _bout.get_parent() != _bx_rt
	if moved:
		_bout.reparent(_bx_rt, false)
		_bx_rt_age = 0  # 刚进离屏：这一帧 RT 还是空的，扣两帧再贴（防一闪而过的空场）
	_bout.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_bout.position = Vector2.ZERO
	_bout.size = size
	_sv_set(_bx_rt, size)
	var tex: Texture2D = _bx_rt.get_texture()
	var fresh := _bx_rt_age < 2
	if _bx_rt_age < 8:
		_bx_rt_age += 1
	_bx_ensure(chain.size())
	var slot := 0
	for ci in chain:
		var e2: Dictionary = nong[int(ci)]
		if int(_bx_age[slot]) == 0:
			fresh = true  # 池位首帧 RT 未初始化 ⇒ 本帧不贴（与 unit/gx 同一套防闪现）
		_bx_age[slot] = int(_bx_age[slot]) + 1
		tex = _fx_pass(2, slot, e2, tex, size)
		slot += 1
	for j in range(slot, _bx_sv.size()):
		(_bx_quads[j] as ColorRect).material = null
	_blk_out.texture = _blk_tail(tex, _bx_rt.get_texture())
	_blk_out.visible = not fresh
	if fresh:
		# 与 unit/gx 同一套：首帧被扣住的回贴要在暂停/冻结态也续跑预热，否则定帧截图
		# 里这条链永远只跑了 1 帧（_qashot 手动调一次 _update_effects 就完事）
		_fx_pending = true
	# 回贴层要和 _bout 抢同一个层位（game 根 z=52：HUD 之上、相机滤镜之下），
	# 所以走同一个提层入口；QA 直开舞台时没有 host，退化成贴在 _fx_post 全屏。
	if _blk_host != null and is_instance_valid(_blk_host):
		place_block_overlay(_blk_host, _blk_host_z)
	else:
		_blk_out.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func set_render_scale(rs: float) -> void:
	render_scale = rs
	if _csv != null:
		_sv_set(_csv, size)
	if _lsv != null:
		_sv_set(_lsv, size)
	if _bsv != null:
		_sv_set(_bsv, size)
	for u in _units:
		_sv_set(u["sv"], size)
	for sv in _fx_sv:
		_sv_set(sv, size)
	for sv in _gx_sv:
		_sv_set(sv, size)

## 定帧诊断：冻结时钟到指定秒并重绘（--qashot 用，与 player 截图同时刻对拍）
func freeze_at(sec: float) -> void:
	_paused = true
	_clock = sec
	if _audio != null:
		_audio.stream_paused = true
	if _cp:
		_cp.set_now(sec)
		_cp.queue_redraw()
	_update_blocks()  # 冻结帧也要有噪域（--qashot/rot_shot 取证用）

## 从 freeze_at 的定帧状态放开续播。音频这里必须走"仍在播但被暂停"的分支：
## 4.7 里 stream_paused=true 之后 is_playing() 依然返回 true，只按 is_playing() 判会
## 从旧播放位置继续，而不是接着当前时钟走。
func resume_live() -> void:
	_paused = false
	# 显式续播 ⇒ 不再等背景虚化收尾去 play（否则这里起了音频、烘焙完成时又 play 一次=从头开始）
	_audio_start_pending = false
	if _audio == null:
		return
	# 光把 stream_paused 置回 false 不够：_process 里 _clock 会被
	# get_playback_position() 纠偏覆盖回冻结那一刻，等于时钟不动。seek 到当前时钟
	# 再续播，音频和时钟才对得上。
	_audio.stream_paused = false
	if _audio.is_playing():
		_audio.seek(_clock)
	else:
		_audio.play(_clock)
		_audio_started = true
	_pos_watch_reset(_clock)


## ── 渲染录制（离线逐帧出片，驱动方见 render_record.gd）────────────────────
## 录制时谱面时钟**只**按外部给的步长走：一帧录制帧 = 一次 _process = 一步。
## 音频钟/软锁相整条不参与（内容时间与墙钟不成比例，实时混音对不上帧号——
## 成片里的声音由编码器直接读谱包音频文件），其余管线（判定/特效/噪域/视频层/
## HUD）与实跑走的是同一个 _process，所以录出来的就是玩家看到的那一帧。
var record_mode := false
var _rec_dt := 1.0 / 60.0      # 本步的内容时长（= 1/输出帧率）
var _rec_pending := false      # 录制器已排好下一步，等这一拍 _process 消费
var rec_hits: Array = []      # 录制期间攒下的打击音 [内容秒, 判定类型, 谱包音名]

## 排一步：录制器每帧调用一次，然后等 frame_post_draw 抓图。
## 不调这一步时钟就不动（宁可画面停住，也不许丢帧或重复帧）。
func record_step(dt: float) -> void:
	_rec_dt = dt
	_rec_pending = true

## 成片时长 = **音乐的**长度（用户 2026-10-23："渲染的时间改为音乐开头与音乐结束"）。
## 以前用的是谱面时长（最后一条事件），带 offset 的谱会少掉/多出一截音乐。
func record_duration() -> float:
	if _song_stream != null:
		var l := _song_stream.get_length()
		if l > 0.05:
			return l
	return _cp.get_duration() if _cp != null else 0.0

## 打击音的采样源：res:// 的音频在导出包里没有源文件（只有 .import / 导入产物），
## 原生解码器开不了。内置三支打击音旁边各放一份 48k 立体声 f32 旁车（assets 里原样导出），
## 录制时用它；皮肤包/谱包自带的是真实文件，直接交给原生解码。
func hit_sound_pcm(type_: int, sname: String) -> String:
	var p := hit_sound_path(type_, sname)
	if p == "":
		return ""
	if not p.begins_with("res://"):
		return p
	var side := p.get_basename() + ".f32"
	return side if FileAccess.file_exists(side) else ""

## 整局的打击事件（音乐时间轴）：autoplay 下每条非 fake 音符都在起点响一次，hold 也只在头响。
## 由 player 直接给出（与它内部的判定代码同一份偏移），不靠边渲边记——原生编码器要在
## 开录之前就把音轨编好，muxer 的轨道必须在写第一帧视频之前挂上。
func sound_events() -> Array:
	return _cp.get_sound_events() if _cp != null else []

## 背景虚化还在异步烘焙时不能开机录：前几秒会是没糊的底（与实况不同的一帧）
func record_warm() -> bool:
	return not _bg_blur_pending and not _baking

## 进录制态：自动游玩 + 停音频 + 锁输入 + 收掉调试层（调试层是舞台自己画的，
## 不锁就会把 F12 序号层录进片子里）
func record_begin(fps: float) -> void:
	record_mode = true
	_rec_dt = 1.0 / maxf(fps, 1.0)
	_pos_watch_reset(0.0)
	_rec_pending = false
	rec_hits = []
	_rec_step_log = 0
	# 第 0 帧必须正好是"音乐第 0 秒"：建谱到开录之间 _process 可能已经按音频钟走过几帧，
	# 不归零的话整条片子的音画会一起偏那几十毫秒
	_clock = 0.0
	_clock_last = 0.0
	_fps_reset()
	if _cp != null:
		_cp.reset_play_state()
		_cp.set_autoplay(true)
	_paused = false
	_cd_busy = false
	if is_instance_valid(_cd_lbl):
		_cd_lbl.visible = false
	_pm_show(false)
	if _audio != null:
		_audio.stop()
	_audio_started = false
	_audio_start_pending = false
	if is_instance_valid(_dbg):
		_dbg.visible = false
	if is_instance_valid(_dbg_lbl):
		_dbg_lbl.visible = false

var _rec_step_log := 0   # 录制步数诊断（每 60 步打一行）

## 补渲用：时钟与判定状态一起归零，然后从 0 精确推帧到目标段首。
## （子进程偶尔会挂掉，那一段就由主进程按这个入口重新渲一遍，成片不留洞）
func record_restart() -> void:
	_clock = 0.0
	_clock_last = 0.0
	_pos_watch_reset(0.0)
	_fps_reset()
	_rec_pending = false
	_rec_step_log = 0
	rec_hits = []
	if _cp != null:
		_cp.reset_play_state()
	if _audio != null:
		_audio.stop()
	_audio_started = false
	_audio_start_pending = false
	_paused = false

func record_end() -> void:
	record_mode = false
	_rec_pending = false


## 音频头软锁相 + "输出设备被系统作废"检测。返回 0=无事 1=把音频 seek 到谱面 2=重新落拍。
## 拔耳机/切默认输出会让 WASAPI 关掉输出设备（audio_driver_wasapi.cpp:778 GetBufferSize
## error + :849 output_device invalidated），此后 get_playback_position() 钉住不动：旧代码每帧
## 把 err 往 0 收，谱面时钟就被一路拖停，表现就是"拔掉耳机后再选一首打开，卡住在某一时间点"。
## pos 反过来乱涨（混音线程停了、time_since_last_mix 一直累加）同样判为不可信。
var _lat_cache_ms := 0.0     # AudioServer.get_output_latency() 的缓存（ms）
var _lat_cache_t := 0.0      # 到 0 就重取一次输出延迟
var _qa_audio_probe := true      # false=每帧不再问音频驱动（game.gd 的部件归因用）

## QA 专用开关：关掉音频钟的每帧驱动查询，只留帧时推进。
## 为什么值得单独一档：get_playback_position / get_time_since_last_mix / get_output_latency
## 是每帧三次打进音频驱动的调用，而本项目已经实测过"手机 AAudio 一次 play() 约 1ms"（见下面
## 打击音那段注释），所以"查询本身贵不贵"必须能和"播放贵不贵"分开量。pos=0 会走上面
## "音频还没起来"那条纯帧时分支，不会触发 seek/revive。
var _qa_no_set_now := false   # false 前每帧都调原生 set_now（部件归因用）

## QA 专用：跳过每帧的 `_cp.set_now(_clock)`，也就是让原生管线这一帧什么都不推进。
## 为什么这一档才是关键：舞台不可见、画布减半、音频停干净之后仍然只有 107~109，
## 说明那一笔固定开销不在"画"也不在"听"上；而 set_now 是在 _process 里调的，
## **藏 visible 停不掉它**，`停 player 的 _process` 也停不掉它（它不是靠节点自己的
## _process 跑的）。原生每帧做的音符窗口/四顶点重建就是最后一个还没被排除的嫌疑人。
func qa_set_now(p_on: bool) -> void:
	_qa_no_set_now = not p_on

func qa_audio_clock(p_on: bool) -> void:
	_qa_audio_probe = p_on
	_pos_prev = 0.0
	_pos_stall = 0.0

func _lock_clock(pos: float, delta: float) -> int:
	var adv: float = pos - _pos_prev
	_pos_prev = pos
	var live: bool = _audio != null and _audio.is_playing() and not _audio.stream_paused
	if not live:
		# 音频没在跑（被 stop 掉 / 乐曲已结束，正常收尾走 _on_song_finished）：
		# 没有可信参考就只按帧时走，绝不钉死在最后一个 pos 上。
		_pos_stall = 0.0
		_clock += delta
		return 0
	_pos_stall = 0.0 if adv > 0.0005 else _pos_stall + delta
	var err: float = pos - _clock
	if _pos_stall > AUDIO_STALL_SEC or err > 2.0:
		_clock += delta            # 音频头不可信：只按帧时走，绝不跟着钉住的 pos 回拖
		_revive_wait += delta
		if _revive_wait >= 1.0:    # 每秒试一次；设备回来后这条会把拍重新落准
			_revive_wait = 0.0
			return 2
		return 0
	if err > 0.25:
		_clock = pos               # 音频超前（seek / 长卡顿）：谱面跟过去
	elif err < -0.25:
		return 1                   # 音频落后：把音频拉到谱面，谱面钟恒单调不减（旧代码在这里
									 # 会把 _clock 拨回去、再被上面的单调门吞掉 = 永久冻住）
	else:
		_clock += delta + err * clampf(delta * 6.0, 0.0, 0.3)
	return 0

func _seek_audio_to_clock() -> void:
	if _audio == null or _audio.stream == null or not _audio_started:
		return
	_audio.seek(maxf(_clock, 0.0))
	_pos_stall = 0.0
	print("QA-AUDIO 音频落后谱面 → seek 到谱面时钟 t=%.2f" % _clock)

func _revive_audio() -> void:
	if _audio == null or _audio.stream == null:
		return
	print("QA-AUDIO 音频头停滞 %.2fs（输出设备疑似被系统作废）→ 按谱面时钟重新落拍 t=%.2f" % [
		_pos_stall, _clock])
	_audio.stream_paused = false
	_audio.stop()
	_audio.play(maxf(_clock, 0.0))
	_pos_watch_reset(_clock)
	_audio_started = true

## 换曲/重开/续播/录制复位都要重置这条滑动窗口，否则 seek 造成的 pos 回跳会被
## 误判成"音频头停滞"，白重落一次拍（听感就是突然跳回半秒）。
func _pos_watch_reset(pos: float) -> void:
	_pos_prev = pos
	_pos_stall = 0.0
	_revive_wait = 0.0

func _process(delta: float) -> void:
	_perf_tick(delta)  # 帧率/落核诊断：暂停时也要继续采（面板就是暂停时才露出来）
	if not record_mode:
		_loud_tick()   # 响度标准化：只在开局前 5 秒采，采完自己关掉
	if _audio_start_pending and Time.get_ticks_msec() > _audio_start_deadline:
		# 兜底：烘焙被驱动/显存问题挂在某次 await 上，绝不能让"等虚化"把谱面永久锁死
		push_warning("QA-BLUR 背景虚化 3s 未完成，强行开演")
		_bg_blur_done()
	if delta > 0.8:
		# 用户报"画面卡住但声音在放"：主循环若只是长卡顿（非死锁），这里留证据
		# （压力谱 1.pez：定位是 CPU 侧还是 GPU 提交/特效堆积）
		var fxn := _cp.debug_fx_count() if _cp != null else -1
		var hn: int = _hits_last_frame
		print("QA-FREEZE delta=%.2fs clock=%.2f paused=%s fx=%d hits=%d" % [
			delta, _clock, _paused, fxn, hn])
	if _cp == null:
		return
	if _paused:
		if _fx_pending:
			_update_effects()  # 新视口预热：冻结/暂停态也要把链续跑满一帧再贴回
		if not _vids.is_empty() or not _vid_xcode.is_empty():
			_sync_videos()  # 冻结/暂停：视频对齐到当前时刻（seek/pause），转码队列也要推进
		return
	# 帧率统计不在这里采：取样点是 _on_post_draw（呈现节拍），见那里的注释
	# 音频钟三件套（Godot 官方 "Synchronizing with audio"）：
	#   get_playback_position() = 已混进输出的位置，不是喇叭正在发的位置；
	#   + get_time_since_last_mix() 补上这一帧之后混进去的那段；
	#   − get_output_latency() 减掉设备输出缓冲（Android AAudio/OpenSL 常见 30~120ms）。
	# 缺第三项时谱面钟比耳朵听到的声音超前一个输出延迟=音符先到线、声音后到耳，
	# 玩家按"听到的点"下手就系统性判晚（P 窗只有 80ms，手机上一超窗就全是 Good/Bad/Miss）。
	# 桌面 WASAPI 这段近乎 0，所以只在 APK 上暴露。
	# ⚠ get_output_latency() 不该每帧问：perfY 的 A/B/A/B 显示"跳过这三件套查询"值 +4.5fps
	# （≈0.42ms/帧），而三项里真正每帧变的只有 get_playback_position()。输出延迟在设备不变时
	# 是常数，Android 上这次调用要走到音频驱动 ⇒ 每 0.5s 重取一次就够了。
	if _lat_cache_t <= 0.0:
		_lat_cache_ms = AudioServer.get_output_latency()
		_lat_cache_t = 0.5
	else:
		_lat_cache_t -= delta

	var pos := _audio.get_playback_position() + AudioServer.get_time_since_last_mix() \
		- _lat_cache_ms \
		if (_audio_started and _audio != null and _qa_audio_probe) else 0.0
	# 音频钟**软锁相**，不再每帧硬覆盖。旧代码是 `if pos > 0.05: _clock = pos`，可 pos
	# 只能按混音缓冲的粒度前进，于是高帧率下变成"连续几帧时钟一动不动、然后一次跳上去"。
	# --qaclock 在 PC 120Hz 实测：5.5% 的帧推进不足帧时 30%、推进偏差 p95=7.05ms
	# （≈每 18 帧抖一整帧）——这就是"明明 120 帧却卡卡的"。现在改成：帧时自己推进 +
	# 每帧按误差的一小部分修正（时间常数≈1/6 秒），误差 >0.25s（seek/长卡顿）才硬对齐。
	if record_mode:
		# 录制态：时钟只走录制器排好的那一步。没排步就原地不动（宁可画面停住，
		# 也不许丢帧或重复帧——成片帧号 = 时间轴，一错就全错）。
		if _rec_pending:
			_clock += _rec_dt
			_rec_pending = false
			_rec_step_log += 1
		_clock_last = _clock
	elif _audio_start_pending:
		# 等背景虚化烘焙完成：一拍都不走（否则 _audio_started=false 会让下面的分支
		# 按帧时把谱面推起来，等于"音乐没响但谱面已经在滚"）。兜底见 _process 开头。
		_clock_last = _clock
	elif pos <= 0.05:
		_clock += delta  # 音频还没起来（前 50ms）：只能靠帧时
		_pos_prev = pos
		_pos_stall = 0.0
	else:
		var act := _lock_clock(pos, delta)
		if act == 1:
			_seek_audio_to_clock()
		elif act == 2:
			_revive_audio()
	if _clock < _clock_last - delta * 1.5:
		# 只挡真正的倒退（seek 级）：time 驱动 random(trunc(time)) 的故障类滤镜会被回跳
		# 触发一帧满屏马赛克，player 时钟单调不减。软锁相的亚帧修正要放行。
		_clock = _clock_last
	else:
		_clock_last = _clock
	if not _qa_no_set_now:
		_cp.set_now(_clock)
	_sync_block_audio(delta)
	_step_block_audio(delta)
	_hits_last_frame = _cp.hit_count()
	if _cp.hit_count() > 0:  # 无命中时不分配 take_hits 的 Array
		# 压力谱防御（1.pez 2400note/s 实测）：AudioStreamPlayer.play() 单次
		# ~0.5ms，一帧 2400 连发 = 1.5s 卡顿（gd_us 证据）。每帧封顶声，
		# 多余直接丢（take_hits 已排空队列，不积压）；常规谱远低于封顶零差异。
		# 手机音频驱动更慢（AAudio 每次 play ~1ms）→ 移动端折半。
		var nh := 0
		for h in _cp.take_hits():
			if nh >= _hit_cap:
				break
			nh += 1
			_play_hit(int(h[0]), String(h[1]))
	_cp.queue_redraw()
	_update_blocks()
	_update_effects()
	if not _vids.is_empty() or not _vid_xcode.is_empty():
		_sync_videos()
	_apply_attachments()
	_update_hud()
	# 分区拆细（perfR 实测"前置"能占到 1.7ms，但那一栏里混了时钟+set_now+噪域步进+打击音，
	# 分不清该怪谁）。现在：前置=时钟+set_now+block 步进，打击音与噪域各自单列。

# HUD 缓存：值没变就不重建字符串/不触发布局（低端机每帧省 GC 与重排）
var _hud_combo := -1
var _hud_auto := false
var _hud_score := -1
var _hud_acc := ""
var _hud_barw := -1.0
var _hud_prog := 0.0   # 进度条只滑动不缩放，摆位时要用同一个值

## extra.json 后期特效 = player 相机级滤镜链（ShaderPipeline.ts：每个 shader 依次消费上一层输出，
## 作用于整块画面含 HUD）。实现：每层一个离屏 SubViewport（池按需增长，UPDATE_ALWAYS——
## 4.7 无 render_locally，靠 ViewportTexture 依赖+树序保证同帧链序），最终 TextureRect
## 盖在 HUD(z50/55) 之上。特效 shader 统一采样 fx_src uniform（离屏里拿不到主屏 hint_screen_texture）。
func _setup_effects() -> void:
	if _fx_root != null:
		return
	# 更新序=树序（Godot 嵌入式 SubViewport）：单元幽灵层 → 非 global 链池 → _csv(gout/_lout)
	# → global 链池 → _fx_out。旧结构里池/单元挂在 _csv 之后 → gout 恒显示 1~2 帧前的
	# 旧链内容（游玩时"突然冒出上一帧"，冻结截图看不出来）。
	_fx_units = Control.new()
	_fx_units.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fx_units)
	_fx_root = Control.new()
	_fx_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fx_root)
	_fx_post = Control.new()
	_fx_post.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx_post.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)  # _fx_out 锚它全屏，容器必须有尺寸
	_fx_post.z_index = 60  # player 相机滤镜盖全画面：HUD 也被特效作用（用户实证截图）
	add_child(_fx_post)
	move_child(_fx_units, 0)
	move_child(_fx_root, 1)
	_fx_out = TextureRect.new()
	_fx_out.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx_out.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fx_out.stretch_mode = TextureRect.STRETCH_SCALE
	var fmat := CanvasItemMaterial.new()
	fmat.set("blend_mode", 4)  # 链 RT 是预乘数据，终合成用 Premultiplied Alpha
	_fx_out.material = fmat
	_fx_out.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fx_out.visible = false
	_fx_post.add_child(_fx_out)
	_bx_setup()

## 噪域特效链的离屏目标 + 回贴层。都挂在 _fx_post 里（树序在 _csv 之后 ⇒ 现场不晚一帧），
## 回贴层 _blk_out 则被 place_block_overlay 提到 game 层，和 _bout 抢同一个层位。
func _bx_setup() -> void:
	_bx_rt = SubViewport.new()
	_bx_rt.transparent_bg = true
	_bx_rt.size_2d_override_stretch = false
	_bx_rt.render_target_update_mode = SubViewport.UPDATE_DISABLED  # 没被认领就不渲染
	_fx_post.add_child(_bx_rt)
	_blk_out = TextureRect.new()
	_blk_out.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blk_out.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_blk_out.stretch_mode = TextureRect.STRETCH_SCALE
	var bm := CanvasItemMaterial.new()
	bm.set("blend_mode", 4)  # 预乘回贴：链 RT 是预乘数据（与 _fx_out 同一套）
	_blk_out.material = bm
	_blk_out.visible = false
	_fx_post.add_child(_blk_out)
	# 回贴层排在链池之后、_fx_out 之前（_fx_out 采 global 链，必须最后更新）
	_fx_post.move_child(_blk_out, _fx_out.get_index())

func _bx_ensure(n: int) -> void:
	while _bx_sv.size() < n:
		var sv := _fx_make_pool_sv()
		_fx_post.add_child(sv)
		if _blk_out.get_parent() == _fx_post:
			_fx_post.move_child(_blk_out, _fx_out.get_index())  # 回贴层紧跟链池、仍在 _fx_out 前
		_bx_sv.append(sv)
		_bx_quads.append(sv.get_child(0))
		_bx_age.append(0)
	if is_instance_valid(_blk_tail_sv) and _blk_tail_sv.get_parent() == _fx_post:
		# 新池位插在尾层前面 ⇒ 尾层要重新排到最后，否则它读到的是上一帧的链输出
		_fx_post.move_child(_blk_tail_sv, _fx_post.get_child_count() - 1)

## 链尾复位：stock 滤镜会把整屏 alpha 拉成 1（它们的输入按整块画面设计），这里用噪域
## 自己的 alpha 复位一次，官方 Active 的"压住现场"语义才不被破坏。见 block_chain_alpha.gdshader。
func _blk_tail(src: Texture2D, mask: Texture2D) -> Texture2D:
	if _blk_tail_sv == null:
		_blk_tail_sv = _fx_make_pool_sv()
		_fx_post.add_child(_blk_tail_sv)
	if _blk_tail_mat == null:
		_blk_tail_mat = ShaderMaterial.new()
		_blk_tail_mat.shader = load("res://shaders/block_chain_alpha.gdshader")
	_blk_tail_mat.set_shader_parameter("uSrc", src)
	_blk_tail_mat.set_shader_parameter("uMask", mask)
	_sv_set(_blk_tail_sv, size)
	var q: ColorRect = _blk_tail_sv.get_child(0)
	q.size = size
	q.material = _blk_tail_mat
	return _blk_tail_sv.get_texture()

func _fx_ensure(n: int) -> void:
	while _fx_sv.size() < n:
		var sv := _fx_make_pool_sv()
		_fx_root.add_child(sv)
		_fx_sv.append(sv)
		_fx_quads.append(sv.get_child(0))
		_fx_age.append(0)

func _gx_ensure(n: int) -> void:
	while _gx_sv.size() < n:
		var sv := _fx_make_pool_sv()
		_fx_post.add_child(sv)
		_fx_post.move_child(_fx_out, -1)  # 叠加层永远排最后：先更新池再采样
		_gx_sv.append(sv)
		_gx_quads.append(sv.get_child(0))
		_gx_age.append(0)

func _fx_make_pool_sv() -> SubViewport:
	var sv := SubViewport.new()
	sv.size = Vector2i(1350, 900)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.transparent_bg = true  # 清零到 (0,0,0,0)：MIX 落笔即存成预乘数据，
							  # 最终 _lout/_fx_out 用 Premultiplied Alpha 一次性正确合成
	var q := ColorRect.new()
	q.mouse_filter = Control.MOUSE_FILTER_IGNORE
	q.color = Color(0, 0, 0, 0)  # = gl_FragColor 初值（ANGLE 实测零初始化）：
								  # rgb-only 着色器由转译器补 alpha 继承行
	sv.add_child(q)
	return sv

func _update_effects() -> void:
	if _fx_root == null:
		return
	if not _cp.has_effects():
		# 这份谱面一个特效事件都没有：连"问一帧有哪些激活"都省掉（native 侧是线性扫两张表 +
		# 每个激活项造两个 Dictionary）。链池本来就是空的，跳过不影响任何状态。
		return
	var acts: Array = _cp.get_effects(_clock)
	var sz := size
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	_fx_pending = false
	var glo: Array = []
	var nong: Array = []
	for e in acts:
		if bool(e.get("global", false)):
			glo.append(e)
		else:
			nong.append(e)
	# —— 逐深度桶特效链（player ShaderNode 嵌套语义，ShaderPipeline.ts:305 + Game.ts:928）——
	# player：每个节点在首次激活时收集范围内的对象，后激活者会嵌套进先激活者内部
	# → 同一桶上后激活特效的滤镜先处理（内层→外层）。等价模型：
	# 链(桶) = 所有 range 含该桶的特效按 (激活时刻, 数组序) 降序；链相同的桶共用一个渲染单元。
	# （旧"范围组首认领先分区"是错的：Designant 尾段 #25 bloom 458 拍激活晚于 #26/#27 455 拍，
	# player 里音符/HUD 走 bloom→cpow→radialBlur 全链，旧模型只给 bloom，径向辉光丢了 →"压曝光"）
	var groups := {}
	if not nong.is_empty():
		# 桶清单只在有非 global 特效时才被消费——bad apple 3.4 万线逐帧重建
		# 3.4 万个桶字典实测 33ms/帧（无特效谱也照跑）。空链直接跳过整段。
		var buckets: Array = [{"d": 0.0, "kind": 2, "nm": ""}]  # kind: 0=gameplay 1=hud 2=bg
		for d in _line_depths:
			buckets.append({"d": d, "kind": 0, "nm": ""})
		for d in _note_depths:
			buckets.append({"d": d, "kind": 0, "nm": ""})
		for d in _fx_depths:
			buckets.append({"d": d, "kind": 0, "nm": ""})
		for nm in HUD_Z:
			buckets.append({"d": float(HUD_Z[nm]), "kind": 1, "nm": nm})
		for bk in buckets:
			var chain: Array = []
			for i in nong.size():
				var e: Dictionary = nong[i]
				if float(e["rmin"]) <= float(bk["d"]) and float(bk["d"]) < float(e["rmax"]):
					chain.append(i)
			if chain.is_empty():
				continue
			chain.sort_custom(_chain_inner_first.bind(nong))
			var sig := ""
			for ci in chain:
				sig += str(ci) + ","
			var g = groups.get(sig)
			if g == null:
				g = {"sig": sig, "chain": chain, "play": [], "hud": [], "bg": false, "mn": 99.0}
				groups[sig] = g
			if int(bk["kind"]) == 2:
				g["bg"] = true
			elif int(bk["kind"]) == 1:
				g["hud"].append(String(bk["nm"]))
			else:
				g["play"].append(float(bk["d"]))
			g["mn"] = minf(float(g["mn"]), float(bk["d"]))
	var live: Array = []
	var cnt_nong := 0
	for sig2 in groups:
		var gg: Dictionary = groups[sig2]
		live.append(gg)
		cnt_nong += gg["chain"].size()
	# —— 单元分配先行（新鲜度决定本帧认领门控，必须在 skip 计算之前定）——
	# 注意：单元字典每帧都会改内容（age++），绝不能当 Dictionary 键（内容哈希会漂移 →
	# used.has(u) 失配 → 在用的单元被当空闲隐藏）。用帧令牌标记占用。
	_use_seq += 1
	for g in live:
		var u: Dictionary = {}
		for cand in _units:
			if int(cand["seq"]) == _use_seq:
				continue
			if str(cand["k"]) == str(g["sig"]):  # String(null) 构造器会炸，str() 安全
				u = cand
				break
		if u.is_empty():
			for cand in _units:
				if int(cand["seq"]) != _use_seq:
					u = cand
					break
		if u.is_empty():
			u = _make_unit()
		elif str(u["k"]) != str(g["sig"]):
			u["age"] = 0  # 复用单元换链：RT 里还是旧链内容，按新渲染防旧帧闪现（用户报"突然冒出上一帧"）
		u["k"] = g["sig"]
		u["busy"] = true
		u["seq"] = _use_seq
		g["u"] = u
		if _qa_fx_dump:
			# QA 诊断快照：只抄值，绝不能存 g 本身（g["u"]=u 已经存在，互相引用=每帧泄漏一个环）
			u["dbg"] = {"chain": g["chain"], "play": g["play"], "hud": g["hud"],
					"bg": g["bg"], "mn": g["mn"]}
	# 只有 gout 本帧真的会显示（age≥1=RT 已过帧）的组才从主实例手里认领桶/HUD/背景；
	# 否则主实例照常画（skip 会让 fresh 帧出现 1 帧空洞）。ready 在链循环里还可能被
	# "新池位"下调，故 skip/迁移都推迟到链循环之后统一算。
	for g3 in live:
		g3["ready"] = int((g3["u"] as Dictionary)["age"]) >= 1
	_cp.set_skip_depths([])  # 占位；真实值在链循环后按 ready 组重算
	_fx_ensure(cnt_nong)
	_gx_ensure(glo.size())
	# —— 逐单元：keep 桶 + 幽灵同步 + 链 + 回贴 ——
	var slot := 0
	for g in live:
		var u: Dictionary = g["u"]
		u["age"] = int(u["age"]) + 1
		(u["cp"] as ChartPlayer).set_keep_depths(g["play"])
		(u["cp"] as ChartPlayer).set_now(_clock)  # 只触发重绘（状态实时读主实例）
		var prev: Texture2D = (u["sv"] as SubViewport).get_texture()
		u["slot0"] = slot  # QA：这条链占的池位区间（诊断逐层落盘要用）
		for ci2 in g["chain"]:
			var e2: Dictionary = nong[int(ci2)]
			if int(_fx_age[slot]) == 0:
				g["ready"] = false  # 池位首帧 RT 未初始化 → 本帧该组不认领
			_fx_age[slot] = int(_fx_age[slot]) + 1
			prev = _fx_pass(0, slot, e2, prev, sz)
			slot += 1
		var gout: TextureRect = u["gout"]
		gout.texture = prev
		gout.visible = bool(g["ready"])
		if not bool(g["ready"]):
			_fx_pending = true
		# 合成序（player：层在深度 min 处绘制）：bg 之下=35，gameplay=41..，含 HUD=58
		if not g["hud"].is_empty() or float(g["mn"]) >= 8.0:
			gout.z_index = 58
		elif g["bg"]:
			gout.z_index = 35
		else:
			gout.z_index = 41
		(u["sv"] as SubViewport).render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# 空闲单元：停渲染 + 隐藏回贴
	for u in _units:
		if int(u["seq"]) == _use_seq:
			continue
		u["k"] = null
		if u["busy"]:
			(u["gout"] as TextureRect).visible = false
			(u["sv"] as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
		u["busy"] = false
	# —— ready 组 → 主实例 skip / HUD / 背景认领（链循环可能下调 ready：新池位首帧）——
	var claimed: Array = []
	var want_hud := {}
	var bg_unit = null
	for g4 in live:
		if not bool(g4["ready"]):
			continue
		claimed.append_array(g4["play"])
		for nm2 in g4["hud"]:
			want_hud[nm2] = g4
		if g4["bg"] and bg_unit == null:
			bg_unit = g4
	_cp.set_skip_depths(claimed)
	# —— HUD/背景归属迁移 ——
	for nm in HUD_Z:
		var el: Control = get(nm)
		if el == null or not is_instance_valid(el):
			continue
		var target: Variant = null
		if want_hud.has(nm) and want_hud[nm].has("u"):
			target = (want_hud[nm]["u"] as Dictionary)["mc"]
		var carrier := _hud_carrier(el)
		if target == null:
			if carrier.get_parent() != _hud_home.get(carrier, _host):
				var home: Node = _hud_home.get(carrier, _host)
				if home == null or not is_instance_valid(home):
					home = _host
				carrier.reparent(home, false)  # 保局部坐标：mc 与 _host 同原点后还要经 gout 回翻，保全局=会被翻进镜像位
		else:
			if not _hud_home.has(carrier):
				_hud_home[carrier] = carrier.get_parent()
			if carrier.get_parent() != target:
				carrier.reparent(target as Node, false)  # 同上：局部坐标直进镜像容器
	# 背景：_bg 是普通 TextureRect（_host 里），被 ready 单元认领时挪进单元镜像容器；
	# 未 ready（gout 还藏着）时留在家里，避免背景缺一帧
	if bg_unit != null and bg_unit.has("u"):
		var bmc: Control = (bg_unit["u"] as Dictionary)["mc"]
		if not _hud_home.has(_bg):
			_hud_home[_bg] = _bg.get_parent()
		if _bg.get_parent() != bmc:
			_bg.reparent(bmc, false)
	else:
		if _hud_home.has(_bg):
			var bh: Node = _hud_home[_bg]
			_hud_home.erase(_bg)
			if is_instance_valid(bh) and _bg.get_parent() != bh:
				_bg.reparent(bh, false)
	_bg.visible = true
	# —— 噪域特效链（targetRange 命中深度 16 才走；必须在 global 链之前，两者互不采样）——
	_update_block_chain(nong)
	# —— global 链（相机滤镜语义）：吃整张 _csv 合成图（_csv 在树序中先于 _fx_post 更新）——
	var prev2: Texture2D = _csv.get_texture()
	var gfresh2 := false
	var gslot := 0
	for e in glo:
		if int(_gx_age[gslot]) == 0:
			gfresh2 = true
		_gx_age[gslot] = int(_gx_age[gslot]) + 1
		prev2 = _fx_pass(1, gslot, e, prev2, sz)
		gslot += 1
	for j in range(slot, _fx_sv.size()):
		(_fx_quads[j] as ColorRect).material = null  # 本帧用不到的池位：只清屏不绘制
	for j in range(gslot, _gx_sv.size()):
		(_gx_quads[j] as ColorRect).material = null
	if gfresh2:
		_fx_pending = true
	if glo.is_empty() or gfresh2:  # 链上有新视口 → 本帧不叠（下帧即正常）
		_fx_out.visible = false
		return
	_fx_out.texture = prev2
	_fx_out.visible = true

## 特效链排序：内层先处理 = (激活时刻, 数组序) 降序（player 嵌套语义，见 _update_effects 头注）
func _chain_inner_first(a: int, b: int, nong: Array) -> bool:
	var sa := float((nong[a] as Dictionary)["s"])
	var sb := float((nong[b] as Dictionary)["s"])
	if sa != sb:
		return sa > sb
	return a > b

## pool: 0=非 global 链池（_fx_*），1=global 池（_gx_*，材质键加 g: 前缀防层位撞名）
## 谱包贴图缓存：噪域位移图那条坑是 **res://** 在导出包里只剩 .ctex，而谱包在
## **user://** 下是散文件，load() 直接可用（.png 有 .import 时走导入件，没有时按文件读）。
var _fx_texs := {}

func _fx_tex(n: String) -> Texture2D:
	if n == "":
		return null
	if _fx_texs.has(n):
		return _fx_texs[n]
	var t: Texture2D = null
	for c in [n, n.get_basename() + ".png"]:
		var p := _dir.path_join(String(c))
		if not FileAccess.file_exists(p):
			continue
		# 先按原始像素读：user:// 下的散 png 不是资源，先 load() 会在控制台刷一排
		# "Resource file not found"（假报错，兜底其实成功了），而且白付一次失败尝试。
		# load() 只留给"编辑器里已导入过"的情形。
		var im := Image.load_from_file(p)
		if im != null and not im.is_empty():
			t = ImageTexture.create_from_image(im)
		else:
			t = load(p) as Texture2D
		if t != null:
			break
	_fx_texs[n] = t
	return t


func _fx_pass(pool: int, i: int, e: Dictionary, prev: Texture2D, sz: Vector2) -> Texture2D:
	var raw := String(e["shader"])
	# 材质按 (shader, 池, 层位) 缓存：同一 shader 同链出现两次时两层必须持不同的 fx_src
	var mkey := (String("g:") if pool == 1 else ("b:" if pool == 2 else "")) + raw + "@" + str(i)
	var m: ShaderMaterial = _fx_mats.get(mkey)
	if m == null:
		var sh := _resolve_shader(raw)
		if sh == null:
			return prev
		m = ShaderMaterial.new()
		m.shader = sh
		_fx_mats[mkey] = m
		var ok := {}
		var ssize := false
		for u in sh.get_shader_uniform_list(true):
			var uty := int(u["type"])
			var un := String(u["name"])
			# rpe-next 的 vars 可以是 float / vec2 / vec3 / vec4（颜色按 Color 进）
			if uty in [TYPE_FLOAT, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4]:
				ok[un] = uty
			if uty == TYPE_VECTOR2 and un == "fx_screen_size":
				ssize = true
		_fx_fparams[mkey] = ok
		_fx_ssize[mkey] = ssize
	var ok2: Dictionary = _fx_fparams[mkey]
	for k in e["params"]:
		var pname := String(k)
		var pv: Variant = e["params"][k]
		if typeof(pv) == TYPE_STRING:
			# 字符串 var = 谱包里的贴图名（player 的 extra texture 同一套语义）
			m.set_shader_parameter(pname, _fx_tex(String(pv)))
		elif ok2.has(pname):
			var val: Variant = pv
			if typeof(val) == TYPE_ARRAY:
				var ar: Array = val
				if ar.size() == 2:
					val = Vector2(float(ar[0]), float(ar[1]))
				elif ar.size() == 3:
					val = Vector3(float(ar[0]), float(ar[1]), float(ar[2]))
				elif ar.size() == 4:
					val = Color(float(ar[0]), float(ar[1]), float(ar[2]), float(ar[3]))
			m.set_shader_parameter(pname, val)
	var sv: SubViewport = (_gx_sv if pool == 1 else (_bx_sv if pool == 2 else _fx_sv))[i]
	_sv_set(sv, sz)  # 物理=逻辑×render_scale（低预设时链上每一 pass 的填充量同步降）
	var q: ColorRect = (_gx_quads if pool == 1 else (_bx_quads if pool == 2 else _fx_quads))[i]
	q.size = sz
	q.material = m
	m.set_shader_parameter("fx_src", prev)
	if ok2.has("u_time"):
		m.set_shader_parameter("u_time", _clock)
	if ok2.has("resolution"):
		m.set_shader_parameter("resolution", sz)
	# 0=游戏层链（透明底，保留源 alpha），1=global 全帧链（整帧不透明）
	m.set_shader_parameter("fx_stage", 1.0 if pool == 1 else 0.0)
	if bool(_fx_ssize.get(mkey, false)):
		m.set_shader_parameter("fx_screen_size", sz)  # 逻辑 px：低预设下特效半径不变
	return sv.get_texture()

## targetRange 渲染单元（player ShaderNode）：透明 SubViewport + 镜像容器 +
## 幽灵 ChartPlayer（set_state_source：判定/事件/特效全读主实例，零解析成本）
## + 回贴 gout（_host 内，预乘 alpha，镜像回正同 _lout）。
func _make_unit() -> Dictionary:
	var sv := SubViewport.new()
	sv.transparent_bg = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_fx_units.add_child(sv)  # 单元层必须最先更新（链池→gout 在同帧消费它）
	_sv_set(sv, size)  # 关键：物理=逻辑×render_scale + override。裸抄 _csv.size 会
					   # 半 buffer 无 override → 幽灵层只画左上 1/4，gout 拉伸后与全屏叠加（F10 实测）
	var mc := Control.new()
	mc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mc.size = Vector2(size.x, size.y)
	mc.pivot_offset = mc.size * 0.5
	mc.scale = Vector2(1, -1)  # 浏览器 uv 约定（同 _lsv 的 _cp 镜像）
	sv.add_child(mc)
	var cp := ChartPlayer.new()
	cp.set_state_source(_cp)
	# 单元内是**同一个 canvas**：背景(_bg, z=0) 会被认领进 mc 当底，幽灵的线精灵画在
	# 自己的 CanvasItem 上（默认 z=0）。bg 是后加入的兄弟、同 z 排在后面 → 把线整片盖掉
	# （非 global 特效一开，判定线全消失；音符是 z=1 的 MultiMesh 子节点所以还在）。
	# 幽灵抬到 z=1（音符相对 +1=2 仍在线上），HUD 是 z=55 绝对层，仍在最上。
	cp.z_index = 1
	mc.add_child(cp)
	var gout := TextureRect.new()
	gout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gout.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	gout.stretch_mode = TextureRect.STRETCH_SCALE
	gout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var gm := CanvasItemMaterial.new()
	gm.set("blend_mode", 4)  # 链 RT 是预乘数据
	gout.material = gm
	gout.pivot_offset = gout.size * 0.5
	gout.scale = Vector2(1, -1)  # 镜像回正
	gout.resized.connect(_unit_gout_resized.bind(gout))
	gout.visible = false
	_host.add_child(gout)
	var u := {"sv": sv, "mc": mc, "cp": cp, "gout": gout, "busy": false, "k": null, "age": 0, "seq": 0}
	_units.append(u)
	return u

func _unit_gout_resized(gout: TextureRect) -> void:
	gout.pivot_offset = gout.size * 0.5

## HUD 部件的"承载节点"：若挂在 attachUI holder 上则整组迁移（attach 变换跟随），否则本体
func _hud_carrier(el: Control) -> Control:
	var p := el.get_parent()
	for hk in _attach_holders:
		if _attach_holders[hk] == p:
			return p as Control
	return el

## 特效名 → Shader：谱面自带的 "/xxx.glsl" 在**运行时转译**成 gdshader（phizone 语义）；
## 其余（无斜杠的 stock 特效名）不预置任何 .gdshader —— 预转好的那几个已经删掉，
## 以后都按需转。解析失败也缓存（null），避免每帧重试刷错误。
func _resolve_shader(raw: String) -> Shader:
	if _fx_custom.has(raw):
		return _fx_custom[raw]
	var sh: Shader = null
	var nm := raw.trim_prefix("/")
	if raw != "" and raw.begins_with("/") and not nm.contains("..") and not nm.contains("\\"):
		sh = _custom_shader(nm)
	_fx_custom[raw] = sh
	return sh

func _custom_shader(nm: String) -> Shader:
	var cands: PackedStringArray = [nm]
	if nm.get_extension() == "":
		cands.append(nm + ".glsl")
		cands.append(nm + ".frag")
	for c in cands:
		var p := _dir.path_join(c)
		if not FileAccess.file_exists(p):
			continue
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null:
			continue
		var src := f.get_as_text()
		f.close()
		var g := _glsl_to_gdshader(src)
		if g == "":
			push_warning("chart_stage: 无法转译谱面特效 " + c)
			continue
		var sh := Shader.new()
		sh.code = g
		var df := FileAccess.open("user://qa/tx_%s.gdshader" % nm.get_basename(), FileAccess.WRITE)
		if df != null:
			df.store_string(g)
			df.close()  # QA：留档转译产物便于排查
		return sh  # 4.7 GDScript 无 Shader.compile()：真实渲染时由 GPU 编译，出错会打日志
	return null

static var _RX_UV := RegEx.create_from_string("\\buv\\b")
static var _RX_TIME := RegEx.create_from_string("\\btime\\b")
static var _RX_SSIZE := RegEx.create_from_string("\\bscreenSize\\b")
static var _RX_TEX2D := RegEx.create_from_string("\\btexture2D\\b")
static var _RX_SCREENTEX := RegEx.create_from_string("\\bscreenTexture\\b")
static var _RX_PREC := RegEx.create_from_string("\\b(lowp|mediump|highp)\\s+")
static var _RX_TEXDECL := RegEx.create_from_string("uniform\\s+sampler2D\\s+(\\w+)")

## 方言预处理：谱面/皮肤的 GLSL 不全是 Phira 的 uv+screenTexture 写法。
## - Cocos/RPE：v_texCoord / CC_Texture0 / u_texture / v_fragmentColor / texture2DProj，
##   且把游戏区硬编码在 1280×720 的 0..0.7031 × 0.0333..0.8667（rpe-next 的 1.2 映射）。
##   本项目整幅画布就是游戏区 → 常量归一成 0/1、1.2→1，rect 边界同步改。
## - ES3：out vec4 xxx / in vec2 vUv / #ifdef GL_ES。
func _glsl_pre(src: String) -> String:
	var cocos := src.contains("v_texCoord") or src.contains("CC_Texture0") \
			or src.contains("u_texture") or src.contains("v_fragmentColor")
	# ES3 out vec4 name; → 删除声明，xxx 全部换成 gl_FragColor
	var rx_out := RegEx.create_from_string(
			"(?m)^[ \\t]*(?:layout\\s*\\([^)]*\\)\\s*)?out\\s+vec4\\s+(\\w+)\\s*;")
	var m := rx_out.search(src, 0)
	while m != null:
		var nm := m.get_string(1)
		src = src.substr(0, m.get_start(0)) + src.substr(m.get_end(0))
		src = RegEx.create_from_string("\\b" + nm + "\\b").sub(src, "gl_FragColor", true)
		m = rx_out.search(src, 0)
	# ES3 in/varying 的 uv 与顶点色
	var rx_in := RegEx.create_from_string("(?m)^[ \\t]*(?:in|varying)\\s+vec([24])\\s+(\\w+)\\s*;")
	var lines0 := src.split("\n")
	var keep0 := PackedStringArray()
	var uv_names := PackedStringArray()
	var col_names := PackedStringArray()
	for ln in lines0:
		var mi := rx_in.search(ln)
		if mi != null:
			if int(mi.get_string(1)) == 2:
				uv_names.append(mi.get_string(2))
			else:
				col_names.append(mi.get_string(2))  # vec4 varying = 顶点色，统一取白
			continue
		keep0.append(ln)
	src = "\n".join(keep0)
	for un in uv_names:
		src = RegEx.create_from_string("\\b" + un + "\\b").sub(src, "UV", true)
	for cn in col_names:
		src = RegEx.create_from_string("\\b" + cn + "\\b").sub(src, "vec4(1.0)", true)
	# 有 v_texCoord / vUv 这类"坐标 varying"时，UV 已经由它们映射而来；
	# 剩下的 uv 只能是一个局部别名（Cocos 常见 `vec2 uv = v_texCoord;`）。
	# 先改名，避免后面 \buv\b→UV 把局部声明变成 `vec2 UV = UV;`（阴影修复会再把它改成 UV__l）。
	# 注意 `varying vec2 uv;` 是 Phira 的老写法：删声明后 uv 就是 UV 的别名，不能改名。
	var rename_uv := cocos
	for un in uv_names:
		if String(un) != "uv":
			rename_uv = true
	if rename_uv:
		src = RegEx.create_from_string("\\buv\\b").sub(src, "_uv", true)
	if cocos:
		# #ifdef GL_ES 块（内容保留，precision 稍后由头解析丢弃）
		var lines1 := src.split("\n")
		var keep1 := PackedStringArray()
		var skip := 0
		for ln in lines1:
			var s := ln.strip_edges()
			if s.begins_with("#ifdef GL_ES") or s.begins_with("#ifndef GL_ES"):
				skip += 1
				continue
			if skip > 0 and s.begins_with("#endif"):
				skip -= 1
				continue
			keep1.append(ln)
		src = "\n".join(keep1)
		# texture2DProj(sampler, vec4(xy, 0.0, 1.0)) → 直采 xy
		var rx_proj := RegEx.create_from_string(
				"texture2DProj\\s*\\(\\s*(?:CC_Texture0|u_texture|texture)\\s*,\\s*vec4\\s*\\(\\s*([^,]+?)\\s*,\\s*0\\.0\\s*,\\s*1\\.0\\s*\\)\\s*\\)")
		var out := ""
		var last := 0
		var mp := rx_proj.search(src)
		while mp != null:
			out += src.substr(last, mp.get_start(0) - last) \
					+ "texture2D(screenTexture, " + mp.get_string(1) + ")"
			last = mp.get_end(0)
			mp = rx_proj.search(src, last)
		if last > 0:
			src = out + src.substr(last)
		src = src.replace("texture2DProj(", "textureProjF(")
		# 采样器名统一成 screenTexture（随后由 swizzle 换成 fx_src）
		src = RegEx.create_from_string("texture2D\\s*\\(\\s*(?:CC_Texture0|u_texture|texture)\\s*,") \
				.sub(src, "texture2D(screenTexture,", true)
		src = src.replace("CC_Texture0", "screenTexture").replace("u_texture", "screenTexture")
		src = RegEx.create_from_string("(?m)^[ \\t]*uniform\\s+sampler2D\\s+texture\\s*;[^\\n]*$") \
				.sub(src, "", true)
		src = src.replace("v_texCoord", "UV")
		src = RegEx.create_from_string("\\bv_fragmentColor\\b").sub(src, "vec4(1.0)", true)
		# RPE 游戏区常量 → 整幅画布
		var lines2 := src.split("\n")
		var keep2 := PackedStringArray()
		for ln in lines2:
			if ("0.7031" in ln) or ("0.703" in ln) or ("0.0333" in ln) or ("0.033" in ln) \
					or ("0.867" in ln and "rect" in ln):
				ln = ln.replace("0.7031", "1.0").replace("0.703", "1.0") \
						.replace("0.0333", "0.0").replace("0.033", "0.0")
				ln = ln.replace("0.867", "1.0")
				if "1.2" in ln:
					ln = ln.replace("1.2", "1.0")
			keep2.append(ln)
		src = "\n".join(keep2)
	return src

## 谱面自带 glsl（webgl 片元）→ Godot canvas_item gdshader：
## 先做方言归一（Cocos/RPE：v_texCoord/CC_Texture0/u_texture/v_fragmentColor/
##   texture2DProj、#ifdef GL_ES、0.7031/0.0333 游戏区常量；ES3：out vec4/in vec2），
## 再剥 #version/precision/varying/sampler 声明；注释里 %默认值% 转成 uniform 默认值；
## texture2D→texture、screenTexture→screen_texture、uv→UV、screenSize→1/SCREEN_PIXEL_SIZE、
## gl_FragColor→COLOR；大括号配对取出 main() 函数体包进 fragment()。
func _glsl_to_gdshader(src: String) -> String:
	src = _glsl_pre(src)
	if src.find("textureProjF(") >= 0:
		src = "vec4 textureProjF(sampler2D s, vec4 p) { return texture(s, p.xy / p.w); }\n" + src
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
	# screenSize 语义=视口像素。不能换成 SCREEN_PIXEL_SIZE：那是 fragment 专属内置，
	# 谱内 shader 常在顶层函数里用它（Designant bloom.glsl → 编译失败 → 全灰屏）。
	# 改为注入 fx_screen_size uniform，链渲染时每层喂真实视口尺寸。
	var uses_ssize: bool = _RX_SSIZE.search(head + body) != null
	# 只写 gl_FragColor.rgb 的谱内 shader（chromatic_pow/random_rate）：player 实测不糊背景
	# → 按"继承源 alpha"合成（透明区输出透明），顶点色保持 (0,0,0,0)=GLSL 初值
	var rgb_only_write: bool = "gl_FragColor." in src
	var decls := ""
	var helpers := ""
	var declared := {}
	var tex_decls := {}
	for line in head.split("\n"):
		var t := line.strip_edges()
		if t == "" or t.begins_with("//"):
			continue
		if t.begins_with("#version") or t.begins_with("# version") or t.begins_with("precision"):
			continue
		if t.begins_with("varying"):
			continue
		if t.begins_with("uniform sampler2D"):
			# screenTexture 由 fx_src 顶替；但谱内自带的**第二张**贴图必须保留声明——
			# extra.json 把 vars 写成字符串（谱包里的文件名）就是 player 的 extra texture
			# 语义（ShaderPipeline.boot：字符串 → 查 asset 纹理 → 绑到该 uniform）。
			# 整行丢掉等于"遮罩/条带类 shader 永远拿不到纹理"，全还原方案卡在这。
			var mt := _RX_TEXDECL.search(t)
			if mt != null:
				var tn := String(mt.get_string(1))
				if tn != "screenTexture" and not tex_decls.has(tn):
					tex_decls[tn] = true
			continue
		if t.begins_with("uniform "):
			var d := _convert_uniform(t)
			if d != "":
				decls += d + "\n"
				var u_names := PackedStringArray()
				for tk in t.split(" ", false):
					if tk != "lowp" and tk != "mediump" and tk != "highp":
						u_names.append(tk)
				if u_names.size() >= 3:
					var tok := String(u_names[2])
					var sc := tok.find(";")
					if sc >= 0:
						tok = tok.substr(0, sc)
					declared[tok] = true
			continue
		helpers += line + "\n"
	var has_time_uniform: bool = declared.has("time")
	if helpers != "":
		helpers = _glsl_swizzle(helpers, has_time_uniform, uses_ssize)
	body = _glsl_swizzle(body, has_time_uniform, uses_ssize)
	# Godot canvas 内置混合全部再乘 src.a（实测 blend_add=(SRC_ALPHA,ONE)，pass=unit·a 二次预乘），
	# 而链 RT 存的已是预乘值 → 见下方"反预乘写出"补偿尾。
	var out := "shader_type canvas_item;\n"
	out += "uniform sampler2D fx_src;\n"
	for tn2 in tex_decls.keys():
		# 采样器 uniform 名 = extra.json 里那个字符串 var 的键（_fx_pass 按名字绑纹理）。
		# Nearest + Repeat 是官方那几张的用法：uSparkTex(PointNoise) 要平铺才出颗粒、
		# uMasks 先 snap_eff 再取格。linear+clamp 会把 PointNoise 钳成一条边色 ⇒ 颗粒全没。
		out += "uniform sampler2D %s : filter_nearest, repeat_enable;\n" % String(tn2)
	if uses_ssize:
		out += "uniform vec2 fx_screen_size = vec2(1350.0, 900.0);\n"
	out += decls
	if helpers != "":
		out += helpers
	# 只写 .rgb 的谱内 shader（chromatic_pow/random_rate）：player 实证不糊背景
	# → 转译时补一行 alpha 继承源层（透明区保持透明）
	if rgb_only_write:
		body += "\n\tCOLOR.a = texture(fx_src, UV).a;"
	# 反预乘尾：rgb/=a'、a'=max(a,max(rgb))，经默认 MIX 落回 (rgb/a')·a' = 原预乘值；
	# a'=max 保证 bloom 加性光晕（rgb>a）不被 alpha 裁掉。
	body += ("\n\tfloat __s = max(max(COLOR.r, COLOR.g), COLOR.b);"
		+ "\n\tfloat __a = max(COLOR.a, __s);"
		+ "\n\tCOLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);"
		+ "\n\tCOLOR.a = __a;")
	out += "void fragment() {\n" + body + "\n}\n"
	out = _dedupe_fns(out)
	var shadow_names: Array = declared.keys()
	shadow_names.append_array(["UV", "COLOR", "FRAGCOORD", "TIME", "SCREEN_UV", "VERTEX"])
	out = _fix_shadows(out, shadow_names)
	out = _thread_uv(out)
	out = _fix_mat_ctors(out)
	out = out.replace("__FRAGL", "UV")  # gl_FragCoord 占位符落地（见 _glsl_swizzle 注）
	# A/B 对拍实测（ab_run t=30/150 背景条亮度）：本项目 2D 管线整体是字节直通
	# （运行时 ImageTexture 无 sRGB 解码、RT/回读无编码，modulate=m 即显示=m·p），
	# 与浏览器 canvas 滤镜同空间 → 不再做 sRGB 边界往返（旧 _srgb_boundary 会把
	# correction 的 contrast 支点从字节域挪到线性域，暗部被提亮 ~2.5×，实测反向）。
	return out

## Godot 4 的 2D 离屏 RT 走线性色空间，浏览器 WebGL 滤镜直接在 sRGB 字节上运算——
## tone.glsl 的 pow(2.2)、correction 的 contrast 支点、bloom 的亮度阈值这类非线性色彩
## 数学在两种空间下结果相反（Designant 最后一分钟"player 提曝光、PTN 压暗"案）。
## 边界还原浏览器语义：采样处解码(线性→sRGB)，shader 全程按 sRGB 值算，写出处编码回线性。
## 对纯几何/混合类 shader（invis/beam/chromatic）解码-编码往返中性或更贴近浏览器。
func _srgb_boundary(code: String) -> String:
	var rx := RegEx.create_from_string("texture\\(\\s*fx_src\\s*,\\s*((?:[^()]|\\([^()]*\\))*)\\)")
	var out := ""
	var last := 0
	var m := rx.search(code)
	while m != null:
		out += code.substr(last, m.get_start(0) - last) + "_fxs(" + m.get_string(1) + ")"
		last = m.get_end(0)
		m = rx.search(code, last)
	out += code.substr(last)
	# 声明先于使用：helper 插到最后一个顶格 uniform 行之后（任何函数体之前）——
	# 否则采样 fx_src 的顶层 helper（bloom.getBloomOrigin）会 "No matching function found for '_fxs'"
	if out.find("void fragment()") < 0:
		return code
	var helper := "vec4 _fxs(vec2 __u){\n\tvec4 __c = texture(fx_src, __u);\n" \
		+ "\treturn vec4(pow(clamp(__c.rgb, vec3(0.0), vec3(1.0)), vec3(0.45454545)), __c.a);\n}\n\n"
	var ls := out.split("\n")
	var lu := -1
	for i in ls.size():
		if String(ls[i]).begins_with("uniform"):
			lu = i
	if lu < 0:
		return code
	var head := ""
	for i in range(0, lu + 1):
		head += String(ls[i]) + "\n"
	var tail := ""
	for i in range(lu + 1, ls.size()):
		tail += String(ls[i]) + "\n"
	out = head + helper + tail
	var close := out.rfind("}")
	if close < 0:
		return code
	return out.substr(0, close) + "\n\tCOLOR.rgb = pow(clamp(COLOR.rgb, vec3(0.0), vec3(1.0)), vec3(2.2));\n" + out.substr(close)

## GLSL ES 允许 mat4(16 个标量) / mat4(vec3,标量,…按列填充)，Godot 只认列向量构造
## （shadertoy 移植谱惯用写法，correction.glsl 案）。按列重排为 vec4(...) 形式。
func _fix_mat_ctors(code: String) -> String:
	var rx := RegEx.create_from_string("\\bmat([34])\\s*\\(")
	var edits: Array = []
	var m := rx.search(code)
	while m != null:
		var ms := m.get_string(0)
		var pb := m.get_start(0) + ms.length() - 1
		var pe := _paren_end(code, pb)
		var inner := code.substr(pb + 1, pe - pb - 1)
		var args: PackedStringArray = PackedStringArray()
		var d := 0
		var cur := ""
		for i in inner.length():
			var ch := inner[i]
			if ch == "(":
				d += 1
			elif ch == ")":
				d -= 1
			if ch == "," and d == 0:
				args.append(cur.strip_edges())
				cur = ""
			else:
				cur += ch
		args.append(cur.strip_edges())
		var dim := 3 if int(m.get_string(1)) == 3 else 4
		var rep := ""
		var al := Array(args)
		if dim == 4 and args.size() == 16:
			rep = "mat4(vec4(%s, %s, %s, %s), vec4(%s, %s, %s, %s), vec4(%s, %s, %s, %s), vec4(%s, %s, %s, %s))" % al
		elif dim == 3 and args.size() == 9:
			rep = "mat3(vec3(%s, %s, %s), vec3(%s, %s, %s), vec3(%s, %s, %s))" % al
		elif dim == 4 and args.size() == 10:
			rep = "mat4(vec4(%s, %s), vec4(%s, %s), vec4(%s, %s), vec4(%s, %s, %s, %s))" % al
		if rep != "":
			edits.append([m.get_start(0), pe + 1, rep])
			m = rx.search(code, pe + 1)
		else:
			m = rx.search(code, m.get_start(0) + ms.length())
	edits.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	for e in edits:
		code = code.substr(0, int(e[0])) + String(e[2]) + code.substr(int(e[1]))
	return code

## Godot 的 UV 只在 fragment() 作用域可用，顶层辅助函数引用它会 "Unknown identifier"
## （Designant bloom.glsl 案）。给所有（直接或传递）用到 UV 的函数加 vec2 __UV 形参，
## 体内 UV→__UV，调用点按调用者上下文补 , UV / , __UV。
func _thread_uv(code: String) -> String:
	var spans := _fn_spans(code)
	var rx_uv := RegEx.create_from_string("\\bUV\\b")
	var needs := {}
	for sp in spans:
		var nm := String(sp["name"])
		if nm == "fragment":
			continue
		var body := code.substr(int(sp["start"]), int(sp["end"]) - int(sp["start"]) + 1)
		if rx_uv.search(body) != null:
			needs[nm] = true
	var changed := true
	while changed:
		changed = false
		for sp in spans:
			var nm2 := String(sp["name"])
			if nm2 == "fragment" or needs.has(nm2):
				continue
			var body2 := code.substr(int(sp["start"]), int(sp["end"]) - int(sp["start"]) + 1)
			for t in needs.keys():
				if RegEx.create_from_string("\\b" + String(t) + "\\s*\\(").search(body2) != null:
					needs[nm2] = true
					changed = true
					break
	if needs.is_empty():
		return code
	var edits: Array = []
	# 1) 函数自身：签名加参 + 体内改名
	for sp in spans:
		var nm3 := String(sp["name"])
		if not needs.has(nm3):
			continue
		var seg := code.substr(int(sp["start"]), int(sp["end"]) - int(sp["start"]) + 1)
		var pc := seg.find(")")
		var op := seg.find("(")
		var params := seg.substr(op + 1, pc - op - 1)
		var add := "vec2 __UV" if params.strip_edges() == "" else ", vec2 __UV"
		seg = seg.substr(0, pc) + add + seg.substr(pc)
		seg = rx_uv.sub(seg, "__UV", true)
		# 该函数体内对其他 needs 函数的调用同样补 __UV 实参（整段重写后外部循环会跳过）
		var rx_inner := RegEx.create_from_string("\\b(" + "|".join(needs.keys()) + ")\\s*\\(")
		var inner_edits: Array = []
		var mi := rx_inner.search(seg, op + 1)
		while mi != null:
			var pci := seg.find("(", mi.get_start(0))
			var pei := _paren_end(seg, pci)
			var argsi := seg.substr(pci + 1, pei - pci - 1)
			inner_edits.append([pei, pei, (", __UV" if argsi.strip_edges() != "" else "__UV")])
			mi = rx_inner.search(seg, mi.get_start(0) + 1)
		inner_edits.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
		for ie in inner_edits:
			seg = seg.substr(0, int(ie[0])) + String(ie[2]) + seg.substr(int(ie[1]))
		edits.append([int(sp["start"]), int(sp["end"]) + 1, seg])
	# 2) 调用点：在实参表末尾补 UV/__UV（跳过 1) 已整段重写的函数体内部）
	var rx_call := RegEx.create_from_string("\\b(" + "|".join(needs.keys()) + ")\\s*\\(")
	var m2 := rx_call.search(code)
	while m2 != null:
		var pos := m2.get_start(0)
		var in_def := false
		for e in edits:
			if pos >= int(e[0]) and pos < int(e[1]):
				in_def = true
		if not in_def:
			var pb := code.find("(", pos)
			var pe := _paren_end(code, pb)
			var caller_uv := "UV"
			for sp2 in spans:
				if String(sp2["name"]) != "fragment" and needs.has(String(sp2["name"])) \
						and pos >= int(sp2["start"]) and pos <= int(sp2["end"]):
					caller_uv = "__UV"
			var args := code.substr(pb + 1, pe - pb - 1)
			var add2 := caller_uv if args.strip_edges() == "" else ", " + caller_uv
			edits.append([pe, pe, add2])
		m2 = rx_call.search(code, m2.get_start(0) + 1)
	edits.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	for e in edits:
		code = code.substr(0, int(e[0])) + String(e[2]) + code.substr(int(e[1]))
	return code

# ── gdshader 兼容层：GLSL ES 允许而 Godot 不允许的两种写法 ──
# 1) 函数重载（tone.glsl 的 float/vec3 同名 toneMap）→ 按定义顺序改 name_2 并按实参数重写调用
# 2) 局部/参数遮蔽 uniform 或内置（bloom intensity、correction brightness、bloom 的 vec2 uv）
#    → 该函数体内改名 X__l（GLSL 的遮蔽语义在改名后逐字保持）

static var _RX_FN := RegEx.create_from_string("(?m)^[ \t]*(?:[A-Za-z_]\\w*[ \t]+)+([A-Za-z_]\\w*)[ \t]*\\(([^()]*)\\)[ \t\r\n]*(?:/[^\n]*)?[ \t\r\n]*\\{")

func _brace_end(code: String, open_at: int) -> int:
	var depth := 0
	for i in range(open_at, code.length()):
		var ch := code[i]
		if ch == "{":
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0:
				return i
	return code.length() - 1

func _paren_end(code: String, open_at: int) -> int:
	var depth := 0
	for i in range(open_at, code.length()):
		var ch := code[i]
		if ch == "(":
			depth += 1
		elif ch == ")":
			depth -= 1
			if depth == 0:
				return i
	return code.length() - 1

func _argc(params: String) -> int:
	var t := params.strip_edges()
	if t == "":
		return 0
	var d := 0
	var c := 0
	for i in t.length():
		var ch := t[i]
		if ch == "(":
			d += 1
		elif ch == ")":
			d -= 1
		elif ch == "," and d == 0:
			c += 1
	return c + 1

func _fn_spans(code: String) -> Array:
	var spans := []
	var mm := _RX_FN.search(code)
	while mm != null:
		var nm := mm.get_string(1)
		if nm != "if" and nm != "while" and nm != "for" and nm != "switch":
			var ob := code.find("{", mm.get_start(0))
			var ce := _brace_end(code, ob)
			spans.append({"name": nm, "argc": _argc(mm.get_string(2)), "start": mm.get_start(0), "nstart": mm.get_start(1), "end": ce})
			mm = _RX_FN.search(code, ce + 1)
		else:
			mm = _RX_FN.search(code, mm.get_start(0) + 1)
	return spans

func _dedupe_fns(code: String) -> String:
	var spans := _fn_spans(code)
	var count := {}
	var renames: Array = []
	for sp in spans:
		var nm := String(sp["name"])
		count[nm] = int(count.get(nm, 0)) + 1
		if int(count[nm]) > 1:
			renames.append({"old": nm, "new": nm + "_" + str(int(count[nm])), "argc": int(sp["argc"]), "start": int(sp["start"]), "nstart": int(sp["nstart"]), "end": int(sp["end"])})
	if renames.is_empty():
		return code
	var edits: Array = []
	for r in renames:
		# 只改定义处的函数名：体内对同名其他重载的调用保持原名（tone.glsl 案——整段改名
		# 让 toneMap(vec3) 里调 toneMap(float) 变成调自己 → "Recursion is not allowed"）
		edits.append([int(r["nstart"]), int(r["nstart"]) + String(r["old"]).length(), String(r["new"])])
	for r in renames:
		var crx := RegEx.create_from_string("\\b" + String(r["old"]) + "\\s*\\(")
		var m2 := crx.search(code)
		while m2 != null:
			var in_def := false
			for e in edits:
				if m2.get_start(0) >= int(e[0]) and m2.get_start(0) < int(e[1]):
					in_def = true
			if not in_def:
				var pb := code.find("(", m2.get_start(0))
				var pe := _paren_end(code, pb)
				if _argc(code.substr(pb + 1, pe - pb - 1)) == int(r["argc"]):
					edits.append([m2.get_start(0), m2.get_start(0) + String(r["old"]).length(), String(r["new"])])
			m2 = crx.search(code, m2.get_start(0) + 1)
	edits.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	for e in edits:
		code = code.substr(0, int(e[0])) + String(e[2]) + code.substr(int(e[1]))
	return code

func _fix_shadows(code: String, names: Array) -> String:
	var spans := _fn_spans(code)
	var edits: Array = []
	for sp in spans:
		var seg := code.substr(int(sp["start"]), int(sp["end"]) - int(sp["start"]) + 1)
		var seg2 := seg
		for nm in names:
			var sname := String(nm)
			var decl := RegEx.create_from_string("\\b(?:float|vec2|vec3|vec4|int|bool|mat2|mat3|mat4)[ \t]+" + sname + "\\b")
			if decl.search(seg2) != null:
				var rx := RegEx.create_from_string("\\b" + sname + "\\b")
				seg2 = rx.sub(seg2, sname + "__l", true)
		if seg2 != seg:
			edits.append([int(sp["start"]), int(sp["end"]) + 1, seg2])
	edits.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	for e in edits:
		code = code.substr(0, int(e[0])) + String(e[2]) + code.substr(int(e[1]))
	return code

## "uniform float extend; // %0.25% 0..1" → "uniform float extend = 0.25;"
func _convert_uniform(t: String) -> String:
	var semi := t.find(";")
	if semi < 0:
		return ""
	var decl := t.substr(0, semi)
	var rest := t.substr(semi + 1)
	var parts := PackedStringArray()
	for tk in decl.split(" ", false):
		if tk != "lowp" and tk != "mediump" and tk != "highp":
			parts.append(tk)
	if parts.size() < 3:
		return ""
	var ty := parts[1]
	var name := parts[2]
	if name == "screenSize":
		return ""  # 用法统一替换成 1/SCREEN_PIXEL_SIZE
	var def := ""
	var c1 := rest.find("%")
	if c1 >= 0:
		var c2 := rest.find("%", c1 + 1)
		if c2 > c1:
			def = rest.substr(c1 + 1, c2 - c1 - 1).strip_edges()
	var dflt := ""
	if def != "":
		if ty == "vec2" or ty == "vec3" or ty == "vec4":
			if not def.begins_with("vec"):
				def = "%s(%s)" % [ty, def]
			dflt = def
		elif ty == "float":
			if "." not in def and "e" not in def.to_lower():
				def += ".0"
			dflt = def
		elif ty == "bool":
			dflt = "false" if def == "0" or def.to_lower() == "false" else "true"
		else:
			dflt = def
	return "uniform %s %s = %s;" % [ty, name, dflt] if dflt != "" else "uniform %s %s;" % [ty, name]

func _glsl_swizzle(s: String, keep_time: bool, ssize_uniform: bool) -> String:
	s = s.replace("gl_FragColor", "COLOR")
	if ssize_uniform:
		# F10 取证（pass0 全图 2× 案）：FRAGCOORD/VERTEX 都是物理像素坐标（低预设
		# buffer 675；VERTEX 已含视口 stretch 变换），fx_screen_size 是逻辑 1350
		# → gl_FragCoord.xy/screenSize ∈ [0,0.5) = 只采 fx_src 左上 1/4 再铺满 = 2×。
		# 唯一尺度无关的量是内置 UV∈[0,1] → 逻辑 fragment 坐标 = UV·fx_screen_size。
		# 用占位符：直接写 UV 会被 _fix_shadows 连坐改名（谱内 main 常声明局部 uv）。
		s = s.replace("gl_FragCoord", "vec4(__FRAGL * fx_screen_size, 0.0, 1.0)")
	else:
		s = s.replace("gl_FragCoord", "FRAGCOORD")
	s = _RX_TEX2D.sub(s, "texture", true)
	s = _RX_SCREENTEX.sub(s, "fx_src", true)
	s = _RX_UV.sub(s, "UV", true)
	if ssize_uniform:
		s = _RX_SSIZE.sub(s, "fx_screen_size", true)
	else:
		s = _RX_SSIZE.sub(s, "(1.0 / SCREEN_PIXEL_SIZE)", true)
	s = _RX_PREC.sub(s, "", true)
	if not keep_time:
		s = _RX_TIME.sub(s, "TIME", true)
	return s

## attachUI 跟随（player GameUI.updateAttach 语义，实证=部署版 player 截图）：
## HUD = 默认布局 + 线相对屏幕中心的偏移（delta），随线旋转/透明度/extended 缩放；
## 子元素位置仍由 _hud_layout 写舞台坐标（holder 原点=delta，二者天然相加）。
## attach 线的线精灵由 C++ 按 player Line.ts:297 隐藏（用户确认白线不应出现）。
func _apply_attachments() -> void:
	var cx := size.x * 0.5
	var cy := size.y * 0.5
	for a in _cp.get_attachments():
		var nm := String(a["ui"]).to_lower()
		var names: Array = ATTACH_MAP.get(nm, [])
		if names.is_empty():
			continue
		var els: Array = []
		for m in names:
			var el: Control = get(m)
			if el != null and is_instance_valid(el):
				els.append(el)
		if els.is_empty():
			continue
		var holder: Control = _attach_holders.get(nm)
		if holder == null:
			holder = Control.new()
			holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
			holder.z_index = 55  # 与 HUD 同层、特效层(40)之上——player 后期不盖 UI
			_host.add_child(holder)
			_attach_holders[nm] = holder
		for el in els:
			# 只从 _host 收编：被 targetRange 单元认领的部件（父级=单元镜像容器）不动
			if el.get_parent() == _host:
				el.reparent(holder)  # add_child 不会自动脱离原父（4.7 报错）
		holder.position = Vector2(float(a["x"]) - cx, float(a["y"]) - cy)
		holder.rotation = float(a["rot"])
		# player GameUI.updateAttach：_text.setTint(line.tint)——combo 数字等跟随线色
		# （テレパシ 紫数字案：无此步白字叠白星=看不见）。.get 兜底=旧 DLL 无键不炸
		holder.modulate = Color(float(a.get("tr", 1.0)), float(a.get("tg", 1.0)),
			float(a.get("tb", 1.0)), clampf(float(a["alpha"]), 0.0, 1.0))
		holder.scale = Vector2(float(a["sx"]), float(a["sy"]))

# —— extra.json videos（player Video.ts：depth=zIndex??1、start=time 拍→秒、时长=视频时长、
# scale=cropCenter(cover)/inside(fit)/fit(stretch)、alpha/dim 可为事件、attach 跟线变换+遮罩）。
# Godot 只内置 Ogg Theora 解码：mp4/webm 首次遇到用 ffmpeg 异步转码为同名 .ptn.ogv 缓存。
# 已知差异（Stage A）：视频不参与 targetRange 特效链（player 里 d1 会被 1-16 滤镜扫到）。 ——
var _vids: Array = []
var _vid_xcode: Array = []
var _vid_host: Control
var _viddbg := false  # QA：--qaviddbg 每帧打印各视频窗口/位置

const VID_MASK_SHADER := """
shader_type canvas_item;
uniform vec4 mask_rect = vec4(0.0, 0.0, 1.0, 1.0); // uv 系可见框 min.xy max.zw
void fragment() {
	if (UV.x < mask_rect.x || UV.x > mask_rect.z || UV.y < mask_rect.y || UV.y > mask_rect.w) {
		COLOR = vec4(0.0);
	} else {
		COLOR = COLOR * texture(TEXTURE, UV);
	}
}
"""

func _setup_videos(dir_path: String) -> void:
	for a in OS.get_cmdline_user_args():
		if String(a) == "--qaviddbg":
			_viddbg = true
	var ex := dir_path.path_join("extra.json")
	if not FileAccess.file_exists(ex):
		return
	var raw := FileAccess.get_file_as_bytes(ex)
	if raw.size() >= 3 and raw[0] == 0xEF and raw[1] == 0xBB and raw[2] == 0xBF:
		raw = raw.slice(3, raw.size())
	var j: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(j) != TYPE_DICTIONARY:
		return
	var vids: Array = j.get("videos", [])
	if vids.is_empty():
		return
	_vid_host = Control.new()
	_vid_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_host.add_child(_vid_host)
	_host.move_child(_vid_host, _bg.get_index() + 1)  # player 默认 depth 1：背景之上、判定线之下
	for vd in vids:
		if typeof(vd) != TYPE_DICTIONARY:
			continue
		var fn := String(vd.get("path", ""))
		if fn == "":
			continue
		var src := dir_path.path_join(fn)
		if not FileAccess.file_exists(src):
			var cdst := _vid_cache_path(dir_path, fn)
			if FileAccess.file_exists(cdst):
				_build_video(vd, cdst, cdst)  # 源已删（转码后清理），直接用缓存
			else:
				print("QA-VID missing ", fn)
			continue
		var ext := fn.get_extension().to_lower()
		if ext == "ogv":
			_build_video(vd, src, src)
		elif ext in ["mp4", "webm", "mkv", "avi", "mov"]:
			var dst := _vid_cache_path(dir_path, fn)
			if FileAccess.file_exists(dst):
				_build_video(vd, dst, src)
			else:
				_start_xcode(src, dst, vd)
	print("QA-VID n=", vids.size(), " live=", _vids.size(), " xcode=", _vid_xcode.size())

func _vid_cache_path(dir_path: String, fn: String) -> String:
	# 可写探测（4.7 无 DirAccess.is_writable）：res:// 导出包只读。探测用临时名，绝不碰已转码缓存！
	var probe := dir_path.path_join(".wtest.tmp")
	var pw := FileAccess.open(probe, FileAccess.WRITE)
	if pw != null:
		pw.close()
		DirAccess.remove_absolute(probe)
		return dir_path.path_join(fn.get_basename() + ".ptn2.ogv")
	var cd := "user://vid_cache/" + dir_path.md5_text()
	DirAccess.make_dir_recursive_absolute(cd)
	return cd.path_join(fn.get_basename() + ".ogv")

func _start_xcode(src: String, dst: String, vd: Dictionary) -> void:
	if OS.execute("ffmpeg", PackedStringArray(["-version"]), [], false) != 0:
		print("QA-VID no ffmpeg, skip ", src)
		return
	# 原子写：输出 .part.ogv（ffmpeg 按扩展名选封装，纯 .part 会 "Unable to choose an output format"），
	# 成功退出后轮询处改名转正——中断留下的半截文件永不被视为缓存
	var part := dst.trim_suffix(".ogv") + ".part.ogv"
	# 上次转码可能在游戏退出后才完成（cmd 子进程存活）：part 有效就直接转正，不重来
	if FileAccess.file_exists(part):
		var pdur: float = _vid_probe(part)[2]
		if pdur > 0.01:
			DirAccess.remove_absolute(dst)
			DirAccess.rename_absolute(part, dst)
			_build_video(vd, dst, src)
			return
	var vh := int(vd.get("xcodeHeight", 540))
	if vh < 120:
		vh = 540
	var vq := clampi(int(vd.get("xcodeQuality", 6)), 1, 10)
	for stale in [dst, part, part + ".log"]:
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(stale)
	# 注意两个 Windows 坑：① OS.create_process 不给含空格参数加引号（"Designant. (Release)"
	# 被拆碎，ffmpeg 秒退）；② OS.execute 在工作线程里 rc=-22/挂死。
	# 解法：cmd.exe /c 单串命令行（自己加引号），输出重定向到日志文件，轮询 pid。
	# 滤镜用 force_original_aspect_ratio（≤960×540），避开 if() 表达式的逗号转义问题。
	var glog := ProjectSettings.globalize_path(part + ".log")
	var cmdline := "ffmpeg -hide_banner -loglevel error -y -i \"" + ProjectSettings.globalize_path(src) \
		+ "\" -an -c:v libtheora -q:v " + str(vq) + " -vf scale=-2:" + str(vh) + " \"" \
		+ ProjectSettings.globalize_path(part) + "\" > \"" + glog + "\" 2>&1"
	var pid := OS.create_process("cmd.exe", PackedStringArray(["/c", cmdline]), false)
	if pid <= 0:
		print("QA-VID spawn failed ", src)
		return
	_vid_xcode.append({"pid": pid, "src": src, "dst": dst, "part": part, "vd": vd, "log": part + ".log"})

func _build_video(vd: Dictionary, ogv_path: String, src_path: String) -> void:
	var meta := _vid_probe(ogv_path)
	var smeta := _vid_probe(src_path) if src_path != ogv_path else meta
	# 无效缓存：探不到时长，或与源时长差 >1s（中断的半截文件头部可能完好）
	if meta[2] <= 0.01 or (smeta[2] > 0.01 and absf(meta[2] - smeta[2]) > 1.0):
		DirAccess.remove_absolute(ogv_path)
		push_warning("vid cache invalid, re-xcode: " + ogv_path)
		_start_xcode(src_path, ogv_path, vd)
		return
	var vs := load(ogv_path) as VideoStreamTheora
	if vs == null:
		print("QA-VID load fail ", ogv_path)
		return
	var tv: Variant = vd.get("time", [0, 0, 1])
	var beats: float = 0.0
	if typeof(tv) == TYPE_ARRAY and tv.size() >= 3:
		beats = float(tv[0]) + (float(tv[1]) / float(tv[2]) if float(tv[2]) != 0.0 else 0.0)
	else:
		beats = float(tv)
	var vp := VideoStreamPlayer.new()
	vp.stream = vs
	vp.autoplay = false
	vp.expand = true
	vp.loop = false
	vp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vp.visible = false
	_vid_host.add_child(vp)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 1)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vp.add_child(dim)  # 遮罩随视频变换（player overlay 与视频同位同尺寸）
	var att: Variant = vd.get("attach", null)
	var has_mask: bool = att != null and (int((att as Dictionary).get("scaleXMode", 0)) in [2, 3]
			or int((att as Dictionary).get("scaleYMode", 0)) == 2)
	if has_mask:
		# 遮罩材质建谱时预建：起播帧才现编译 shader 会在视频窗口开始处掉一帧（FPS 单谷帮凶）
		var msh := Shader.new()
		msh.code = VID_MASK_SHADER
		var mmat := ShaderMaterial.new()
		mmat.shader = msh
		vp.material = mmat
	# 预热首帧解码（Theora 打开容器+解关键帧挪到加载期，避开演出高峰）
	vp.stream_position = 0.0
	if bool(vd.get("removeSource", false)) and src_path != ogv_path 			and FileAccess.file_exists(src_path):
		DirAccess.remove_absolute(src_path)
		print("QA-VID source removed after xcode ", src_path)
	_vids.append({"vp": vp, "dim": dim, "data": vd, "start": _cp.beat_to_sec(beats),
		"dur": meta[2], "sw": maxf(meta[0], 1.0), "sh": maxf(meta[1], 1.0),
		"att": att if typeof(att) == TYPE_DICTIONARY else null})

## 4.7 VideoStreamTheora 不暴露宽高/时长：ffprobe 一次拿 [w, h, dur]
func _vid_probe(path: String) -> Array:
	var out: Array[String] = []
	var rc := OS.execute("ffprobe", PackedStringArray(["-v", "error", "-select_streams", "v:0",
		"-show_entries", "stream=width,height", "-show_entries", "format=duration",
		"-of", "default=nw=1:nk=1", ProjectSettings.globalize_path(path)]), out, false)
	if rc == 0 and not out.is_empty():
		# OS.execute 把整段 stdout 作单个元素返回（含 \r\n）——按行拆
		var lines := out[0].split("\n", false)
		if lines.size() >= 3:
			return [float(String(lines[0]).strip_edges()), float(String(lines[1]).strip_edges()),
					float(String(lines[2]).strip_edges())]
	push_warning("vid probe failed: " + path + " rc=" + str(rc) + " out=" + str(out))
	return [0.0, 0.0, 0.0]

func _sync_videos() -> void:
	var i := _vid_xcode.size() - 1
	while i >= 0:
		var x: Dictionary = _vid_xcode[i]
		if OS.is_process_running(int(x["pid"])):
			i -= 1
			continue
		_vid_xcode.remove_at(i)
		var part := String(x["part"])
		var dst := String(x["dst"])
		if FileAccess.file_exists(part):
			DirAccess.rename_absolute(part, dst)
			_build_video(x["vd"], dst, String(x["src"]))
		else:
			print("QA-VID xcode failed ", x["src"], " log=",
					FileAccess.get_file_as_string(String(x["log"])).left(200))
		if FileAccess.file_exists(String(x["log"])):
			DirAccess.remove_absolute(String(x["log"]))
		i -= 1
	if _vids.is_empty():
		return
	var cx := size.x * 0.5
	var cy := size.y * 0.5
	for v in _vids:
		var t := _clock - float(v["start"])
		var on: bool = t >= 0.0 and t < float(v["dur"])
		var vp: VideoStreamPlayer = v["vp"]
		var dim: ColorRect = v["dim"]
		if _viddbg:
			print("QA-VIDDBG clock=", _clock, " start=", float(v["start"]), " dur=", float(v["dur"]),
					" t=", t, " on=", on, " pos=", vp.stream_position, " playing=", vp.is_playing())
		vp.visible = on
		if not on:
			if vp.is_playing():
				vp.stop()
			continue
		var sw := float(v["sw"])
		var sh := float(v["sh"])
		var sx := size.x / sw
		var sy := size.y / sh
		var mode := String(v["data"].get("scale", "cropCenter"))
		if mode == "inside":
			var s2 := minf(sx, sy)
			sx = s2
			sy = s2
		elif mode != "fit":
			var s1 := maxf(sx, sy)
			sx = s1
			sy = s1
		var pos := Vector2(cx, cy)
		var rot := 0.0
		var scl := Vector2(1, 1)
		var mask: Variant = null  # Vector2(可见宽, 可见高) px，vp 局部
		var tint_f := 1.0
		var att: Variant = v["att"]
		if att != null:
			var st: Dictionary = _cp.get_line_state(int(att.get("line", -1)))
			if not st.is_empty():
				var fx := float(att.get("positionXFactor", 1.0))
				var fy := float(att.get("positionYFactor", 1.0))
				pos = Vector2(cx + (float(st["x"]) - cx) * fx, cy + (float(st["y"]) - cy) * fy)
				rot = float(st["rot"]) * float(att.get("rotationFactor", 1.0))
				tint_f = float(att.get("tintFactor", 1.0))
				var sxm := int(att.get("scaleXMode", 0))
				var sym := int(att.get("scaleYMode", 0))
				if sxm == 1:
					scl.x = float(st["sx"])
				if sym == 1:
					scl.y = float(st["sy"])
				if sxm == 2 or sxm == 3 or sym == 2:
					var mw := sw * sx
					var mh := sh * sy
					if sxm == 2:
						mw = float(st["w"])
					elif sxm == 3:
						mw = sw * sx * float(st["sx"])
					if sym == 2:
						mh = sh * sy * float(st["sy"])
					mask = Vector2(mw, mh)
		var w := sw * sx
		var h := sh * sy
		vp.pivot_offset = Vector2(w, h) * 0.5
		vp.position = pos - Vector2(w, h) * 0.5
		vp.size = Vector2(w, h)
		vp.rotation = rot
		vp.scale = scl
		# alpha：player update() 在 attach 之后写 → 数据 alpha（或事件）为最终值（alphaFactor 被覆盖）
		# tintFactor：0→白（不染色）；1→线色（Stage A 未接线染色，两者视觉同为原色）
		var av: Variant = v["data"].get("alpha", 1.0)
		vp.modulate = Color(1, 1, 1, 1)
		vp.modulate.a = _vid_value(av, t) if typeof(av) == TYPE_ARRAY else float(av)
		var dv: Variant = v["data"].get("dim", 0.0)
		dim.color.a = _vid_value(dv, t) if typeof(dv) == TYPE_ARRAY else float(dv)
		if mask != null:
			var m: ShaderMaterial = vp.material as ShaderMaterial
			if m == null:
				var sh2 := Shader.new()
				sh2.code = VID_MASK_SHADER
				m = ShaderMaterial.new()
				m.shader = sh2
				vp.material = m
			m.set_shader_parameter("mask_rect", Rect2(
				Vector2(0.5 - mask.x / (2.0 * w), 0.5 - mask.y / (2.0 * h)),
				Vector2(0.5 + mask.x / (2.0 * w), 0.5 + mask.y / (2.0 * h))))
		else:
			vp.material = null
		if _paused or record_mode:
			# 4.7 无 pause()、play() 不带起点：停止态先摆位再播（保持播放 + 每帧漂移回拽 ≈ 定格）
			# 录制态也走这条：离线逐帧时内容钟与墙钟不成比例，"自由播放+漂移纠偏"必然错位，
			# 只能每帧硬定位（Theora 回关键帧重解很贵，但这是正确性的代价）
			vp.stream_position = t
			if not vp.is_playing():
				vp.play()
		else:
			# player 语义：进窗 resume 后自由播放不 seek。Theora 回关键帧重解很贵，
			# 游玩中每帧漂移纠偏（旧 0.3s 阈值）= 周期性掉帧尖谷（用户 FPS 图实证）。
			# 只在大偏移（拖进度条/换档）才硬定位；小漂移交给音视频各自时钟。
			if not vp.is_playing():
				vp.stream_position = t
				vp.play()
			elif absf(vp.stream_position - t) > 1.5:
				vp.stream_position = t

## 事件数组 → 秒值（player VariableAnimator：事件时间为拍，换算在 C++ _parse_ext 内完成）
func _vid_value(evs: Variant, _t: float) -> float:
	if typeof(evs) != TYPE_ARRAY or evs.is_empty():
		return 0.0
	return _cp.eval_events(evs, _clock)

func _update_hud() -> void:
	var combo: int = _cp.get_combo()
	var auto: bool = _cp.get_autoplay()
	if combo != _hud_combo or auto != _hud_auto:
		_hud_combo = combo
		_hud_auto = auto
		_lbl_combo.text = str(combo)
		_lbl_combo.visible = combo >= 3
		# PT Loop.ts:267 combo2 = playConfig.mode=="preview" ? "PREVIEW" : "COMBO"：
		# 自动游玩时数字和显隐门（combo>2）都不动，只有标签换成 PREVIEW
		_lbl_combo_tag.text = "PREVIEW" if auto else "COMBO"
		_lbl_combo_tag.visible = combo >= 3
	var sc: int = _cp.get_score()
	if sc != _hud_score:
		_hud_score = sc
		_lbl_score.text = "%07d" % sc
	var acc := "%.2f%%" % (_cp.get_accuracy() * 100.0)
	if acc != _hud_acc:
		_hud_acc = acc
		_lbl_acc.text = acc
	var dur: float = maxf(_cp.get_duration(), 1.0)
	var prog: float = clampf(_clock / dur, 0.0, 1.0)
	# 进度条不缩放贴图，只滑动（player 同式）：右端=进度点，整条宽度恒=屏宽。
	# 位移不足 1px 不重设（TextureRect 改 position 会连带重算画布，60fps 下白耗）
	_hud_prog = prog
	var bx: float = (prog - 1.0) * size.x
	if absf(bx - _hud_barw) >= 1.0:
		_hud_barw = bx
		_bar.position.x = bx

## Android 返回键用（game._back_pressed 调）：游玩中按一下=进 PT 暂停层。
## 3-2-1 倒数期间不打断——那段时间暂停层正收着，插进去会把倒数和层状态搅乱。
func request_pause() -> void:
	if _cd_busy or _paused:
		return
	_toggle_pause()

func _toggle_pause() -> void:
	_paused = not _paused
	# 进暂停前先把手指全部放开：_input_body 在 _paused 时早退，正在按着的那根**永远收不到
	# up**，槽里就留下 down/blocked —— 表现是 hold 断、以及噪域低通一直压着（"没声音"）。
	if _paused:
		_release_all_touches()
	if _audio != null:
		_audio.stream_paused = _paused
	_pm_show(_paused)

## 把 GDScript 侧登记的触点全量交还原生（并清表）。暂停/切后台/重开都用这一条。
func _release_all_touches() -> void:
	if _cp == null:
		_touches.clear()
		return
	for k in _touches.keys():
		_cp.touch_up(_touches[k])
	_touches.clear()

## ───────── 暂停层：PhiTogether 1:1 复刻 ─────────
## 用户要求"一模一样"，故放弃 player 的闪光式双击，全部按 PT 源码取规格：
## · 触发：左上角暂停键 300ms 内连点两下（SpecialClick.ts:59-66 `click()`：
##   `now - time[id] < 300` 才执行，第一下只记时间、**没有任何视觉反馈**）
## · 画面：定格 + 其上叠纯黑 alpha 0.6（Drawer.ts:510-527）；点"继续"后
##   0.6→0 用 easeOutCubic 走 2000ms（pauseBackgroundDimPara1=performance.now()）
## · 三枚**纯图标**按钮水平一行、垂直中心都压在 hlen 上（Drawer.ts:590-612）：
##   imgX(n)=wlen+S·(2n−0.5)、imgBaseLine(n)=hlen−n·S/2，
##   Back(return.png, imgX(-1.1), 1.5S) / Retry(replay.png, imgX(0), 1.25S) /
##   Resume(play.png, imgX(1), 1.5S)；无文字、无边框、无 hover 态
## · 左侧 6 行判定统计 + DSP/AVG + 左上时间（Drawer.ts:530-578），字号 0.4S，
##   配色 Perfect #f0ed69 / Good·Early·Late #0ac3ff / Bad #fe7b93 / Miss #999
## · 继续 = 中央 2S 大白字 3→2→1（Drawer.ts:710-721），倒计时期间三按钮不画
##   （Drawer.ts:529 的 `if (!pauseTime)` 门）；autoplay/preview 无倒计时
## · Retry = 重载 + 统计清零（playerMain.js:605-609 → PlayController.startOver），
##   立刻开跑不再倒数；Back = 直接回上一屏，两者都**没有二次确认弹窗**
## 尺寸基准 S = PT 的 lineScale（renderer/index.ts:105-112）：
## 横屏取 高/18.75，竖屏取 宽/14.0625。
func _pt_scale() -> float:
	return size.y / 18.75 if size.x > size.y * 0.75 else size.x / 14.0625

func _pm_label() -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", UiTokens.install_font())
	add_child(l)
	return l

func _pm_icon(path: String, cb: Callable) -> Button:
	var b := Button.new()
	b.icon = load(path)
	b.expand_icon = true
	b.flat = true  # PT 的按钮就是裸图标：无背景/无边角/无 focus 框
	b.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(cb)
	add_child(b)
	return b

func _build_pause_menu() -> void:
	# 同一个舞台二次 open()（换曲/重开）时，这里原来只往里 append，不拆旧的：
	# 旧控件留在树上、数组翻倍，_refresh_pause_stats 按下标取 vals[i] 就 Out of bounds。
	if _pm_dim != null and is_instance_valid(_pm_dim):
		_pm_dim.queue_free()
	for l in [_pm_time, _pm_dsp, _pm_avg, _pm_back, _pm_retry, _pm_resume]:
		if l != null and is_instance_valid(l):
			l.queue_free()
	for l in _pm_lbl_name:
		(l as Node).queue_free()
	for l in _pm_lbl_val:
		(l as Node).queue_free()
	_pm_lbl_name.clear()
	_pm_lbl_val.clear()
	_pm_dim = ColorRect.new()
	_pm_dim.color = Color(0, 0, 0, 0.6)
	_pm_dim.z_index = 94
	_pm_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pm_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pm_dim.visible = false
	add_child(_pm_dim)
	_pm_time = _pm_label()
	_pm_time.z_index = 95
	for i in PT_COMBO_TEXTS.size():
		var nl := _pm_label()
		nl.text = PT_COMBO_TEXTS[i]
		nl.z_index = 95
		nl.add_theme_color_override("font_color", Color(PT_COMBO_COLORS[i]))
		var vl := _pm_label()
		vl.z_index = 95
		vl.add_theme_color_override("font_color", Color(PT_COMBO_COLORS[i]))
		_pm_lbl_name.append(nl)
		_pm_lbl_val.append(vl)
	_pm_dsp = _pm_label()
	_pm_dsp.z_index = 95
	_pm_avg = _pm_label()
	_pm_avg.z_index = 95
	_pm_back = _pm_icon("res://assets/icons/pt/return.png", _pm_exit)
	_pm_retry = _pm_icon("res://assets/icons/pt/replay.png", _pm_restart)
	_pm_resume = _pm_icon("res://assets/icons/pt/play.png", _pm_continue)
	for b in [_pm_back, _pm_retry, _pm_resume]:
		(b as Control).z_index = 95
	_cd_lbl = _pm_label()
	_cd_lbl.z_index = 96
	_cd_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cd_lbl.visible = false
	## PT 里这一整层都在 `if (pauseTime !== undefined || paused)` 门内，开打时什么都没有。
	## 只关按钮的话左上时间行/六行统计/DSP/AVG 会留在屏幕上——必须整层一起关。
	_pm_set_info(false)

## 三枚图标按钮只在"暂停且没在倒数"时画（Drawer.ts:528-529）
func _pm_set_buttons(v: bool) -> void:
	for b in [_pm_back, _pm_retry, _pm_resume]:
		if b != null:
			(b as Control).visible = v

## PT 的 `if (!pauseTime)` 门（Drawer.ts:529 起整个块）把三按钮、左上时间行、
## 六行判定统计、DSP/AVG **一起**藏掉——倒数时屏幕上只剩中央那个大数字。
func _pm_set_info(v: bool) -> void:
	_pm_set_buttons(v)
	_pm_set_detail(v)

## 判定详细那一块：左上时间行 + 六行判定统计 + DSP/AVG。
## 设置页「暂停详细」只关这一层——**三枚按钮绝不能跟着关**，
## 否则关了之后暂停屏既不能继续也不能退出（--qapause 实测抓到过一次）。
func _pm_set_detail(v: bool) -> void:
	if _pm_time != null:
		_pm_time.visible = v
	for l in _pm_lbl_name:
		(l as Control).visible = v
	for l in _pm_lbl_val:
		(l as Control).visible = v
	if _pm_dsp != null:
		_pm_dsp.visible = v
	if _pm_avg != null:
		_pm_avg.visible = v

func _layout_pause_menu() -> void:
	if _pm_back == null or size.x <= 0.0:
		return
	var sc := _pt_scale()
	var wl := size.x * 0.5
	var hl := size.y * 0.5
	var fnt := UiTokens.install_font()
	var f: Font = fnt
	# 三枚图标：几何完全照 Drawer.ts:590-612
	var bx: Array = [wl + sc * (2.0 * -1.1 - 0.5), wl + sc * (2.0 * 0.0 - 0.5),
			wl + sc * (2.0 * 1.0 - 0.5)]
	var bs: Array = [sc * 1.5, sc * 1.25, sc * 1.5]
	var btns: Array = [_pm_back, _pm_retry, _pm_resume]
	for i in 3:
		var b: Button = btns[i]
		b.size = Vector2(bs[i], bs[i])
		b.position = Vector2(bx[i], hl - bs[i] * 0.5)
	# 文字统一 0.4S（PT 的时间/统计字号），倒计时 2S
	var fs := maxi(int(sc * 0.4), 11)
	var cds := maxi(int(sc * 2.0), 40)
	_pm_time.add_theme_font_size_override("font_size", fs)
	_pm_dsp.add_theme_font_size_override("font_size", fs)
	_pm_avg.add_theme_font_size_override("font_size", fs)
	_cd_lbl.add_theme_font_size_override("font_size", cds)
	var th: float = f.get_ascent(fs) + f.get_descent(fs)
	# 左上时间：PT 画在 (0.05S, 0.35S) 且 baseline=middle
	_pm_time.position = Vector2(sc * 0.05, sc * 0.35 - th * 0.5)
	_pm_time.size = Vector2(sc * 6.0, th)
	# 6 行统计：label x=0.05S、value x=1.75S、y = hlen + S·(idx−2.8)·0.5
	for i in _pm_lbl_name.size():
		var cy := hl + sc * (float(i) - 2.8) * 0.5
		var nl: Label = _pm_lbl_name[i]
		var vl: Label = _pm_lbl_val[i]
		nl.add_theme_font_size_override("font_size", fs)
		vl.add_theme_font_size_override("font_size", fs)
		nl.position = Vector2(sc * 0.05, cy - th * 0.5)
		nl.size = Vector2(sc * 1.65, th)
		vl.position = Vector2(sc * 1.75, cy - th * 0.5)
		vl.size = Vector2(sc * 1.6, th)
	_pm_dsp.position = Vector2(sc * 0.05, hl + sc * 2.6 - th * 0.5)
	_pm_dsp.size = Vector2(sc * 6.0, th)
	_pm_avg.position = Vector2(sc * 0.05, hl + sc * 3.1 - th * 0.5)
	_pm_avg.size = Vector2(sc * 6.0, th)
	# 中央倒计时：fillText(pauseTime, W/2, H/2) + center/middle
	var cth: float = f.get_ascent(cds) + f.get_descent(cds)
	_cd_lbl.size = Vector2(size.x, cth)
	_cd_lbl.position = Vector2(0.0, hl - cth * 0.5)
	_refresh_pause_stats()

func _pt_time(t: float) -> String:
	var neg := t < 0.0
	var a := absf(t)
	var m := int(a) / 60
	var sec := int(a) % 60
	return "%s%02d:%02d" % ["-" if neg else "", m, sec]

func _refresh_pause_stats() -> void:
	if _cp == null or _pm_time == null:
		return
	_pm_time.text = "%s/%s(Paused)" % [_pt_time(_clock), _pt_time(_cp.get_duration())]
	var vals: Array = [_cp.get_perfect(), _cp.get_good(), _cp.get_good_early(),
			_cp.get_good_late(), _cp.get_bad(), _cp.get_miss()]
	for i in _pm_lbl_val.size():
		(_pm_lbl_val[i] as Label).text = str(int(vals[i]))
	_pm_dsp.text = "DSP:  %d" % roundi(_cp.get_avg_delta_ms())
	_pm_avg.text = "AVG:  %d" % roundi(_cp.get_std_dev_ms())

## 暂停层的显示/隐藏：PT 是"黑幕 + 三按钮 + 统计"一起进出，没有淡入动画
func _pm_show(v: bool) -> void:
	if _pm_dim == null:
		return
	if is_instance_valid(_dim_tween):
		_dim_tween.kill()
		_dim_tween = null
	_pm_dim.visible = v
	_pm_dim.color = Color(0, 0, 0, 0.6)
	# 暂停详细（设置页「通用」）：只收判定/时间那一块，三枚按钮永远在
	_pm_set_info(v)
	_pm_set_detail(v and pause_detail)
	if v:
		_refresh_pause_stats()

## 触发：300ms 内两下才暂停（PT SpecialClick.click()）
func _on_pause_tap() -> void:
	if _cd_busy:
		return
	var now := Time.get_ticks_msec()
	if now - _ptap_ms < 300:
		_ptap_ms = 0
		_toggle_pause()
	else:
		_ptap_ms = now  # PT：第一下只记时间，不做任何反馈

func _pm_exit() -> void:
	# PT func[4]：hitManager.clear() + $router.back()，没有二次确认
	set_process_input(false)
	finished.emit()

func _pm_restart() -> void:
	# PT func[1]：pause() → retry()（genPlayToken + recordMgr.reset + 统计清零）
	# → startOver()（Stop→Play，立刻从头开跑，不再走 3-2-1）
	_cp.reset_play_state()
	_clock = 0.0
	_clock_last = 0.0
	if _audio != null and _audio.stream != null:
		_audio.stream_paused = false
		_audio.stop()
		_audio.play(0.0)
		_audio_started = true
		_pos_watch_reset(0.0)
	_cp.set_now(0.0)
	_update_hud()
	_cd_busy = false
	_cd_lbl.visible = false
	_paused = false
	_pm_show(false)

## 继续：PT 的 3 秒倒数——黑幕 2000ms easeOutCubic 淡出、中央 3→2→1、三按钮先隐藏
func _pm_continue() -> void:
	if _cp.get_autoplay():
		_cd_finish()  # PT preview/autoplay 分支：无倒数
		return
	_cd_busy = true
	_cd_n = 3
	_pm_set_info(false)
	_cd_lbl.visible = true
	if is_instance_valid(_dim_tween):
		_dim_tween.kill()
	_dim_tween = create_tween()
	_dim_tween.tween_property(_pm_dim, "color:a", 0.0, 2.0) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tick_cd()

func _tick_cd() -> void:
	if not _cd_busy:
		return
	if _cd_n <= 0:
		_cd_finish()
		return
	_cd_lbl.text = str(_cd_n)
	_refresh_pause_stats()
	_cd_n -= 1
	get_tree().create_timer(1.0).timeout.connect(_tick_cd)

func _cd_finish() -> void:
	_cd_busy = false
	_cd_n = 0
	_cd_lbl.visible = false
	_pm_show(false)
	resume_live()  # 解 _paused + 把音频对到当前时钟（暂停后必须走这条）

var _hits_last_frame := 0  # QA 诊断：本帧命中批大小（压力谱卡顿定位）
var _hit_cap := 12 if OS.has_feature("mobile") else 24  # 每帧音效播放封顶（手机音频驱动更慢）

## 切后台/失焦（接电话、下拉通知栏、Android 手势挂起）：正在按着的手指往往**不会**再收到
## up——原生槽里就留着 down/blocked，回来以后 hold 直接断、噪域感染锁卡死
## （blocked_touch_count() 恒 >0 → 音乐一直压在 1500Hz）。统一交还一次。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(_cp):
		_release_all_touches()

func _input(ev: InputEvent) -> void:
	if record_mode:
		return  # 录制期间零输入：暂停/退出/F12 都不该发生，更不该被录进片子里
	# F12：线/音符序号调试层（只读原生当前帧位姿，不改任何状态；见 debug_overlay.gd）
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F12:
		if is_instance_valid(_dbg):
			_dbg.visible = not _dbg.visible
			print("QA-DBG F12 序号层=", _dbg.visible)
		return
	# 舞台现在只是屏幕中间那块 ≤16:9 的画布，事件坐标是视口系的 → 平移+缩放进画布系。
	# 判定和离屏 GUI（_csv 里的暂停钮等）都在画布系里算，两边都得用换算后的事件。
	# 门控必须同时看 _k：竖屏/4:3 上画布占满整宽，position 就是 (0,0)，只判位置会把
	# 逻辑坐标原样喂进设备像素的画布 → 越往右偏得越多（用户实测"右边无法判定"，
	# PC 上 --resolution 2700x1800 复现：和弦两条一条 Good 一条 Miss）。
	var local_ev := ev
	if position.x != 0.0 or position.y != 0.0 or _k != 1.0:
		local_ev = _shift_event(ev)
	_input_body(local_ev)
	if _csv != null:
		_csv.push_input(local_ev)  # 内容已挪进离屏层：GUI（暂停钮等）需手动喂事件（坐标同系）
	# HUD 部件被 targetRange 单元认领时（player 语义：透明了也仍可点）：镜像空间换 y 转发
	if is_instance_valid(_btn_pause):
		for u in _units:
			if not u["busy"]:
				continue
			var mc: Control = u["mc"]
			if not mc.is_ancestor_of(_btn_pause):
				continue
			var e2 := ev.duplicate()
			if e2 is InputEventMouseButton or e2 is InputEventMouseMotion \
					or e2 is InputEventScreenTouch or e2 is InputEventScreenDrag:
				e2.position = Vector2(e2.position.x, size.y - e2.position.y)
				if e2 is InputEventMouseButton or e2 is InputEventMouseMotion:
					e2.global_position = e2.position
				(u["sv"] as SubViewport).push_input(e2)

## 只平移鼠标/触屏类事件的 position（其它事件原样返回）。返回新对象，
## 不改原事件——那是 Viewport 还在用的输入帧数据。
func _shift_event(ev: InputEvent) -> InputEvent:
	var e: InputEvent = ev.duplicate()
	# 根视口给的是逻辑坐标，舞台内部是逻辑×_k（见 _fit_play_rect），所以减完位置还要乘回来
	var p := position
	var k := _k
	if e is InputEventScreenTouch:
		e.position = ((e as InputEventScreenTouch).position - p) * k
	elif e is InputEventScreenDrag:
		e.position = ((e as InputEventScreenDrag).position - p) * k
	elif e is InputEventMouseButton:
		e.position = ((e as InputEventMouseButton).position - p) * k
		e.global_position = ((e as InputEventMouseButton).global_position - p) * k
	elif e is InputEventMouseMotion:
		e.position = ((e as InputEventMouseMotion).position - p) * k
		e.global_position = ((e as InputEventMouseMotion).global_position - p) * k
	return e

func _input_body(ev: InputEvent) -> void:
	if _cp == null:
		return
	# 只有按键/鼠标键事件才可能匹配 action——对每个 mouse motion 做 is_action_pressed
	# 是全量 action 注册的白扫描（1000Hz+ 鼠标 = 每秒上千次，帧尾抖动来源）
	if (ev is InputEventKey or ev is InputEventMouseButton) and ev.is_action_pressed("ui_cancel"):
		# Android 的返回键除了 go_back_requested/通知之外**还会顺手发来一个 ui_cancel**。
		# 手机上返回的语义由 game._back_pressed 定（游玩中=先暂停），这里必须让路，
		# 否则一次返回 = 暂停 + 拆台两件事，表现就是"滑动返回直接崩溃/直接退出"。
		# 桌面端没有这个问题，Esc = 退出本局照旧。
		if _is_mobile:
			return
		set_process_input(false)
		finished.emit()
		return
	if _paused:
		return
	if ev is InputEventScreenTouch:
		_saw_touch = true
		var evi := (ev as InputEventScreenTouch).index
		var p := (ev as InputEventScreenTouch).position
		# 触点槽 = Android/Linux 的 pointer index 本身（player PointerHandler 直接用
		# Phaser 的 pointer.id，一个接触一个 Finger）。此前这里是"每次按下铸造一个新 id、
		# 池子只增不回收"，累计 14 次后 _next_id 永远返回 14 → 手机上所有手指共用
		# _fingers[14]：多押时后落的手指覆盖前一根的落点（其余音符没人认领→Miss/Bad 连坐），
		# 两根手指分别按两条 hold 时先松的那根把共享槽 down=false，另一条当场断。
		# 原生只有 16 槽（0..15），15 号留给鼠标，所以 index 钳到 0..14。
		if evi < 0 or evi > 14:
			return
		if (ev as InputEventScreenTouch).pressed:
			# 同一个 index 连来两个 down = 上一个 up 没送到（暂停早退、切后台、Android 丢事件）。
			# 先补一次 up 再按：槽里不会带着上一根的感染锁进这一按，
			# 否则 blocked_touch_count() 永远 >0，噪域低通一直压着 1500Hz=听感"没声音"。
			if _touches.has(evi):
				_cp.touch_up(_touches[evi])
			_touches[evi] = evi
			_cp.touch_down(evi, p)
		elif _touches.has(evi):
			_cp.touch_up(_touches[evi])
			_touches.erase(evi)
	elif ev is InputEventScreenDrag and _touches.has((ev as InputEventScreenDrag).index):
		_cp.touch_move(_touches[(ev as InputEventScreenDrag).index], (ev as InputEventScreenDrag).position)
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		# 手机：emulate_mouse_from_touch 必须开着（关了整个 App 的 Control 都不能点），
		# 所以"每下触摸还会再来一个合成鼠标事件"=一点两判是**消不掉**的，只能在判定层挡。
		# 手机没有真鼠标 ⇒ mobile 直接不认鼠标通道；_saw_touch 再兜一层
		# （触屏笔电/我们 QA 里推的 ScreenTouch 之后，鼠标也不该再进判定）。
		if _is_mobile or _saw_touch:
			return
		# 鼠标手指 id=15：原生 _fingers 只有 16 槽（0..15），旧值 99 会被
		# touch_down 的 id>=16 守卫丢弃=鼠标完全不判定（2026-10-05 实证）。
		# 触点槽现在直接用触屏 index 0..14，15 号恒留给鼠标，两者不冲突。
		if ev.pressed:
			if _touches.has("mouse"):
				_cp.touch_up(15)   # 同触屏：漏送的 up 在这里补，槽不带旧感染锁
			_touches["mouse"] = 15
			_cp.touch_down(15, ev.position)
		elif _touches.has("mouse"):
			_cp.touch_up(15)
			_touches.erase("mouse")
	elif ev is InputEventMouseMotion and _touches.has("mouse"):
		_cp.touch_move(15, ev.position)

# 触点槽映射：直接用 InputEventScreenTouch.index（0..14），15=鼠标专用槽（原生 _fingers
# 共 16 槽）。旧的"每次按下铸造递增 id"方案已删——它只增不回收，累计 14 次后永远返回 14，
# 手机上所有手指塌进同一个槽，多押与双 hold 互踩。

func _on_song_finished() -> void:
	_song_done = true   # 帧率统计到此为止（结算页背景继续跑的不算本局）
	set_process_input(false)
	## PT 进结算第一步就是 audio.stop()（Loop.ts:34），随后 1s 才起 end 计时器放动画
	if _audio != null:
		_audio.stop()
	# 自然打完才入档（Esc 中途退出不记）；PlayRecords 内部只保留最好成绩。
	# PT 的 auto/preview 局不导出成绩（SpecialClick.ts:24 只在 mode!=="preview" 时
	# exportRecord），所以自动游玩打完什么都不写。
	var auto: bool = _cp != null and _cp.get_autoplay()
	var old := {}
	if not auto and record_key != "" and _cp != null:
		old = PlayRecords.get_record(record_key)  # 先取旧最佳：结算页的 NEW BEST/差值靠它
		var new_rec := PlayRecords.save_record(record_key, _cp.get_score(), _cp.get_accuracy(), _cp.get_max_combo())
		print("QA-REC key=", record_key, " score=", _cp.get_score(),
			" acc=%.4f" % _cp.get_accuracy(), " rank=", PlayRecords.RANK_NAMES[PlayRecords.rank_index(_cp.get_score())],
			" best=", new_rec)
	elif auto:
		print("QA-REC skipped(PREVIEW) key=", record_key, " score=", _cp.get_score())
	if _cp != null:
		results_ready.emit(_results_payload(old))

## 结算页数据：全部字段按 PT Stat.getData() + Stat 的 getter 语义算（components/Stat.ts:26-125），
## 数字补零到 7 位、Acc 用全角％、FC 用 FCV 徽章，都是 PT 自己的做法，不另立标准。
func _results_payload(old: Dictionary) -> Dictionary:
	var score := _cp.get_score()
	# PT Stat.ts:107-113：isAuto（自动游玩/预览）走单独一支——历史最佳当作 0000000、
	# 左上角写 PREVIEW、差值写死 +1000000（照抄，不自己换算）
	var auto: bool = _cp.get_autoplay()
	var best := 0 if auto else int(old.get("score", 0))
	var lvl := _meta_or(_cp.get_level(), _info_level, hint_level)
	# PT 的 lineStatus==3 判据是 `bad` getter = noteRank[6]+noteRank[2]，而 [2] 就是 Miss 槽
	# （ResultPage 的 MISS 显示取的正是 [2]）⇒ FC = 无 Bad **且无 Miss**。之前只看了 bad，
	# 结果 0Bad/13Miss 的一局被当成 FC 上了青色 FCV 徽章（应为按分数的白 V）。
	var fc := _cp.get_bad() == 0 and _cp.get_miss() == 0 and _cp.get_good() > 0
	return {
		"name": _meta_or(_cp.get_song_name(), _info_name, hint_name),
		"level": lvl,
		"score_str": "%07d" % score,
		"acc_str": "%.2f％" % (_cp.get_accuracy() * 100.0),
		"max_combo": _cp.get_max_combo(),
		"perfect": _cp.get_perfect(),
		"good": _cp.get_good(),
		"bad": _cp.get_bad(),
		"miss": _cp.get_miss(),
		"early": _cp.get_good_early(),
		"late": _cp.get_good_late(),
		"new_best": "PREVIEW" if auto else ("NEW BEST" if best < score else " "),
		"best_str": "0000000" if auto else ("%07d" % best),
		"delta_str": "+1000000" if auto else (" " if best > score else "+%07d" % absi(best - score)),
		"badge": load("res://assets/ranks/FCV.png") if fc \
				else PlayRecords.rank_cell(PlayRecords.rank_index(score)),
		"bg": _bg.texture if is_instance_valid(_bg) else null,
		"art": _bg_sharp,
		# PT：结算 BGM 按难度取 LevelOver{ez,hd,in,at}_v2，识别不了用 2（Loop.ts:58-72）
		"jingle": "res://assets/sfx/LevelOver%d_v2.ogg" % _level_over_index(lvl),
		# 本局帧率统计（最大/平均/最小）：只有设置页开了「调试模式」才带——
		# 正常玩家不该在结算页看到工程读数
		"fps": fps_stats() if debug_mode else {},
	}

func _level_over_index(lvl: String) -> int:
	var i: int = ["ez", "hd", "in", "at"].find(lvl.left(2).to_lower())
	return i if i >= 0 else 2

func current_note_count() -> int:
	return _cp.get_total_notes() if _cp != null else 0

## 本局的记录键（game.gd 启动前注入；"" = 不记录）
var record_key := ""

## 曲名/难度兜底链：RPE META > 谱包 info.txt > game 注入的服务器 hint（PZ 直下的老 .pe 无 info.txt）
var hint_name := ""
var hint_level := ""
var _info_name := ""
var _info_level := ""
var _info_song := ""     # official sidecar Song:（music.wav 等非 song.* 命名的曲目文件）
var _info_picture := ""  # official sidecar Picture:（illustration.png 已在本管线的 bg 优先级里）

static func _meta_or(a: String, b: String, c: String) -> String:
	for v in [a, b, c]:
		if String(v) != "":
			return String(v)
	return ""

## 谱包元数据：info.txt / info.yml / info.csv 三种都吃（解析本身在 ChartInfo，
## 和选曲卡片共用同一份键名口径）；official 目录还有 <难度>.json 配 <难度>.txt 的 sidecar。
## 只取游玩侧用得上的四项：曲名 / 难度 / 乐曲文件 / 封面文件。
func _read_info(dir_path: String) -> void:
	var im := ChartInfo.read_dir(dir_path)
	var base := dir_path.path_join(chart_file.get_basename() + ".txt") if chart_file != "" else ""
	if base != "":
		# sidecar 比目录级 info 更具体（同名不同难度的包各难度曲名不同）
		var per := ChartInfo.read_file(base)
		for k in per:
			im[k] = per[k]
	if im.is_empty():
		return
	if _info_name == "":
		_info_name = String(im.get("name", ""))
	if _info_level == "":
		_info_level = String(im.get("level", ""))
	if _info_song == "":
		_info_song = String(im.get("song", ""))
	if _info_picture == "":
		_info_picture = String(im.get("picture", ""))

## 触摸特效的第二半：官方把触点表喂给 shader 的 _TouchPos[]（画布 uv×aspect、原点左下），
## 并用 (0.63+0.37×(sin(t×43)×0.5+0.5))×2 做呼吸亮度（block_shader.rs:501-505）。
func _sync_block_touch() -> void:
	if _bmat == null:
		return
	var slots: Array = _cp.debug_touch_slots() if _cp != null else []
	var n: int = mini(slots.size() / 3, 10)
	var asp: float = size.x / max(size.y, 1.0)
	var pts := PackedVector2Array()
	pts.resize(10)
	for i in n:
		pts[i] = Vector2(float(slots[i * 3]) * asp, float(slots[i * 3 + 1]))
	_bmat.set_shader_parameter("uTouchCount", n)
	_bmat.set_shader_parameter("uTouchPos", pts)
	_bmat.set_shader_parameter("uTouchPosShine", (0.63 + 0.37 * (sin(_clock * 43.0) * 0.5 + 0.5)) * 2.0)
