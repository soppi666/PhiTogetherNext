class_name UserPrefs
extends RefCounted
## user://prefs.json 的唯一读写口：设置页（在舞台之外）和游玩中的判定补偿面板共用一份键表。
##
## 为什么单独一层：这份 JSON 原本只在 chart_stage._load_prefs/_save_prefs 里读写，值也长在
## 舞台节点上。设置页要动的是同一批键，两边各写一份 schema 迟早走样（漏一个键=静默丢设置）。
## 这里只管**存什么、默认值、取值范围**；**怎么生效**仍归各自主人：
## 判定窗口/偏移/多押→原生管线，vsync/帧率→引擎与窗口，模糊/亮度/音量/调试层→开谱时读。

const FILE := "user://prefs.json"

## 默认值 = 玩家第一次进游戏看到的行为（改这里等于改全项目的出厂设置，别顺手调）
const DEFAULTS := {
	"line_tex_tint": 0,      # 判定线贴图按判定态染色：0=自动 1=从不 2=总是
	"perfect_ms": 80.0,      # player constants：DEFAULT_PERFECT_JUDGMENT_MS
	"good_ms": 180.0,        # DEFAULT_GOOD_JUDGMENT_MS
	"chart_offset_ms": 0.0,  # player preferences.chartOffset（−600…600 ms）
	"multi_hint": true,      # simultaneousNoteHint（多押高亮）
	"fps_cap": 0,            # Engine.max_fps，0=不限
	"vsync": 0,              # Window.VSyncMode：0=开 1=关 2=宽松
	"hi_res": true,          # 内部分辨率=设备像素（关=逻辑像素，填充量小但放大后发糊）
	"low_res": false,        # F10 低渲染精度预设（render_scale 0.5）
	"autoplay": false,       # 自动游玩（设置页唯一入口；游玩中 combo 标签变 PREVIEW）
	"dbg_overlay": false,    # F12 线/音符序号层的默认开关
	"bg_blur": 1.0,          # player backgroundBlur：模糊半径 = 115·该值 px
	"bg_lum": 0.5,           # player backgroundLuminance：压暗 = 1 − 该值
	"fc_ap": true,           # AP/FC 判定线染色（fcApIndicator）
	# 取景口径：1=注重演出（音符折回编辑器 px 后超出 ±675 制谱器画框的不画，
	# 宽屏不再露出作者看不见的表演元素）；0=注重游玩（框外也照画，宁可看见再判）。
	"frame_cull": 1,
	"music_vol": 1.0,        # 线性 0..1（转 dB 由舞台做）
	"hit_vol": 0.5,          # 打击音音量
	# —— 设置页新增项（每一项都有真实落点，见 SettingsPage._spec_for 的备注）——
	"master_vol": 1.0,       # Master 总线线性音量
	"loud_norm": false,      # 响度标准化：把乐曲测到约 −14 LUFS 后一次性回补增益
	"fps_lock": false,       # 关=只设上限不锁；开=真的把 Engine.max_fps 钉在所选档
	"hdr": false,            # Window.hdr_output_requested（显示器支持时才有效）
	"msaa": 0,               # Viewport.msaa_2d：0=关 1=2X 2=4X 3=8X
	# 噪域掩码网格单元（画布 px）：0=自动（按解析度），4/八/十二 =强制。
	# 成本≈网格面积×可见区数：2560×1600 + 109 区，4px 要 42ms（~57fps）、12px 才能 120fps。
	"block_cell": 0,
	# 噪域掩码走 GPU（zone 加法多边形 → 位移+膨胀 shader → 每帧读回）。
	# 与 CPU 渲染同帧对拍：t=2.0 差 0.09%、t=20 差 0.00%，个别时刻 ~9%（待查）。
	# ⚠ hover 必须单独一张纹理：aux 是预乘贴图（alpha 恒 1），读它的 .a 会让整屏"手指按着"。
	# 暂关：GPU 掩码在官方谱（千万级 blockArea）上只有 ~10fps——每帧 debug_blocks() 把每个区都建成 Dictionary，十几万个就是逐帧十几万次分配；而且摇干特效要回退 CPU。要重启得先把四角改成原生数组传输。
	"block_gpu": false,
	"note_scale": 1.0,       # 音符大小（PT noteScale 语义：只缩放贴图，不动位置/判定）
	"fx_scale": 1.0,         # 特效大小（命中特效/粒子；与音符大小同范围）
	"debug_mode": false,     # 游玩中常驻显示帧率/线程读数
	"pause_detail": true,    # 暂停层显示判定详细/时间详细（默认=原有行为）
	# —— 皮肤/资源包（见 skin_pack.gd）——
	"skin_pack": "",         # user://skins 下的包目录名；空串=内置 pack-1
	# —— 渲染录制（见 render_record.gd；主菜单输 REC 也开/关这一项）——
	"render_rec": false,     # 总开关：开=选谱面后离线逐帧渲染成视频，不进场打
	"rec_res": 2,            # 0=720P 1=1080P 2=2K(1440p) 3=4K 4=自定义（默认 1440p）
	"rec_w": 1920,           # 自定义宽（只有 rec_res=4 时读）
	"rec_h": 1080,           # 自定义高
	"rec_fps": 60,           # 30/60/120 三档（离线逐帧，帧率=输出帧率，与实跑帧率无关）
	"rec_mbps": 20,          # 视频码率 Mbps（1…200，用户指定的可调范围）
	"rec_vcodec": 0,         # 0=H264(libx264) 1=H265(libx265)
	"rec_acodec": 0,         # 0=MP3(libmp3lame) 1=AAC —— 都是 ffmpeg 侧的编码，容器固定 mp4
}

## 数值范围：读盘和写盘都过一遍，文件被手改坏也不会把引擎推进非法档位
const RANGE := {
	"perfect_ms": [5.0, 150.0],
	"good_ms": [5.0, 300.0],
	"chart_offset_ms": [-600.0, 600.0],
	"fps_cap": [0, 240],
	"vsync": [0, 2],
	"line_tex_tint": [0, 2],
	"frame_cull": [0, 1],
	"bg_blur": [0.0, 2.0],
	"bg_lum": [0.05, 1.0],
	"music_vol": [0.0, 1.0],
	"hit_vol": [0.0, 1.0],
	"master_vol": [0.0, 1.0],
	"note_scale": [0.8, 1.5],
	"fx_scale": [0.8, 1.5],
	"msaa": [0, 3],
	"rec_res": [0, 4],
	"rec_w": [480, 3840],
	"rec_h": [480, 3840],
	"rec_fps": [1, 240],
	"rec_mbps": [1, 200],
	"rec_vcodec": [0, 1],
	"rec_acodec": [0, 1],
}

static var _d := {}
static var _loaded := false

static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	_d = {}
	for k in DEFAULTS:
		_d[k] = DEFAULTS[k]
	if not FileAccess.file_exists(FILE):
		return
	var txt := FileAccess.get_file_as_string(FILE)
	if txt == "":
		return
	var j: Variant = JSON.parse_string(txt)
	if not (j is Dictionary):
		return
	for k in (j as Dictionary):
		if DEFAULTS.has(k):
			_d[k] = _clamped(k, (j as Dictionary)[k])

## 按默认值的类型收：bool 归 bool，有范围的数字夹进范围，其余数字只做类型转换
static func _clamped(k: String, v: Variant) -> Variant:
	var dflt: Variant = DEFAULTS[k]
	if dflt is String:
		return str(v)   # 字符串键（皮肤包 id）不夹范围，也不许被下面的数字转换吃掉
	if dflt is bool:
		return bool(v)
	if not RANGE.has(k):
		return int(v) if dflt is int else float(v)
	var r: Array = RANGE[k]
	if dflt is int:
		return clampi(int(v), int(r[0]), int(r[1]))
	return clampf(float(v), float(r[0]), float(r[1]))

static func num(k: String) -> float:
	_load()
	return float(_d.get(k, DEFAULTS.get(k, 0.0)))

static func int_of(k: String) -> int:
	_load()
	return int(_d.get(k, DEFAULTS.get(k, 0)))

## prefs 里 vsync 的编号是**产品口径**：0=开 1=关 2=兼容（设置页文案就是这么写的）。
## 引擎 4.7 的枚举在 DisplayServer.VSyncMode：0=DISABLED 1=ENABLED 2=ADAPTIVE 3=MAILBOX。
## 两边 0 和 1 的含义正好相反，而且老代码写的是 `get_window().set("vsync_mode", v)`：
## 4.7 的 Window 已经没有 vsync_mode 这个属性了（extension_api-4-7.json 的 Window 里
## properties/methods 都没有 vsync 字样），set() 于是静默失败。桌面实测证据：
##   window_get_vsync_mode()=1 → Window.set("vsync_mode",0) → 仍然是 1（没动）
##   window_get_vsync_mode()=1 → DisplayServer.window_set_vsync_mode(VSYNC_DISABLED) → 0（动了）
## 所以"垂直同步"这个开关在项目里从来没生效过，而 QA 的排程扫掠里 vsync 那几档也全是假的。
## 统一从这里出一个映射，别再手写数字。
static func vsync_ds(p_pref: int = -1) -> int:
	var v := p_pref if p_pref >= 0 else int_of("vsync")
	match v:
		1:
			return DisplayServer.VSYNC_DISABLED      # 产品口径的"关"
		2:
			return DisplayServer.VSYNC_ADAPTIVE      # "兼容"=自适应（Swappy 按目标帧排程）
		_:
			return DisplayServer.VSYNC_ENABLED       # "开"（默认）

## 把 prefs 里的 vsync 真的写进窗口（4.7 唯一有效的入口是 DisplayServer，不是 Window）
static func vsync_apply() -> int:
	var m := vsync_ds()
	DisplayServer.window_set_vsync_mode(m)
	return m

static func str_of(k: String) -> String:
	_load()
	return String(_d.get(k, DEFAULTS.get(k, "")))

static func flag(k: String) -> bool:
	_load()
	return bool(_d.get(k, DEFAULTS.get(k, false)))

static func set_num(k: String, v: float) -> void:
	_load()
	_d[k] = _clamped(k, v)
	save()

static func set_int(k: String, v: int) -> void:
	_load()
	_d[k] = _clamped(k, v)
	save()

static func set_str(k: String, v: String) -> void:
	_load()
	_d[k] = v
	save()

static func set_flag(k: String, v: bool) -> void:
	_load()
	_d[k] = v
	save()

## 批量写：一次改多项（舞台的 _save_prefs 就是整份回写）时只落盘一次。
## 未知键直接丢——宁可丢，也不要把拼错的键写进文件里当"永久设置"。
static func set_many(vals: Dictionary) -> void:
	_load()
	for k in vals:
		if not DEFAULTS.has(k):
			push_warning("UserPrefs: 未知键 %s 被忽略" % String(k))
			continue
		_d[k] = _clamped(k, vals[k])
	save()

## 判定窗口的耦合下限（G ≥ max(P+5, 1.125P)，见 player Preferences.svelte）由调用方给：
## UserPrefs 不知道"当前 P 是多少"这层业务，只负责夹进硬范围。
static func set_good_ms(v: float, lo: float) -> void:
	set_num("good_ms", maxf(v, lo))

static func save() -> void:
	var s := JSON.stringify(_d)
	var f := FileAccess.open(FILE, FileAccess.WRITE)
	if f != null:
		f.store_string(s)
		f.close()

## 恢复默认：整份键表回到 DEFAULTS（设置页"通用"里那颗按钮用）
static func reset_all() -> void:
	_d = {}
	for k in DEFAULTS:
		_d[k] = DEFAULTS[k]
	save()

## 外部改过文件后（QA 探针还原现场）重读一遍：清掉内存缓存即可，下次取值自动回盘
static func reload() -> void:
	_loaded = false
	_d = {}
