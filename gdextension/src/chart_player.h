#pragma once

#include <godot_cpp/classes/font.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance2d.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <vector>

namespace godot {

// 原生 RPE 谱面播放器（按 PhiZone/player 渲染链路规格）：
// 解析一次 → 每帧事件求值（含 extended scale/color/incline）→ 屏幕系父链合成 →
// _draw 画皮肤线/四类音符（control 数组透视）→ 触点判定 + 命中特效。
// 单位：图面 1350×900，原点屏心，Y 向上；旋转=度。
class ChartFxLayer;

class ChartPlayer : public Node2D {
	GDCLASS(ChartPlayer, Node2D)

public:
	// 轨迹表达式 `ease(x, type)` 用：RPE 1..29 缓动表
	static double traj_ease(int type, double x) { return _ease_fn(type, x); }

	// ---- 事件（s/t 秒；v 值；color 事件用 rgb0/rgb1） ----
	struct Event {
		double s = 0, t = 0;
		int traj = -1;         // >=0：本事件带"整体轨迹"（rpe-next moveXEvents[].trajectory）
		int traj_axis = 0;     // 0=x 1=y 2=rotation（y/rot 是同一轨迹的虚拟副本）
		double bS = 0, bT = 0;    // 起止拍（speed 导数模式 Δbeat 用）
		double v0 = 0, v1 = 0;
		double k = 0, bi = 0;     // v<170 speed：speed(beat)=k·dE/dbeat+b
		int ease = 1;          // 1=linear 2..26 RPE 表
		double el = 0, er = 1; // easingLeft/Right
		bool bez = false;
		double bp[4] = { 0, 0, 1, 1 };
		bool color = false;
		double rgb0[3] = { 1, 1, 1 }, rgb1[3] = { 1, 1, 1 };
	};

	// 线级 control 数组节点（按到线距离 chartDist 插值）
	struct Ctrl {
		double x = 0, v = 0;
		int ease = 0;
	};

	// 音符记录。字段类型是**内存预算**定出来的，不是随手写的：这张 1093 万音符的谱
	// 每条 304B ⇒ 常驻 3.6GB、加载峰值 5.8GB，手机直接被杀；而 Phira 同谱能跑。
	// 只有时间和 speed 积分链必须留 double（对拍钉的是 1e-9 级一致，hT 能量级到 1e5），
	// 其余字段数值范围都在 ±1e4 内，float 的 7 位有效数字给出 ≤1e-3px / ≤1e-5s 的误差，
	// 比任何判定窗（≥10ms）和像素都小三个数量级。整型全部按取值范围降位。
	struct Note {
		double t = 0, t2 = 0;   // 起止（秒）
		double hT = 0, hT2 = 0; // 头/尾的 speed 积分高度（图面单位，可达 1e5）
		double fp = 0;              // json.floorPosition（已换算到 player 单位）
		double mvp = 0;       // official maxVisiblePos（= fp + float32 容差）：线高越过它即整条音符不可见
		double hold_off = 0;    // official hold 刚性尾端偏移（图面单位 = SPD_UNIT·holdSec·json.speed）
		double hold_rate = 0;   // official hold 尾端收到线上的速率（图面单位/秒 = SPD_UNIT·json.speed）
		float vis_lo = 0;       // t - visibleTime（_finalize 预计算：绘制循环第一道闸）
		float x = 0;            // positionX（图面单位，±1e3）
		float speed = 1.0f;     // 音符自身速度倍率（只作乘数，误差随 dist 线性）
		float size = 1.0f;
		float yoff = 0;         // yOffset（已乘 speed，player 语义）
		float alpha = 255;      // 0..255
		float vtime = 999999;   // visibleTime；缺省=不限（PE 负 alpha 编码折出来的秒数）
		float jt = 0;           // 判定时刻（fade 用）
		float fx_last = 0;      // hold 持续特效：上次生成时刻（player 每 0.5 拍补一次）
		float z = -1;           // zIndex；-1 = 按 NOTE_PRIORITIES[type]+2（6.5 等小数层级存在）
		float zfx = 7;          // zIndexHitEffects（player 缺省 7）
		float jsize = -1;       // judgeSize；-1 = 跟随 size（player 仅 PE 转换器赋值，判定不使用）
		float tr = 1, tg = 1, tb = 1; // tint [r,g,b]/255
		float ftr = 1, ftg = 1, ftb = 1; // tintHitEffects（player createHitEffects：判定特效+粒子色）
		int above = 1;          // 音符在线的哪一侧（谱面可写任意整数，别降位）
		int8_t type = 1;        // 1tap 2hold 3flick 4drag
		int8_t state = 0;       // 0未判 1perfect 2good 3bad 4miss
		int8_t finger = -1;     // 绑定的触点槽 0..15（-1=无）
		int8_t temp_state = 0;  // hold 头部暂判（1/2）；尾部 settle 才计入统计
		int8_t temp_late = 0;   // 头部暂判的早/晚方向（尾判入统计时才知道该进哪一行）
		int8_t safe_frames = 0; // hold 中段抬指保护（连续 2 帧无指才断）
		// 判定管线（player JudgmentHandler 两段式：匹配→评分，四类音符四套控制）
		bool has_fp = false;    // 到达线所需 speed 积分高度存在（official floorPosition）
		bool rigid_tail = false; // true=尾端取 hT+hold_off（official 语义）；false=取线 speed 积分（RPE/PE）
		bool fake = false;
		bool multi = false;     // 同拍多押 → 用 HL 贴图（PhiTogether highLight 默认开）
		bool click_matched = false; // 点击已认领（黄键/红键保护下才允许换绑）
		bool drag_marked = false;   // 黄键：任意手指在 ±0.1s 窗内靠近即成
		bool flick_matched = false; // 红键：需划动手势
		bool hold_head = false;     // 头部已接住（含 temp）
		bool hold_missed = false;   // 中段断/尾漏：终判 Miss，控制即终止
		bool hold_over = false;     // 尾部已结算（计入统计一次）
		bool has_tint = false;
		bool has_fx_tint = false;
		String hs;              // hitsound 自定义资源名（空=按类型默认）
	};

	// ── 整体轨迹（rpe-next curve-trajectory.mjs）──
	// 表达式编译成后缀程序（RPN），槽位 0=t 1=u 2=theta 3=seed 4=randomness 5..=自定义参数。
	struct TrajOp {
		int op = 0;     // 0=常量 1=变量 2..7=+ - * / % ^ 8=neg 9=not
		                // 20..33=abs min max floor ceil round sin cos tan sqrt pow clamp lerp ease
		                // 40..47=lt gt le ge eq ne and or  50=ternary
		double num = 0;
		int var = 0;
		int argc = 0;
	};
	struct TrajProg { std::vector<TrajOp> ops; };
	struct Traj {
		bool ok = false;
		int mode = 0;    // 0=parametric 1=polar
		int shape = 0;   // 0=无 1=star 2=random-polygon
		bool tangent = false, align = false, has_dir = false;
		double trim0 = 0, trim1 = 1, rot = 0, sx = 1, sy = 1, startX = 0, startY = 0;
		double seed = 1, randomness = 0;
		int easeX = 1, easeY = 1;
		std::vector<std::pair<String, double>> params;
		TrajProg px, py, pr, pdir;
		double begin = 0, finish = 1;
		double firstX = 0, firstY = 0;
		std::vector<double> angles; // tangentRotation 的 1025 点角度表（含 360° 解缠）
	};
	struct Layer {
		std::vector<Event> alpha, mx, my, rot, speed;
	};

	struct Line {
		std::vector<Layer> layers;
		std::vector<int> cur_ev; // 事件游标（4/层：alpha,mx,my,rot）——坏苹果 3.4 万线
		                         // 逐帧二分是 set_now 大头；单调帧只前移 O(1)，seek 回退/大跳自动二分重锚
		// extended（layer 0）
		std::vector<Event> ext_sx, ext_sy, ext_color, ext_incline, ext_gif; // gifEvents：动画贴图进度
		bool is_gif = false;   // rpe-next line.isGif（扩展名之外的显式动画标记）
		float gif_prog = -1;   // 当前 gifEvents 值（<0=没有事件，按时间自动播）
		// control 数组
		std::vector<Ctrl> c_alpha, c_pos, c_size, c_skew, c_y;
		std::vector<Traj> trajs;   // 轨迹池（Event::traj 为线内下标；rpe-next 每条 event 自带 options）
		std::vector<Note> notes;
		double n_lo = 0, n_hi = -1e18; // 本线音符时间窗 [min vis_lo, max t2+1s]（_finalize 算）：
		                               // 窗外整条线跳过音符循环（bad apple 3.4万线×1note）
		// 事件值缓存（alpha/mx/my/rot 之和）：全部瞬时事件（cp/cd/ca/cv）时两事件之间
		// 线状态不变——tsec<ev_next 直接复用缓存，跳过 4 数组游标推进（bad apple
		// set_now 8.8ms 的主体是 3.4 万线×每帧 4 评估）。speed 积分不受影响（每帧照走）。
		double ev_next = 0, last_tsec = -1e18;
		double k_a = 0, k_x = 0, k_y = 0, k_r = 0;
		bool ev_init = false;
		std::vector<int> nord;  // 绘制序：稳定按 zIndex（未定义→类型优先级+2），_finalize 构建
		// 每帧音符扫描的二分前提（_finalize 校验）：notes 按 t 升序、hT 又随 t 单调，
		// 于是「在屏上」= 「hT 落在一个区间里」= 「下标落在一段连续范围内」。
		// nrank[i] = 音符 i 在 nord 中的位次：候选按它重排才能还原 zIndex 绘制序。
		std::vector<int> nrank;
		bool t_mono = false;
		double hold_span = 0;        // 本线最长 hold 时长（秒）：hold 续特效窗的左界
		int am_cur = 0;              // autoplay 自动判定的前向游标（整曲只走一遍）
		// 高度候选窗聚合量（_finalize 算）：音符上屏 ⟺ 它的目标高度落在
		//   |(hT-height)·speed·dScale + ky·yoff| ≤ cull
		// 之内，所以对「按 hT 升序」的数组二分就能取到本帧候选。
		// h_mono=false（speed 积分非单调 / official 手填 floorPosition 乱序）时不许二分。
		double h_spd_min = 1, h_yoff_abs = 0, h_delta_max = 0;
		bool h_mono = false;
		bool has_static = false; // 含 speed=0 的"静态钉线"音符 → 该线放弃 hT 窗、全表扫（rpe-next staticNotes）
		int father = -1;
		int zorder = 0;
		double zidx = -1;     // 线级 zIndex（player Line.ts:296：有则替代 2+precedence）
		double depth = 2;     // _finalize 计算的深度桶（targetRange 路由用）
		bool rwith = false;   // rotateWithFather
		bool cover = false;   // isCover：音符到线前不可见
		bool ui_attach = false; // attachUI 非空：UI/文字挂载线（player _hasAttach）
		String attach;          // attachUI 名（score/combo/name/level/pause/bar…）
		int aoe = 0;              // appearanceOnAttach：0=线精灵随挂载隐藏，≠0=仍显示
		double ax = 0.5, ay = 0.5; // anchor（player Line.ts:300 setOrigin(a[0],1-a[1])）：
		                           // 线贴图锚点，テレパシ 锤子初音两帧错位真因
		double bpmf = 1;      // bpmfactor（秒/拍换算）
		String texture = "line.png"; // RPE "Texture"：线贴图文件名（缺省 line.png，player Line.ts:266）
		bool block_marker = false;   // Texture=isSubtract0/1.png：这是**噪域标记线**（编辑器引导图），
		                             // 不当普通线画、不请求贴图、几何/颜色喂给 _blocks
		// extended.textEvents：线以文字呈现。口径 = rpe-next src/core/events.mjs EventTrack：
		// 事件内从 start 文本逐字打到 end 文本；事件结束后**保持 end 文本**（不删字）。
		struct TxtEv {
			double t0 = 0, t1 = 0;
			String s0, s1;
			String font;   // textEvents[].font：皮肤/谱包里的字体名（空=内置字体）
			int ease = 1;
			double el = 0, er = 1;
			bool bez = false;
			double bp[4] = { 0, 0, 1, 1 };
		};
		std::vector<TxtEv> tx_ev;
		String cur_text;
		String cur_font;
		bool has_text = false;
		// textEvents **有声明**（哪怕每条事件的文字都是空的）⇒ 这条线是文字线，
		// 只画字、永远不画线精灵。用户口径："文字事件但没有文字" 的线要隐藏，
		// 不能因为没有非空文字就退化成普通白线（屏幕正中一条 3 屏宽的线）。
		bool text_kind = false;
		// 每帧缓存
		double ox = 0, oy = 0, rot_deg = 0; // 本地（图面）
		double wx = 0, wy = 0, wrot = 0;    // 世界（屏幕像素/弧度）
		double opa = 0;                     // 0..1；<-0.5 隐藏全部；-0.5..0 镜像半平面
		double txt_opa = 1;                 // 文字线当前透明度（= 线 alpha；rpe-next 同式）
		double araw = 0;                    // alpha 原始和（−1/−2 镜像语义按此判断）
		double esx = 1, esy = 1, einc = 0;  // extended 当前值
		double tr = 1, tg = 1, tb = 1;      // colorEvents tint（0..1）
		double height = 0;
		std::vector<double> cur_h;
		std::vector<int> cur_i;
	};

	struct FX {
		double x = 0, y = 0, t0 = 0;
		int kind = 0; // 0 perfect 1 good
		double rot = 0; // 生成时判定线的世界角度（phira hitFxRotate 才用）
		double depth = 7;    // 命中特效容器深度 = note.zIndexHitEffects（player JudgmentHandler:892）
		bool has_tint = false;
		double tr = 1, tg = 1, tb = 1; // tintHitEffects（player：hit(tint) 覆盖判定色）
		double pd[4] = {0, 0, 0, 0}; // PT 粒子射程（185~265 图面单位），Perfect 4 颗 / Good 3 颗
		double pa[4] = {0, 0, 0, 0}; // PT 粒子角度（0~2π）
	};

	// ── 官方谱 blockArea（噪域）──
	// 语义权威 = Phira-Pro 的 prpr fork `src/core/block.rs`（逆向自官游
	// PreviewBlockControl / JudgeControl / BlockArea，注释带 RVA 地址），KaedePhi 只作字段映射佐证
	// （它自己的 GUI 对含噪域的谱弹"行为暂时尚不明确…无法进行任何处理"）。要点：
	//   * 关键帧段 = [本帧, 下一帧]，用【本帧】的 easeType 从本帧值插到下一帧值；首帧前取默认
	//     （move=无 / rotate=0 / scale=1），末帧后保持末帧值；easeType 0=Linear、1..12=幂表
	//     （n=(type-1)/3+2，余数 In/Out/InOut）、13=HoldStart（整段按住起值）、14=JumpToEnd；
	//   * 锚点是**阶跃**的（取本帧 anchor，不插值）；rect 的 center 要按每个关键帧的锚点差
	//     逐段搬运（"锚点不动、框长大/转过去"），顺序 = 缩放 → 旋转 → move 增量；
	//   * size = 基准尺寸 × scale（不绕锚点），rotation 绕搬运后的 center；
	//   * 相位只有 3 个：Hidden / Disabled / Active（`ready` 是渲染层概念=enable 前 0.5s，
	//     与 Active 同层绘制）；Disabled 渐显 0.5s 仅当 appear 时刻尚未激活；
	//   * 触点拦截 = **奇偶规则**（normal 覆盖 XOR subtract 计数的奇偶），且同时测"整框"和
	//     "内缩框"（blockTouchInset：0.05×屏高，普通框缩小、减算框放大），两者都判阻塞才阻塞；
	//   * 坐标 = 屏百分比 [0,1] 原点左下 → 图面系 x∈[-1,1]、y∈[-1/aspect,1/aspect]（1 单位=半屏宽，
	//     各向同性）；官方角度逆时针为正（y 上图面系），进本管线 y 向下画布时由映射自动翻掉。
	struct BlockRot {
		double t = 0, ax = 0, ay = 0, rot = 0;
		int ease = 0;
	};
	struct BlockMove {
		double t = 0, ex = 0, ey = 0;
		int ease_x = 0, ease_y = 0;
	};
	struct BlockScale {
		double t = 0, ax = 0, ay = 0, sx = 1, sy = 1;
		int ease_x = 0, ease_y = 0;
	};
	// rpe-next（Re:PhiEdit Next，RPEVersion>=220）的噪域轨道：**每轴一条独立轨道**，
	// 和官方案"一条事件同时带 x/y 两个分量和两个 ease"不同 —— 它的 moveX/moveY/scaleX/scaleY
	// 各自有自己的关键帧时刻、各自的锚点和各自的缓动，混到一条时间轴上会在两轴键时刻不一致时
	// 改变曲线形状（把一个 ease 拆成两段各自 ease ≠ 原 ease）。
	// ev = 采样用的 RPE 事件（s/t 秒、v0→v1、ease/bez/easingLeft/Right，直接复用 _event_value）；
	// tv0/tv1 = rpe-next 的 transformStart/transformEnd：官谱 ease 13/14 导进来的阶跃键里，
	// 采样值是平的、但"围绕锚点累计多少"看的是这两个参考值。
	struct BlockSpan {
		Event ev;
		double ax = 0, ay = 0;      // 锚点（归一化百分比），仅旋转/缩放用
		double tv0 = 0, tv1 = 0;    // 变换基准/终值
	};
	// RPE 噪域标记（phira-Pro prpr/src/core/rpe_block.rs 的 Span）：
	// 一条 marker 线可以反复"出现→激活→失效→消失"，所以生命周期是**多段**，
	// 每段带自己的四个时间（appear/enable/disable/disappear）给现算的 phase 用。
	struct BSpan {
		double start = 0, end = 0;
		int phase = 0;              // 0 Hidden 1 Disabled 2 Active
		double t[4] = {0, 0, 0, 0}; // appear / enable / disable / disappear
	};
	struct Block {
		int layer = 0;                          // 噪域层（rpe-next noiseAreaLayers；默认 0）
		double trx = 0, tr_y = 0, blx = 0, bly = 0; // 两对角（归一化百分比，原点左下）
		double appear = 0, enable = 0, disable = 0, disappear = 0; // 音乐秒
		bool sub = false;
		std::vector<BlockRot> rot;
		std::vector<BlockMove> mv;
		std::vector<BlockScale> sc;
		// ── RPE 通道（贴图线当噪域标记）专用：src_line>=0 时上面那些字段全不用 ──
		int src_line = -1;             // 载体线的索引（几何/颜色逐帧从它的世界状态推）
		std::vector<BSpan> rpe_spans;  // 多段生命周期（speed 状态码或 alpha 状态码算出来）
		double pw = 900, ph = 900;     // 标记贴图尺寸（编辑器引导图，缺省按 900×900）
		double anx = 0.5, any_ = 0.5;  // RPE 原始 anchor（Line::ax/ay 存的是翻转后的 Phaser origin）
		// 每帧缓存（update_blocks 写）
		int phase = 0;   // 0 Hidden 1 Disabled 2 Active
		bool ready = false;
		double opacity = 0;
		double ccx = 0, ccy = 0; // 图面系 center
		double hhx = 0, hhy = 0; // 图面系 half size（**旋转前**的单位，不含 ys）
		double rot_ccw = 0;      // 图面系角度（度，逆时针正）
		// Line2Area 专用：先在 1350×900 创作画布里转，再按视口纵向拉伸
		// （prpr BlockTransform::y_scale = 1.5/aspect；官方案 blockAreaList 恒 1）
		double ys = 1.0;
		double qx[4] = {0, 0, 0, 0}, qy[4] = {0, 0, 0, 0}; // 画布像素四角（y 向下）
		// 逐区颜色（phira-Pro 的 Marker.color / Zone.color）：默认 DEFAULT_BLOCK_COLOR
		double cr = 1.0, cg = 84.0 / 255.0, cb = 84.0 / 255.0;
		// ── rpe-next（RPEVersion>=220）专用：nx1=true 时上面那套 mv/rot/sc 全不用 ──
		bool nx1 = false;
		int nx_area = -1;               // 源 blockAreaList 下标（一段一 Block，给对拍脚本认亲用）
		std::vector<BlockSpan> mvx, mvy, rot1, scx, scy;
		double ready_lead = 0.5; // activeIntervals[].readyFlash（预警闪烁提前量，秒）
	};

private:
	std::vector<Line> _lines;
	std::vector<double> _bpm_beats, _bpm_times, _bpm_bps;
	std::vector<double> _pe_bpm_beats, _pe_bpm_vals; // .pe 原始断点（拍,bpm）
	int _bpm_n = 0;
	double _duration = 0;
	bool _loaded = false;
	int _dbg_lines_drawn = 0; // QA：最近一次 _draw 里通过了深度门的线数（幽灵/主实例分开数）
	int _dbg_tex_draws = 0;   // QA：其中走了贴图分支的
	int _dbg_line_skip_opa = 0; // QA：其中因 opa<=0 被跳过的
	int _dbg_tex_invalid = 0;   // QA：defline 无效（掉到 draw_line 兜底）
	int _speedMode = 0; // 0=RPE<170 导数仿射 speed；1=≥170 直接积分
	int _rpe_ver = 0;   // META.RPEVersion（rotateWithFather 缺省值按 >=163 判）
	int _nx_cursor = -1; // 当前正在解析的 rpe-next blockAreaList 下标（一段一 Block，对拍要认亲）
	String _name, _level;

	std::vector<FX> _fx;

	std::vector<Block> _blocks; // 噪域列表（官方 blockAreaList 或 RPE 标记线；列表序 = 合成序）
	double _now_music = 0;      // 音乐秒原值（blockArea 时间轴，不减 offset）
	bool _blk_sizes_dirty = false; // RPE 标记贴图的真实尺寸还没取到（贴图在 load 之后才注入）

	// 噪域掩码（CPU 复刻 prpr block_mask.rs，见 chart_block.cpp）
	struct BlockMaskBuf {
		int bw = 0, bh = 0;
		std::vector<unsigned char> l;      // 6 层栅格（每层 bw*bh）
		std::vector<unsigned char> rawg;   // disabled 减算 green
		std::vector<unsigned char> readyg; // ready 减算 green
		std::vector<unsigned char> compose, disabled, rgba, aux;
		std::vector<unsigned char> hover; // 触摸 hover 掩码：1/8 屏网格（官方 touch camera）
		std::vector<int> d0, d1;          // 行差分+前缀和的复用缓冲（原来每帧 new 两块 923KB）
		// ── 逐区配色（prpr block_color.rs 的 Colors）──
		// 配色与覆盖独立：色相不改减算/触点/透明度/边缘辉光。种子只从"合成后存活的那一侧"
		// 取（被抵消的框不能把自己的颜色渗进别人的描边），两次 chamfer 扫描把最近种子
		// 传到辉光环与被挖的洞里。Active 层还要按位移源像素重取一次颜色（跟场一起跑）。
		std::vector<unsigned char> col0, col1, raw_active;
		std::vector<size_t> seeds, owners;
		struct ColZone {
			double cx, cy, hx, hy, rot, ys, op;
			int flags; // bit0=active bit1=invert bit2=非默认色
			bool operator==(const ColZone &o) const {
				return cx == o.cx && cy == o.cy && hx == o.hx && hy == o.hy && rot == o.rot
						&& ys == o.ys && op == o.op && flags == o.flags;
			}
		};
		std::vector<ColZone> col_zones;   // 上一次播种用的区集合
		// ── 栅格结果签名缓存：几何没跨过像素边界的那几帧，跳过 清零 + 六层栅格 + 前缀合成 ──
		// 方向取自 prpr `Masks::render_displaced` 的 `last_zones == zones`，但判据换成**行段**：
		// 实测浮点几何签名在 ハテ AT 上 240 帧只命中 1 帧（move/rotate 每帧都在插值），
		// 而"每区逐行 [y,first,last)"是栅格的真正输出——段没变 ⇒ 六层与差分数组逐字节不变
		// ⇒ 合成/disabled 也不变。代价是每帧多跑一遍行段计算（实测 栅格=50~114µs），
		// 换来的是命中帧省掉 ~0.7~1.1ms。比较用逐字段相等，不做哈希（撞一次=某一帧画错）。
		// 签名格式（int64 序列，逐区）：[标志 | 软路径时的透明度位型 | 段数 | (y<<40|first<<20|last)…]
		// 标志低位：bit0=Active bit1=减算 bit2=ready bit3=来自 RPE 标记线 bit8=软路径。
		std::vector<int64_t> lay_sig;     // 本帧签名（复用成员，免得每帧 new）
		std::vector<int64_t> lay_prev;    // 上一次真正栅格化用的签名
		bool lay_valid = false;
		long lay_n = 0, lay_hits = 0;     // 命中率统计（debug_block_phases 末尾两项）
		bool col_warp = false;            // Active 层颜色非均匀 ⇒ 每帧按位移源重取
		double col_time = -1e18;
		int col_w = 0, col_h = 0;
		double col_aspect = -1.0;
		int hw = 0, hh = 0;
		bool hover_any = false;
		bool empty_last = false;          // 上一帧交出去的就是"全空"⇒ 这帧再全空就不必重传
	};
	BlockMaskBuf _bmb;
	// 噪域层（rpe-next noise-segment 230）：空 = 单层 "default"，行为与以前完全一致。
	struct BlockLayer { String id = "default", name = "默认层", skin, channel = "normal"; Dictionary params; };
	std::vector<BlockLayer> _block_layers;
	std::vector<BlockMaskBuf> _bml;   // 每层一份掩码缓冲（仅 N>1 时使用）
	// 掩码构建的分阶段耗时（µs 累计 + 完整构建的帧数）。搬线程之前要先知道钱花在
	// 六段里的哪一段：早退帧（没有可见区）不计数，否则均值被 60% 的空帧稀释。
	double _blk_ph[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
	int _blk_ph_n = 0;
	std::vector<unsigned char> _blk_noise; // BlockNoise1 的 R 通道（已按 GL 行序翻转）
	int _blk_nw = 0, _blk_nh = 0;
	double _blk_warp = 1.0;
	double bm_noise(double u, double v) const;

	double _now = 0;
	double _offset = 0; // 秒（谱面 META.offset；player Game.ts:957 timeSec = realTime − offset/1000）
	// 判定补偿（player Game.ts:713 `_offset = META.offset + preferences.chartOffset`，
	// chartOffset 单位 ms、可正可负）。真机触摸/音频链路延迟由它吸收，不做"猜值自动补偿"。
	double _user_offset = 0; // 秒
	bool _multiHint = true;  // player preferences.simultaneousNoteHint（关=moments 空=一律不高亮）
	// 取景口径：true=注重演出（音符折回"编辑器 px"后超出 ±675 制谱器画框的不画，
	// 宽屏不再露出作者看不见的表演元素）；false=注重游玩（框外也照画，宁可看见再判）。
	bool _frame_cull = true;
	// 判定粒子形状：PT 在线资源包在 meta.json 里自带绘制代码（hitEvtDrawer），
	// 官方 Phigros 包是 ctx.fillRect(...)=**方块**，缺省那条是 arc=圆。
	// 0=圆（内置与 prpr/phira 那套），1=方块（包声明了 fillRect）。见 SkinPack._parse_meta_json。
	int _fx_particle_shape = 0;
	// 判定窗口（秒）。player JudgmentHandler.windows()：P/G 读 preferences，
	// B = G + BAD_EXTRA(0.04)，F = FLICK_P_FACTOR(1.75) × P；黄键 D=0.1 不随窗口变。
	double _jp = 0.08, _jg = 0.18, _jb = 0.22, _jf = 0.14;
	std::vector<double> _jdeltas; // player _judgmentDeltas 的 delta 部分（秒；正=按晚）
	double _kx = 1.0, _ky = 1.0, _cx = 675.0, _cy = 450.0;
	double _cw = 1350.0, _ch = 900.0; // set_scale 画布存档（headless 诊断的权威尺寸）
	double _noteScale = 1.0;          // 设置页「音符大小」：只缩放音符/hold 贴图，不动判定与位置
	double _fxUserScale = 1.0;       // 设置页「特效大小」：只缩放命中特效与粒子

	double _b2s(double beat) const {
		int cur = 0;
		for (int i = 0; i < _bpm_n; i++) {
			if (_bpm_beats[i] <= beat + 1e-6) cur = i;
			else break;
		}
		return _bpm_times[cur] + (beat - _bpm_beats[cur]) / _bpm_bps[cur];
	}
	double _s2b(double sec) const {
		int cur = 0;
		for (int i = 0; i < _bpm_n; i++) {
			if (_bpm_times[i] <= sec + 1e-6) cur = i;
			else break;
		}
		return _bpm_beats[cur] + (sec - _bpm_times[cur]) * _bpm_bps[cur];
	}

	// 噪域触摸特效的单个手指槽（官方 block_touch.rs 的 Slot）
	struct BTouchSlot {
		int finger = -1;    // 手指号；-1=空闲或正在消失
		bool seen = false;  // 本帧是否还按着（没按到就进 Hide）
		double cx = 0, cy = 0; // 画布 UV，原点左下、y 向上
		double t0 = 0, s0 = 0, s1 = 0, scale = 0;
	};
	struct Finger {
		bool down = false;
		// 噪域"感染"锁：官方 judge.rs 每帧把落在 Active 域里的触点从手指表里摘掉，
		// 一旦 infected 就持续到该手指 Ended/Cancelled —— 离开噪域也不会恢复。
		bool blocked = false;
		double x = 0, y = 0;
		double hx = 0, hy = 0; // 原始触点位置：被噪域感染而退出判定流程的手指也要画 hover
		double x0 = 0, y0 = 0;
		double t0 = 0;
		bool new_flick = false;
		// player 手指运动学：d1=本帧位移、d0=上一帧位移（世界单位=1/10 画布高），
		// px/py=上帧结算位置；stopped=静止判定（连击红键的门槛），lifted=刚抬起
		// 还差最后一次运动学结算（同帧内 划→松 不丢手势）。
		double d0x = 0, d0y = 0, d1x = 0, d1y = 0;
		double px = 0, py = 0;
		bool stopped = true;
		bool lifted = false;
	};
	Finger _fingers[16];
	// 判定管线状态（player _pendingClicks/_controls/_notesByTime 同构）
	struct NT { int line = 0, note = 0; double t = 0; }; // 全局时间序音符表条目（非 fake）
	std::vector<NT> _notes_by_time;                      // 按 t 升序——匹配/激活窗二分用
	std::vector<int> _pending_clicks;                    // touch_down 排队，set_now 消费
	std::vector<std::pair<Line *, Note *>> _controls;    // 存活控制（评分中）
	int _ctl_cur = 0;                                    // 控制激活游标（_notes_by_time 下标）
	double _prev_now = -1e18;                            // 上帧时刻（帧时长→划速归一）

	int _perfect = 0, _good = 0, _bad = 0, _miss = 0;
	// player 把 Good 分成 GOOD_EARLY / GOOD_LATE 两个计数（PT 的暂停统计面板
	// 也要 Early/Late 两行）；_good 仍是两者之和，判分/准确率不受影响
	int _good_early = 0, _good_late = 0;
	int _combo = 0, _max_combo = 0;
	int _total_notes = 0;
	bool _fcApIndicator = true; // player getLineColor：全 AP 线淡黄 / FC 淡蓝 / 破线白
	bool _autoplay = false;     // 自动 Perfect 判定（player autoplay：命中音效+特效）
	std::vector<std::pair<int, String>> _hitq; // P/G 命中事件队列 [type, hitsound 名]，GDScript 取走发声
	std::vector<int> _draw_order;              // 线绘制序（按 zorder，_finalize 缓存，避免每帧重排）
	std::vector<int> _cand;                    // 每帧音符候选下标缓冲（复用，避免 1093 万级谱上反复分配）
	std::vector<unsigned char> _pc_done;       // set_now 父链合成：帧间复用的"已落位"标记（同 _cand 的理由）
	std::vector<size_t> _pc_chain;             // set_now 父链合成：帧间复用的依赖链暂存
	double _hold_span_max = 0;                 // 全谱最长 hold（秒）：hold 续特效候选窗的左界

	// ── GPU 实例化音符层 ──
	// 现状是 CanvasItem 每帧逐个 draw_texture_rect：实测约 1µs/个（1093 万音符谱里
	// 有一帧真有 41 万个通过判据 ⇒ 单音符层 412ms）。搬到 MultiMeshInstance2D 后
	// CPU 侧只剩"写实例数组"，原型量到 40 万个 10px quad 与"什么都不画"同价。
	// 分组 = 深度桶 × 贴图（合批的前提，也是 prpr 的 BatchRenderer 的分组方式）。
	enum MmKind {
		MK_HOLD_BODY = 0, MK_HOLD_HEAD, MK_HOLD_TAIL,   // hold 在下（player NOTE_PRIORITIES）
		MK_HOLD_TAIL_HL,                               // phira 的 hold_mh.png 自巸有尾帽（prpr 用多押图集）
		MK_DRAG, MK_TAP, MK_FLICK,
		MK_HOLD_BODY_HL, MK_HOLD_HEAD_HL, MK_DRAG_HL, MK_TAP_HL, MK_FLICK_HL,
		MK_N
	};
	struct MmGroup {
		Ref<MultiMesh> mm;               // RefCounted，可 Ref<>
		MultiMeshInstance2D *node = nullptr;   // Node 派生不归 Ref 管，生命周期交给树
		std::vector<Vector2> xf;   // 每实例 3 条：X 轴 / Y 轴 / 原点（4.7 实测布局）
		std::vector<Color> col;
		int cap = 0;               // 已分配实例数（高水位，避免每帧重分配）
		Ref<Texture2D> tex;        // 建节点时用的贴图；换皮后要能察觉
	};
	std::vector<MmGroup> _mmg;     // 索引 = 深度桶 * MK_N + kind
	ChartFxLayer *_fxl = nullptr;    // 命中特效层（排在所有音符节点之后）
	bool _mm_nodes = false;        // 子节点是否已建
	bool _mm_ok = false;           // 深度桶太多放不下时= false，音符必须留在旧路径
	bool _note_mm = true;          // false=退回逐个 draw_texture_rect（同进程 A/B 对拍）
	// 旧路径也照填实例缓冲（只为对拍能读到"旧路径这一帧到底落了哪些 quad"）。
	// 生产默认关：关掉时不分配、不清零、不写属性口，旧路径一分钱都不多花。
	bool _mm_rec = false;
	static int _mm_bucket(const std::vector<double> &ds, double depth);
	Ref<Texture2D> _mm_tex(int kind);
	void _mm_ensure(ChartPlayer *S);   // 状态来源 S（幽灵实例读主实例），节点归 this
	void _mm_quad(int bucket, int kind, const Line &l, double cosr, double sinr,
			double cx, double cy, double w, double h, double shear, const Color &c);
	void _mm_push(int bucket, int kind, const Vector2 &bx, const Vector2 &by,
			const Vector2 &origin, const Color &c);
	void _mm_commit(bool show);
	void _mm_reset();

	// 低端 120 帧诊断：主线程 CPU 侧 _draw / set_now 累计耗时（µs），不受 vsync/GPU 干扰
	double _prof_draw_us = 0, _prof_set_us = 0;
	int _prof_n = 0;
	// _draw 内部分相（µs 累计 + 次数）：定位"到底是哪一段在花钱"。
	// commit 那一段单独计时，并记下"每帧写出去的实例数"和"真正有用的实例数"——
	// 两者之比就是高水位 cap 的浪费倍数（cap 只涨不落 ⇒ 一帧密集，帧帧跟着付）。
	double _ph_lines_us = 0, _ph_cand_us = 0, _ph_notes_us = 0, _ph_commit_us = 0;
	int64_t _ph_cap_written = 0, _ph_n_used = 0, _ph_frames = 0;
	// 视口外接框（画布尺寸，_draw 每帧从 S 带进来）：实例化那条路在 _mm_quad 里
	// 做"整块 quad 在视口外就不提交"的剔除。这不是新加的画面规则——本来就落在
	// 视口外的 quad 一个像素都不产生（旧路径交给光栅器裁掉），这里只是把它从
	// 缓冲和 draw call 里省掉。A/B 台逐像素验。
	double _vpx = 0, _vpy = 0;
	int64_t _vcull_drop = 0;

	// ── 临时：千万音符谱（1093 万 note 的 .pe）耗时/候选窗归因，量完即删 ──
	// _draw 里统计：全表扫描数 vs 真正建 quad 数，以及「按高度窗二分」的候选数。
	// _pb_out 必须在所有帧都为 0，高度窗才是全表扫描的合法超集（否则不许改成二分）。
	bool _probe = false;
	int64_t _pb_scanned = 0, _pb_kept = 0, _pb_win = 0, _pb_out = 0, _pb_frames = 0;
	int64_t _pb_cand_max = 0, _pb_ctl_max = 0;   // 单帧峰值：候选数 / 活控制数

public:
	// FLAC → 裸 int16 PCM（third_party/dr_flac.h）。Godot 运行时不解 FLAC，谱包里的
	// "song.mp3" 其实是 FLAC 时必须靠这条出声。空字典=不是 FLAC 或解不开。
	static Dictionary decode_flac(PackedByteArray bytes);
	static double now_us();                 // 单调 µs 计时（chrono）：chart_block 的分段相位也用它
	// 音符实例化层开关：关掉就退回逐个 draw_texture_rect。同进程开/关各渲一帧再逐像素比，
	// 这是"搬渲染不改画面"唯一的证法。
	void set_note_multimesh(bool on) { _note_mm = on; }
	bool get_note_multimesh() const { return _note_mm; }
	// 对拍台专用：让旧路径也把 quad 记进实例缓冲（quad 数/位置逐条可比）
	void set_mm_record(bool on) { _mm_rec = on; }
	// 对拍排查用：把上一帧每个实例组写进缓冲的东西原样吐出来
	// （组=深度桶×类别；含 quad 数、贴图尺寸、首实例的基向量与颜色）。
	Array mm_debug_groups() const;
	void draw_fx_into(CanvasItem *ci);   // ChartFxLayer::_draw 的全部工作
	void probe_set(bool on) { _probe = on; }
	// 内存按容器拆开算账（诊断，见 chart_mem.cpp）：每行 [name,count,bytes,mb]
	Array mem_report() const;
	Array probe_report() const;             // [窗内, 真画, 全表, 越窗, 帧数]
	void probe_reset();

private:

	// extra.json 后期特效（player ShaderPipeline 语义）：beat 区间内激活，vars 为事件驱动 uniform
	struct EffectVar {
		String name;
		std::vector<Event> evs;
		bool konst = false;   // extra.json 里 vars 直接写数值（Designant 谱）：常量 uniform
		double kv = 0;
		// 字符串 var = 谱包里的另一张贴图（player ShaderPipeline.boot：字符串 → extra
		// texture）。之前这条路径整个不存在：谱内 `uniform sampler2D mask;` 拿不到东西。
		bool ktex = false;
		String kstr;
		bool karr = false;     // 常量数组（vec2/vec4：rpe-next vars 直接写 [..]）
		std::vector<double> ka;
	};
	struct Effect {
		double s_sec = 0, e_sec = 0;
		String shader;
		bool glob = false;    // extra.json global：true=相机级（盖全屏含背景/HUD），
		                      // false=只作用判定线+音符层（player Game.ts:853 默认 targetRange 0..8）
		double rmin = 0, rmax = 8; // targetRange 深度桶 [rmin,rmax)（player ShaderPipeline.ts:305）
		bool exclusive = false;    // player 的 LCA 展开标志（本谱集未用，解析保留）
		double bpmf = 1;           // 归属线（rpe-next effect.line）的 bpmfactor：vars 时间 = 秒 × bpmf
		int order = 0;             // rpe-next effect.order（链内排序）
		std::vector<EffectVar> vars;
	};
	std::vector<Effect> _effects;        // extra.json 特效
	std::vector<Effect> _chart_effects;  // 谱面内嵌特效（chart.effects / shaderEvents / META.effects / paintEvents）
	Dictionary _fonts;                   // 字体名 → Font（textEvents[].font）
	bool _noise_ignore_triple = false;   // noiseAreaOptions.ignoreTripleInversion

	// ── targetRange 深度路由（player ShaderNode 语义）──
	// 幽灵实例：不持有谱面状态，_draw 直接读主实例（_src）共享数据，只渲染自己 keep 桶。
	ChartPlayer *_src = nullptr;
	std::vector<double> _keep; // 非空=只画这些深度桶（幽灵实例）
	std::vector<double> _skip; // 非空=这些桶交给幽灵实例画（主实例）
	std::vector<double> _note_depths, _fx_depths; // _finalize 缓存的去重深度桶（GDScript 分组用）
	bool _depth_ok(double d) const;
	static double _note_depth(const Note &n); // zIndex ?? NOTE_PRIORITIES[type]+2

	// 皮肤
	Ref<Texture2D> _tex_line, _tex_tap, _tex_drag, _tex_flick;
	Ref<Texture2D> _tex_hold_head, _tex_hold, _tex_hold_end, _tex_fx;
	Ref<Texture2D> _tex_hold_end_hl;   // 多押长条的尾帽：phira 从 hold_mh.png 切，其余回落 hold_end
	Ref<Texture2D> _tex_tap_hl, _tex_drag_hl, _tex_flick_hl, _tex_hold_head_hl, _tex_hold_hl;
	// 资源包自带的表现参数（phira info.yml 那套开关；PT/内置用默认值）。见 set_pack_options
	int _fx_cols = 0, _fx_rows = 0;      // 0 = 按内置 256 方帧自己推
	double _fx_duration = 0.5;           // hitFxDuration
	double _fx_scale = 1.0;              // hitFxScale
	bool _fx_tinted = true;              // hitFxTinted：false=特效不着色（白）
	bool _fx_rotate = false;             // hitFxRotate：特效随线旋转
	double _blk_cell = 4.0;   // 噪域掩码网格单元（画布 px）
	bool _fx_prpr = false;               // phira 包：特效/粒子走 prpr 的 ParticleEmitter 模型
	bool _hide_particles = false;        // hideParticles：打击时不出粒子
	bool _hold_repeat = false;           // holdRepeat：身体平铺而不是拉伸
	bool _hold_compact = false;          // holdCompact：头尾帽与身体重叠（锚点居中）
	bool _hold_keep_head = false;        // holdKeepHead：头过线后仍画头
	bool _phira_sizing = false;          // true=宽按"播放器宽度参数"归一（prpr 规则）
	double _mh_width_factor = 1.0;       // 双押贴图宽 / 单押贴图宽（prpr note_style_mh.click.w/…）
	// phira 的 colorPerfect/colorGood：**判定线**在 AP/FC 时的颜色，hitFxTinted 时也拿它染特效
	Color _c_perfect = Color(1.0, 236 / 255.0, 159 / 255.0, 15 / 17.0);
	Color _c_good = Color(180 / 255.0, 225 / 255.0, 1.0, 47 / 51.0);

	// 谱面自带线贴图（player `asset-<Texture>` 语义）：文件名 → 贴图
	Dictionary _line_texs;
	Dictionary _line_tex_tint; // 文件名 → 该贴图是否近白/灰（可安全乘判定色而不丢信息）
	Dictionary _line_tex_anim; // 文件名 → [帧数, fps]：gif/apng 解码后的竖排帧条动画
	int _lineTexTintMode = 0;  // 0=自动（白灰贴图跟随判定色）1=从不（player 一致）2=总是
	String _meta_bg; // META.background（谱包自带背景文件名，可缺）

	static double _ease_fn(int type, double x);
	static double _bezier_fn(const double *p, double x);
	static double _ease_integral(int ease, bool bez, const double *bp, double x);
	static double _event_value(const Event &e, double tsec);
	static double _event_integral(const Event &e, double progressed_sec, int mode);
	static double _enorm(const Event &e, double u);
	// 数值事件沿用 player 的“保持”语义（两事件之间冻结在上一事件 end；实测改成的
	// prpr 关键帧插值会让整屏判定线位置/HUD 全错，用户驳回）。
	// 文字事件是另一回事：start/end 是两个端点文本，事件内逐字打、空隙里逐字删。
	String _text_at(const std::vector<Line::TxtEv> &evs, double tsec) const;
	void _prep_speed(Event &e) const;
	void _event_color(const Event &e, double tsec, double out[3]) const;
	double _line_layer_value(const Line &l, int layer, const std::vector<Event> &evs, double tsec) const;
	static double _ext_value(const std::vector<Event> &evs, double tsec, double defv);
	void _parse_chart_effects(const Dictionary &d); // chart.effects / shaderEvents / META.effects / paintEvents
	static double _ctrl_value(const std::vector<Ctrl> &arr, double cd, double defv);
	double _height_at(const Line &l, double tsec) const;
	// 整体轨迹：解析（返回轨迹下标，失败 -1）与求值
	int _parse_trajectory(const Variant &tv, Line &line);
	double _traj_value(const Line &l, const Event &e, double tsec) const;
	void _update_line(Line &l, double tsec);
	void _parse_ctrl(const Dictionary &jd, const char *key, std::vector<Ctrl> &out);
	void _parse_ext(const Dictionary &ext, const char *key, std::vector<Event> &out);
	// ── 判定管线（player JudgmentHandler 语义：触发→匹配→评分，四类四套控制）──
	void _jkinem(double now, double dt);              // 手指位移向量 + 划动手势检测
	void _jcheck_note(int fi, double now);            // 点击匹配（黄/红键保护）
	void _jcheck_flick(int fi, double now);           // 红键手势匹配
	bool _jnear(Note &n, Line &l, double range_wu);   // 任意按住手指沿轴靠近
	bool _jcontrol(Line &l, Note &n, double now);     // 单控制评分；true=终止
	void _jreset();                                  // 载入/回跳：清控制与游标
	void _auto_hit(Line &l, Note &n, double now);    // autoplay 命中：判 Perfect + 在音符位置补一次特效
	void _jcount(Note &n, int st, double now, bool late = false); // 仅计数（hold 尾结算用）
	void _judge(Note &n, int st, double now, double delta = 1e18);
	FX _make_fx(double x, double y, double t0, int kind, const Note &n, double rot = 0.0); // 随机粒子参数（PT HitImage）
	// phira 的命中表现：1 颗特效贴图 + 4 颗方块（prpr ParticleEmitter，见 .cpp 注释）
	static void _draw_prpr_fx(CanvasItem *ci, ChartPlayer *S, const FX &fx,
			int cols, int rows, int total, int fw, int fh);
	double _spb_at(double now) const;                     // 当前秒/拍（hold 持续特效间隔用）

	// 噪域：解析 / 缓动 / 关键帧求值 / 每帧几何
	void _parse_blocks(const Array &arr);
	void _parse_block_next(const Dictionary &bd);      // rpe-next（RPEVersion>=220）schema → 0..N 个 Block
	static double _area_ease(int type, double x);
	static double _area_norm(double cur, double next, double t);
	static double _rot_at(const std::vector<BlockRot> &e, double t);
	static double _scale_at(const std::vector<BlockScale> &e, double t, int axis);
	double _t1_at(const std::vector<BlockSpan> &e, double t, double fallback) const;
	static void _mv_at(const std::vector<BlockMove> &e, double t, double out[2]);
	void _block_geom(Block &b, double W, double H) const; // 图面系 transform → 画布像素四角
	void _block_geom_next(Block &b, double W, double H) const; // rpe-next 的逐轴累计变换
	static bool _block_contains(const Block &b, double px, double py, double inset_world);
	void update_blocks(double music_sec);
	// ── RPE 噪域（贴图线标记）：见 prpr/src/core/rpe_block.rs ──
	static int _marker_kind(const String &tex);         // -1 不是；0 普通框；1 减算框
	void _rpe_markers();                                 // 扫描标记线 → 建 _blocks
	void _rpe_spans_speed(Block &b, const Line &l) const; // 新协议：speed 事件当状态码 1..4
	void _rpe_spans_alpha(Block &b, const Line &l) const; // 旧协议：alpha 轨道当状态码
	double _rpe_alpha_at(const Line &l, double t) const;   // 逐层求和，跟 live 的 k_a 同语义
	void _rpe_block_geom(Block &b, double music_sec) const; // 从线世界状态推 rect（图面系）
	void _rpe_tex_sizes();            // 标记贴图注入后补取真实像素尺寸（缺省 900×900）
	void _infect_fingers();                 // set_now 里调（用音乐秒原值）

public:
	ChartPlayer();
	~ChartPlayer() {}

	bool load_chart_json(PackedByteArray bytes);
	bool load_extra(PackedByteArray bytes); // extra.json（后期特效）
	Array get_effects(double sec);
	// 谱面到底有没有特效事件：没有的话 _update_effects() 整帧都可以跳过（含 native 侧的扫描）
	bool has_effects() const;           // 该秒激活的特效 [{shader, params, global, rmin, rmax}]
	// 深度路由：幽灵实例共享主实例状态；keep/skip = targetRange 认领的深度桶集合
	void set_state_source(Object *main);     // 传主 ChartPlayer；传 null 解除
	void set_keep_depths(Array depths);
	void set_skip_depths(Array depths);
	Array get_line_depths() const;           // 每条线的深度桶（线序=文件序）
	Array get_note_depths();                 // 全谱音符深度桶（去重升序）
	Array get_fx_depths();                   // 全谱命中特效深度桶（去重升序）
	Array get_attachments();                 // attachUI 线当前变换（HUD 跟随用）
	bool load_pe_bytes(const uint8_t *data, size_t len);  // PhiEditer .pe 文本格式（PZ 老谱）：直接在字节上扫
	bool load_rpe_json(String txt);
	bool load_official(String txt); // official（Phigros 原生）json：formatVersion 1/3
	// 官谱音符继承判定线 alpha（Unity 里音符是线 GameObject 的子节点）；
	// RPE/pe 系作者常"藏线留音符"，所以这条语义按格式分开。
	bool _official_fmt = false;

	// —— 噪域触摸特效（官方 TouchMask）——
	BTouchSlot _bts[10];
	double _bts_last = -1e18;
	PackedByteArray _hover_src; // RGBA8
	int _hover_w = 0, _hover_h = 0;
	void _bts_update(double time);
	unsigned char _hover_at(double u, double v, double aspect) const;
	void _finalize();        // 两条解析路径共用：多押标记 + hT 积分
	void set_now(double sec);
	// 重开一局（player 的 restart 语义）：判定统计/音符判定态/控制/特效/触点全清，
	// 谱面解析结果（线/音符/事件/多押标记）保持不动——重新走一遍 load 是几 MB JSON 的
	// 解析成本，手机上会白卡一下。
	void reset_play_state();
	void set_scale(double canvas_w, double canvas_h);
	// 判定窗口（ms）：player preferences.perfectJudgment/goodJudgment。
	// 派生 B=G+40、F=1.75P、淡出窗（tap/hold=G、flick=F、drag=100）同步跟随。
	void set_judgment_windows(double p_ms, double g_ms);
	Dictionary get_judgment_windows() const; // {p,g,b,f}（ms）——设置页回显用
	// 判定补偿（ms，可负）：叠加在谱面 META.offset 之上（player chartOffset）
	void set_chart_offset_ms(double ms) { _user_offset = ms / 1000.0; }
	double get_chart_offset_ms() const { return _user_offset * 1000.0; }
	// 多押提示（player simultaneousNoteHint）：关=同刻音符不再用 HL 贴图
	void set_multi_hint(bool on) { _multiHint = on; }
	bool get_multi_hint() const { return _multiHint; }
	void set_frame_cull(bool on) { _frame_cull = on; queue_redraw(); }
	bool get_frame_cull() const { return _frame_cull; }
	// 音符大小（PT 的 noteScale 语义：只缩放贴图，不缩放位置/判定窗）
	void set_note_scale(double v) { _noteScale = v; }
	void set_fx_user_scale(double v) { _fxUserScale = std::max(0.1, v); }
	double get_fx_user_scale() const { return _fxUserScale; }
	double get_note_scale() const { return _noteScale; }
	// 本局判定偏差（player StatisticsHandler：mean/std，uncorrected=总体标准差）
	// 正均值=按晚，负=按早；这是判定补偿的读数依据（不做未经参考实现支持的自动回灌）
	int get_delta_count() const { return (int)_jdeltas.size(); }
	double get_avg_delta_ms() const;
	double get_std_dev_ms() const;
	void touch_down(int id, Vector2 pos);
	void touch_move(int id, Vector2 pos);
	void touch_up(int id);
	void set_skin(String name, Ref<Texture2D> tex);
	// 资源包自带的表现参数（一次给全，缺的键保持内置默认）：
	//   fx_cols/fx_rows/hit_fx_duration/hit_fx_scale/hit_fx_tinted/hide_particles/
	//   hold_repeat/hold_compact/hold_keep_head/color_perfect/color_good/
	//   phira_sizing/mh_width_factor
	// 语义与默认值全部取 prpr/src/core/resource.rs 的 ResPackInfo + note.rs 的 draw 路径。
	void set_pack_options(Dictionary opts);
	// 噪域掩码网格的单元边长（画布像素）：小=精细/慢，大=粗/快（成本≈面积×区数）
	void set_block_cell(double px) { if (px >= 1.0) _blk_cell = px; }
	double get_block_cell() const { return _blk_cell; }
	Dictionary get_pack_options() const;
	// 皮肤槽读回（QA 判据用）：13 个键 → 当前真的挂在渲染器上的贴图
	Dictionary get_skin_textures() const;
	// 判定粒子形状（0=圆 1=方块）：来自 PT 在线包的 meta.json hitEvtDrawer，见 _fx_particle_shape
	void set_hit_particle_shape(int kind) { _fx_particle_shape = kind == 1 ? 1 : 0; }
	int get_hit_particle_shape() const { return _fx_particle_shape; }
	void set_line_texture(String name, Ref<Texture2D> tex, bool tintable, int frames = 0, double fps = 0.0); // 谱目录图片注入（按文件名）；frames>0=竖排帧条动画（gif/apng）
	void set_line_tex_tint_mode(int m) { _lineTexTintMode = m; }
	int get_line_tex_tint_mode() const { return _lineTexTintMode; }
	Array get_line_textures();                              // 全部线引用的贴图名（去重）
	String get_meta_background() const { return _meta_bg; }
	void set_fc_ap_indicator(bool on) { _fcApIndicator = on; }
	// QA 判据：当前该用的判定线颜色（AP/FC 状态 × 包的 colorPerfect/colorGood）
	Color get_judge_line_color() const {
		if (_fcApIndicator && _miss == 0 && _bad == 0)
			return _good == 0 ? _c_perfect : _c_good;
		return Color(1, 1, 1, 1);
	}
	bool get_fc_ap_indicator() const { return _fcApIndicator; }
	void set_autoplay(bool v) { _autoplay = v; }
	bool get_autoplay() const { return _autoplay; }
	int blocked_touch_count(); // 噪域「感染」中的手指数（官方 chart.blocked_touches）
	Array take_hits();         // 取出并清空命中音效队列：[[type, hitsound名], ...]
	// 整局打击事件（音乐时间轴，秒）：[[t, type, hitsound名], ...]，跳过 fake。
	// 离线录制要在开录之前把音轨编好（muxer 轨道必须先于第一帧视频挂上），
	// 所以不能靠边渲边记；autoplay 下每条非 fake 音符命中即一声，hold 只在头响。
	Array get_sound_events() const;
	int hit_count() const { return (int)_hitq.size(); } // 有待取命中数（避免每帧空数组分配）
	// 主线程 CPU 帧耗时诊断（µs/帧）：判定低端设备是否真有 120 帧（8.33ms）余量
	double get_prof_draw_us() const { return _prof_n ? _prof_draw_us / (double)_prof_n : 0.0; }
	double get_prof_set_us() const { return _prof_n ? _prof_set_us / (double)_prof_n : 0.0; }
	int get_prof_n() const { return _prof_n; }
	void prof_reset() { _prof_draw_us = _prof_set_us = 0; _prof_n = 0; }

	Array debug_line_state(int idx) const; // [wx, wy, wrot, araw, height]
	Array debug_hold_states(double tsec);  // 暂存诊断：hold 在各门控下的状态
	Array debug_multi_counts();            // 诊断：[real_total, real_multi, fake_total, fake_multi]
	int debug_fx_count();                  // 诊断：当前存活命中特效数
	Array debug_notes() const;             // 诊断：全部音符 [line,idx,t,t2,x,type,above,fake,spd,sz,yoff,alpha,vtime,hT,hT2,state]
	Array debug_alpha_events(int idx) const; // 诊断：某线 alpha 事件 [bS,bT,s,t,v0,v1,ease]
	Array debug_note_worlds(double tsec);    // 诊断：音符世界坐标 [line,idx,wx,wy,dist]
	// F12 调试层：**不调 set_now、不改任何状态**，直接读上一帧 set_now 已经算好的线/音符位姿。
	// debug_note_worlds 会重跑整帧更新（判定/触点/特效都在里面），拿来每帧画编号是不安全的。
	Array debug_overlay_notes() const;  // 屏内音符 [line,idx,wx,wy,type,state,fake,w]（w=绘制宽度 px）
	Array debug_overlay_lines() const;  // 每条线 [idx,wx,wy,rot,w,alpha]
	// —— 视频层（player Video.ts）GDScript 侧接口 ——
	double eval_events(Array events, double sec);   // 拍→秒换算后的事件插值（复用 _parse_ext/_ext_value）
	double beat_to_sec(double beat) const { return _b2s(beat); }
	int debug_lines_drawn() const { return _dbg_lines_drawn; } // QA：最近一帧 _draw 画了几条线
	Array debug_keep() const { Array a; for (double d : _keep) a.push_back(d); return a; }
	Array debug_draw_counts() const { Array a; a.push_back(_dbg_lines_drawn); a.push_back(_dbg_tex_draws); a.push_back(_dbg_line_skip_opa); a.push_back(_dbg_tex_invalid); return a; }
	Array debug_skip() const { Array a; for (double d : _skip) a.push_back(d); return a; }
	void set_named_font(String name, Ref<Font> font); // 谱包/皮肤字体（textEvents[].font）
	Array get_touches() const;                        // 当前按下的触点（画布像素 [x,y]）
	Dictionary get_line_state(int idx) const;       // {x,y,rot,alpha,sx,sy,w}：w=线显示像素宽（attach 遮罩用）
	Array debug_drawn_notes(double tsec);  // 诊断：复刻绘制门控，返回将被绘制的音符
	Array debug_note_window(double tsec);  // 诊断：本帧每条线的音符 hT 候选窗（_draw 二分用的同一套数学）
	// —— 噪域（blockArea）GDScript 侧接口：C++ 只出几何/语义，合成与表现在 GDScript 层 ——
	bool has_blocks() const { return !_blocks.empty(); }
	Array get_block_quads();               // 可见块（列表序）：[{sub,alpha,phase,p:[8 px]}]
	bool block_hit(Vector2 pos);           // 顺序画家覆盖测试：Active 域内触点不判定
	Array debug_blocks(double music_sec);  // 诊断/oracle 对拍：全部块的相位+当前变换+四角
	void set_block_noise(PackedByteArray rgba, int w, int h);
	// 官方 TouchHover.png（Round10_Blur4，44×44 RGBA：R=255、A=软圆盘）
	void set_block_hover(PackedByteArray rgba, int w, int h);
	unsigned char debug_hover_at(double u, double v, double aspect); // 对拍 oracle 用
	Array debug_touch_slots(); // [u, v, scale]×N：官方喂给 _TouchPos[] 的那份触点 // BlockNoise1 位移图（RGBA）
	Array debug_block_phases(); // 8 个阶段的平均 µs（hover/清零/栅格/前缀和/配色/位移/膨胀/打包）
	// GPU 掩码路径用：这一帧有没有"触摸感染"（有就得回退 CPU，hover 只在 CPU 里算）
	bool block_hover_active() {
		_bts_update(_now);
		for (const auto &st : _bts) if (st.scale > 0.0) return true;
		return false;
	}
	void debug_block_phases_reset() { for (int i = 0; i < 8; i++) _blk_ph[i] = 0.0; _blk_ph_n = 0; _bmb.lay_n = 0; _bmb.lay_hits = 0; }
	void debug_force_blocked(int id, bool on, Vector2 pos); // 仅单测：钉住 blocked 位，绕开 judge 的域检测
	void set_block_warp(double v) { _blk_warp = v; }   // 掩码位移幅度（1.0 = prpr 原式 0.1 UV）
	double get_block_warp() const { return _blk_warp; }
	Array build_block_mask();              // {w,h,bytes,aux}：1/4 屏效果网格的官方掩码（合并所有层）
	Array build_block_mask_layer(int li);  // 单层掩码（noiseAreaLayers；N==1 时等价于 build_block_mask）
	Array build_block_mask_bits(int li);   // 噪域皮肤 blockMask：R = 6bit 覆盖（act/actInv/dis/disInv/ready/readyInv）
	Array _build_block_mask_impl(const std::vector<const Block *> &list, BlockMaskBuf &buf);
	Array get_block_layers() const;        // [{id,name,skin}]
	void _draw() override;

	int get_perfect() const { return _perfect; }
	int get_good() const { return _good; }
	int get_good_early() const { return _good_early; }
	int get_good_late() const { return _good_late; }
	int get_bad() const { return _bad; }
	int get_miss() const { return _miss; }
	int get_combo() const { return _combo; }
	int get_max_combo() const { return _max_combo; }
	int get_total_notes() const { return _total_notes; }
	int get_score() const;
	double get_accuracy() const { int j = _perfect + _good + _bad + _miss; return j ? double(_perfect + 0.65 * _good) / double(j) : 1.0; } // player: judgmentCount===0 ? 1（开局 0/0 曾显示 -nan%）
	String get_song_name() const { return _name; }
	String get_level() const { return _level; }
	double get_duration() const { return _duration; }

protected:
	static void _bind_methods();
};


class ChartPlayer;

// 命中特效层。音符搬进 MultiMeshInstance2D 子节点后，子节点整体画在本节点 _draw 之后，
// 而 player/PT 的层序是 线 < 音符 < 命中特效 —— 特效必须一起搬出去，做成排在所有
// 音符节点之后的最后一个子节点，这条层序才保得住。
class ChartFxLayer : public Node2D {
	GDCLASS(ChartFxLayer, Node2D)   // CanvasItem 是抽象类，扩展类不能直接继承

public:
	ChartPlayer *owner = nullptr;

	// 必须 public：godot-cpp 为基类虚方法生成的绑定代码要从类外引用它
	void _draw() override;
	static void _bind_methods();
};


} // namespace godot
