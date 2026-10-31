class_name RenderRecorder
extends Node
## 渲染录制：把一张谱面**离线逐帧**渲染成视频（出厂默认 1080P · 60fps · 20Mbps · H264 + MP3）。
##
## 为什么是"离线逐帧"而不是"边打边录"：录制态下谱面时钟由本类每帧排一步（一步 = 1/输出帧率），
## 判定/特效/噪域/视频层走的还是舞台那条 _process，但**内容时间与墙钟脱钩**——机器快就提前录完
## （加速），机器慢就拖长时间（放慢），成片永远"一帧不落、一帧不重"：帧号 k 就是 k/fps 秒。
## 时钟只在 record_step() 被调用时前进，所以宁可画面停住也不会出现丢帧或重复帧。
##
## 音轨不进这条链：游戏里混出来的声音是按墙钟走的，对不上成片帧号。成片的声音由编码器
## **直接读谱包的 song 文件**（chart_stage.record_begin 把整局静音就是为这个）。
##
## 编码用系统 ffmpeg——Godot 自己不能编码，这和故事版视频转码是同一条依赖
## （见 chart_stage._start_xcode 的 cmd.exe /c + 轮询 pid 那套）。Android 既没有 ffmpeg
## 也不给应用起子进程，所以移动端整条不可用，has_encoder() 直接返回 false（见文件末注）。
##
## 中间产物形态：原始 RGB 帧**分块**落盘（一块 ≈ 上限 256MB，1080P 约 40 帧）→ 每块起一次
## ffmpeg 压成 seg_*.mp4（下一块在渲染，这一块的编码在后台跑）→ 全部完成后 concat 拼起来
## 并挂上音轨 → 落到 video/ 目录，临时目录整个删掉。
## 分块的理由：① 磁盘峰值只有一块（整片原始 1080P60 三分钟 = 67GB，不可接受）；
## ② 中途取消/崩溃已经渲出来的部分还在；③ 编码与渲染重叠，不互相等。

signal finished(info: Dictionary)

## 一块的目标字节上限（原始 RGB24）：1080P 一帧 6.2MB ⇒ ~31 帧一块；4K 一帧 24.9MB ⇒ 7 帧
## 为什么按字节而不是按帧数：磁盘峰值与"写盘能不能藏在渲染背后"都由字节数决定。
const CHUNK_BYTES := 768 * 1024 * 1024
const CHUNK_MIN_FRAMES := 6
const CHUNK_MAX_FRAMES := 120
## 最多几笔写盘挂在后台线程（写盘 1.9ms/帧从主线程挪走 = 直接快 20%+）。
## 实测 2 笔在跑时读回反而慢 0.6ms（磁盘与显存回读抢同一条内存带宽），
## 1 笔已经足够把写完全藏进渲染背后：一块 ~30 帧≈0.9s 的渲染，写盘只要 60ms。
const WRITE_SLOTS := 1
## 中间格式是 rawvideo（不经过任何有损编码），画质只由 x264 码率那一档决定

## 分辨率档位：720P/1080P/2K/4K 是**固定的 16:9**（1280×720 / 1920×1080 / 2560×1440 / 3840×2160），
## 不跟着播放窗口的比例走（用户 2026-10-22 定案：预设默认就是 16:9）。
## 只有"自定义"才是精确像素。离屏画布开成 16:9 后，舞台自己按 16:9 排布，画面不会被拉伸。
const RES_TABLE := [[1280, 720], [1920, 1080], [2560, 1440], [3840, 2160]]
const RES_NAMES := ["720P", "1080P", "2K", "4K", "自定义"]
const VCOPY := ["libx264", "libx265"]
const ACOPY := ["libmp3lame", "aac"]
const A_KBPS := [320, 256]     # mp3 用满 320k；aac 256k（谱面录音够用）

static func size_for(preset: int) -> Vector2i:
	var m := clampi(preset, 0, 4)
	if m < RES_TABLE.size():
		return Vector2i(int(RES_TABLE[m][0]), int(RES_TABLE[m][1]))
	# 自定义：用户给多少就是多少。x264/x265 的 yuv420p 要求宽高都是偶数
	return Vector2i(_even(UserPrefs.int_of("rec_w")), _even(UserPrefs.int_of("rec_h")))

static func target_size() -> Vector2i:
	return size_for(UserPrefs.int_of("rec_res"))

static func _even(v: int) -> int:
	return maxi(2, v - v % 2)

static func res_label() -> String:
	var m := clampi(UserPrefs.int_of("rec_res"), 0, 4)
	var sz := target_size()
	if m < RES_TABLE.size():
		return "%s %d×%d" % [RES_NAMES[m], sz.x, sz.y]
	return "自定义 %d×%d" % [sz.x, sz.y]

var out_path := ""            # 绝对路径（给 ffmpeg / 给用户看的都是它）
var song_path := ""           # 绝对路径；空=只出画面
var frame_limit := 0          # >0 = 只录前 N 帧（QA 用）
var w := 1920
var h := 1080
var fps := 60.0
var mbps := 20
var vcodec := 0
var acodec := 0
var _expect_total := 0        # 本次应渲的帧数（收尾对账用）
## ── 多进程切片 ────────────────────────────────────────────────────────────
## 一张谱切成 K 段：主进程渲第 0 段（就是用户眼前这个窗口，看得见进度），其余段交给
## K-1 个**离屏子进程**。1440P60 下单进程只有 ~66 帧/秒（≈1.1× 实时），而每帧里
## 等 GPU 与"显存→内存"搬运是两条能并行的活，所以切片是唯一能把倍率抬上去的办法。
## 优化点（相对上一版）：① 子进程在**自己开始渲之前**就全部拉起来，加载谱/烘背景与
## 父进程的渲染重叠；② 每段严格按 1/fps 推帧，边界帧与连续跑逐位一致（分数/连击不断档）；
## ③ 子进程只写块+音轨片段+清单，编码统一由父进程按全局帧序做（段号=时间轴）；
## ④ 收尾必须等所有编码落地再拼表（上一版漏了这步，600 帧只出 544）。
var workers := 1
var is_worker := false        # 自己是子进程：只渲自己那段，不编码不合成
var part_tag := "s"           # 块/音轨/清单前缀：s=主进程，w1/w2…=子进程
var slice_from := 0
var slice_to := 0
var tmp_root := ""            # 子进程用父进程建好的临时目录
var dir_path := ""            # 子进程要开哪张谱（目录 / 指定谱文件 / 皮肤包）
var chart_file := ""
var skin_dir := ""
var _wp: Array = []           # 父进程：[{pid,k,done}]
var _worker_frames := 0       # 子进程交回的总帧数（对账用）
var _hw_off := false          # 硬件编码失败过 → 后续全部走软编
var _defer_encode := false     # 并行时把所有块攒到最后按全局帧序压
var _bounds: Array = []        # 本次的分段表
var _failed: Array = []        # 子进程没交活的段 [[k, from, to]]，父进程补渲

var _tmp := ""                # 本次录制的临时目录（工程口径）
var _fa: FileAccess = null    # 当前块常开的文件句柄（一帧一写，不在内存里攒整块）
## 写盘流水线：一帧在飞 + 最多 3 帧排队。写一帧 1080P 要 1.8ms、1440P 要 3ms，
## 把它挪到后台线程就直接省下这块（实测约 15~20% 的吞吐）。
var _wbuf: Array = []
var _wid := -1
var _chunk_path := ""
var _first := 0                # 当前块第一帧的全局帧号
var _chunk_n := 0             # 当前块已写帧数
var _chunk_i := 0             # 块序号
var _seg_names: Array[String] = []
var _seg_i := 0               # 已起的编码段数（段名用它，完成顺序不代表编号顺序）
var _pcm_i := 0               # 打击音解码临时文件的计数（避免同名）
var _enc: Array = []          # [{pid, seg, chunk, n, log}] 后台编码中的块
var _frames := 0              # 已写入的总帧数
var _cancel := false
var _fail := ""
var _win: Window = null
var _win_mode := 0
var _win_pos := Vector2i.ZERO
var _win_size := Vector2i.ZERO
var _win_title := ""
var _master_db := 0.0
var _muted := false
var _t_ms := 0
var _grab_us := 0             # 累计：抓图+写盘耗时（诊断"慢在哪"）
var _us_read := 0             # 累计：后缓冲读回
var _us_cvt := 0              # 累计：convert(RGB8)+get_data
var _us_wr := 0               # 累计：写进块的 raw 流
var _us_step := 0             # 累计：排一步到下一次 frame_post_draw（=整帧节拍，含渲染与上屏）
var _size_warned := false
## 中间流的像素格式：**必须与 Image 的真实格式一致**。
## 曾经写死 rgba，而离屏 RT 读回来是 RGB8（fmt=4）⇒ ffmpeg 按 4 字节跨步读 3 字节的数据，
## 整部片子被斜切成条纹状的近黑噪声（用户："录制的视频全是黑的"）。现在由第一帧定、之后逐帧对齐。
var _pix := ""
## 离屏渲染三件套：SubViewport（=录制尺寸的画布）+ 装画面节点的 host + 贴回窗口的预览层
var _sv: SubViewport = null
var _host: Control = null
var _prev: TextureRect = null
var _moved: Array = []        # [[节点, 原父级, 原兄弟序号]]，收尾时按原样搬回去
var extras: Array = []        # 和舞台一起搬进离屏的 game 层节点（两侧背景延伸带）

## ── 输出目录 ─────────────────────────────────────────────────────────────
## 桌面：应用文件夹下的 video（user:// 就是 OS.get_user_data_dir()）。
## 手机：相册/影片目录——Godot 给的 SYSTEM_DIR_MOVIES / DCIM 就是 MediaStore 会扫的公共目录，
## 但**目录存在不等于写得进去**（Android 10+ 分区存储），所以真写一个探针文件才算数；
## 写不进就退回应用目录并如实打日志，不假装成功。
static var _dir_cache := ""

## user:// 在 Android 上是 /data/user/0/<包名>/files —— 包名从这里取，别写死
static func _pkg_id() -> String:
	var ud := OS.get_user_data_dir().replace("\\", "/")
	for key in ["/data/user/0/", "/data/data/"]:
		var i := ud.find(key)
		if i >= 0:
			return ud.substr(i + key.length()).get_slice("/", 0)
	return ""

static func _external_video_dir() -> String:
	var pkg := _pkg_id()
	if pkg == "":
		return ""
	var dir := "/storage/emulated/0/Android/data/%s/files/video" % pkg
	DirAccess.make_dir_recursive_absolute(dir)
	if not DirAccess.dir_exists_absolute(dir):
		return ""
	var probe := dir.path_join(".ptn_probe")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string("x")
	f.close()
	DirAccess.remove_absolute(probe)
	return dir

static func video_dir() -> String:
	if _dir_cache != "":
		return _dir_cache
	var out := "user://video"
	if OS.has_feature("mobile"):
		var album_ok := false
		for d in [OS.get_system_dir(OS.SYSTEM_DIR_MOVIES), OS.get_system_dir(OS.SYSTEM_DIR_DCIM)]:
			if String(d) == "":
				continue
			DirAccess.make_dir_recursive_absolute(String(d))
			if not DirAccess.dir_exists_absolute(String(d)):
				continue
			var probe := String(d).path_join(".ptn_probe")
			var f := FileAccess.open(probe, FileAccess.WRITE)
			if f == null:
				print("QA-REC 相册目录写不进去（分区存储）：", d)
				continue
			f.store_string("x")
			f.close()
			DirAccess.remove_absolute(probe)
			out = String(d).path_join("PhiTogetherNext")
			DirAccess.make_dir_recursive_absolute(out)
			album_ok = true
			break
		if not album_ok:
			# 分区存储写不进相册：退到**应用专属外部目录**（Android/data/<包名>/files/video）。
			# 它不需要任何权限，插上电脑 / 文件管理器也找得到——比藏在 /data/data 里强得多
			var ext := _external_video_dir()
			if ext != "":
				out = ext
	DirAccess.make_dir_recursive_absolute(out)
	_dir_cache = out
	return out

## 相册里的相对目录（Android 10+ 走 MediaStore，不需要任何权限，文件管理器/相册直接能看到）
const ALBUM_DIR := "Pictures/PhiTogetherNext"

## 成片写哪儿。手机 + 进程内编码器 → `mediastore:` 伪路径（原生侧 ContentResolver.insert）；
## 其它情况（桌面 ffmpeg / 没有 MediaStore 的老系统）→ 普通文件路径。
static func output_path(name: String) -> String:
	if OS.has_feature("mobile") and native_available():
		return "mediastore:" + ALBUM_DIR + "/" + name + ".mp4"
	return video_dir().path_join(name + ".mp4")

## 给人看的输出位置
static func output_display() -> String:
	if OS.has_feature("mobile") and native_available():
		return "相册 " + ALBUM_DIR
	return video_dir_display()

static func video_dir_abs() -> String:
	var p := video_dir()
	if p.begins_with("user://") or p.begins_with("res://"):
		return ProjectSettings.globalize_path(p)
	return p

## 设置页上给人看的那一条：绝对路径在 1350 宽的基准视口下放不下（右对齐还会顶出屏幕），
## 应用文件夹那一段直接写成"应用文件夹"，一眼就知道去哪儿找。
static func video_dir_display() -> String:
	var p := video_dir_abs().replace("\\", "/")
	var ud := OS.get_user_data_dir().replace("\\", "/").trim_suffix("/")
	if ud != "" and p.begins_with(ud):
		return "应用文件夹" + p.substr(ud.length())
	return p

## ── 编码器可用性 ─────────────────────────────────────────────────────────
static var _ff := {}

## 进程内编码器（Android MediaCodec，见 gdextension/src/video_enc.cpp）。
## 桌面没有这个类/不可用 → 仍然走系统 ffmpeg；手机没有 ffmpeg → 只有它。
static var _nat := {}

static func native_available() -> bool:
	if _nat.is_empty():
		var ok := false
		if ClassDB.class_exists("NativeVideoEncoder"):
			var e: Variant = ClassDB.instantiate("NativeVideoEncoder")
			if e != null:
				ok = bool(e.call("available"))
		_nat = {"ok": ok}
		if ok:
			print("QA-REC 进程内编码器可用（MediaCodec）")
	return bool(_nat["ok"])

static func has_encoder() -> bool:
	if native_available():
		return true
	if _ff.is_empty():
		_ff = {"ok": _probe_ffmpeg()}
	return bool(_ff["ok"])

static func _probe_ffmpeg() -> bool:
	# 手机/网页端起不了子进程，也不带 ffmpeg：这条链整条不存在，不是"暂时没找到"
	if OS.has_feature("mobile") or OS.has_feature("web"):
		print("QA-REC 当前平台无编码器（Android/Web 不能起 ffmpeg 子进程）")
		return false
	var out: Array[String] = []
	if OS.execute("ffmpeg", PackedStringArray(["-version"]), out, false) != 0:
		print("QA-REC 未找到 ffmpeg，渲染录制不可用（PATH 里装一个即可）")
		return false
	print("QA-REC ffmpeg ", String(out[0]).split("\n", false)[0].strip_edges())
	return true

## 硬件编码：ffmpeg 自带 h264_amf/hevc_amf（AMD 媒体引擎）。1440P 下 x264 会把
## 十几个核吃满、还跟渲染进程抢 CPU；AMF 把编码挪到 GPU 的媒体引擎，CPU 只负责喂帧。
## 探一次真的编两帧（只看 -encoders 列表不算数：驱动坏的时候列表也照样列出来）。
static var _amf := {}

static func has_hw_encoder() -> bool:
	if not _amf.is_empty():
		return bool(_amf["ok"])
	_amf = {"ok": false}
	if not has_encoder():
		return false
	var out: Array[String] = []
	if OS.execute("ffmpeg", PackedStringArray(["-hide_banner", "-encoders"]), out, false) != 0:
		return false
	if out.is_empty() or not String(out[0]).contains("h264_amf"):
		print("QA-REC 无 amf 编码器，用 libx264")
		return false
	var probe := "ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=size=256x256:rate=30:duration=0.1 -c:v h264_amf -f null -"
	var rc := OS.execute("cmd.exe", PackedStringArray(["/c", probe]), [], false)
	_amf = {"ok": rc == 0}
	print("QA-REC amf 实测 rc=", rc, " → ", "用 AMF" if rc == 0 else "退回 libx264")
	return bool(_amf["ok"])

## 主菜单输 REC / 设置页都改这同一个键（储存性质，重启还在）
static func toggle() -> bool:
	var v := not UserPrefs.flag("render_rec")
	UserPrefs.set_flag("render_rec", v)
	return v

## ── 录制主体 ─────────────────────────────────────────────────────────────
func start(stage: ChartStage, o: Dictionary) -> void:
	w = int(o.get("w", 1920))
	h = int(o.get("h", 1080))
	fps = float(o.get("fps", 60))
	mbps = int(o.get("mbps", 20))
	vcodec = clampi(int(o.get("vcodec", 0)), 0, VCOPY.size() - 1)
	acodec = clampi(int(o.get("acodec", 0)), 0, ACOPY.size() - 1)
	out_path = String(o.get("out", ""))
	song_path = String(o.get("song", ""))
	frame_limit = int(o.get("limit", 0))
	extras = o.get("extras", []) as Array
	workers = maxi(int(o.get("workers", 1)), 1)
	is_worker = bool(o.get("worker", false))
	part_tag = String(o.get("tag", "s"))
	slice_from = int(o.get("from", 0))
	slice_to = int(o.get("to", 0))
	tmp_root = String(o.get("tmp", ""))
	dir_path = String(o.get("dir", ""))
	chart_file = String(o.get("chart", ""))
	skin_dir = String(o.get("skin", ""))
	_run(stage)

## 把 total 帧切成 k 段。**每段至少 MIN_SLICE 帧**：子进程要重新加载谱、烘背景、
## 推帧到段首（实测合计 5 秒上下），切太碎只会把并行的收益吃回去——
## 20 秒的短片并行反而更慢（0.88×），2 分钟以上的谱才值得切。
const MIN_SLICE := 1800

static func split_frames(total: int, k: int) -> Array:
	var n := clampi(k, 1, 8)
	n = mini(n, maxi(int(float(total) / float(MIN_SLICE)), 1))
	var out: Array = []
	var per := int(ceilf(float(total) / float(n)))
	for i in n:
		var lo := i * per
		if lo >= total:
			break
		out.append([lo, mini(lo + per, total)])
	return out

## 并行档位：**固定 1**（用户 2026-10-22 定案："还是关了多线程吧，只要单线程调用核心合理也比他强"）。
## 实测这块 iGPU 上多进程合计吞吐并不比单进程高（瓶颈是每帧的显存→内存搬运，全机共享），
## 所以切片/子进程那条链保留但不再启用：split_frames 只会给出一段。
static func worker_count(notes: int) -> int:
	return 1

func _run(stage: ChartStage) -> void:
	if not has_encoder():
		finished.emit({"ok": false, "error": "平台无可用编码器"})
		return
	var tree := get_tree()
	_t_ms = Time.get_ticks_msec()
	_win = get_window()
	_win_mode = _win.mode
	_win_size = _win.size
	_win_pos = _win.position
	_win_title = _win.title
	_master_db = AudioServer.get_bus_volume_db(0)
	AudioServer.set_bus_volume_db(0, -80.0)   # 录制全程静音：见文件头"音轨不进这条链"
	_muted = true
	# 录制吞吐只由"渲染+抓图+写盘"决定，帧率上限和 vsync 会把每帧钉在屏幕刷新率上
	# （60Hz 屏就永远只有 1× 实时）。这两条在录制期间放开，机器快就录得快——
	# 这就是用户要的"性能好就加速渲染"；收尾按 prefs 原样设回去，不留污染。
	Engine.max_fps = 0
	# 录制期间关掉垂直同步：要的是真实帧耗时，不是被合成器放行节奏污染的节奏
	# ⚠ 只能走 DisplayServer：4.7 的 Window 没有 vsync_mode 属性，老写法 set("vsync_mode",1)
	#   既静默失败、又把 1 当成了 DISABLED（引擎里 1=ENABLED），等于整段录制都开着 vsync
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# 录制期间窗口置顶：被别的窗口完全盖住 / 最小化时，系统会停止给它出帧（frame_post_draw 不来），
	# 录制就会卡住。收尾在 _finish 里恢复
	_aot0 = _win.always_on_top
	_win.always_on_top = true
	var dur := stage.record_duration()
	var total := maxi(int(roundf(dur * fps)), 1)
	if frame_limit <= 0 and OS.is_debug_build() and OS.has_feature("mobile"):
		# 调试钩子：把帧数上限写进应用外部目录的 reclimit.txt 就能只录前 N 帧，
		# 手机上验证一次编码只要几十秒（正式包没有这段）
		var pkg := _pkg_id()
		if pkg != "":
			var lf := "/storage/emulated/0/Android/data/%s/files/reclimit.txt" % pkg
			if FileAccess.file_exists(lf):
				var lfa := FileAccess.open(lf, FileAccess.READ)
				if lfa != null:
					var n := int(lfa.get_as_text().strip_edges())
					lfa.close()
					if n > 0:
						frame_limit = n
						print("QA-REC 调试帧数上限 ", n)
	if frame_limit > 0:
		total = mini(total, frame_limit)
	# 1440P 一帧原始帧就 14.7MB（RGBA），整张谱的中间产物是"渲染-编码"流水线吃的，
	# 留不出几个 GB 的话中途一定"编码失败"。开工前先查，别等录到一半才炸
	var free_mb := -1
	var da_v := DirAccess.open(video_dir())
	if da_v != null:
		free_mb = int(da_v.get_space_left() / 1048576)
	var need_mb := 6144
	if free_mb > 0 and free_mb < need_mb:
		_fail = "磁盘只剩 %d MB，录制至少需要 %d MB 缓存（可调到 1080P 或先清视频目录）" % [
			free_mb, need_mb]
		print("QA-REC FAIL ", _fail)
		finished.emit({"ok": false, "path": "", "frames": 0, "secs": 0.0, "error": _fail, "bytes": 0})
		return
	print("QA-REC 磁盘剩余 ", free_mb, " MB")
	_tmp = video_dir().path_join(".rec" + str(int(Time.get_unix_time_from_system())))
	# 子进程必须落在父进程建好的那个临时目录里（块/清单/完成标记都要被父进程看到）。
	# 少了这一句每个子进程各建一个 .rec<时间戳>，父进程永远收不到活（实测就这么假死过）
	if is_worker and tmp_root != "":
		_tmp = tmp_root
	# 只看返回值不算数：4.7 的 make_dir_recursive_absolute 打出来是 0（Error.OK），
	# 用 `if not ...` 判就把成功当失败（第一次 QA 就是这样整条录不起来的）。
	# 建完直接查目录在不在，这个判据在哪个版本都不会骗人。
	DirAccess.make_dir_recursive_absolute(_tmp)
	if not DirAccess.dir_exists_absolute(_tmp):
		_fail = "临时目录建不出来 " + _tmp + "（磁盘/权限）"
		_finish(stage)
		return
	# 离屏渲染：把这一局的画面整棵子树搬进一块 SubViewport，尺寸就是录制尺寸。
	# 为什么不"把窗口改成录制分辨率"：那样每帧读的是**交换链**（实测 6.0ms），
	# 读一块普通 RT 只要 3.3ms（--qarecperf 的 H 段量的）；顺带窗口不再被撑大、
	# 不用做 DPI 自校准，输出尺寸是构造上精确的。
	_enter_offscreen(stage)
	stage.record_begin(fps)
	await tree.process_frame
	await tree.process_frame
	# 对账：成片帧数 = 音乐长度 × 帧率（用户 2026-10-23 定案：从音乐开头录到音乐结束）
	_expect_total = total
	# 背景虚化是异步烘焙的（2~12 轮，每轮等一帧）：这段时间不排步=时钟停在 0，
	# 糊完之前一帧都不落盘，否则片头几秒是没模糊的底（与实况不一致）
	var guard := 0
	while not stage.record_warm() and guard < 900 and not _cancel:
		if not await _wait_frame():
			break
		guard += 1
	if guard > 0:
		print("QA-REC 等背景烘焙 ", guard, " 帧")
	if is_worker:
		print("QA-REC worker ", part_tag, " 开跑 帧=", slice_from, "→", slice_to, " ", w, "x", h)
		await _render_range(stage, slice_from, slice_to, slice_to)
		await _chunk_end()
		_build_hits(stage, slice_from, slice_to, slice_to)
		var df := FileAccess.open(_tmp.path_join("done_%s.txt" % part_tag), FileAccess.WRITE)
		if df != null:
			df.store_string(str(_frames))
			df.close()
		print("QA-REC worker ", part_tag, " 交活 帧=", _frames, " 墙钟=%.1fs" % [
			float(Time.get_ticks_msec() - _t_ms) / 1000.0])
		finished.emit({"ok": _fail == "", "worker": true, "frames": _frames, "error": _fail})
		return
	print("QA-REC begin out=", out_path, " ", w, "x", h, "@", fps,
		" fps mbps=", mbps, " vcodec=", VCOPY[vcodec], " acodec=", ACOPY[acodec],
		" dur=", "%.2f" % dur, " frames=", total,
		" tmp=", _tmp, " song=", song_path if song_path != "" else "(无音轨)")
	# 原生编码器（Android）：**必须在第一帧抓取之前打开**——`_grab()` 是靠 `_nat_enc`
	# 决定"喂 MediaCodec"还是"落原始块给 ffmpeg"。原来这个块放在渲完第 0 段之后，
	# 于是主进程那一段先走了 ffmpeg 分块（手机上必然失败，只剩一个 .error.txt）。
	if native_available():
		var ne: Variant = ClassDB.instantiate("NativeVideoEncoder")
		if ne != null:
			var nrc := int(ne.call("open", out_path, w, h, int(roundf(fps)), mbps))
			if nrc == 0:
				_nat_enc = ne
				_prep_native_audio(stage, ne)
			else:
				print("QA-REC 原生编码器打不开 rc=", nrc, " ", ne.call("last_error"))
	var bounds := split_frames(total, worker_count(int(stage.note_total())))
	_bounds = bounds
	# 自己那段照旧边渲边压（编码与渲染重叠，别攒到最后白等）；各子进程的块在它交活之后
	# 按 k 的顺序压，段序天然等于时间轴。补渲的段也挂在同一个 man_w<k> 里，顺序不受影响。
	_defer_encode = false
	# 先把子进程全放出去（它们要加载谱、烘背景），再渲自己这一段——启动成本与渲染重叠
	if bounds.size() > 1:
		_spawn_workers(bounds, total)
	await _render_range(stage, 0, int(bounds[0][1]), total)
	await _chunk_end()
	if _nat_enc == null:
		# 只有 ffmpeg 那条链需要"渲完再摆打击音"：原生编码器的音轨在开录前就编好了
		# （set_hits），这里再摆一遍既没用、还会在手机上白写几十 MB 的裸 PCM
		_build_hits(stage, 0, int(bounds[0][1]), total)
	var _t1 := Time.get_ticks_msec()
	await _wait_workers()
	var _ta := Time.get_ticks_msec()
	await _render_and_encode_slices(stage)
	if _nat_enc != null:
		# 原生路径：视频已经在 push_frame 里进了编码器，这里只需要冲刷 + 收尾
		var rc := int(_nat_enc.call("finish"))
		_nat_out_bytes = int(_nat_enc.call("output_size"))
		print("QA-REC 原生统计 ", _nat_enc.call("debug_stats"))
		if rc != 0 and _fail == "":
			_fail = "原生编码收尾失败 rc=" + str(rc) + " " + String(_nat_enc.call("last_error"))
		_nat_enc = null
		await _concat_native()
		_finish(stage)
		return
	var _t2 := Time.get_ticks_msec()
	# 必须等所有 ffmpeg 收工再拼表：_seg_names 是"编码完成"才进表的，
	# 少等这一步，最后几段还没压完就写进 list.txt → 成片短几十帧（实测 600→544）
	await _wait_encodes()
	var _t3 := Time.get_ticks_msec()
	_join_hits(bounds)
	await _concat()
	var _t4 := Time.get_ticks_msec()
	print("QA-REC 分段 自己渲完=%dms 等子进程+补渲=%dms 编码=%dms 合成=%dms" % [
		_t1 - _t_ms, _ta - _t1, _t2 - _ta, _t4 - _t3])
	_finish(stage)

## ── 原生音轨：乐曲 + 打击音，在推第一帧之前整条编好 ────────────────────────
## MediaMuxer 的轨道只能在写第一帧之前 addTrack，而 AAC 的输出格式要等编码器跑起来才有；
## 所以音轨必须开录前编完。打击音事件由 player 直接给出（音乐时间轴、含谱面 offset），
## 不靠边渲边记——那条路子只能等渲完才知道音轨内容，轨道就挂不上了。
var _mat_i := 0

## 原生编码器只认 `::open` 的真实文件；res:// 的导入件、user:// 里的 zip 虚拟路径
## （`...zip%2Fxxx/song.ogg`）都不是真实路径，先经 FileAccess 落成临时文件。
func _materialize(src: String) -> String:
	if src == "":
		return ""
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null:
		return ""
	var ext := src.get_extension()
	if ext == "":
		ext = "bin"
	var dst := _tmp.path_join("audio_%d.%s" % [_mat_i, ext])
	_mat_i += 1
	var d := FileAccess.open(dst, FileAccess.WRITE)
	if d == null:
		f.close()
		return ""
	d.store_buffer(f.get_buffer(f.get_length()))
	d.close()
	f.close()
	return ProjectSettings.globalize_path(dst)

func _prep_native_audio(stage: ChartStage, enc: Variant) -> void:
	var t0 := Time.get_ticks_msec()
	var song_real := _materialize(song_path) if song_path != "" else ""
	enc.call("set_audio", song_real, UserPrefs.num("music_vol"))
	var times := PackedFloat64Array()
	var paths := PackedStringArray()
	var cache := {}
	var cap := stage.record_duration()   # 音乐结束之后不再摆打击音（成片就到音乐结尾）
	for ev in stage.sound_events():
		var e: Array = ev
		if float(e[0]) < 0.0 or float(e[0]) >= cap:
			continue
		var pcm := stage.hit_sound_pcm(int(e[1]), String(e[2]))
		if pcm == "":
			continue
		if not cache.has(pcm):
			cache[pcm] = _materialize(pcm)
		var real := String(cache[pcm])
		if real == "":
			continue
		times.append(float(e[0]))
		paths.append(real)
	enc.call("set_hits", times, paths, UserPrefs.num("hit_vol"))
	print("QA-REC 原生音轨 用时=", Time.get_ticks_msec() - t0, "ms 打击=", times.size(),
		" 音色=", cache.size(), " 曲=", song_real.get_file())

## 等下一帧上屏。**必须带超时**：窗口被最小化或完全遮挡时 `frame_post_draw` 永远不触发，
## 整个录制协程就干等在那里（用户看到"录到一半暂停了"、只剩一个 .rec 文件夹）。
## 超时先试着把窗口拉回前台；连续 12 秒没有帧就判失败，带着已渲的部分收尾，而不是卡死。
var _no_draw_ms := 0
var _aot0 := false
var _nat_enc: Variant = null   # 进程内编码器实例（非空 = 这条录制走原生编码，不落原始块）
var _nat_out_bytes := 0        # 原生编码器写出的字节（相册输出时用来判成败/报大小）

func _wait_frame() -> bool:
	# 用"已画帧数"轮询，而不是 await 信号或给信号挂一次性 lambda：
	# 实测给 frame_post_draw 挂 lambda 时回调是**下一拍**才到的，等于每帧白等 200ms（录成 5fps）
	var t0 := Time.get_ticks_msec()
	var f0 := Engine.get_frames_drawn()
	while Engine.get_frames_drawn() == f0 and not _cancel 			and Time.get_ticks_msec() - t0 < 200:
		await get_tree().process_frame
	if Engine.get_frames_drawn() != f0:
		_no_draw_ms = 0
		return true
	_no_draw_ms += int(Time.get_ticks_msec() - t0)
	if _no_draw_ms > 1500 and _win != null:
		print("QA-REC 窗口 ", _no_draw_ms, "ms 没出帧，拉回前台继续")
		_win.mode = Window.MODE_WINDOWED
		_win.always_on_top = true
		DisplayServer.window_move_to_foreground()
	if _no_draw_ms > 12000:
		_fail = "窗口被最小化/遮挡，系统停止渲染（恢复成前台窗口再录一次）"
		print("QA-REC FAIL ", _fail)
		return false
	return true

## 渲 [from, to) 这一段：一真帧一帧，抓离屏 RT、攒进当前块。
## from>0 时先**同步推帧**把状态演到那一刻（判定/连击/特效都是历史相关的，
## 跳秒会漏判、段边界的分数与连击会跟上一段对不上）。推帧不走渲染，很便宜。
func _render_range(stage: ChartStage, from: int, to: int, total: int) -> void:
	_chunk_begin()
	if from > 0:
		var t0 := Time.get_ticks_usec()
		for g in from:
			stage.record_step(1.0 / fps)
			stage._process(1.0 / fps)
		print("QA-REC 推帧 ", from, " 用时=%.0fms" % (float(Time.get_ticks_usec() - t0) / 1000.0))
		# 推帧阶段也会走 _play_hit，那些命中是"为了把状态演到位"而不是本段的画面内容，
		# 不清掉会让 _build_hits 拿到负偏移（t < 段起点）→ 越界（实测子进程就崩在这）
		stage.rec_hits.clear()
	for i in range(from, to):
		if _cancel or _fail != "":
			break
		# 段首不排步：抓的就是这一帧当前的样子（主进程第 0 段 = 谱面 0 秒）
		if i > from:
			var s0 := Time.get_ticks_usec()
			stage.record_step(1.0 / fps)
			if not await _wait_frame():
				break
			_us_step += int(Time.get_ticks_usec() - s0)
		else:
			if not await _wait_frame():
				break
		_grab()
		if _fail != "":
			break
		if _chunk_n >= _chunk_cap():
			# 背压：渲染快过编码时块会堆在磁盘上（1440P 一块 768MB），堆满盘就是
			# "编码失败"。在飞超过 3 块就等编码追上，宁可整体慢一点也不能写爆盘
			while _enc.size() >= 3 and _fail == "" and not _cancel:
				if not await _wait_frame():
					break
				_prune_encodes(true)
			_chunk_flush()
		_prune_encodes(false)
		if i % 60 == 0:
			_progress(total, i)
	_progress(total, to)

## 把"这一局会出现在画面上的东西"整棵搬进离屏画布：舞台本体 + 两侧那条背景延伸带
## + 被提到 game 层的噪域 Active 层。搬完 `get_viewport_rect()` 就是录制尺寸，
## 舞台里所有百分比布局/离屏链/字体取整自动跟着升到目标分辨率（一行都不用改）。
## 预览层用 SubViewportContainer 把离屏结果贴回窗口：不然录制期间屏幕上什么都没有。
func _enter_offscreen(stage: ChartStage) -> void:
	_sv = SubViewport.new()
	_sv.size = Vector2i(w, h)
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sv.transparent_bg = false
	var vp := get_viewport()
	# 抗锯齿 / HDR 两档必须跟实跑一致，否则录出来的边缘和色彩与屏幕上看到的不是一套
	_sv.msaa_2d = vp.msaa_2d
	_sv.use_hdr_2d = vp.use_hdr_2d
	_host = Control.new()
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_host.size = Vector2(w, h)
	_sv.add_child(_host)
	_prev = TextureRect.new()
	_prev.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prev.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_prev.stretch_mode = TextureRect.STRETCH_SCALE
	_prev.z_index = 40
	_prev.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_sv)
	_prev.texture = _sv.get_texture()
	add_child(_prev)
	# ⚠ 顺序有讲究：背景延伸带与舞台 **z 都是 0**，同 z 由树序决定先后。
	# 原布局是"背景先加、舞台后加"，照抄到 host 里才不会让背景把舞台整块盖住（实测踩过：
	# 离屏里只剩背景、舞台全黑）。所以 extras 先搬，stage 最后搬。
	for n in (extras + [stage]):
		var c := n as Node
		if c == null or not is_instance_valid(c) or c.get_parent() == _host:
			continue
		_moved.append([c, c.get_parent(), c.get_index()])
		c.reparent(_host, false)
	# 噪域 Active 层原本被提到 game 层（HUD 之上）；离屏之后"屏"就是这块画布，
	# 提到 host 上才在片子里（place_block_overlay 自己会 reparent + 摆 FULL_RECT）
	stage.place_block_overlay(_host, 52)
	_rebind_stage(stage)

## reparent 会打断 ViewportTexture 的路径绑定：`_content_out`（显示 _csv）和 `_lout`（显示 _lsv）
## 是建谱时静态贴上去的，搬完就画不出来了（症状：离屏里只剩背景延伸带，舞台整块不见）。
## 顺带调一次 `_resized()` 让舞台按新画布尺寸重排（否则它还是旧窗口的 size/scale，
## 画面缩在左上角）。收尾搬回去之后同样要做一遍。
func _rebind_stage(stage: ChartStage) -> void:
	stage._resized()
	stage._content_out.texture = stage._csv.get_texture()
	stage._lout.texture = stage._lsv.get_texture()

## 搬回原处：结算/选曲那些路径都按"舞台在 game 根下"写的，录制结束必须还原回去
func _leave_offscreen() -> void:
	for e in _moved:
		var n: Node = e[0]
		var old: Node = e[1]
		if is_instance_valid(n) and is_instance_valid(old):
			n.reparent(old, false)
			# Node 没有 set_index：要回到原来的兄弟位置得让父级 move_child
			# （两侧背景延伸带在舞台之前，树序乱了 z 序就跟着乱）
			old.move_child(n, clampi(int(e[2]), 0, maxi(old.get_child_count() - 1, 0)))
			# 搬回根画布同样要重贴一次 + 重排（舞台尺寸要回到窗口那一套）
			if n is ChartStage:
				_rebind_stage(n as ChartStage)
	_moved = []
	if _prev != null and is_instance_valid(_prev):
		_prev.queue_free()
	_prev = null
	if _sv != null and is_instance_valid(_sv):
		_sv.queue_free()
	_sv = null
	_host = null

var _last_pct := -100   # 进度日志的节流（每 10% 一行，窗口标题一直在动）

## 进度：标题栏 + 每 10% 一行日志。录制期间**不能**在画面上摆进度条——
## 抓的是整块后缓冲，摆上去就被录进片子里。
func _progress(total: int, i: int) -> void:
	var ms := float(Time.get_ticks_msec() - _t_ms)
	var content := float(_frames) / fps
	var p := int(float(i) * 100.0 / maxf(float(total), 1.0))
	_win.title = "录制 %d/%d (%d%%) · 墙钟 %.0fs / 内容 %.0fs" % [i, total, p, ms / 1000.0, content]
	if p >= _last_pct + 10 or i >= total:
		_last_pct = p
		var f := maxf(float(_frames), 1.0)
		print("%s 帧=%d/%d 墙钟=%.0fs 内容=%.0fs 速度=%.2fx | 每帧ms 帧间=%.2f 读回=%.2f 转=%.2f 写=%.2f 编码中=%d" % [
			"QA-REC 进度", i, total, ms / 1000.0, content, content / maxf(ms / 1000.0, 0.001),
			float(_us_step) / 1000.0 / f, float(_us_read) / 1000.0 / f,
			float(_us_cvt) / 1000.0 / f, float(_us_wr) / 1000.0 / f, _enc.size()])

## 一块多少帧：按字节上限折算，再夹进 [CHUNK_MIN, CHUNK_MAX]
func _chunk_cap() -> int:
	var bpp := 4 if _pix == "rgba" else 3
	var per := float(w * h * bpp)
	return clampi(int(float(CHUNK_BYTES) / maxf(per, 1.0)), CHUNK_MIN_FRAMES, CHUNK_MAX_FRAMES)

## 一帧在飞：上一笔写完了就交下一笔；队列堆到 4 帧说明磁盘跟不上，就地同步写（背压）
func _pump_write() -> void:
	if _wid >= 0:
		if not WorkerThreadPool.is_task_completed(_wid):
			if _wbuf.size() < 4:
				return
			WorkerThreadPool.wait_for_task_completion(_wid)
			_wid = -1
		else:
			WorkerThreadPool.wait_for_task_completion(_wid)
			_wid = -1
	while not _wbuf.is_empty():
		var buf: PackedByteArray = _wbuf.pop_front()
		if _wid < 0:
			_wid = WorkerThreadPool.add_task(_write_buf.bind(_fa, buf), false, "rec_write")
			return
		if _fa != null:
			_fa.store_buffer(buf)

## 换块/收尾前必须排空（文件句柄马上要关）
func _drain_write() -> void:
	if _wid >= 0:
		WorkerThreadPool.wait_for_task_completion(_wid)
		_wid = -1
	while not _wbuf.is_empty():
		var buf: PackedByteArray = _wbuf.pop_front()
		if _fa != null:
			_fa.store_buffer(buf)
	if _fa != null and _fa.get_error() != OK:
		_fail = "写帧失败 err=" + str(_fa.get_error()) + " " + _chunk_path

func _write_buf(fa: FileAccess, buf: PackedByteArray) -> void:
	if fa != null:
		fa.store_buffer(buf)

func _chunk_begin() -> void:
	_chunk_n = 0
	_first = slice_from + _frames        # 本块第一帧的全局帧号（父进程按它排序）
	_chunk_path = _tmp.path_join("c_%s_%04d.rgb" % [part_tag, _chunk_i])
	_chunk_i += 1
	_fa = FileAccess.open(_chunk_path, FileAccess.WRITE)
	if _fa == null:
		_fail = "临时帧文件打不开 " + _chunk_path

## 收口当前块：关文件 → 记清单 → 起一次编码。
## 帧是**逐帧顺序写**的（每帧 2~3ms），不在内存里攒整块：1440P 一帧就 9.3MB，
## 攒 200 帧就是 1.8GB × 5 个进程，不现实。块开大是为了少起进程（AMF 每次初始化要 0.3s）。
func _chunk_flush() -> void:
	if _fa == null:
		return
	_drain_write()
	_fa.flush()
	_fa.close()
	_fa = null
	if _chunk_n <= 0:
		return
	_note_chunk(_chunk_path, _first, _chunk_n)
	# 子进程只落盘不编码；父进程并行时也攒到最后统一压（段序=全局帧序）
	if not is_worker and not _defer_encode:
		_encode_chunk(_chunk_path, _chunk_n)
	_chunk_n = 0
	_chunk_begin()

## 每块在清单里留一行：全局首帧 / 帧数 / 文件名。父进程靠它把各段按时间轴拼回去。
func _note_chunk(path: String, first: int, n: int) -> void:
	var mf := _tmp.path_join("man_%s.txt" % part_tag)
	var f := FileAccess.open(mf, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(mf, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_string("%d %d %s" % [first, n, path.get_file()] + String.chr(10))
	f.close()

## 收尾：最后一块交出去（编码由 _wait_encodes 管）
func _chunk_end() -> void:
	if _fa != null:
		_drain_write()
		_fa.flush()
		_fa.close()
		_fa = null
	if _chunk_n > 0:
		var p := _chunk_path
		var n := _chunk_n
		var f0 := _first
		_chunk_n = 0
		_note_chunk(p, f0, n)
		if not is_worker and not _defer_encode:
			_encode_chunk(p, n)

## ffmpeg：rawvideo 输入 → x264/x265 一段 mp4。命令行照 _start_xcode 那条经验写：
## create_process 不给带空格的参数加引号，所以走 cmd.exe /c 单串、自己引号、日志重定向。
func _encode_chunk(rgb: String, n: int, sw := false, name_override := "") -> void:
	# 段名按**起进程的顺序**编号：_seg_names 只在块完成后才增长，用它算下标会让
	# 同时在跑的两块抢同一个文件名（后写的把先写的覆盖掉，拼出来就缺一段）。
	# 失败重试必须**沿用原来的段名**，否则重试块拿到更大的编号，最后按名排序时顺序就错了
	var seg_name := name_override
	if seg_name == "":
		_seg_i += 1
		seg_name = "s_%04d.mp4" % _seg_i
	var seg := _tmp.path_join(seg_name)
	var glog := ProjectSettings.globalize_path(seg + ".log")
	# 常量表下标出来的是 Variant，所以这里显式声明 args: String（:= 会推不出类型）
	var pf := _pix if _pix != "" else "rgb24"
	# 硬件编码优先：1440P 下 x264 会和渲染进程抢十几个核
	# 统一走 libx264：AMF 的 -rc cbr **不补 filler**，画面越简单码率掉得越狠
	# （实测同一条谱设 50Mbps 只出 11Mbps）；x264 的 nal-hrd=cbr 会补填充，
	# 才会"设多少出多少"。单进程下 x264 veryfast 也追得上渲染速度。
	var hw := false
	var cenc := ("hevc_amf" if vcodec == 1 else "h264_amf") if hw else String(VCOPY[vcodec])
	# **CBR**：用户设 50Mbps 实测只出 17Mbps——那是 ABR 在低复杂度画面上"省比特"。
	# 要按设定值出片就必须钉成 CBR：x264 用 nal-hrd=cbr 补 filler，AMF 用 -rc cbr；
	# minrate/maxrate 与目标相同、bufsize 取 1 秒，码率才会贴着设定值走
	var copts := "-quality balanced -rc cbr" if hw else "-preset veryfast -x264-params nal-hrd=cbr"
	var args: String = "ffmpeg -hide_banner -loglevel error -y -f rawvideo -pix_fmt " + pf + " -s " \
		+ str(w) + "x" + str(h) + " -framerate " + str(int(roundf(fps))) \
		+ " -i \"" + ProjectSettings.globalize_path(rgb) + "\"" \
		+ " -frames:v " + str(n) + " -fps_mode passthrough -an" \
		+ " -c:v " + cenc + " " + copts + " -bf 0 -pix_fmt yuv420p" \
		+ " -b:v " + str(mbps) + "M -minrate " + str(mbps) + "M -maxrate " + str(mbps) + "M" \
		+ " -bufsize " + str(mbps) + "M" \
		+ " -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709" \
		+ " \"" + ProjectSettings.globalize_path(seg) + "\" > \"" + glog + "\" 2>&1"
	var pid := OS.create_process("cmd.exe", PackedStringArray(["/c", args]), false)
	if pid <= 0:
		_fail = "ffmpeg 起不来 pid=" + str(pid)
		return
	_enc.append({"pid": pid, "seg": seg, "name": seg_name, "chunk": rgb, "n": n, "sw": sw})

## 回收已完成的块：失败就把日志末行带进 _fail；成功就把那一块的原始 rgb 删掉（磁盘只留一块）
func _prune_encodes(verbose: bool) -> void:
	var i := _enc.size() - 1
	while i >= 0:
		var e: Dictionary = _enc[i]
		if OS.is_process_running(int(e["pid"])):
			i -= 1
			continue
		_enc.remove_at(i)
		var fa := FileAccess.open(String(e["seg"]), FileAccess.READ)
		var sz := fa.get_length() if fa != null else -1
		if fa != null:
			fa.close()
		# 段帧数必须等于预期：少了就是码流被截断，拼进去的成片会"播到一半拖进度条直接结束"
		var got_n := -1
		if sz > 1024:
			got_n = _seg_frames(String(e["seg"]))
		if sz <= 1024 or (got_n > 0 and got_n != int(e["n"])):
			# 硬件编码偶发会挂（多开 AMF 会话时尤其容易）：这一块退回软编重试，
			# 并把后续块也切到软编。直接判整条失败是最糟的体验（用户只看到一个"报错"）
			if not bool(e.get("sw", false)) and not _hw_off:
				print("QA-REC 第", e["name"], " 块硬件编码失败，退回 libx264 重试：",
					_tail(String(e["seg"]) + ".log"))
				_hw_off = true
				DirAccess.remove_absolute(String(e["seg"]))
				_encode_chunk(String(e["chunk"]), int(e["n"]), true, String(e["name"]))
				i -= 1
				continue
			_fail = "第" + str(e["name"]) + " 块编码失败 " + _tail(String(e["seg"]) + ".log")
			print("QA-REC FAIL ", _fail)
			_dump_fail(String(e["name"]), String(e["seg"]) + ".log", String(e["chunk"]))
			return
		_seg_names.append(String(e["name"]))
		DirAccess.remove_absolute(String(e["chunk"]))
		DirAccess.remove_absolute(String(e["seg"]) + ".log")
		if verbose:
			print("QA-REC seg done ", e["name"], " frames=", e["n"], " ", sz / 1024, "KB")
		i -= 1

## 失败现场：ffmpeg 完整日志 + 块大小 + 磁盘余量 → 输出目录旁的 .error.txt
## （临时目录收尾会整个删掉，不落出来就只能靠用户截图）
func _dump_fail(tag: String, log: String, chunk: String) -> void:
	var txt := "块=" + tag + String.chr(10)
	var f := FileAccess.open(log, FileAccess.READ)
	if f != null:
		txt += "--- ffmpeg log ---" + String.chr(10) + f.get_as_text().right(8000)
		f.close()
	var cf := FileAccess.open(chunk, FileAccess.READ)
	txt += String.chr(10) + "chunk bytes=" + str(cf.get_length() if cf != null else -1)
	if cf != null:
		cf.close()
	txt += " 期望=" + str(_chunk_n * w * h * (4 if _pix == "rgba" else 3))
	txt += String.chr(10) + "hw=" + str(not _hw_off) + " pix=" + _pix + " " + str(w) + "x" + str(h)
	var da2 := DirAccess.open(video_dir())
	if da2 != null:
		txt += String.chr(10) + "freeMB=" + str(int(da2.get_space_left() / 1048576))
	var out := out_path if out_path != "" else video_dir().path_join("record")
	var errp := out.get_basename() + ".error.txt"
	var w2 := FileAccess.open(errp, FileAccess.WRITE)
	if w2 != null:
		w2.store_string(txt)
		w2.close()
		print("QA-REC 失败现场写到 ", errp)

## 段文件的视频帧数（从容器头读，快）
func _seg_frames(path: String) -> int:
	var out: Array[String] = []
	if OS.execute("ffprobe", PackedStringArray(["-v", "error", "-select_streams", "v:0",
			"-show_entries", "stream=nb_frames", "-of", "default=nw=1:nk=1",
			ProjectSettings.globalize_path(path)]), out, false) != 0:
		return -1
	if out.is_empty():
		return -1
	return int(String(out[0]).strip_edges())

func _tail(log: String) -> String:
	var f := FileAccess.open(log, FileAccess.READ)
	if f == null:
		return "(无日志)"
	var s := f.get_as_text()
	f.close()
	return s.right(300).replace("\n", " ")

func _wait_encodes() -> void:
	var guard := 0
	while not _enc.is_empty() and guard < 60000 and not _cancel:
		await get_tree().process_frame
		_prune_encodes(true)
		guard += 1
		if _fail != "":
			break
	_prune_encodes(true)

## 收尾：拼块 + 挂音轨。-c:v copy 是关键——已经压过一遍，再压就二次损失。
func _concat() -> void:
	if _fail != "":
		return
	if _seg_names.is_empty():
		_fail = "一段都没渲出来"
		return
	# 段是**完成序**进表的（哪块的 ffmpeg 先跑完先记账），拼之前必须按名字排回渲染序
	_seg_names.sort()
	var list := _tmp.path_join("list.txt")
	var lf := FileAccess.open(list, FileAccess.WRITE)
	if lf == null:
		_fail = "list.txt 写不出来"
		return
	for s in _seg_names:
		lf.store_string("file '" + String(s) + "'\n")
	lf.close()
	var glog := ProjectSettings.globalize_path(list + ".log")
	var args: String = "ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i \"" \
		+ ProjectSettings.globalize_path(list) + "\""
	var has_a := song_path != "" and FileAccess.file_exists(song_path)
	var has_h := _hits_file != "" and FileAccess.file_exists(_hits_file)
	if has_a:
		args += " -i \"" + song_path + "\""
	if has_h:
		args += " -f f32le -ar " + str(SR) + " -ac 2 -i \"" \
			+ ProjectSettings.globalize_path(_hits_file) + "\""
	if has_a and has_h:
		# 这条 ffmpeg（N-125752）已经没有 -filter_complex_script 了，只能把图写在命令行上。
		# 图里有分号与方括号：整条命令本来就是走 cmd.exe /c 的**单个字符串**，
		# 所以给图套上双引号，cmd 就不会把分号当参数分隔符吃掉。
		var graph := "[1:a]volume=%.3f[m];[2:a]volume=%.3f[h];" % [
				UserPrefs.num("music_vol"), UserPrefs.num("hit_vol")]
		graph += "[m][h]amix=inputs=2:duration=first:normalize=0,apad[a]"
		args += " -filter_complex \"" + graph + "\" -map 0:v:0 -map [a]"
	elif has_a:
		# apad：把音轨补静音到视频长度，否则 -shortest 会按较短的音轨把片尾黑帧剪掉
		args += " -map 0:v:0 -map 1:a:0 -af apad"
	elif has_h:
		args += " -map 0:v:0 -map 1:a:0"
	else:
		args += " -an"
	if has_a or has_h:
		args += " -c:a " + String(ACOPY[acodec]) + " -b:a " + str(int(A_KBPS[acodec])) + "k"
	args += " -c:v copy -shortest -movflags +faststart \"" + out_path + "\" > \"" + glog + "\" 2>&1"
	print("QA-REC concat ", _seg_names.size(), " 段 → ", out_path)
	# 同样走 create_process + 轮询：OS.execute 在这台机器上有过工作线程里 rc=-22 的记录
	# （见 chart_stage._start_xcode 的注释），而且它会冻住主线程，长谱合成几秒=窗口无响应
	var pid := OS.create_process("cmd.exe", PackedStringArray(["/c", args]), false)
	if pid <= 0:
		_fail = "合成进程起不来 pid=" + str(pid)
		return
	var guard := 0
	while OS.is_process_running(pid) and guard < 20000:
		await get_tree().process_frame
		guard += 1
	if not FileAccess.file_exists(out_path):
		_fail = "合成没产出文件 " + _tail(String(list) + ".log")
		return
	print("QA-REC concat log=", _tail(String(list) + ".log"))

## ── 打击音离线混音 ───────────────────────────────────────────────────────
## 成片里为什么不能"边渲边播再抓声音"：内容时间与墙钟脱钩（机器快就提前录完），
## 实时混出来的音对不上帧号。所以打击音按**内容时间**在渲染结束后一次性摆进一条
## 裸 PCM（48k 立体声 f32le），最后与谱包乐曲一起交给 ffmpeg amix —— 和画面同一套口径。
const SR := 48000
var _hits_file := ""

func _build_hits(stage: ChartStage, from: int, to: int, total: int) -> void:
	var hits: Array = stage.rec_hits
	if hits.is_empty() or song_path == "" or _fail != "":
		return
	var secs := float(to - from) / fps
	var total_sr := int(roundf(secs * float(SR))) * 2
	var acc := PackedFloat32Array()
	acc.resize(total_sr)
	var t0 := Time.get_ticks_usec()
	# 每种音只解一次（一张谱通常就 3~4 种），ffmpeg 直接吐 48k 立体声裸 float
	var dec := {}
	var peak := 0.0           # 打击音那条 stem 的峰值/均方根：证明"音真的摆进去了"
	var sum := 0.0
	var ns := 0
	for h in hits:
		var hd: Array = h
		var path := stage.hit_sound_path(int(hd[1]), String(hd[2]))
		if path == "":
			continue
		var s: PackedFloat32Array
		if dec.has(path):
			s = dec[path]
		else:
			s = _decode_pcm(path)
			dec[path] = s
			if s.is_empty():
				continue
		if s.is_empty():
			continue
		# 命中时刻就是内容时间：整片从 0 开始，直接按秒换成采样下标
		# 段内偏移：命中时刻减掉段起点（父进程最后按段序把这些裸 PCM 首尾相接）
		var off := int(roundf((float(hd[0]) - float(from) / fps) * float(SR))) * 2
		if off < 0:
			continue
		var lim := total_sr - off
		if lim <= 0:
			continue
		var m: int = mini(s.size(), lim)
		ns += m
		for i in m:
			var v := acc[off + i] + s[i]
			acc[off + i] = v
			var av := absf(v)
			if av > peak:
				peak = av
			sum += av * av
	var mix_us := int(Time.get_ticks_usec() - t0)
	_hits_file = _tmp.path_join("hits_%s.f32" % part_tag)
	var f := FileAccess.open(_hits_file, FileAccess.WRITE)
	if f == null:
		_hits_file = ""
		return
	var out := PackedByteArray()
	out.resize(total_sr * 4)
	for i in total_sr:
		out.encode_float(i * 4, acc[i])
	f.store_buffer(out)
	f.close()
	print("QA-REC 打击音 响=", hits.size(), " 种=", dec.size(), " 混音=%.0fms 长度=%.1fs 峰=%.2f 命中段RMS=%.3f" % [
		float(mix_us) / 1000.0, secs, peak, sqrt(sum / maxf(float(ns), 1.0))])

## ffmpeg 把任意容器/采样率的音解成 48k 立体声 float 裸 PCM（重采样交给它，别自己插值）
func _decode_pcm(path: String) -> PackedFloat32Array:
	var gsrc := path
	if gsrc.begins_with("user://") or gsrc.begins_with("res://"):
		gsrc = ProjectSettings.globalize_path(gsrc)
	var dst := _tmp.path_join("pcm_%d.f32" % _pcm_i)
	_pcm_i += 1
	var gdst := ProjectSettings.globalize_path(dst)
	var cmd: String = "ffmpeg -hide_banner -loglevel error -y -i \"" + gsrc \
		+ "\" -vn -ac 2 -ar " + str(SR) + " -f f32le -c:a pcm_f32le \"" + gdst + "\" 2>&1"
	var out: Array[String] = []
	if OS.execute("cmd.exe", PackedStringArray(["/c", cmd]), out, false) != 0:
		print("QA-REC 打击音解码失败 ", path.get_file())
		return PackedFloat32Array()
	var f := FileAccess.open(dst, FileAccess.READ)
	if f == null:
		return PackedFloat32Array()
	var buf := f.get_buffer(f.get_length())
	f.close()
	DirAccess.remove_absolute(dst)
	var n := buf.size() / 4
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		s[i] = buf.decode_float(i * 4)
	# 掐头去尾的静音不算：命中音往往后半秒全是噪声底，白乘几百万次累加
	var lo := 0
	while lo < n and absf(s[lo]) < 1e-5:
		lo += 1
	var hi := n - 1
	while hi >= lo and absf(s[hi]) < 1e-5:
		hi -= 1
	if lo > hi:
		return PackedFloat32Array()
	for i in range(lo, hi + 1):
		s[i - lo] = s[i]
	s.resize(hi - lo + 1)
	return s

## ── 多进程：拉起 / 收活 / 按全局帧序编码 / 拼音轨 ─────────────────────────
## spec 用 | 分隔（路径里不可能有 |，Windows 非法字符），引号交给 cmd.exe 处理。
func _spawn_workers(bounds: Array, total: int) -> void:
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	for k in range(1, bounds.size()):
		var spec := "%s|%s|%s|%s|%d|%d|%d|%d|%d|%d|%d|%d" % [dir_path, chart_file, skin_dir,
				_tmp, k, int(bounds[k][0]), int(bounds[k][1]), w, h,
				int(roundf(fps)), mbps, (vcodec << 1) | acodec]
		var logp := ProjectSettings.globalize_path(_tmp.path_join("w%d.log" % k))
		var cmd := "\"" + exe + "\" --path \"" + proj + "\" -- --ptnrec=\"" + spec 				+ "\" > \"" + logp + "\" 2>&1"
		var pid := OS.create_process("cmd.exe", PackedStringArray(["/c", cmd]), false)
		if pid <= 0:
			_fail = "子进程起不来 pid=" + str(pid)
			return
		_wp.append({"pid": pid, "k": k, "done": _tmp.path_join("done_w%d.txt" % k)})
	print("QA-REC 并行 ", _wp.size(), " 个子进程 + 自己 1 段，共 ", total, " 帧")

func _wait_workers() -> void:
	var tree := get_tree()
	var guard := 0
	while not _wp.is_empty() and guard < 1200000 and not _cancel:
		await tree.process_frame
		guard += 1
		var i := _wp.size() - 1
		while i >= 0:
			var e: Dictionary = _wp[i]
			if OS.is_process_running(int(e["pid"])):
				i -= 1
				continue
			_wp.remove_at(i)
			var k := int(e["k"])
			if not FileAccess.file_exists(String(e["done"])):
				# 子进程没交活：记下来，等会儿父进程自己补渲这一段（不整条作废）
				print("QA-REC worker ", k, " 没交活 → 交给主进程补渲：",
					_tail(_tmp.path_join("w%d.log" % k)))
				var b: Array = _bounds[k] if k < _bounds.size() else [0, 0]
				_failed.append([k, int(b[0]), int(b[1])])
				continue
			print("QA-REC worker ", k, " 交活")
			i -= 1
		if _win != null:
			_win.title = "录制中 · 还有 %d 个子进程在渲" % _wp.size()

## 收尾：按 k 的顺序处理每个子进程的段——没交活的先由主进程补渲，再把这块的清单压成 seg。
## 段号=时间轴，所以必须严格按 k 递增做（自己的第 0 段已经在渲的时候压完了）。
func _render_and_encode_slices(stage: ChartStage) -> void:
	if is_worker:
		return
	for k in range(1, _bounds.size()):
		var fk := -1
		for i in _failed.size():
			if int(_failed[i][0]) == k:
				fk = i
				break
		if fk >= 0:
			var a := int(_failed[fk][1])
			var b := int(_failed[fk][2])
			_failed.remove_at(fk)
			print("QA-REC 补渲 w", k, " 帧=", a, "→", b)
			part_tag = "w%d" % k
			_chunk_i = 0
			stage.record_restart()
			await _render_range(stage, a, b, _expect_total)
			await _chunk_end()
			_build_hits(stage, a, b, _expect_total)
			part_tag = "s"
		await _encode_manifest("w%d" % k)
	_failed = []

## 把一个清单里的块按行序（=全局帧序）压成 seg
func _encode_manifest(tg: String) -> void:
	var mf := _tmp.path_join("man_%s.txt" % tg)
	if not FileAccess.file_exists(mf):
		return
	var f := FileAccess.open(mf, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var lines := txt.split(String.chr(10), false)
	var fr := 0
	for ln in lines:
		var parts := String(ln).split(" ", false)
		if parts.size() < 3:
			continue
		fr += int(parts[1])
		while _enc.size() >= 4 and _fail == "":
			await get_tree().process_frame
			_prune_encodes(true)
		if _fail != "":
			return
		_encode_chunk(_tmp.path_join(String(parts[2])), int(parts[1]))
	if String(tg) != "s":
		_worker_frames += fr
	print("QA-REC 收 ", tg, "：块=", lines.size(), " 帧=", fr)

## 原生编码器把 MP4 直接写在 out_path 上，没有"分段拼接"这一步；只做存在性检查
func _concat_native() -> void:
	if _fail != "":
		return
	if _nat_out_bytes <= 0 and not FileAccess.file_exists(out_path):
		_fail = "原生编码没有产出文件"
		return
	var bytes := _nat_out_bytes
	if bytes <= 0:
		var f := FileAccess.open(out_path, FileAccess.READ)
		if f != null:
			bytes = f.get_length()
			f.close()
	var mb := float(bytes) / 1048576.0
	var kbps := int(float(bytes) * 8.0 / 1000.0 / maxf(float(_expect_total) / maxf(fps, 1.0), 0.1))
	print("QA-REC 原生成片 ", out_path, " %.1fMB 实测≈%dkbps 目标=%dMbps" % [mb, kbps, mbps])
	if kbps < mbps * 500:  # 目标码率的一半以下：编码器没听 CBR，留证据
		print("QA-REC 码率偏低：编码器可能忽略了 bitrate-mode")

## 各段打击音裸 PCM 首尾相接 = 整条音轨。哪段没交（那段一次命中都没有）就补同样长的静音，
## 少一段会让后面所有段整体前移——音画就对不上了。
## 各段打击音裸 PCM 首尾相接 = 整条音轨。哪段没交（那段一次命中都没有）就补同样长的静音，
## 少一段会让后面所有段整体前移——音画就对不上了。
func _join_hits(bounds: Array) -> void:
	if bounds.size() <= 1 or song_path == "" or _fail != "":
		return
	var all := _tmp.path_join("hits_all.f32")
	var o := FileAccess.open(all, FileAccess.WRITE)
	if o == null:
		return
	var tags: Array = ["s"]
	for k in range(1, bounds.size()):
		tags.append("w%d" % k)
	var got := 0
	for i in tags.size():
		var p := _tmp.path_join("hits_%s.f32" % String(tags[i]))
		var want := (int(roundf(float(bounds[i][1]) / fps * SR))
				- int(roundf(float(bounds[i][0]) / fps * SR))) * 2 * 4
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null:
			var z := PackedByteArray()
			z.resize(maxi(want, 0))
			o.store_buffer(z)
			continue
		got += f.get_length()
		o.store_buffer(f.get_buffer(f.get_length()))
		f.close()
	o.close()
	_hits_file = all
	print("QA-REC 音轨拼接 段=", tags.size(), " 字节=", got)

func _finish(stage: ChartStage) -> void:
	if OS.get_cmdline_user_args().has("--qakeeptmp"):
		print("QA-REC 临时目录留着（--qakeeptmp）：", _tmp)
	else:
		_clean_tmp()
	# 帧数对不上就是链上漏了块——宁可日志里喊出来，也别交一部"看着完整、
	# 其实中间跳了几十帧"的片子（_qarender 的验收判据也看这一行 + 外面 ffprobe 数帧）
	# 用户按 Esc 收手是"故意渲到一半"，不能算账目不符
	var all_f := _frames + _worker_frames
	if _expect_total > 0 and all_f != _expect_total and not _cancel:
		print("QA-REC 帧数不符：应 ", _expect_total, " 自己渲 ", _frames,
			" 子进程交 ", _worker_frames)
	_leave_offscreen()
	if _muted:
		AudioServer.set_bus_volume_db(0, _master_db)
		_muted = false
	if _win != null and is_instance_valid(_win):
		_win.always_on_top = _aot0
		_win.title = _win_title
		DisplayServer.window_set_size(_win_size)
		_win.position = _win_pos
		DisplayServer.window_set_mode(_win_mode)
		# 帧率策略与 vsync 一律按 prefs 原样设回（不是记 _run 前那次读值）：
		# 录制期间用户可能进过设置页改过，回到他的设置才对
		UserPrefs.vsync_apply()
	Engine.max_fps = UserPrefs.int_of("fps_cap") if UserPrefs.flag("fps_lock") else 0
	if is_instance_valid(stage):
		stage.record_end()
	var secs := float(Time.get_ticks_msec() - _t_ms) / 1000.0
	var ok := false
	var sz := 0
	if _nat_out_bytes > 0:
		# 相册输出（mediastore:）：文件不在可访问的目录里，大小以原生编码器写的字节数为准
		ok = _fail == ""
		sz = _nat_out_bytes
	elif _fail == "":
		ok = FileAccess.file_exists(out_path)
		if ok:
			var f := FileAccess.open(out_path, FileAccess.READ)
			if f != null:
				sz = f.get_length()
				f.close()
	print("QA-REC %s frames=%d 墙钟=%.1fs 内容=%.1fs 速度=%.2fx 抓图+写盘=%.1fms/帧 → %s (%.1fMB)" % [
		"OK" if ok else "FAIL", all_f, secs, float(all_f) / fps,
		(float(all_f) / fps) / maxf(secs, 0.001), float(_grab_us) / 1000.0 / maxf(float(_frames), 1.0),
		out_path, float(sz) / 1048576.0])
	if not ok:
		print("QA-REC reason=", _fail)
	finished.emit({"ok": ok, "path": out_path, "frames": all_f, "secs": secs,
		"error": _fail, "bytes": sz})

func _clean_tmp() -> void:
	# 空串必须挡掉：DirAccess.open("") 不是"打不开"，而是开到当前工作目录，
	# 那样下面那个循环就会把**工程目录**的文件挨个删掉。这条路径平时走不到，
	# 但一旦 _tmp 因为哪个早退分支没赋值，代价就是整个仓库。
	if _tmp == "" or not _tmp.contains(".rec"):
		return
	var da := DirAccess.open(_tmp)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(_tmp.path_join(String(f)))
	DirAccess.remove_absolute(_tmp)

## 抓一帧：后缓冲 → RGB8 → 追加进当前块的 raw 流。
## 尺寸对不上（窗口被系统夹过/旋转屏）就重采一次并只报一次，不静默出错误尺寸。
## 四段分别计时：这台机器上"读回"和"写盘"谁是瓶颈只能量出来看（上一版整条只有 1.1× 实时，
## 光看总帧数分不出是渲染慢、读回慢、还是编码器把 CPU 抢走了）。
func _grab() -> void:
	var t0 := Time.get_ticks_usec()
	# 读的是那块离屏 RT（构造上就是目标尺寸），不是窗口的交换链
	var img := _sv.get_texture().get_image()
	var t1 := Time.get_ticks_usec()
	var want := Vector2i(w, h)
	if img.get_size() != want:
		if not _size_warned:
			_size_warned = true
			print("QA-REC 后缓冲=", img.get_size(), " ≠ 目标=", want, "，逐帧双线性重采")
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)
	# 像素格式：第一帧是什么就喂什么（RGB8→rgb24 / RGBA8→rgba），
	# 之后的帧万一变了才转一次——**绝不能写死**，否则字节流错位、整片变黑
	var fmt := img.get_format()
	if _pix == "":
		if fmt == Image.FORMAT_RGBA8:
			_pix = "rgba"
		elif fmt == Image.FORMAT_RGB8:
			_pix = "rgb24"
		else:
			img.convert(Image.FORMAT_RGBA8)
			_pix = "rgba"
			print("QA-REC 帧格式 ", fmt, " → 统一转 RGBA8")
	elif _pix == "rgba" and fmt != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	elif _pix == "rgb24" and fmt != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	var t2 := Time.get_ticks_usec()
	# QA 取证（--qadump）：离屏图与窗口各存一张 + 中心像素，一眼看出是"离屏黑"还是"整屏黑"
	if _frames == 30 and OS.get_cmdline_user_args().has("--qadump"):
		DirAccess.make_dir_recursive_absolute("user://qa")
		img.save_png("user://qa/rec_sv.png")
		var wimg := get_viewport().get_texture().get_image()
		wimg.save_png("user://qa/rec_win.png")
		var c := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
		var c2 := wimg.get_pixel(wimg.get_width() / 2, wimg.get_height() / 2)
		print("QA-REC dump sv=", img.get_size(), " fmt=", img.get_format(), " 中心=", c,
			" | win=", wimg.get_size(), " fmt=", wimg.get_format(), " 中心=", c2)
		# 舞台区域(topleft 1350x900)与右侧背景带各取一点：一样 = 舞台没画进来
		print("QA-REC dump 像素 舞台内(200,200)=", img.get_pixel(200, 200),
			" (800,500)=", img.get_pixel(800, 500),
			" 带外(1560,1000)=", img.get_pixel(1560, 1000),
			" (1600,100)=", img.get_pixel(1600, 100))
	# 原生编码器：这一帧直接喂 MediaCodec（不落盘、不分块）
	if _nat_enc != null:
		var nbpp := 4 if _pix == "rgba" else 3
		var prc := int(_nat_enc.call("push_frame", img.get_data(), nbpp))
		if prc != 0:
			_fail = "原生编码失败 rc=" + str(prc) + " " + String(_nat_enc.call("last_error"))
			return
		_frames += 1
		_us_read += int(t1 - t0)
		_grab_us += int(Time.get_ticks_usec() - t0)
		return
	# 排进写盘队列（后台线程落盘），主线程不等磁盘
	if _fa == null:
		_fail = "帧文件写不进去（磁盘满/权限）" + _chunk_path
		return
	_wbuf.append(img.get_data())
	_pump_write()
	if _fail != "":
		return
	_chunk_n += 1
	_frames += 1
	var t3 := Time.get_ticks_usec()
	_us_read += int(t1 - t0)
	_us_cvt += int(t2 - t1)
	_us_wr += int(t3 - t2)
	_grab_us += int(t3 - t0)

## 注：移动端为什么不做。成片要 H264，Godot 没有编码器，只能借系统：
## 桌面 = PATH 里的 ffmpeg（本项目已经依赖它转故事版视频），
## Android = 只能走 NDK 的 AMediaCodec/AMediaMuxer，那是要往 gdextension 里加原生编码器的
## 独立一步（且这里没法验证——平板不在手）。所以这里选择**如实关着**，
## 而不是在手机上悄悄产出没有声音、或者相册打不开的半成品。
