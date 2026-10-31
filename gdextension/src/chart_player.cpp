#include "chart_player.h"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/font.hpp>
#include <godot_cpp/classes/theme_db.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <functional>

using namespace godot;

// ───────── 判定（player JudgmentHandler 两段式：触发→匹配→评分）─────────
// P/G/B/F 是**可调配的判定窗口**（player JudgmentHandler.windows() 读 preferences，
// 默认 P=0.08 G=0.18 ⇒ B=G+0.04=0.22、F=1.75P=0.14），存在 ChartPlayer 实例字段上；
// 这里只留派生系数和不随窗口变的事实常量：
// 黄键时间窗 DRAG=0.1s（constants.ts："unaffected by judgment-window preferences"）；
// X 向 tap/hold=1.9wu drag/flick=2.1wu；bad 收缩：dx≤0.9wu 全额 B，超出每 wu 收 0.5P；
// tie-break 度量 y 权 1/2.2；匹配时刻容差 0.01s；黄/红键在 dt<5ms 才落分（特效延到
// 音符时刻）；hold：中段 2 帧抬指保护、尾前 0.22s 提前结算、尾后 0.25s 无头判 Miss；
// 划动手势：d0/d1 位移（wu，60fps 归一），u=0.06·dpi/380（96 基），
// 同向投影 ≥u 视为连划（不产生新手势），否则速度 ≥5u 起新手势。
namespace jd {
constexpr double B_EXTRA = 0.04, FLICK_F = 1.75;
constexpr double DRAG_T = 0.1, X_TAP = 1.9, X_WIDE = 2.1, X_SHRINK = 0.9;
constexpr double METRIC_Y = 2.2, T_EPS = 0.01, SCORE_EPS = 0.005;
constexpr double TAIL_SETTLE = 0.22, TAIL_MISS = 0.25;
constexpr int SAFE_FRAMES = 2;
constexpr double FLICK_U = 0.06 * 96.0 / 380.0, FLICK_K = 5.0, FLICK_PROJ_MIN = 0.1;
} // namespace jd

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static double clampd(double v, double a, double b) { return v < a ? a : (v > b ? b : v); }

// 事件游标（二分：最后一个 s<=tsec 的下标）与贴图变体——定义在文件后段，
// 噪域（RPE 标记线）解析在前，先前置声明。
static inline int _ev_cursor(const std::vector<ChartPlayer::Event> &evs, double tsec);
static Ref<Texture2D> tex_from(const Variant &v);

// 主线程 CPU 帧耗时计时（µs）：steady_clock 单调，判低端设备 120 帧真余量
static inline double _prof_us() {
	return std::chrono::duration<double, std::micro>(
			std::chrono::steady_clock::now().time_since_epoch()).count();
}

double ChartPlayer::now_us() { return _prof_us(); }

Array ChartPlayer::probe_report() const {
	Array r;
	r.push_back((double)_pb_scanned);  // 本帧进循环的音符（候选窗内）
	r.push_back((double)_pb_kept);     // 真正落 quad 的音符
	r.push_back((double)_pb_win);      // 不窗化要扫的音符（对照）
	r.push_back((double)_pb_out);      // 越窗次数：必须恒为 0，否则二分=丢音符
	r.push_back((double)_pb_frames);
	r.push_back((double)_pb_cand_max);
	r.push_back((double)_pb_ctl_max);
	return r;
}

void ChartPlayer::probe_reset() {
	_pb_scanned = _pb_kept = _pb_win = _pb_out = _pb_frames = 0;
	_pb_cand_max = 0; _pb_ctl_max = 0;
}

// ───────── easing（RPE type 1..27 → EASINGS[type-1]，player utils.ts） ─────────

// RPE 的 easingType 编号**不是** CSS 那套 "In,Out,InOut 依次排"：参考实现的真表在
// prpr/src/parse.rs 的 RPE_TWEEN_MAP（30 项，索引 0/1=linear），Out 在前、In 在后，
// 各种 InOut 分散在后面。之前照 CSS 顺序写的表从 4 号开始就整体错位 ⇒ 线的 move/rotate
// 缓动与原版不一致（用户："CALAMITY RHAPSDOY 播放不对、线与音符编排不对"）。
// 曲线函数本体 = prpr/src/core/tween.rs：In 是原函数，Out = 1−f(1−x)，InOut = 折半拼接。
static double _in_sine(double x) { return 1.0 - std::cos(x * M_PI * 0.5); }
static double _in_quad(double x) { return x * x; }
static double _in_cubic(double x) { return x * x * x; }
static double _in_quart(double x) { return x * x * x * x; }
static double _in_quint(double x) { return x * x * x * x * x; }
static double _in_expo(double x) { return std::pow(2.0, 10.0 * (x - 1.0)); }
static double _in_circ(double x) { return 1.0 - std::sqrt(std::max(0.0, 1.0 - x * x)); }
static double _in_back(double x) {
	const double c1 = 1.70158;
	const double c3 = c1 + 1.0;
	return (c3 * x - c1) * x * x;
}
static double _in_elastic(double x) {
	const double c4 = (2.0 * M_PI) / 3.0;
	return -std::pow(2.0, 10.0 * x - 10.0) * std::sin((x * 10.0 - 10.75) * c4);
}
static double _out_bounce(double x) {
	const double n1 = 7.5625, d1 = 2.75;
	if (x < 1.0 / d1) return n1 * x * x;
	if (x < 2.0 / d1) { x -= 1.5 / d1; return n1 * x * x + 0.75; }
	if (x < 2.5 / d1) { x -= 2.25 / d1; return n1 * x * x + 0.9375; }
	x -= 2.625 / d1;
	return n1 * x * x + 0.984375;
}
static double _in_bounce(double x) { return 1.0 - _out_bounce(1.0 - x); }

double ChartPlayer::_ease_fn(int type, double x) {
	if (x <= 0.0) return 0.0;
	if (x >= 1.0) return 1.0;
	auto out = [](double (*f)(double), double v) { return 1.0 - f(1.0 - v); };
	auto inout = [](double (*f)(double), double v) {
		const double v2 = v * 2.0;
		return v2 < 1.0 ? f(v2) * 0.5 : 1.0 - f(2.0 - v2) * 0.5;
	};
	switch (type) {
		case 0:
		case 1: return x;
		case 2: return out(_in_sine, x);
		case 3: return _in_sine(x);
		case 4: return out(_in_quad, x);
		case 5: return _in_quad(x);
		case 6: return inout(_in_sine, x);
		case 7: return inout(_in_quad, x);
		case 8: return out(_in_cubic, x);
		case 9: return _in_cubic(x);
		case 10: return out(_in_quart, x);
		case 11: return _in_quart(x);
		case 12: return inout(_in_cubic, x);
		case 13: return inout(_in_quart, x);
		case 14: return out(_in_quint, x);
		case 15: return _in_quint(x);
		case 16: return out(_in_expo, x);
		case 17: return _in_expo(x);
		case 18: return out(_in_circ, x);
		case 19: return _in_circ(x);
		case 20: return out(_in_back, x);
		case 21: return _in_back(x);
		case 22: return inout(_in_circ, x);
		case 23: return inout(_in_back, x);
		case 24: return out(_in_elastic, x);
		case 25: return _in_elastic(x);
		case 26: return out(_in_bounce, x);
		case 27: return _in_bounce(x);
		case 28: return inout(_in_bounce, x);
		case 29: return inout(_in_elastic, x);
		default: return x;
	}
}

double ChartPlayer::_bezier_fn(const double *p, double x) {
	if (x <= 0) return 0;
	if (x >= 1) return 1;
	double lo = 0, hi = 1, t = x;
	for (int i = 0; i < 18; i++) {
		t = (lo + hi) * 0.5;
		double u = 1.0 - t;
		double cx = 3.0 * t * u * u * p[0] + 3.0 * t * t * u * p[2] + t * t * t;
		if (cx < x) lo = t;
		else hi = t;
	}
	double u = 1.0 - t;
	return 3.0 * t * u * u * p[1] + 3.0 * t * t * u * p[3] + t * t * t;
}

double ChartPlayer::_ease_integral(int ease, bool bez, const double *bp, double x) {
	static int key = -1;
	static double tab[129];
	static double last_bp[4] = { 0, 0, 0, 0 };
	int bkey = ease + (bez ? 1000 : 0);
	bool bp_same = !bez || (bp[0] == last_bp[0] && bp[1] == last_bp[1] && bp[2] == last_bp[2] && bp[3] == last_bp[3]);
	if (key != bkey || !bp_same) {
		key = bkey;
		if (bez) for (int i = 0; i < 4; i++) last_bp[i] = bp[i];
		tab[0] = 0;
		for (int i = 1; i <= 128; i++) {
			double a = (i - 1) / 128.0, b = i / 128.0;
			double fa = bez ? _bezier_fn(bp, a) : _ease_fn(ease, a);
			double fb = bez ? _bezier_fn(bp, b) : _ease_fn(ease, b);
			tab[i] = tab[i - 1] + (fa + fb) * 0.5 / 128.0;
		}
	}
	if (x <= 0) return 0;
	if (x >= 1) return tab[128];
	double f = x * 128.0;
	int i0 = (int)f;
	return tab[i0] + (tab[i0 + 1] - tab[i0]) * (f - i0);
}

// 归一化缓动 E(x)：子区间 [el,er] 拉伸到全时长后按端点值归一（player calculateEasingValue）
double ChartPlayer::_enorm(const Event &e, double u) {
	u = clampd(u, 0.0, 1.0);
	if (e.bez) return _bezier_fn(e.bp, u);
	if (e.ease <= 1) return u;
	double l = e.el, r = e.er;
	if (!(l >= 0.0) || l >= r) l = 0;
	if (r > 1.0 || l >= r) r = 1;
	double raw = _ease_fn(e.ease, l + (r - l) * u);
	double ps = _ease_fn(e.ease, l);
	double pe = _ease_fn(e.ease, r);
	return pe != ps ? (raw - ps) / (pe - ps) : 0.0;
}

// 事件取值（秒系）：linear 直接 lerp；eased 走 E_norm，允许过冲
double ChartPlayer::_event_value(const Event &e, double beat) {
	if (beat <= e.s) return e.v0;
	if (beat >= e.t) return e.v1;
	double x = clampd((beat - e.s) / (e.t - e.s), 0.0, 1.0);
	if (!e.bez && e.ease <= 1) return e.v0 + (e.v1 - e.v0) * x;
	return e.v0 + (e.v1 - e.v0) * _enorm(e, x);
}

// v<170 speed 模式预计算（player getIntegral 非积分分支）：
// k=(v1−v0)/(dE/dx|1 − dE/dx|0)，b=v0−k·dE/dx|0；积分 I(x)=(E(x)k+bx)·lenSec/Δbeat
void ChartPlayer::_prep_speed(Event &e) const {
	if (!e.bez && e.ease <= 1) { e.k = 0; e.bi = 0; return; }
	double h = 1e-4;
	double d0 = (_enorm(e, h) - _enorm(e, 0)) / h;
	double d1 = (_enorm(e, 1) - _enorm(e, 1 - h)) / h;
	double denom = d1 - d0;
	if (std::abs(denom) < 1e-12) { e.k = 0; e.bi = (e.v0 + e.v1) * 0.5; }
	else { e.k = (e.v1 - e.v0) / denom; e.bi = e.v0 - e.k * d0; }
}

// rpe-next 着色器名 → 本项目内置资源名（snake_case）。
// 名单与归一化逐条照 src/core/shader.mjs: SHADER_NAMES / canonicalShaderName：
// 数字下标取表、去路径/扩展名、去 _pr、camelCase→snake_case、连字符→下划线、
// 再去下划线查别名（radialblur→radial_blur 等）。_2 变体保留（它们与基础版同源，
// 由 GDScript 侧回落；clone 事件按 rpe-next 语义映射到 _2）。
static const char *_RPE_SHADER_NAMES[50] = {
	"chromatic", "circle_blur", "fisheye", "glitch", "grayscale", "noise", "pixel", "radial_blur",
	"shockwave", "vignette", "chromatic_2", "circle_blur_2", "fisheye_2", "glitch_2", "grayscale_2",
	"noise_2", "pixel_2", "radial_blur_2", "shockwave_2", "vignette_2",
	"liquid", "flowing", "image_noise", "snow", "glow_effect", "flip", "night_vision", "scanline",
	"rain", "rainbow", "flare", "underwater", "fog", "kaleidoscope", "emboss", "sobel", "oil_painting",
	"distortion", "hologram", "burn", "camera", "lightning", "old_tv", "bokeh", "neon",
	"heat_distortion", "rays", "color_shift", "wave", "two_tone"
};

static String _canon_shader_name(const Variant &v) {
	if (v.get_type() == Variant::INT || v.get_type() == Variant::FLOAT) {
		const int i = v.get_type() == Variant::INT ? (int)(int64_t)v : (int)(double)v;
		return (i >= 0 && i < 50) ? String(_RPE_SHADER_NAMES[i]) : String();
	}
	if (v.get_type() != Variant::STRING) return String();
	String n = ((String)v).strip_edges();
	if (n.is_empty()) return n;
	if (n.begins_with("/") || n.begins_with("\\")) return n; // 谱包自带 glsl（GDScript 解析）
	n = n.get_file();
	String low = n.to_lower();
	if (low.ends_with(".glsl") || low.ends_with(".frag")) n = n.get_basename();
	low = n.to_lower();
	if (low.ends_with("_pr")) n = n.substr(0, n.length() - 3);
	// camelCase → snake_case（rpe-next：([a-z])([A-Z]) → $1_$2；全大写不拆）
	String snake;
	char32_t prev = 0;
	for (int i = 0; i < n.length(); i++) {
		const char32_t c = n[i];
		if (c >= 'A' && c <= 'Z') {
			const bool prev_lower = (prev >= 'a' && prev <= 'z') || (prev >= '0' && prev <= '9');
			if (i > 0 && prev_lower && !snake.is_empty() && snake[snake.length() - 1] != '_') snake += "_";
			snake += (char32_t)(c - 'A' + 'a');
		} else if (c == '-') {
			snake += "_";
		} else {
			snake += c;
		}
		prev = c;
	}
	snake = snake.to_lower();
	const String flat = snake.replace("_", "");
	if (flat == "radialblur") snake = "radial_blur";
	else if (flat == "circleblur") snake = "circle_blur";
	else if (flat == "oldtv") snake = "old_tv";
	else if (flat == "oilpainting") snake = "oil_painting";
	else if (flat == "heateffect") snake = "heat_distortion";
	return snake;
}

// colorEvents：rgb 三通道按 progress（含缓动）插值
void ChartPlayer::_event_color(const Event &e, double tsec, double out[3]) const {
	double p;
	if (tsec <= e.s) p = 0;
	else if (tsec >= e.t) p = 1;
	else {
		double prog = clampd((tsec - e.s) / std::max(1e-9, e.t - e.s), 0.0, 1.0);
		p = e.ease <= 1 ? prog : _ease_fn(e.ease, prog);
	}
	for (int i = 0; i < 3; i++) out[i] = e.rgb0[i] + (e.rgb1[i] - e.rgb0[i]) * p;
}

// 文本插值（prpr Tweenable for String）：两个端点文本之间"逐字打字 / 逐字删除"。
// 端点相等=原样；目标为空=反向删除；起点为空=从目标头部补字；互为前缀=追加/回删；
// 其余情况（整句替换）=保持起值（prpr 同）。%P% 计数器语法此处不支持（谱面极少用）。
static String _tween_text(const String &x, const String &y, double t) {
	if (x == y) return x;
	if (t <= 0.0) return x;
	if (t >= 1.0) return y;
	if (x.is_empty() && y.is_empty()) return String();
	if (y.is_empty()) return _tween_text(y, x, 1.0 - t);
	const int xl = x.length(), yl = y.length();
	if (x.is_empty()) {
		const int take = (int)std::lround(t * (double)yl);
		return y.substr(0, take);
	}
	if (y.begins_with(x)) { // x 是 y 的前缀：从 x 的长度往外补
		const int take = (int)std::floor((double)(yl - xl) * t) + xl;
		return y.substr(0, take);
	}
	if (x.begins_with(y)) { // y 是 x 的前缀：从 x 往回删
		const int take = (int)std::lround((double)(xl - yl) * (1.0 - t)) + yl;
		return x.substr(0, take);
	}
	return x;
}

String ChartPlayer::_text_at(const std::vector<Line::TxtEv> &evs, double tsec) const {
	if (evs.empty()) return String();
	// 最后一个 t0 < tsec 的事件（与 _ev_cursor 同口径：端点算前一事件）
	int c = 0, lo = 0, hi = (int)evs.size() - 1;
	while (lo <= hi) {
		const int mid = (lo + hi) >> 1;
		if (tsec > evs[mid].t0) { c = mid; lo = mid + 1; } else hi = mid - 1;
	}
	const Line::TxtEv &e = evs[c];
	Event tmp;
	tmp.ease = e.ease; tmp.el = e.el; tmp.er = e.er; tmp.bez = e.bez;
	for (int k = 0; k < 4; k++) tmp.bp[k] = e.bp[k];
	auto prog = [&](double u) -> double {
		u = clampd(u, 0.0, 1.0);
		return (tmp.ease <= 1 && !tmp.bez) ? u : _enorm(tmp, u);
	};
	// 权威口径 = rpe-next src/core/events.mjs EventTrack.sample(string)：
	//   seconds < start → ''；[start, end) 内按缓动进度逐字补/删；>= end → **保持 end 文本**
	//   （事件之间的空隙不删字，一直保持到下一个文本事件起点）。
	if (tsec < e.t0) return String();
	if (tsec < e.t1) {
		const double x = (tsec - e.t0) / std::max(1e-9, e.t1 - e.t0);
		return _tween_text(e.s0, e.s1, prog(x));
	}
	return e.s1;
}

// speed 事件 [s, s+prog秒] 的积分：linear 梯形；v<170 导数仿射；v≥170 直接积分缓动
double ChartPlayer::_event_integral(const Event &e, double prog, int mode) {
	if (prog <= 0) return 0;
	double length = e.t - e.s;
	if (length <= 0) return 0;
	double x = clampd(prog / length, 0.0, 1.0);
	if (!e.bez && e.ease <= 1) {
		double v1 = e.v0 + (e.v1 - e.v0) * x;
		return (e.v0 + v1) * 0.5 * prog;
	}
	if (mode == 0) {
		double dbeat = std::max(1e-9, e.bT - e.bS);
		return (_enorm(e, x) * e.k + e.bi * x) * length / dbeat;
	}
	double J = _ease_integral(e.ease, e.bez, e.bp, x);
	return e.v0 * prog + (e.v1 - e.v0) * J * length;
}

// ───────── 解析辅助 ─────────

static double _to_num(const Variant &v) {
	switch (v.get_type()) {
		case Variant::INT: return (double)(int64_t)v;
		case Variant::FLOAT: return (double)v;
		case Variant::BOOL: return (bool)v ? 1.0 : 0.0; // json true/false（isSubtract/isCover 等）
		case Variant::STRING: return ((String)v).to_float();
		case Variant::ARRAY: {
			Array a = v;
			return a.size() ? _to_num(a[0]) : 0;
		}
		case Variant::VECTOR2: return ((Vector2)v).x;
		default: return 0;
	}
}

static double _beat_of(Variant v) {
	if (v.get_type() == Variant::ARRAY) {
		Array a = v;
		return a.size() >= 3 ? _to_num(a[0]) + _to_num(a[1]) / std::max(1.0, _to_num(a[2])) : _to_num(v);
	}
	return _to_num(v);
}

// player 的 above 语义分两套（自制谱 above=2 时表现不同）：
//   PlainNote.ts:71 / Line.ts:601 用严格 ===1 → above=2 落下方
//   LongNote.ts:63 用 truthy (data.above ? -1 : 1) → above=2 仍在上方
static double _note_ymod(const ChartPlayer::Note &n) {
	// rpe-next scene.mjs noteIsAbove：所有类型一律 `above === 1`（hold 不再用 player 的 truthy 语义）
	bool up = n.above == 1;
	return up ? -1.0 : 1.0;
}

static void _to_rgb(const Variant &v, double out[3]) {
	if (v.get_type() == Variant::ARRAY) {
		Array a = v;
		for (int i = 0; i < 3; i++) out[i] = i < (int)a.size() ? _to_num(a[i]) : 255;
	} else {
		double g = _to_num(v);
		out[0] = out[1] = out[2] = g > 1 ? g : 255;
	}
}

ChartPlayer::ChartPlayer() {
	set_process(false);
}

void ChartPlayer::set_scale(double canvas_w, double canvas_h) {
	_kx = canvas_w / 1350.0;
	_ky = canvas_h / 900.0;
	_cx = canvas_w * 0.5;
	_cy = canvas_h * 0.5;
	_cw = canvas_w;
	_ch = canvas_h;
}

void ChartPlayer::set_skin(String name, Ref<Texture2D> tex) {
	if (name == "line") _tex_line = tex;
	else if (name == "tap") _tex_tap = tex;
	else if (name == "drag") _tex_drag = tex;
	else if (name == "flick") _tex_flick = tex;
	else if (name == "hold_head") _tex_hold_head = tex;
	else if (name == "hold") _tex_hold = tex;
	else if (name == "hold_end") _tex_hold_end = tex;
	else if (name == "fx") _tex_fx = tex;
	else if (name == "tap_hl") _tex_tap_hl = tex;
	else if (name == "drag_hl") _tex_drag_hl = tex;
	else if (name == "flick_hl") _tex_flick_hl = tex;
	else if (name == "hold_head_hl") _tex_hold_head_hl = tex;
	else if (name == "hold_hl") _tex_hold_hl = tex;
	else if (name == "hold_end_hl") _tex_hold_end_hl = tex;
}

// 资源包表现参数：全部来自 phira 的 info.yml（ResPackInfo），默认值与 prpr 一致。
// 一次调用给全，缺键=保持默认，所以 PT 包/内置只需要不调或空调。
// ⚠ 判定色 alpha 是 prpr 的 ARGB 语义（0xe1ffec9f → alpha 0xe1），不是 PT 的判定色常量。
void ChartPlayer::set_pack_options(Dictionary opts) {
	auto num_or = [&](const char *k, double def) {
		return opts.has(k) ? (double)opts[k] : def;
	};
	auto bool_or = [&](const char *k, bool def) {
		return opts.has(k) ? (bool)opts[k] : def;
	};
	_fx_cols = (int)num_or("fx_cols", 0);
	_fx_rows = (int)num_or("fx_rows", 0);
	_fx_duration = std::max(0.05, num_or("hit_fx_duration", 0.5));
	_fx_scale = num_or("hit_fx_scale", 1.0);
	_fx_tinted = bool_or("hit_fx_tinted", true);
	_fx_rotate = bool_or("hit_fx_rotate", false);
	_fx_prpr = bool_or("prpr_fx", false);
	_hide_particles = bool_or("hide_particles", false);
	_hold_repeat = bool_or("hold_repeat", false);
	_hold_compact = bool_or("hold_compact", false);
	_hold_keep_head = bool_or("hold_keep_head", false);
	_phira_sizing = bool_or("phira_sizing", false);
	_mh_width_factor = std::max(0.05, num_or("mh_width_factor", 1.0));
	if (opts.has("color_perfect")) _c_perfect = opts["color_perfect"];
	if (opts.has("color_good")) _c_good = opts["color_good"];
}

Dictionary ChartPlayer::get_pack_options() const {
	Dictionary o;
	o["fx_cols"] = _fx_cols;
	o["fx_rows"] = _fx_rows;
	o["hit_fx_duration"] = _fx_duration;
	o["hit_fx_scale"] = _fx_scale;
	o["hit_fx_tinted"] = _fx_tinted;
	o["hit_fx_rotate"] = _fx_rotate;
	o["prpr_fx"] = _fx_prpr;
	o["hide_particles"] = _hide_particles;
	o["hold_repeat"] = _hold_repeat;
	o["hold_compact"] = _hold_compact;
	o["hold_keep_head"] = _hold_keep_head;
	o["phira_sizing"] = _phira_sizing;
	o["mh_width_factor"] = _mh_width_factor;
	o["color_perfect"] = _c_perfect;
	o["color_good"] = _c_good;
	return o;
}

// 皮肤槽读回：与 set_skin 那串分支一一对应。QA 用它证明"屏幕上真的是选中的那个包"，
// 而不是拿 GDScript 侧自己算的一份表自证（换过包还显示旧包就是这么漏过去的）。
Dictionary ChartPlayer::get_skin_textures() const {
	Dictionary o;
	o["line"] = _tex_line;
	o["tap"] = _tex_tap;
	o["drag"] = _tex_drag;
	o["flick"] = _tex_flick;
	o["hold_head"] = _tex_hold_head;
	o["hold"] = _tex_hold;
	o["hold_end"] = _tex_hold_end;
	o["hold_end_hl"] = _tex_hold_end_hl;
	o["fx"] = _tex_fx;
	o["tap_hl"] = _tex_tap_hl;
	o["drag_hl"] = _tex_drag_hl;
	o["flick_hl"] = _tex_flick_hl;
	o["hold_head_hl"] = _tex_hold_head_hl;
	o["hold_hl"] = _tex_hold_hl;
	return o;
}

void ChartPlayer::set_line_texture(String name, Ref<Texture2D> tex, bool tintable, int frames, double fps) {
	_line_texs[name] = tex;
	_line_tex_tint[name] = tintable;
	if (_marker_kind(name) >= 0) _blk_sizes_dirty = true; // 噪域尺寸按引导图真实像素算
	if (frames > 1 && fps > 0.0) {
		Array a;
		a.push_back(frames);
		a.push_back(fps);
		_line_tex_anim[name] = a;
	}
}

Array ChartPlayer::get_line_textures() {
	Array out;
	for (const Line &l : _lines) {
		if (!out.has(l.texture)) out.push_back(l.texture);
	}
	return out;
}

// ───────── 解析 ─────────

bool ChartPlayer::load_chart_json(PackedByteArray bytes) {
	const uint8_t *dp = bytes.ptr();
	size_t dn = (size_t)bytes.size();
	size_t di = 0;
	while (di < dn && dp[di] <= 0x20) di++;   // 前置空白/换行/BOM 一律跳过（与原 strip_edges 同语义）
	// 魔数分发：'{' = RPE json 或 official json；否则 = PhiEditer .pe 文本（首行是偏移数字）。
	// .pe 走字节解析：357MB 的谱 parse_utf8 出来是 4 字节/字符的 Godot String（1.4GB），
	// 那笔内存和那次转换都白付——JSON 路径才需要 String。
	if (di < dn && dp[di] == '{') {
		const double _u0 = _prof_us();
		String txt;
		txt.parse_utf8((const char *)dp, dn);
		// official（Phigros 原生）指纹 = **根级** formatVersion。
		// 不能用 txt.contains() 找子串：rpe-next 的转换结果会把整份官谱塞进
		// rpeNextLegacySource.document 里带着走（它自己要拿去做往返），子串探测会把
		// 这份 RPE 谱误判成官谱、然后一条音符都读不出来。先解析、只看根键。
		Ref<JSON> probe;
		probe.instantiate();
		if (probe->parse(txt) == OK && probe->get_data().get_type() == Variant::DICTIONARY) {
			Dictionary root = probe->get_data();
			if (root.has("formatVersion")) return load_official(txt);
		}
		return load_rpe_json(txt);
	}
	return load_pe_bytes(dp, dn);
}

bool ChartPlayer::load_rpe_json(String txt) {
	_official_fmt = false;
	Ref<JSON> json;
	json.instantiate();
	if (json->parse(txt) != OK) {
		UtilityFunctions::push_error("chart json parse failed");
		return false;
	}
	Dictionary d = json->get_data();
	_lines.clear();
	_blocks.clear(); // RPE 噪域来自贴图标记线，线解析完再 _rpe_markers() 重建
	_fx.clear();
	_hitq.clear();
	_total_notes = 0;
	_perfect = _good = _bad = _miss = _combo = _max_combo = 0;
	_good_early = _good_late = 0;
	_duration = 0;

	Array bl = d["BPMList"];
	int bn = (int)bl.size();
	if (bn < 1) bn = 1;
	_bpm_n = bn;
	_bpm_beats.assign(bn, 0);
	_bpm_times.assign(bn, 0);
	_bpm_bps.assign(bn, 0);
	for (int i = 0; i < bn; i++) {
		Dictionary b = bl[i];
		_bpm_bps[i] = std::max(0.0001, _to_num(b["bpm"]) / 60.0);
		Variant st = b.get("startTime", 0.0);
		double beat = _to_num(b.get("startBeat", -1.0));
		if (beat < 0) beat = st.get_type() == Variant::ARRAY ? _beat_of(st) : 0;
		_bpm_beats[i] = beat;
		double t = 0;
		if (st.get_type() == Variant::DICTIONARY) {
			t = _to_num(((Dictionary)st)["time"]) / 1000.0;
		} else if (st.get_type() == Variant::ARRAY) {
			for (int j = 0; j < i; j++) {
				if (_bpm_beats[j] <= beat) t = _bpm_times[j] + (beat - _bpm_beats[j]) / _bpm_bps[j];
			}
		} else {
			t = _to_num(st) / 1000.0;
		}
		_bpm_times[i] = t;
	}
	if (_bpm_bps[0] <= 0) _bpm_bps[0] = 2.0;

	Dictionary meta = d.get("META", Dictionary());
	_offset = _to_num(meta.get("offset", 0.0)) / 1000.0;
	_rpe_ver = (int)_to_num(meta.get("RPEVersion", 0.0));
	_speedMode = _rpe_ver >= 170 ? 1 : 0;
	_name = (String)meta.get("name", "");
	_level = (String)meta.get("level", "");
	_meta_bg = (String)meta.get("background", "");

	Array jll = d["judgeLineList"];
	for (int li = 0; li < (int)jll.size(); li++) {
		Dictionary jd = jll[li];
		Line l;
		l.father = (int)_to_num(jd.get("father", -1));
		{
			// player Line.ts:300: if (anchor) setOrigin(a[0], 1-a[1]) —— 线贴图锚点。
			// テレパシ 01/02_初音带锤子 anchor=[0.65,0.5]/[0.35,0.2]：不处理=人物错位。
			Array anc = jd.get("anchor", Array());
			if (anc.size() >= 2) {
				l.ax = _to_num(anc[0]);
				l.ay = 1.0 - _to_num(anc[1]);
			}
		}
		l.zorder = (int)_to_num(jd.get("zOrder", 0));
		if (jd.has("zIndex")) l.zidx = _to_num(jd["zIndex"]); // player Line.ts:296
		// rpe-next scene.mjs：字段缺失时 RPEVersion>=163 继承父旋转，否则不继承。
		{
			Variant rw = jd.get("rotateWithFather", Variant());
			l.rwith = rw.get_type() == Variant::NIL ? (_rpe_ver >= 163) : (_to_num(rw) != 0);
		}
		// attachUI（player Line.ts:284/297）：UI/文字挂载线默认不画线精灵——
		// visible = !hasAttach || appearanceOnAttach || hasText。キメラ 的
		// level/pause/combo/score/name 六条白线就栽在这（白色 colorEvent 全亮画出来）。
		{
			Variant auv = jd.get("attachUI", Variant());
			String aus;
			if (auv.get_type() == Variant::STRING) aus = auv;
			else if (auv.get_type() == Variant::ARRAY && ((Array)auv).size() > 0) aus = String(((Array)auv)[0]);
			l.ui_attach = !aus.strip_edges().is_empty();
			l.attach = aus.strip_edges();
			l.aoe = (int)_to_num(jd.get("appearanceOnAttach", 0));
			// 线贴图（player Line.ts:266）：Texture≠line.png = 自定义贴图，不套默认线色
			l.texture = (String)jd.get("Texture", "line.png");
			if (l.texture.strip_edges().is_empty()) l.texture = "line.png";
			// 噪域标记线（prpr rpe_block::marker_kind）：isSubtract0/1.png 是编辑器引导图，
			// 不是运行时材质 —— 不画、几何/颜色喂给 _blocks（见 _rpe_markers）。
			l.block_marker = _marker_kind(l.texture) >= 0;
			Dictionary ext = jd.get("extended", Dictionary());
			Array tev = ext.get("textEvents", Array());
			for (int ti = 0; ti < (int)tev.size(); ti++) {
				Dictionary te = tev[ti];
				Variant tsv = te.get("start", Variant());
				Variant tev2 = te.get("end", Variant());
				Line::TxtEv tv;
				tv.s0 = tsv.get_type() == Variant::STRING ? (String)tsv : String();
				tv.s1 = tev2.get_type() == Variant::STRING ? (String)tev2 : tv.s0;
				Variant fv = te.get("font", Variant());
				if (fv.get_type() == Variant::STRING) tv.font = (String)fv;
				if (!tv.s0.is_empty() || !tv.s1.is_empty()) l.has_text = true;
				tv.t0 = _b2s(_beat_of(te.get("startTime", 0.0)));
				tv.t1 = _b2s(te.has("endTime") ? _beat_of(te["endTime"]) : (double)_beat_of(te.get("startTime", 0.0)));
				tv.ease = (int)_to_num(te.get("easingType", 1));
				tv.el = _to_num(te.get("easingLeft", 0.0));
				tv.er = _to_num(te.get("easingRight", 1.0));
				tv.bez = _to_num(te.get("bezier", 0)) == 1 && te.has("bezierPoints") &&
						((Array)te["bezierPoints"]).size() >= 4;
				if (tv.bez) {
					Array bp = te["bezierPoints"];
					for (int k = 0; k < 4; k++) tv.bp[k] = _to_num(bp[k]);
				}
				l.tx_ev.push_back(tv);
			}
			std::sort(l.tx_ev.begin(), l.tx_ev.end(),
					[](const Line::TxtEv &a, const Line::TxtEv &b) { return a.t0 < b.t0; });
			// 文字线（用户口径）：textEvents **有声明**就是文字线，哪怕每条事件的文字都空的
			// （"文字事件但没有文字"）。这种线只画字、不画线精灵；文字为空 ⇒ 画面上什么都没有。
			// 以前只认 has_text（要有非空文字），全空文字的声明会落到 line.png 分支 =
			// 屏幕正中一条 3 屏宽白线。
			l.text_kind = !l.tx_ev.empty();
		}
		l.cover = (int)_to_num(jd.get("isCover", 0)) == 1; // rpe-next：严格 ===1
		l.bpmf = std::max(0.01, _to_num(jd.get("bpmfactor", 1.0)));
		Array evs = jd.get("eventLayers", Array());
		for (int si = 0; si < (int)evs.size(); si++) {
			Dictionary lay = evs[si];
			Layer L;
			std::vector<Event> *dsts[5] = { &L.alpha, &L.mx, &L.my, &L.rot, &L.speed };
			const char *keys[5] = { "alphaEvents", "moveXEvents", "moveYEvents", "rotateEvents", "speedEvents" };
			for (int m = 0; m < 5; m++) {
				Array arr = lay.get(keys[m], Array());
				for (int ei = 0; ei < (int)arr.size(); ei++) {
					Dictionary e = arr[ei];
					Event ev;
					double sb = _beat_of(e.get("startTime", 0.0));
					double eb = _beat_of(e.has("endTime") ? e["endTime"] : e.get("startTime", 0.0));
					ev.s = _b2s(sb);
					ev.t = _b2s(std::max(sb, eb));
					ev.bS = sb;
					ev.bT = std::max(sb, eb);
					Variant sv = e.get("start", 0.0);
					ev.color = sv.get_type() == Variant::ARRAY;
					if (ev.color) {
						_to_rgb(sv, ev.rgb0);
						_to_rgb(e.get("end", sv), ev.rgb1);
						ev.v0 = 0;
						ev.v1 = 1;
					} else {
						ev.v0 = _to_num(sv);
						ev.v1 = _to_num(e.get("end", sv));
					}
					ev.ease = (int)_to_num(e.get("easingType", 1));
					ev.el = _to_num(e.get("easingLeft", 0.0));
					ev.er = _to_num(e.get("easingRight", 1.0));
					ev.bez = _to_num(e.get("bezier", 0)) == 1 && e.has("bezierPoints") &&
							((Array)e["bezierPoints"]).size() >= 4;
					if (ev.bez) {
						Array bp = e["bezierPoints"];
						for (int k = 0; k < 4; k++) ev.bp[k] = _to_num(bp[k]);
					}
					if (m == 1) { // moveXEvents
						Variant tjv = e.get("trajectory", Variant());
						if (tjv.get_type() == Variant::DICTIONARY) {
							const int ti = _parse_trajectory(tjv, l);
							if (ti >= 0) { ev.traj = ti; ev.traj_axis = 0; }
						}
					}
					dsts[m]->push_back(ev);
				}
				std::sort(dsts[m]->begin(), dsts[m]->end(), [](const Event &a, const Event &b) { return a.s < b.s; });
			}
			// rpe-next：moveX 上的 trajectory 事件同时驱动 moveY（axis=y）与 rotate（axis=rotation）
			{
				std::vector<Event> ty, tr;
				for (const Event &e : L.mx) {
					if (e.traj < 0) continue;
					Event c = e;
					c.traj_axis = 1;
					ty.push_back(c);
					const Traj &tj = l.trajs[e.traj];
					if (tj.tangent || tj.has_dir) {
						Event r = e;
						r.traj_axis = 2;
						tr.push_back(r);
					}
				}
				if (!ty.empty()) {
					L.my.insert(L.my.end(), ty.begin(), ty.end());
					std::sort(L.my.begin(), L.my.end(), [](const Event &a, const Event &b) { return a.s < b.s; });
				}
				if (!tr.empty()) {
					L.rot.insert(L.rot.end(), tr.begin(), tr.end());
					std::sort(L.rot.begin(), L.rot.end(), [](const Event &a, const Event &b) { return a.s < b.s; });
				}
			}
			l.layers.push_back(std::move(L));
		}
		// extended（layer 0）
		Dictionary ext = jd.get("extended", Dictionary());
		_parse_ext(ext, "scaleXEvents", l.ext_sx);
		_parse_ext(ext, "scaleYEvents", l.ext_sy);
		_parse_ext(ext, "colorEvents", l.ext_color);
		_parse_ext(ext, "inclineEvents", l.ext_incline);
		_parse_ext(ext, "gifEvents", l.ext_gif);
		l.is_gif = (bool)jd.get("isGif", false);
		// control 数组（player 在缺失时注入默认值）
		_parse_ctrl(jd, "alphaControl", l.c_alpha);
		_parse_ctrl(jd, "posControl", l.c_pos);
		_parse_ctrl(jd, "sizeControl", l.c_size);
		_parse_ctrl(jd, "skewControl", l.c_skew);
		_parse_ctrl(jd, "yControl", l.c_y);

		std::vector<Note> ns;
		Variant nv = jd.get("notes", Array());
		auto push_note = [&](Dictionary nd) {
			Note n;
			double sb = _beat_of(nd.get("startTime", Array()));
			double eb = _beat_of(nd.has("endTime") ? nd["endTime"] : nd.get("startTime", Array()));
			// rpe-next scene.mjs：音符时间同样乘 bpmfactor（事件也乘，二者必须同系）
			n.t = _b2s(sb) * l.bpmf;
			n.t2 = std::max(n.t, _b2s(std::max(sb, eb)) * l.bpmf);
			n.x = _to_num(nd.get("positionX", 0.0));
			n.type = (int)_to_num(nd.get("type", 1));
			n.speed = _to_num(nd.get("speed", 1.0)); // rpe-next：0=静态钉线（不钳位，窗口另行处理）
			n.size = std::max(0.0001, _to_num(nd.get("size", 1.0)));
			n.yoff = _to_num(nd.get("yOffset", 0.0)) * n.speed; // player：构造时 yOffset*=speed
			n.above = (int)_to_num(nd.get("above", 1));
			n.alpha = _to_num(nd.get("alpha", 255.0));
			n.vtime = _to_num(nd.get("visibleTime", 999999.0));
			n.fake = _to_num(nd.get("isFake", 0)) != 0;
			// 扩展属性（player types.ts Note 可选项）
			if (nd.has("zIndex")) n.z = _to_num(nd["zIndex"]);
			if (nd.has("zIndexHitEffects")) n.zfx = _to_num(nd["zIndexHitEffects"]);
			if (nd.has("judgeSize")) n.jsize = _to_num(nd["judgeSize"]);
			// rpe-next preview：`note.tint ?? note.color` 都可当音符染色
			Variant tv = nd.get("tint", Variant());
			if (tv.get_type() != Variant::ARRAY) tv = nd.get("color", Variant());
			if (tv.get_type() == Variant::ARRAY) {
				Array ta = tv;
				if (ta.size() >= 3) {
					n.tr = _to_num(ta[0]) / 255.0;
					n.tg = _to_num(ta[1]) / 255.0;
					n.tb = _to_num(ta[2]) / 255.0;
					n.has_tint = true;
				}
			}
			// tintHitEffects（player JudgmentHandler.createHitEffects：hit(rgbToHex(note.tintHitEffects))
			// —— 命中特效贴图与 PT 粒子都吃这个色，缺省回落判定色）
			Variant fvtv = nd.get("tintHitEffects", Variant());
			if (fvtv.get_type() == Variant::ARRAY) {
				Array ta2 = fvtv;
				if (ta2.size() >= 3) {
					n.ftr = _to_num(ta2[0]) / 255.0;
					n.ftg = _to_num(ta2[1]) / 255.0;
					n.ftb = _to_num(ta2[2]) / 255.0;
					n.has_fx_tint = true;
				}
			}
			Variant hv = nd.get("hitsound", Variant());
			if (hv.get_type() == Variant::STRING) n.hs = String(hv);
			ns.push_back(n);
		};
		if (nv.get_type() == Variant::ARRAY) {
			Array arr = nv;
			for (int i = 0; i < (int)arr.size(); i++) push_note(arr[i]);
		} else if (nv.get_type() == Variant::DICTIONARY) {
			Dictionary dd = nv;
			for (Variant key : dd.keys()) {
				Array arr = dd[key];
				for (int i = 0; i < (int)arr.size(); i++) push_note(arr[i]);
			}
		}
		std::sort(ns.begin(), ns.end(), [](const Note &a, const Note &b) { return a.t < b.t; });
		for (auto &n : ns) {
			if (!n.fake) {
				_total_notes++;
				_duration = std::max(_duration, n.t2);
			}
		}
		// 文字工具建出来的线、文字在这份文件里丢了（opia 案，用户 2026-10-27 两次报"白线没有字"）。
		// PhiEdit 的"文字"会生成一条 line.png 线 + 纯白 colorEvents + scaleX=sY=0.8 + isCover，
		// 内容在 extended.textEvents；PZ 上这份 opia 的 textEvents 整份是 null ⇒ 按 prpr
		// (rpe.rs:741 text_events 为 None → JudgeLineKind::Normal) 和 rpe-next(preview.mjs) 的规则
		// 它退化成普通线 = 屏幕上一条三屏宽白条（beat 125/132/328 ≈ 38.9/41.0/101.9s）。
		// 判据取"文字工具模板"的全套特征，宁可窄不可宽：本机 19 张谱 1581 条线只命中这 3 条；
		// 而"无音符+无文字"的装饰线有 467 条（时光盲盒的雪花 1-6 等），拿它当规则会误伤。
		if (!l.text_kind && !l.ui_attach && l.texture == "line.png" && ns.empty()
				&& !l.ext_color.empty() && !l.ext_sx.empty() && !l.ext_sy.empty()) {
			bool all_white = true, all_08 = true;
			for (const Event &c : l.ext_color)
				if (!(c.rgb0[0] >= 254 && c.rgb0[1] >= 254 && c.rgb0[2] >= 254)) all_white = false;
			for (const Event &c : l.ext_sx)
				if (fabs(c.v0 - 0.8) > 1e-6 || fabs(c.v1 - 0.8) > 1e-6) all_08 = false;
			for (const Event &c : l.ext_sy)
				if (fabs(c.v0 - 0.8) > 1e-6 || fabs(c.v1 - 0.8) > 1e-6) all_08 = false;
			if (all_white && all_08) l.text_kind = true;   // 当文字线处理：没有字就什么都不画
		}
		l.notes = std::move(ns);
		l.cur_h.assign(l.layers.size() + 1, 0);
		l.cur_i.assign(l.layers.size() + 1, 0);
		_lines.push_back(std::move(l));
	}
	// RPE json 也能内嵌官方式 blockAreaList（prpr parse_rpe：有就用它，没有才读外部文件）；
	// 时间同样是音乐秒。标记线噪域**追加**在它后面（prpr block_zones：official 先、marker 后）。
	// 噪域层（rpe-next noise-skin：noiseAreaLayers；缺省 = 单层 default）
	_block_layers.clear();
	_bml.clear();
	{
		Array lya = d.get("noiseAreaLayers", Array());
		for (int i = 0; i < (int)lya.size(); i++) {
			if (lya[i].get_type() != Variant::DICTIONARY) continue;
			Dictionary ld = lya[i];
			BlockLayer bl;
			bl.id = String(ld.get("id", "default"));
			if (bl.id.is_empty()) bl.id = "default";
			bl.name = String(ld.get("name", bl.id));
			bl.skin = String(ld.get("skin", ""));
			bl.channel = String(ld.get("channel", "normal"));
			Variant pv2 = ld.get("parameters", Variant());
			if (pv2.get_type() == Variant::DICTIONARY) bl.params = pv2;
			_block_layers.push_back(bl);
		}
		if (_block_layers.empty()) _block_layers.push_back(BlockLayer());
	}
	{
		Dictionary o = d.get("noiseAreaOptions", Dictionary());
		Variant it = o.get("ignoreTripleInversion", false);
		_noise_ignore_triple = it.get_type() == Variant::BOOL ? (bool)it : (_to_num(it) != 0);
	}
	_parse_blocks(d.get("blockAreaList", Array()));
	_rpe_markers(); // 噪域：贴图标记线 → Block（prpr Chart::new + set_rpe_block_*）
	_parse_chart_effects(d); // 谱内着色器事件（rpe-next 220+：chart.effects / shaderEvents / META.effects / paintEvents）
	_finalize();
	return true;
}

// official（Phigros 原生）格式 → 本管线 RPE 模型。单位事实取 prpr/src/parse/pgr.rs
// （TeamFlos/phira，官方谱的权威加载器）：
//   时间 = tick × (60/32/bpm线)（每线独立 bpm，全部折成秒；全局 BPMList 合成 60bpm → beat≡秒）
//   type 1tap/2drag/3hold/4flick → RPE 1/4/2/3（真谱统计：holdTime>0 当且仅当 type==3）
//   positionX 单位 = 0.1125×半屏宽 → 图面 ×75.9375（11.0 最大偏移 ≈ ±835 图面，出屏合法）
//   speed value ×4.5 = RPE 原值（prpr 两路等价：官方 ∫v dt/H.RATIO ≡ RPE ∫v×(10/45/H.RATIO) dt，
//   常数段、无缓动；实测 400 谱 5706 线 speed 事件全连续无缝隙）
//   位移 fv3 = [0,1] 比例（x 左→右、y 0=底，prpr 2v−1 直取）→ 图面 (v−0.5)×1350 / ×900−450
//   位移 fv1 = 打包值：x=(v−v%1000)/1000∈[0,880]、y=v%1000∈[0,520] → 图面 ×1350/880−675、×900/520−450
//   透明度 = [0,1]（真谱见 ±15 的“迟穿越缓动”手法：使用时钳位，与管线 clampd(opa) 一致）→ ×255
//   hold：头速度恒 1（pgr.rs 强制 speed=1），尾时刻=(time+holdTime) 落在线速度积分曲线上
//   offset = 秒，与 RPE META.offset/1000 同字段同向（prpr game.rs 共用 chart.offset）
// official speedEvent 的 value·秒 → player 内部高度单位的换算常数。player 的换算链是
// dScale = canvas.height*2/15、dist = dScale·(noteHeight − lineHeight)·note.speed
// （Line.ts:621/635、LongNote.ts:116-118）。参考实现 sim-phi（唯一真读过 official 的那套）
// 用的是 transformView 的 `app.scaleY = -(-canvasfg.height)*0.6 = 0.6·H`（core.ts:241）
// 即「1 个 official 高度单位 = 0.6·H 像素」，与本管线同一个画布高 ⇒
//     SPD_UNIT = 0.6 ÷ (2/15) = 4.5   —— 推导值，不是拟合。
// 交叉核对：prpr 那边等价常数是 1/(2×HEIGHT_RATIO)=4.50856，差 0.19%，按用户裁定
// （2026-10-05「只有噪域抄 Phira-Pro，渲染器/RPE/PE/official 全按 player」）不采用。
// 音符**头端**高度优先取 json 自带的 floorPosition（见下），只有缺字段时才回退 _height_at 积分。
//
// 2026-10-08 用 oracle 对拍核实过（tests/off_oracle.mjs = 逐行照抄 sim-phi core.ts/index.ts，
// tests/off_dump.gd = 原生 debug_notes/debug_line_state/debug_note_worlds 落盘）：
// ハテ IN(1014 音符/24 线)、AT(1397 音符/66 线) 各 49 个时刻，线 wx/wy/rot/alpha/height 与
// 音符屏幕坐标 **Δ=0.000**；sim-phi 真跑（self.hook.app.updateByTime(52.8)）也确认
// 「speedEvents 有 value=0 平台段 ⇒ 音符贴线不动」是 official 口径本身，不是本读取器偏差。
// 当时只剩两处真偏差，均已在此修正：① hold 身体长度（见 push_arr 的 ot==3 分支）；
// ② 线 alpha 端点钳 ≥0（见 judgeLineDisappearEvents 分支）。
static const double SPD_UNIT = 4.5;

bool ChartPlayer::load_official(String txt) {
	Ref<JSON> json;
	json.instantiate();
	if (json->parse(txt) != OK) {
		UtilityFunctions::push_error("official chart json parse failed");
		return false;
	}
	Dictionary d = json->get_data();
	int fv = (int)_to_num(d.get("formatVersion", 3.0));
	if (fv != 1 && fv != 3) {
		UtilityFunctions::push_error("official chart unknown formatVersion: " + String::num(fv));
		return false;
	}
	_official_fmt = true; // 仅供诊断：official 的两处口径差异（hold 刚性身体、线 alpha 钳 ≥0）
	// 都在本函数里就地折算成 RPE 模型能表达的数值了，渲染器不需要按格式分支——
	// 之前这里留了个从来没人读的标志，害得「藏线是否该连音符一起藏」反复试错（见上注释块）。
	_lines.clear();
	_fx.clear();
	_hitq.clear();
	_total_notes = 0;
	_perfect = _good = _bad = _miss = _combo = _max_combo = 0;
	_good_early = _good_late = 0;
	_duration = 0;
	// 全线时间已折秒：单断点 60bpm 使 _b2s/_s2b 恒等（bS/bT 直接填秒）
	_bpm_n = 1;
	_bpm_beats.assign(1, 0);
	_bpm_times.assign(1, 0);
	_bpm_bps.assign(1, 1.0);
	_offset = _to_num(d.get("offset", 0.0));
	_speedMode = 0;
	_name = "";
	_level = "";
	_meta_bg = "";

	Array jll = d.get("judgeLineList", Array());
	int notes_total = 0;
	for (int li = 0; li < (int)jll.size(); li++) {
		Dictionary jd = jll[li];
		Line l;
		double bpm = std::max(0.01, _to_num(jd.get("bpm", 140.0)));
		double r = 60.0 / 32.0 / bpm; // 秒/tick
		Layer L;
		auto push_ev = [](std::vector<Event> &dst, double s, double t, double v0, double v1) {
			Event e;
			e.s = s; e.t = t; e.bS = s; e.bT = t; e.v0 = v0; e.v1 = v1;
			dst.push_back(e);
		};
		auto ev_time = [&](Dictionary &e, double &s, double &t) -> bool {
			s = std::max(0.0, _to_num(e.get("startTime", 0.0)) * r); // pgr.rs：起点钳 0（-999999 哨兵）
			t = _to_num(e.get("endTime", 0.0)) * r;
			return t >= s; // pgr.rs validate：区间倒挂整条丢弃
		};
		{
			Array ae = jd.get("judgeLineDisappearEvents", Array());
			for (int i = 0; i < (int)ae.size(); i++) {
				Dictionary e = ae[i];
				double s, t;
				if (!ev_time(e, s, t)) continue;
				// official 的线透明度只有 [0,1]，且**只作用于线精灵**：sim-phi 的音符挂在全局
				// tap/drag/flick/hold 层（index.ts:1695-1722），从不因线隐而隐音符，只做
				// `if (alpha > 1) alpha = 1`（core.ts:422）。而本管线的 RPE 语义里
				// `araw < 0 ⇒ 整条线的音符一起藏`（chart_player.cpp 绘制门 notes_hidden），
				// 真谱 IN 实测有 4 个 -0.003 的浮点噪声端点，落进那段就会「整段音符消失」。
				// ⇒ 官谱端点一律钳到 ≥0：araw 恒非负，负值门/镜像门对官谱不可能触发。
				double v0 = std::max(0.0, _to_num(e.get("start", 1.0))) * 255.0;
				double v1 = std::max(0.0, _to_num(e.get("end", e.get("start", 1.0)))) * 255.0;
				push_ev(L.alpha, s, t, v0, v1);
			}
			Array re = jd.get("judgeLineRotateEvents", Array());
			for (int i = 0; i < (int)re.size(); i++) {
				Dictionary e = re[i];
				double s, t;
				if (!ev_time(e, s, t)) continue;
				double v0 = -_to_num(e.get("start", 0.0));
				double v1 = -_to_num(e.get("end", e.get("start", 0.0)));
				push_ev(L.rot, s, t, v0, v1); // 度：official Unity z 正=视觉逆时针(y上世界)，
				// 本管线/RPE 正=视觉顺时针(y下画布) → 取负（prpr 在 y上世界直取，与本式等价）。
				// 实证：ハテ +90° 竖线音符来向与官屏镜像（用户 gameplay 截图对帧）
			}
			Array me = jd.get("judgeLineMoveEvents", Array());
			for (int i = 0; i < (int)me.size(); i++) {
				Dictionary e = me[i];
				double s, t;
				if (!ev_time(e, s, t)) continue;
				double a = _to_num(e.get("start", 0.0));
				double b = _to_num(e.get("end", a));
				if (fv == 3) {
					push_ev(L.mx, s, t, (a - 0.5) * 1350.0, (b - 0.5) * 1350.0);
					double a2 = _to_num(e.get("start2", 0.5));
					double b2 = _to_num(e.get("end2", a2));
					push_ev(L.my, s, t, (a2 - 0.5) * 900.0, (b2 - 0.5) * 900.0);
				} else {
					// fv1 打包（pgr.rs）：x=(v−v%1000)/1000 ∈[0,880]，y=v%1000 ∈[0,520]
					double x0 = (a - std::fmod(a, 1000.0)) / 1000.0;
					double y0 = std::fmod(a, 1000.0);
					double x1 = (b - std::fmod(b, 1000.0)) / 1000.0;
					double y1 = std::fmod(b, 1000.0);
					push_ev(L.mx, s, t, x0 * 1350.0 / 880.0 - 675.0, x1 * 1350.0 / 880.0 - 675.0);
					push_ev(L.my, s, t, y0 * 900.0 / 520.0 - 450.0, y1 * 900.0 / 520.0 - 450.0);
				}
			}
			Array se = jd.get("speedEvents", Array());
			for (int i = 0; i < (int)se.size(); i++) {
				Dictionary e = se[i];
				double s, t;
				if (!ev_time(e, s, t)) continue;
// 4.5 = 官方 speedEvent 值 → player 内部高度单位的换算常数（推导：sim-phi 0.6·H/单位 ÷
				// 本管线 dScale=H·2/15，见文件上方 SPD_UNIT 注释块）。
				// **不要换成 prpr 的 1/(2×HEIGHT_RATIO)=4.50856**：
				// 用户 2026-10-05 裁定「只有噪域抄 Phira-Pro，渲染器/RPE/PE/official 全按 player」。
				double v = _to_num(e.get("value", 0.0)) * SPD_UNIT;
				push_ev(L.speed, s, t, v, v);
			}
			std::sort(L.alpha.begin(), L.alpha.end(), [](const Event &x, const Event &y) { return x.s < y.s; });
			std::sort(L.rot.begin(), L.rot.end(), [](const Event &x, const Event &y) { return x.s < y.s; });
			std::sort(L.mx.begin(), L.mx.end(), [](const Event &x, const Event &y) { return x.s < y.s; });
			std::sort(L.my.begin(), L.my.end(), [](const Event &x, const Event &y) { return x.s < y.s; });
			std::sort(L.speed.begin(), L.speed.end(), [](const Event &x, const Event &y) { return x.s < y.s; });
		}
		l.layers.push_back(std::move(L));
		std::vector<Note> ns;
		auto push_arr = [&](Array arr, int above) {
			for (int i = 0; i < (int)arr.size(); i++) {
				Dictionary nd = arr[i];
				int ot = (int)_to_num(nd.get("type", 1.0));
				int ty = ot == 1 ? 1 : ot == 2 ? 4 : ot == 3 ? 2 : ot == 4 ? 3 : 0;
				if (ty == 0) {
					UtilityFunctions::push_warning("official: unknown note type " + String::num(ot) + ", skipped");
					continue; // pgr.rs 此处直接 bail 整谱；我们容忍单音符
				}
				Note n;
				double tm = _to_num(nd.get("time", 0.0)) * r;
				double hs = _to_num(nd.get("holdTime", 0.0)) * r; // hold 时长（秒）
				double jsp = _to_num(nd.get("speed", 1.0));
				n.t = tm;
				n.t2 = std::max(tm, tm + hs);
				n.x = _to_num(nd.get("positionX", 0.0)) * 75.9375; // 0.1125×半屏宽
				// official json 自己就把每个音符的累计高度存成了 floorPosition。prpr 的
				// PgrNote 把它 #[allow(unused)] 掉了；我们自己的 sim-phi 拿它当权威
				// （core.ts:454 `(note.floorPosition - line.positionY) * note.speed`，
				// hold(type 3) 不乘 speed —— 与这边 hold speed=1 等价）。
				// 实测ハテ：逐段积分 ∫value·dt_sec 与 json.floorPosition 全部音符偏差 0
				// （AT 1397 个 / IN 1014 个），所以取 json 值不改变结果，
				// 但省掉一整条积分边界规则（事件间隙、首事件起点、缓动、-999999 哨兵）出错的可能。
				if (nd.has("floorPosition")) {
					double ofp = _to_num(nd["floorPosition"]); // official 高度单位
					n.fp = ofp * SPD_UNIT; // 官方单位 → player 高度单位
					n.has_fp = true;
				// maxVisiblePos（sim-phi core.ts:297-308）：fp + 0.001 个官方单位，
					// fp ≥ 11718.75 时容差按 2 的幂放大（补 float32 在大量级下的 ULP）。
					// 用途见绘制循环那道「未到点但已被线高越过 → 不可见」门。
					double prime = ofp >= 11718.75
							? std::pow(2.0, std::floor(1.0 + std::log2(ofp / 11718.75)))
							: 1.0;
					n.mvp = (ofp + 0.001 * prime) * SPD_UNIT;
				}
				n.type = ty;
				if (ot == 3) {
					// hold：头端不乘 note.speed（sim-phi core.ts:456 就是 (fp − positionY)），
					// 身体是**刚性长度 = holdSeconds × note.speed**，与线的 speed 曲线无关：
					//   index.ts:1794-1795 baseLength = app.scaleY·note.speed·speed、
					//                    holdLength = baseLength·holdSeconds（body 从 head 位置
					//                    朝远离线一侧量 holdLength，尾端与头端同速平移）；
					//   prpr parse/pgr.rs:171-174 用 note.speed / v_head 缩放整条，v 局部恒定时
					//                    与上式等价 ⇒ 两权威同向。
					// 官谱的 note.speed 就是「长度旋钮」（实测 IN 0.23/99/999、AT 1.25/2.3/35/
					// 100/500），原先我们强制 1 并按 ∫v_line dt 算尾端 ⇒ hold 长度全错
					// （ハテ AT L3 t=37.551 差 863px vs 147px）。
					n.speed = 1.0;
					n.rigid_tail = true;
					n.hold_off = SPD_UNIT * hs * std::max(0.0, jsp);
					// 头过线后尾端必须以 json.speed 个官方单位/秒 的速率线性收到线上，
					// 才能「尾端正好在 t2 落线」＝长度对齐（sim-phi 那边头尾一起下移，
					// tail = (t−now)·sp + holdSec·sp，now=t2 时恰好 0）。
					// 若沿用 (hT2 − 线高) 让尾端吃线的积分曲线，尾端落线时刻 = ∫v dt 追上
					// hold_off 的那一刻，v≠note.speed 时就提前/滞后（官谱 note.speed 是
					// 0.23…999 这种量级，差得离谱）。
					n.hold_rate = SPD_UNIT * std::max(0.0, jsp);
					if (jsp == 0.0) n.alpha = 0; // sim-phi core.ts:476：speed=0 的 hold 不可见
				} else {
					n.speed = std::max(0.0001, jsp);
				}
				n.above = above;
				ns.push_back(n);
				notes_total++;
			}
		};
		push_arr(jd.get("notesAbove", Array()), 1);
		push_arr(jd.get("notesBelow", Array()), 0);
		std::sort(ns.begin(), ns.end(), [](const Note &a, const Note &b) { return a.t < b.t; });
		for (auto &n : ns) {
			_total_notes++;
			_duration = std::max(_duration, n.t2);
		}
		l.notes = std::move(ns);
		l.cur_h.assign(l.layers.size() + 1, 0);
		l.cur_i.assign(l.layers.size() + 1, 0);
		_lines.push_back(std::move(l));
	}
	UtilityFunctions::print("QA-OFFICIAL fv=", fv, " lines=", (int)_lines.size(),
			" notes=", notes_total, " duration=", _duration, " offset=", _offset);
	_block_layers.clear();
	_bml.clear();
	_block_layers.push_back(BlockLayer());
	_parse_blocks(d.get("blockAreaList", Array()));
	if (!_blocks.empty())
		UtilityFunctions::print("QA-OFFICIAL blockAreas=", (int)_blocks.size());
	_finalize();
	return true;
}


// ════════════════ 官方谱 blockArea（噪域）════════════════
// 语义权威 = Phira-Pro 的 prpr fork `src/core/block.rs`（逆向自官游 PreviewBlockControl /
// JudgeControl / BlockArea，注释里带 RVA 地址；2026-10-05 拉取核对）。逐条照抄：
//   * 关键帧段 = [本帧, 下一帧]，用【本帧】easeType 从本帧值插到下一帧值；首帧前取默认
//     （move=没有移动 / rotate=0 / scale=1），末帧后保持末帧值；
//     easeType 0=Linear、1..12=幂表（n=(type-1)/3+2，余数 0/1/2=In/Out/InOut）、
//     13=HoldStart（整段按住起值）、14=JumpToEnd（整段直接终值）；
//   * 锚点是阶跃的（取本帧 anchor，不插值）；rect 的 center 按每个关键帧的锚点差逐段搬运，
//     顺序 = 缩放 → 旋转 → move 增量（"锚点不动、框自己长大/转过去"）；
//   * size = 基准尺寸 × scale（不绕锚点），rotation 绕搬运后的 center；
//   * 相位 3 个（Hidden/Disabled/Active），ready = enable 前 0.5s 与 Active 同层绘制，
//     Disabled 渐显 0.5s 仅当 appear 时刻该块尚未激活；
//   * 坐标 = 屏百分比 [0,1] 原点左下 → 图面系 x∈[-1,1]、y∈[-1/aspect,1/aspect]
//     （1 单位=半屏宽，各向同性）；角度逆时针为正（图面系 y 上），落到 y 向下画布时
//     由映射自动翻向，无需额外取负；
//   * 触点拦截 = 奇偶规则 + 双框（整框与内缩框都判）：见 block_hit。

double ChartPlayer::_area_ease(int type, double x) {
	if (type <= 0) return x;                                    // 0 = Linear
	if (type >= 13) return type == 13 ? 0.0 : 1.0;              // 13 HoldStart / 14 JumpToEnd
	int n = (type - 1) / 3 + 2; // 1..3=二次 4..6=三次 7..9=四次 10..12=五次
	int variant = (type - 1) % 3;
	x = clampd(x, 0.0, 1.0);
	if (variant == 0) return std::pow(x, n);
	if (variant == 1) return 1.0 - std::pow(1.0 - x, n);
	return x < 0.5 ? std::ldexp(std::pow(x, n), n - 1) : 1.0 - std::pow(2.0 - 2.0 * x, n) * 0.5;
}

double ChartPlayer::_area_norm(double cur, double next, double t) {
	return next <= cur ? 1.0 : (t - cur) / (next - cur);
}

// 最后一个 time<=t 的下标（prpr last_index：t 早于首帧时返回 -1 → 取默认值）
template <typename Ev>
static int _blk_last(const std::vector<Ev> &evs, double t) {
	int i = -1;
	for (int k = 0; k < (int)evs.size(); k++) {
		if (evs[k].t <= t) i = k;
		else break;
	}
	return i;
}

// 官方 SafeDiv：分母≈0 时比值取 1（零缩放不产生 inf/NaN）
static double _blk_div(double a, double b) {
	return std::fabs(b) < 1e-44 ? 1.0 : a / b;
}

double ChartPlayer::_rot_at(const std::vector<BlockRot> &e, double t) {
	int i = _blk_last(e, t);
	if (i < 0) return 0.0;
	if (i + 1 >= (int)e.size()) return e[i].rot;
	const double p = _area_ease(e[i].ease, _area_norm(e[i].t, e[i + 1].t, t));
	return e[i].rot + p * (e[i + 1].rot - e[i].rot);
}

double ChartPlayer::_scale_at(const std::vector<BlockScale> &e, double t, int axis) {
	int i = _blk_last(e, t);
	if (i < 0) return 1.0;
	const double a = axis ? e[i].sy : e[i].sx;
	if (i + 1 >= (int)e.size()) return a;
	const double b = axis ? e[i + 1].sy : e[i + 1].sx;
	const int ez = axis ? e[i].ease_y : e[i].ease_x;
	return a + _area_ease(ez, _area_norm(e[i].t, e[i + 1].t, t)) * (b - a);
}

void ChartPlayer::_mv_at(const std::vector<BlockMove> &e, double t, double out[2]) {
	out[0] = out[1] = 0.0;
	int i = _blk_last(e, t);
	if (i < 0) return; // 首帧前：不移动
	if (i + 1 >= (int)e.size()) {
		out[0] = e[i].ex;
		out[1] = e[i].ey;
		return;
	}
	const double px = _area_ease(e[i].ease_x, _area_norm(e[i].t, e[i + 1].t, t));
	const double py = _area_ease(e[i].ease_y, _area_norm(e[i].t, e[i + 1].t, t));
	out[0] = e[i].ex + px * (e[i + 1].ex - e[i].ex);
	out[1] = e[i].ey + py * (e[i + 1].ey - e[i].ey);
}

// ── rpe-next 轨道求值 ──
// 取最后一条 s<=t 的事件，在它自己的 [s,t] 里按自己的缓动插值 —— 和 rpe-next
// NoiseAreaRuntime.track 的 `upperBound(events, sec+ε, e=>e.start)-1` + 段内 clamp 同构。
static int _span_last(const std::vector<ChartPlayer::BlockSpan> &evs, double t) {
	int i = -1;
	for (int k = 0; k < (int)evs.size(); k++) {
		if (evs[k].ev.s <= t) i = k;
		else break;
	}
	return i;
}

double ChartPlayer::_t1_at(const std::vector<BlockSpan> &e, double t, double fallback) const {
	const int i = _span_last(e, t);
	if (i < 0) return fallback;   // 首键之前：取 rpe-next 的 fallback（缩放 1、旋转 0、移动=基准中心）
	return _event_value(e[i].ev, t);
}

// rpe-next（Re:PhiEdit Next）把噪域做成 RPE 一等公民：顶层 blockAreaList + META.RPEVersion>=220。
// 与官方 v3 的 blockAreaList 是三处不同：
//   ① 矩形是 bottomLeft/topRight 绝对坐标（±675 / ±450），不是百分比；
//   ② 时间是拍三元数组 [拍,分子,分母]，不是音乐秒；
//   ③ 生命周期是 activeIntervals[]（每段自带 readyFlash 预警提前量），
//      减算叫 isInvert，五条轨道 moveX/moveY/rotate/scaleX/scaleY 各自独立成轴。
// 这里统一折算成 ①的百分比 + ②的秒，塞进 Block 的逐轴轨道（nx1=true）。
void ChartPlayer::_parse_block_next(const Dictionary &bd) {
	auto pct_x = [](double v) { return (v + 675.0) / 1350.0; };
	auto pct_y = [](double v) { return (v + 450.0) / 900.0; };
	Dictionary bl = bd.get("bottomLeft", Dictionary());
	Dictionary tr = bd.get("topRight", Dictionary());
	Block base;
	base.nx1 = true;
	{
		const String lid = String(bd.get("layerId", "default"));
		base.layer = 0;
		for (int i = 0; i < (int)_block_layers.size(); i++)
			if (_block_layers[i].id == lid) { base.layer = i; break; }
	}
	base.nx_area = _nx_cursor; // 一个区可能出多个 Block（多段激活区间），都记同一个源下标
	base.blx = pct_x(_to_num(bl.get("x", -250.0)));
	base.bly = pct_y(_to_num(bl.get("y", -150.0)));
	base.trx = pct_x(_to_num(tr.get("x", 250.0)));
	base.tr_y = pct_y(_to_num(tr.get("y", 150.0)));
	base.sub = _to_num(bd.get("isInvert", false)) != 0;
	const double c0x = (base.blx + base.trx) * 0.5, c0y = (base.bly + base.tr_y) * 0.5;
	base.appear = beat_to_sec(_beat_of(bd.get("appearTime", 0.0)));
	base.disappear = beat_to_sec(_beat_of(bd.get("disappearTime", base.appear)));

	// 一条 rpe-next 事件 → BlockSpan。锚点缺省取矩形中心（rpe-next 的 `?? this.center`）；
	// transformStart/End 缺省取采样首尾值（rpe-next 的 `event.transformStart ?? event.start`）。
	// vfun：把该轨的数值折算成 Block 里存的口径。move 两轨传 pct_x/pct_y（rpe-next 是
	// ±675/±450 绝对值，Block 存归一化百分比），缩放/旋转传恒等（本来就是倍率/角度）。
	auto push_span = [&](std::vector<BlockSpan> &out, const Array &arr, bool anchored,
			double fallback_v, std::function<double(double)> vfun) {
		for (int k = 0; k < (int)arr.size(); k++) {
			Dictionary e = arr[k];
			BlockSpan sp;
			sp.ev.s = beat_to_sec(_beat_of(e.get("startTime", 0.0)));
			sp.ev.t = beat_to_sec(_beat_of(e.get("endTime", 0.0)));
			if (sp.ev.t < sp.ev.s) std::swap(sp.ev.s, sp.ev.t); // 倒挂区间：按先后排，不让求值区间为空
			sp.ev.v0 = vfun(_to_num(e.get("start", fallback_v)));
			sp.ev.v1 = vfun(_to_num(e.get("end", _to_num(e.get("start", fallback_v)))));
			sp.ev.ease = (int)_to_num(e.get("easingType", 1));
			sp.ev.el = _to_num(e.get("easingLeft", 0.0));
			sp.ev.er = _to_num(e.get("easingRight", 1.0));
			sp.ev.bez = _to_num(e.get("bezier", 0)) != 0;
			Array bp = e.get("bezierPoints", Array());
			for (int j = 0; j < 4 && j < (int)bp.size(); j++) sp.ev.bp[j] = _to_num(bp[j]);
			if (anchored) {
				Dictionary a = e.get("anchor", Dictionary());
				sp.ax = a.is_empty() ? c0x : pct_x(_to_num(a.get("x", c0x * 1350.0 - 675.0)));
				sp.ay = a.is_empty() ? c0y : pct_y(_to_num(a.get("y", c0y * 900.0 - 450.0)));
			}
			sp.tv0 = _to_num(e.get("transformStart", _to_num(e.get("start", fallback_v))));
			sp.tv1 = _to_num(e.get("transformEnd", _to_num(e.get("end", sp.tv0))));
			if (anchored) { sp.tv0 = vfun(sp.tv0); sp.tv1 = vfun(sp.tv1); } // 缩放/旋转是恒等，显式走一遍
			out.push_back(sp);
		}
		std::stable_sort(out.begin(), out.end(),
				[](const BlockSpan &a, const BlockSpan &b) { return a.ev.s < b.ev.s; });
	};
	auto id = [](double v) { return v; };
	push_span(base.mvx, bd.get("moveXEvents", Array()), false, c0x * 1350.0 - 675.0, pct_x);
	push_span(base.mvy, bd.get("moveYEvents", Array()), false, c0y * 900.0 - 450.0, pct_y);
	// rpe-next 在官谱导入时就把 rotation 取过负（official-noise.mjs `value: -event.rotation`），
	// 而本管线 Block 的角度沿用官谱口径（图面系逆时针为正，且 center 搬运和矩形自转都用它，
	// 已经对过官屏）。这里把符号翻回来，两条路径才在同一约定下比较 —— 差分测试实测：
	// 不翻的话 rot官=90 / rpe=-90，带旋转的区四角整个镜像。
	auto neg = [](double v) { return -v; };
	push_span(base.rot1, bd.get("rotateEvents", Array()), true, 0.0, neg);
	push_span(base.scx, bd.get("scaleXEvents", Array()), true, 1.0, id);
	push_span(base.scy, bd.get("scaleYEvents", Array()), true, 1.0, id);

	// 多段激活区间 → 每段一个 Block（几何轨道整份复制：变换按时刻求值，切时间窗不影响它）。
	// 没有 activeIntervals 时 rpe-next 整段都是 disabled 态，这里用 enable=disable=disappear 表达。
	Array iv = bd.get("activeIntervals", Array());
	if (iv.is_empty()) {
		Block b = base;
		b.enable = b.disable = b.disappear;
		_blocks.push_back(std::move(b));
		return;
	}
	for (int k = 0; k < (int)iv.size(); k++) {
		Dictionary d = iv[k];
		Block b = base;
		// 不做"把区间夹进生命周期"的处理：rpe-next 自己那样做（NoiseAreaRuntime 构造里的
		// Math.max/Math.min + filter(end>start)），会把官谱里 enable/disable 落在
		// appear/disappear 之外的那 16 个区整个丢掉 —— 而官谱路径在这 16 个区上给出的是
		// "整段只当预警显示"，那才是对过官屏的行为。相位判定本来就按 appear/disappear 收口，
		// 区间越界不会多显示一帧，所以这里原样搬数值即可（实测：与官谱路径逐角零误差）。
		b.enable = beat_to_sec(_beat_of(d.get("startTime", 0.0)));
		b.disable = beat_to_sec(_beat_of(d.get("endTime", b.enable)));
		Variant rf = d.get("readyFlash", 0.5);
		b.ready_lead = rf.get_type() == Variant::BOOL ? (_to_num(rf) ? 0.5 : 0.0)
				: std::max(0.0, _to_num(rf));
		_blocks.push_back(std::move(b));
	}
}

void ChartPlayer::_parse_blocks(const Array &arr) {
	_blocks.clear();
	if (arr.is_empty()) return;
	auto srt = [](auto &evs) {
		std::stable_sort(evs.begin(), evs.end(),
				[](const auto &a, const auto &b) { return a.t < b.t; });
	};
	for (int i = 0; i < (int)arr.size(); i++) {
		Dictionary bd = arr[i];
		// 两种 schema 同名不同形：官方案是 *Percentage + 秒 + enableTime/disableTime，
		// rpe-next（RPEVersion>=220）是 bottomLeft/topRight 绝对坐标 + 拍数组 + activeIntervals。
		// 按字段探测，不按 RPEVersion —— 混着写的谱也能各读各的。
		if (bd.has("bottomLeft") || bd.has("activeIntervals")) {
			_nx_cursor = i;
			_parse_block_next(bd);
			continue;
		}
		Block b;
		Dictionary tr = bd.get("topRightPercentage", Dictionary());
		Dictionary bl = bd.get("bottomLeftPercentage", Dictionary());
		b.trx = _to_num(tr.get("x", 0.5));
		b.tr_y = _to_num(tr.get("y", 0.5));
		b.blx = _to_num(bl.get("x", 0.5));
		b.bly = _to_num(bl.get("y", 0.5));
		b.appear = _to_num(bd.get("appearTime", 0.0));
		b.enable = _to_num(bd.get("enableTime", 0.0));
		b.disable = _to_num(bd.get("disableTime", 0.0));
		b.disappear = _to_num(bd.get("disappearTime", 0.0));
		b.sub = _to_num(bd.get("isSubtract", false)) != 0;
		Array mv = bd.get("moveEvents", Array());
		Array ro = bd.get("rotateEvents", Array());
		Array sc = bd.get("scaleEvents", Array());
		for (int k = 0; k < (int)mv.size(); k++) {
			Dictionary e = mv[k];
			Dictionary p = e.get("endPosition", Dictionary());
			BlockMove m;
			m.t = _to_num(e.get("time", 0.0));
			m.ex = _to_num(p.get("x", 0.0));
			m.ey = _to_num(p.get("y", 0.0));
			m.ease_x = (int)_to_num(e.get("easeTypeX", 0));
			m.ease_y = (int)_to_num(e.get("easeTypeY", 0));
			b.mv.push_back(m);
		}
		for (int k = 0; k < (int)ro.size(); k++) {
			Dictionary e = ro[k];
			Dictionary p = e.get("anchor", Dictionary());
			BlockRot r;
			r.t = _to_num(e.get("time", 0.0));
			r.ax = _to_num(p.get("x", 0.0));
			r.ay = _to_num(p.get("y", 0.0));
			r.rot = _to_num(e.get("rotation", 0.0));
			r.ease = (int)_to_num(e.get("easeType", 0));
			b.rot.push_back(r);
		}
		for (int k = 0; k < (int)sc.size(); k++) {
			Dictionary e = sc[k];
			Dictionary p = e.get("anchor", Dictionary());
			Dictionary s = e.get("scale", Dictionary());
			BlockScale q;
			q.t = _to_num(e.get("time", 0.0));
			q.ax = _to_num(p.get("x", 0.0));
			q.ay = _to_num(p.get("y", 0.0));
			q.sx = _to_num(s.get("x", 1.0));
			q.sy = _to_num(s.get("y", 1.0));
			q.ease_x = (int)_to_num(e.get("easeTypeX", 0));
			q.ease_y = (int)_to_num(e.get("easeTypeY", 0));
			b.sc.push_back(q);
		}
		srt(b.mv);
		srt(b.rot);
		srt(b.sc);
		_blocks.push_back(std::move(b));
	}
}

void ChartPlayer::_block_geom(Block &b, double W, double H) const {
	if (b.nx1) { _block_geom_next(b, W, H); return; }
	const double aspect = W / std::max(H, 1.0);
	auto pctX = [](double p) { return 2.0 * p - 1.0; };
	auto pctY = [aspect](double p) { return (2.0 * p - 1.0) / aspect; };
	const double blx = pctX(b.blx), bly = pctY(b.bly);
	const double trx = pctX(b.trx), tr_y = pctY(b.tr_y);
	const double bsx = trx - blx, bsy = tr_y - bly; // 基准尺寸（图面系）
	const double c0x = (blx + trx) * 0.5, c0y = (bly + tr_y) * 0.5; // 基准中心
	const double t = _now_music;
	const double scx = _scale_at(b.sc, t, 0), scy = _scale_at(b.sc, t, 1);
	const double rot = _rot_at(b.rot, t);

	// center 逐段搬运：已完成的关键帧整段按其到下一帧的锚点差应用，当前段用插值后的值
	double cx = c0x, cy = c0y;
	{
		int i = _blk_last(b.sc, t);
		for (int k = 0; i >= 0 && k < i && k + 1 < (int)b.sc.size(); k++) {
			const double ax = pctX(b.sc[k].ax), ay = pctY(b.sc[k].ay);
			cx = ax + _blk_div(b.sc[k + 1].sx, b.sc[k].sx) * (cx - ax);
			cy = ay + _blk_div(b.sc[k + 1].sy, b.sc[k].sy) * (cy - ay);
		}
		if (i >= 0 && i + 1 < (int)b.sc.size()) {
			const double ax = pctX(b.sc[i].ax), ay = pctY(b.sc[i].ay);
			cx = ax + _blk_div(scx, b.sc[i].sx) * (cx - ax);
			cy = ay + _blk_div(scy, b.sc[i].sy) * (cy - ay);
		}
	}
	{
		int i = _blk_last(b.rot, t);
		auto orbit = [](double &x, double &y, double ax, double ay, double deg) {
			const double r = deg * M_PI / 180.0;
			const double c = std::cos(r), s = std::sin(r);
			const double dx = x - ax, dy = y - ay;
			x = ax + c * dx - s * dy;
			y = ay + s * dx + c * dy;
		};
		for (int k = 0; i >= 0 && k < i && k + 1 < (int)b.rot.size(); k++) {
			orbit(cx, cy, pctX(b.rot[k].ax), pctY(b.rot[k].ay), b.rot[k + 1].rot - b.rot[k].rot);
		}
		if (i >= 0 && i + 1 < (int)b.rot.size()) {
			orbit(cx, cy, pctX(b.rot[i].ax), pctY(b.rot[i].ay), rot - b.rot[i].rot);
		}
	}
	double mv[2];
	_mv_at(b.mv, t, mv);
	if (_blk_last(b.mv, t) >= 0) { // move 目标绝对位置 − 原始中心（保留锚点累计偏移）
		cx += pctX(mv[0]) - c0x;
		cy += pctY(mv[1]) - c0y;
	}
	b.ccx = cx;
	b.ccy = cy;
	b.hhx = std::fabs(bsx * scx) * 0.5;
	b.hhy = std::fabs(bsy * scy) * 0.5;
	b.rot_ccw = rot;
	// 图面系四角（y 上）→ 画布像素（y 下）
	const double r = rot * M_PI / 180.0;
	const double c = std::cos(r), s = std::sin(r);
	const double lx[4] = { -b.hhx, b.hhx, b.hhx, -b.hhx };
	const double ly[4] = { -b.hhy, -b.hhy, b.hhy, b.hhy };
	for (int k = 0; k < 4; k++) {
		const double wx = cx + c * lx[k] - s * ly[k];
		const double wy = cy + s * lx[k] + c * ly[k];
		b.qx[k] = (wx + 1.0) * W * 0.5;
		b.qy[k] = (1.0 - wy * aspect) * H * 0.5;
	}
}

// rpe-next 的变换求值：逐轴独立轨道 + 围绕锚点累计。照抄 noise-areas.mjs 的
// cumulativeTrack / relativeTransform / accumulate 三段：
//   prefix(当前键) = 对每个已完成键 j 依次乘 [ratio(tv1_j/tv0_j)]、[ratio(tv0_{j+1}/tv1_j)]
//                    （旋转则是角度差 tv1_j−tv0_j、tv0_{j+1}−tv1_j）；
//   当前键再乘一段 [从 tv0_i 到"此刻采样值"]。
// 缩放只动自己那一轴的 center（scaleX 只搬 cx、scaleY 只搬 cy），
// 旋转同时搬 cx/cy；move 是"采样值 − 基准中心"的绝对偏移，最后叠加。
void ChartPlayer::_block_geom_next(Block &b, double W, double H) const {
	const double aspect = W / std::max(H, 1.0);
	auto pctX = [](double p) { return 2.0 * p - 1.0; };
	auto pctY = [aspect](double p) { return (2.0 * p - 1.0) / aspect; };
	const double blx = pctX(b.blx), bly = pctY(b.bly);
	const double trx = pctX(b.trx), tr_y = pctY(b.tr_y);
	const double bsx = trx - blx, bsy = tr_y - bly;
	const double c0x = (blx + trx) * 0.5, c0y = (bly + tr_y) * 0.5;
	const double t = _now_music;
	const double scxv = _t1_at(b.scx, t, 1.0), scyv = _t1_at(b.scy, t, 1.0);
	const double rotv = _t1_at(b.rot1, t, 0.0);

	double cx = c0x, cy = c0y;
	auto orbit = [](double &x, double &y, double ax, double ay, double deg) {
		const double r = deg * M_PI / 180.0;
		const double c = std::cos(r), s = std::sin(r);
		const double dx = x - ax, dy = y - ay;
		x = ax + c * dx - s * dy;
		y = ay + s * dx + c * dy;
	};
	// 缩放：只搬自己那一根轴，锚点也只看那一根分量（rpe-next 的矩阵就是这么稀疏）
	auto scale_axis = [&](const std::vector<BlockSpan> &tr, double &out, double cur, bool is_x) {
		const int i = _span_last(tr, t);
		if (i < 0) return;
		auto anchor_of = [&](const BlockSpan &sp) { return is_x ? pctX(sp.ax) : pctY(sp.ay); };
		for (int k = 0; k < i; k++) {
			const double a = anchor_of(tr[k]);
			out = a + _blk_div(tr[k].tv1, tr[k].tv0) * (out - a);
			out = a + _blk_div(tr[k + 1].tv0, tr[k].tv1) * (out - a);
		}
		const double a = anchor_of(tr[i]);
		out = a + _blk_div(cur, tr[i].tv0) * (out - a);
	};
	scale_axis(b.scx, cx, scxv, true);
	scale_axis(b.scy, cy, scyv, false);
	{
		const int i = _span_last(b.rot1, t);
		if (i >= 0) {
			for (int k = 0; k < i; k++) {
				const double ax = pctX(b.rot1[k].ax), ay = pctY(b.rot1[k].ay);
				orbit(cx, cy, ax, ay, b.rot1[k].tv1 - b.rot1[k].tv0);
				orbit(cx, cy, ax, ay, b.rot1[k + 1].tv0 - b.rot1[k].tv1);
			}
			orbit(cx, cy, pctX(b.rot1[i].ax), pctY(b.rot1[i].ay), rotv - b.rot1[i].tv0);
		}
	}
	{
		const double bpx = (b.blx + b.trx) * 0.5, bpy = (b.bly + b.tr_y) * 0.5; // 百分比空间基准中心
		const double mx = _t1_at(b.mvx, t, bpx), my = _t1_at(b.mvy, t, bpy);
		if (_span_last(b.mvx, t) >= 0) cx += pctX(mx) - c0x;
		if (_span_last(b.mvy, t) >= 0) cy += pctY(my) - c0y;
	}

	b.ccx = cx;
	b.ccy = cy;
	b.hhx = std::fabs(bsx * scxv) * 0.5;
	b.hhy = std::fabs(bsy * scyv) * 0.5;
	b.rot_ccw = rotv;
	const double r = rotv * M_PI / 180.0;
	const double c = std::cos(r), s = std::sin(r);
	const double lx[4] = { -b.hhx, b.hhx, b.hhx, -b.hhx };
	const double ly[4] = { -b.hhy, -b.hhy, b.hhy, b.hhy };
	for (int k = 0; k < 4; k++) {
		const double wx = cx + c * lx[k] - s * ly[k];
		const double wy = cy + s * lx[k] + c * ly[k];
		b.qx[k] = (wx + 1.0) * W * 0.5;
		b.qy[k] = (1.0 - wy * aspect) * H * 0.5;
	}
}

void ChartPlayer::update_blocks(double music_sec) {
	_now_music = music_sec;
	if (_blk_sizes_dirty) _rpe_tex_sizes();
	for (auto &b : _blocks) {
		if (b.src_line >= 0) {
			// RPE 标记线：生命周期是**多段**的，本帧落在哪一段就用那段的四个时间
			// （prpr Marker::timings → BlockArea → Zone::from_area）。
			int si = -1;
			{
				int lo = 0, hi = (int)b.rpe_spans.size() - 1;
				while (lo <= hi) {
					const int mid = (lo + hi) >> 1;
					if (b.rpe_spans[mid].start <= music_sec) { si = mid; lo = mid + 1; }
					else hi = mid - 1;
				}
			}
			if (si < 0 || music_sec >= b.rpe_spans[si].end || b.rpe_spans[si].phase == 0) {
				b.phase = 0; b.ready = false; b.opacity = 0.0;
				continue;
			}
			const BSpan &sp = b.rpe_spans[si];
			b.appear = sp.t[0]; b.enable = sp.t[1]; b.disable = sp.t[2]; b.disappear = sp.t[3];
			int ph;
			if (music_sec < b.appear || music_sec >= b.disappear) ph = 0;
			else if (music_sec >= b.enable && music_sec < b.disable) ph = 2;
			else ph = 1;
			b.phase = ph;
			if (ph == 0) { b.ready = false; b.opacity = 0.0; continue; }
			b.ready = ph != 2 && music_sec < b.enable && music_sec >= b.enable - 0.5;
			// Zone::from_area：Line2Area **没有** Disabled 渐显（opacity 恒 1），
			// 只有官方案 blockAreaList 才走 disabledBlockShow 的 0.5s。
			b.opacity = 1.0;
			_rpe_block_geom(b, music_sec);
			continue;
		}
		int ph;
		if (music_sec < b.appear || music_sec >= b.disappear) ph = 0;
		else if (music_sec >= b.enable && music_sec < b.disable) ph = 2;
		else ph = 1;
		b.phase = ph;
		if (ph == 0) { // Hidden：Zone::from_area 直接返回 None，ready 也无意义
			b.ready = false;
			b.opacity = 0.0;
			continue;
		}
		b.ready = ph != 2 && music_sec < b.enable && music_sec >= b.enable - b.ready_lead;
		const bool fades_in = !(b.enable <= b.appear && b.appear < b.disable); // is_active(appearTime)
		b.opacity = (ph == 1 && fades_in) ? clampd((music_sec - b.appear) / 0.5, 0.0, 1.0) : 1.0;
		_block_geom(b, _cw, _ch);
	}
}

// ───────── RPE 噪域（贴图线标记）─────────
// 权威 = Phira-Pro 的 prpr `src/core/rpe_block.rs` + `core/chart.rs::rpe_marker_areas`。
// RPE 谱没有 blockAreaList，作者用的是**两条编辑器引导贴图线**：
//   Texture = isSubtract0.png → 普通框，isSubtract1.png → 减算框。
// 引导图本身**不画**（line.rs:318-323：画出来会把编码用的贴图盖在噪域上），
// 它的几何（位置/缩放/旋转/锚点）就是噪域矩形，它的 colorEvents 就是逐区颜色，
// 它的 speed 事件（1=appear 2=enable 3=disable 4=disappear）就是生命周期。

int ChartPlayer::_marker_kind(const String &tex) {
	String name = tex;
	for (int i = name.length() - 1; i >= 0; i--) {
		const char32_t ch = name[i];
		if (ch == '/' || ch == '\\') { name = name.substr(i + 1); break; }
	}
	if (!name.to_lower().ends_with(".png")) return -1;
	// 只按文件名精确比（prpr marker_kind：isSubtract1.png.backup 不算）
	if (name.to_lower() == "issubtract0.png") return 0;
	if (name.to_lower() == "issubtract1.png") return 1;
	return -1;
}

double ChartPlayer::_rpe_alpha_at(const Line &l, double t) const {
	// prpr 的 alpha 链 = 各层**求和**（Anim::now_opt 的 T::add），空层贡献 0。
	// 这里用二分游标（探针/seek 会乱序），不走 live 的单调游标缓存。
	double a = 0;
	for (const Layer &L : l.layers) {
		if (L.alpha.empty()) continue;
		a += _event_value(L.alpha[_ev_cursor(L.alpha, t)], t);
	}
	return a;
}

void ChartPlayer::_rpe_spans_speed(Block &b, const Line &l) const {
	// 新协议（Recorder）：只读 speed 事件的 **start 值**当状态码，1..4；其它值忽略。
	std::vector<std::pair<double, double>> evs;
	for (const Layer &L : l.layers) {
		for (const Event &e : L.speed) {
			const double c = e.v0;
			if (c != c) continue; // NaN
			if (c < 0.5 || c > 4.5) continue;
			const int ic = (int)std::lround(c);
			if (ic < 1 || ic > 4 || std::fabs(c - ic) > 1e-6) continue;
			evs.push_back({e.s, (double)ic});
		}
	}
	if (evs.empty()) return;
	std::stable_sort(evs.begin(), evs.end(),
			[](const std::pair<double, double> &x, const std::pair<double, double> &y) { return x.first < y.first; });
	const double INF = 1e300;
	std::vector<BSpan> spans;
	double tm[4] = {INF, INF, INF, INF};
	int previous = 0;
	size_t first = 0;
	// prpr set_lifecycle 的 finish：闭段时把 disappear 设为段尾，再给段内每段补同一组时间
	auto finish = [&](double end) {
		tm[3] = end;
		for (size_t k = first; k < spans.size(); k++) {
			if (spans[k].end > end) spans[k].end = end;
			for (int j = 0; j < 4; j++) spans[k].t[j] = tm[j];
		}
		for (int j = 0; j < 4; j++) tm[j] = INF;
	};
	for (const auto &pr : evs) {
		const double time = pr.first;
		const int code = (int)pr.second;
		// 状态码往回走（且当前还在一个生命周期里）= 作者重开了一轮
		if (code <= previous && tm[0] != INF) { finish(time); first = spans.size(); }
		if (!spans.empty() && spans.back().end > time) spans.back().end = time;
		if (code == 4) {
			finish(time);
			first = spans.size();
		} else {
			if (time < tm[0]) tm[0] = time;
			tm[code - 1] = time;
			BSpan sp;
			sp.start = time;
			sp.end = INF;
			sp.phase = code == 2 ? 2 : 1; // 只有 enable 段是 Active，其余显示段是 Disabled
			spans.push_back(sp);
		}
		previous = code;
	}
	finish(INF);
	b.rpe_spans = std::move(spans);
}

void ChartPlayer::_rpe_spans_alpha(Block &b, const Line &l) const {
	// 旧协议：alpha 轨道当状态码。phira-Pro 用**原始值** 0 / 128/255 / 255/255 三档
	// （示例谱用 121/127/128 当预警、255 当激活——它们是状态码不是填充透明度）。
	// 本引擎的 alpha 是 0..255 原始和，所以门限就是 0 与 128。
	auto ph = [](double a) {
		if (!(a > 0.0)) return 0;      // 含 NaN
		return a <= 128.0 ? 1 : 2;
	};
	std::vector<double> knots;
	knots.push_back(0.0);
	for (const Layer &L : l.layers)
		for (const Event &e : L.alpha) {
			if (e.s == e.s) knots.push_back(e.s);
			if (e.t == e.t) knots.push_back(e.t);
		}
	std::sort(knots.begin(), knots.end());
	knots.erase(std::unique(knots.begin(), knots.end()), knots.end());
	std::vector<double> bounds = knots;
	// 缓动**中途**的越阈点也要找到：只在关键帧上取样会把 0→255 的斜坡整个算成 Hidden。
	// prpr 用 40 次二分定位 (left>th)!=(right>th) 的那个跳变位置。
	for (size_t k = 0; k + 1 < knots.size(); k++) {
		const double a = knots[k], bb = knots[k + 1];
		const double before_b = bb - std::min((bb - a) * 1e-8, 1e-8);
		const double left = _rpe_alpha_at(l, a), right = _rpe_alpha_at(l, before_b);
		for (const double th : {0.0, 128.0}) {
			if (((left > th) != (right > th))) {
				double lo = a, hi = before_b;
				for (int it = 0; it < 40; it++) {
					const double mid = (lo + hi) * 0.5;
					if ((_rpe_alpha_at(l, mid) > th) == (left > th)) lo = mid;
					else hi = mid;
				}
				bounds.push_back(hi);
			}
		}
	}
	std::sort(bounds.begin(), bounds.end());
	bounds.erase(std::unique(bounds.begin(), bounds.end()), bounds.end());
	for (size_t k = 0; k < bounds.size(); k++) {
		const double start = bounds[k];
		const double end = k + 1 < bounds.size() ? bounds[k + 1] : 1e300;
		// 末段（end=∞）不能按 prpr 那样直接取 sample(start)：本引擎的事件游标是
		// **严格大于**才吃新值（_ev_cursor：tsec > e.s），在端点上取到的还是前一个值，
		// 于是"最后一个 alpha 事件把噪域关掉"这条会被算成仍然显示。末段落在常数区，
		// 往右挪一点取样即可。
		const double probe = end > 1e299 ? start + 0.01 : (start + end) * 0.5;
		const int state = ph(_rpe_alpha_at(l, probe));
		if (!b.rpe_spans.empty() && b.rpe_spans.back().phase == state) b.rpe_spans.back().end = end;
		else {
			BSpan sp;
			sp.start = start;
			sp.end = end;
			sp.phase = state;
			b.rpe_spans.push_back(sp);
		}
	}
	// 每段补四个时间：一段"非 Hidden"的连续区间共享一组 appear/disappear
	const double INF = 1e300;
	size_t first = 0;
	while (first < b.rpe_spans.size()) {
		if (b.rpe_spans[first].phase == 0) { first++; continue; }
		size_t end = b.rpe_spans.size();
		for (size_t k = first; k < b.rpe_spans.size(); k++)
			if (b.rpe_spans[k].phase == 0) { end = k; break; }
		const double appear = b.rpe_spans[first].start;
		const double disappear = end < b.rpe_spans.size() ? b.rpe_spans[end].start : INF;
		double enable = INF;
		for (size_t k = end; k-- > first;) {
			if (b.rpe_spans[k].phase == 2) enable = b.rpe_spans[k].start;
			const double disable = b.rpe_spans[k].phase == 2 ? b.rpe_spans[k].end : INF;
			b.rpe_spans[k].t[0] = appear;
			b.rpe_spans[k].t[1] = enable;
			b.rpe_spans[k].t[2] = disable;
			b.rpe_spans[k].t[3] = disappear;
		}
		bool was_active = false;
		for (size_t k = first; k < end; k++) {
			if (was_active) b.rpe_spans[k].t[0] = std::min(appear, b.rpe_spans[k].start - 0.5);
			was_active = was_active || b.rpe_spans[k].phase == 2;
		}
		first = end;
	}
}

void ChartPlayer::_rpe_markers() {
	// 不清 _blocks：里面可能已经有内嵌的官方式 blockAreaList（prpr 把两类区分开存，
	// 合成/触点都是 official 在前、marker 在后）
	std::vector<Block> marks;
	for (int i = 0; i < (int)_lines.size(); i++) {
		const Line &l = _lines[i];
		if (!l.block_marker) continue;
		Block b;
		b.src_line = i;
		b.sub = _marker_kind(l.texture) == 1;
		// Line::ax/ay 存的是 Phaser origin（y 已翻转），噪域要的是 RPE 原始 anchor
		b.anx = l.ax;
		b.any_ = 1.0 - l.ay;
		_rpe_spans_speed(b, l);
		if (b.rpe_spans.empty()) _rpe_spans_alpha(b, l);
		bool any_show = false;
		for (const auto &s : b.rpe_spans)
			if (s.phase != 0) { any_show = true; break; }
		if (!any_show) continue; // 全程 Hidden：prpr 也会保留这条 marker，但没有一帧有面积
		marks.push_back(std::move(b));
	}
	// 合成序 = prpr 的 sort_by_key(z_index, line)：zIndex 小→大，同值按谱面行序
	std::stable_sort(marks.begin(), marks.end(), [&](const Block &x, const Block &y) {
		if (_lines[x.src_line].zorder != _lines[y.src_line].zorder)
			return _lines[x.src_line].zorder < _lines[y.src_line].zorder;
		return x.src_line < y.src_line;
	});
	_blocks.insert(_blocks.end(), std::make_move_iterator(marks.begin()),
			std::make_move_iterator(marks.end()));
	_blk_sizes_dirty = true;
}

void ChartPlayer::_rpe_tex_sizes() {
	_blk_sizes_dirty = false;
	for (auto &b : _blocks) {
		if (b.src_line < 0) continue;
		Ref<Texture2D> t = _line_texs.get(_lines[b.src_line].texture, Ref<Texture2D>());
		if (t.is_valid() && t->get_width() > 0 && t->get_height() > 0) {
			b.pw = t->get_width();
			b.ph = t->get_height();
		}
	}
}

void ChartPlayer::_rpe_block_geom(Block &b, double music_sec) const {
	(void)music_sec; // 线状态（ox/oy/rot_deg/esx/esy/tr/tg/tb）已由 set_now 的 _update_line 按 tsec 算好
	if (b.src_line < 0 || b.src_line >= (int)_lines.size()) return;
	const double aspect = _cw / std::max(_ch, 1.0);
	const double ys = 1.5 / aspect; // BlockTransform::y_scale（rpe_canvas=true）
	// ── canvas-first 父链（prpr Chart::rpe_canvas_position + JudgeLine::fetch_rot）──
	// 先在各向同性的 1350×900 创作画布单位里累加平移并转父线角度，**最后**才纵向拉伸。
	// 直接用 l.wx/wy 会先把子线偏移拉伸（_kx≠_ky）再转父线的旋转 —— 旋转父链上错位。
	std::vector<int> chain;
	int cur = b.src_line;
	for (int g = 0; g < 128; g++) {
		chain.push_back(cur);
		const int f = _lines[cur].father;
		if (f < 0 || f >= (int)_lines.size() || f == cur) break;
		cur = f;
	}
	double cx = 0, cy = 0, crot = 0; // 画布系位置（1/675 设计像素，y 上）+ CCW 弧度
	for (int k = (int)chain.size() - 1; k >= 0; k--) {
		const Line &lk = _lines[chain[k]];
		const double ox = lk.ox / 675.0, oy = lk.oy / 675.0;
		const double c = std::cos(crot), s = std::sin(crot);
		const double nx = cx + c * ox - s * oy;
		const double ny = cy + s * ox + c * oy;
		// RPE 的 rotate 是"y 向下顺时针正"，画布系是 y 向上逆时针正 ⇒ 取负
		crot = (lk.rwith ? crot : 0.0) - lk.rot_deg * M_PI / 180.0;
		cx = nx;
		cy = ny;
	}
	// 画布 → 图面：y 按视口拉伸（x 恒 ±1，y 恒 ±1/aspect）
	const double px = cx, py = cy * ys;
	// ── Marker::transform ──
	const Line &l = _lines[b.src_line];
	const double ssx = b.pw * l.esx / 675.0, ssy = b.ph * l.esy / 675.0; // signed_size
	const double lcx = (0.5 - b.anx) * ssx, lcy = (0.5 - b.any_) * ssy;  // local_center
	const double rad = crot;
	const double c = std::cos(rad), s = std::sin(rad);
	b.ccx = px + c * lcx - s * lcy;
	b.ccy = py + (s * lcx + c * lcy) * ys;
	b.hhx = std::fabs(ssx) * 0.5;
	b.hhy = std::fabs(ssy) * 0.5;
	b.ys = ys;
	b.rot_ccw = rad * 180.0 / M_PI;
	// 逐区颜色（Marker::color_at：线 colorEvents，无事件=DEFAULT_BLOCK_COLOR）
	if (l.ext_color.empty()) { b.cr = 1.0; b.cg = 84.0 / 255.0; b.cb = 84.0 / 255.0; }
	else { b.cr = l.tr; b.cg = l.tg; b.cb = l.tb; }
	// 四角 → 画布像素（与 _block_geom 同一套 field→px 映射，但旋转**先于**纵向拉伸）
	const double rx[4] = { -b.hhx, b.hhx, b.hhx, -b.hhx };
	const double ry[4] = { -b.hhy, -b.hhy, b.hhy, b.hhy };
	for (int k = 0; k < 4; k++) {
		const double wx = b.ccx + c * rx[k] - s * ry[k];
		const double wy = b.ccy + (s * rx[k] + c * ry[k]) * ys;
		b.qx[k] = (wx + 1.0) * _cw * 0.5;
		b.qy[k] = (1.0 - wy * aspect) * _ch * 0.5;
	}
}

bool ChartPlayer::_block_contains(const Block &b, double px, double py, double inset_world) {
	// 图面系点 → 框局部单位系（|x|,|y| ≤ 0.5 即在框内）。
	// prpr BlockArea::contains 走 matrix_of(...).try_inverse()：
	// 矩阵 = T(center)·S(1,y_scale)·R(θ)·S(size)，所以逆变换要**先**除 y_scale 再转回去。
	const double dx = px - b.ccx, dy = (py - b.ccy) / b.ys;
	const double r = -b.rot_ccw * M_PI / 180.0;
	const double c = std::cos(r), s = std::sin(r);
	const double rx = dx * c - dy * s, ry = dx * s + dy * c;
	const double sx = b.hhx * 2.0, sy = b.hhy * 2.0; // 官方 inset_local 用的是整尺寸
	// JudgeControl.maxBlockTouchInsetLocal=0.05、blockTouchInsetScreenHeightRatio=0.25 上限
	auto inset_local = [](double size, double ins) {
		return std::fabs(size) < 1e-6 ? 0.25 : clampd(std::fabs(ins / size), 0.0, 0.25);
	};
	const double wr = b.rot_ccw * M_PI / 180.0;
	const double wc = std::cos(wr), ws = std::sin(wr);
	// prpr: inset_local(tr.size.x * c.hypot(s * tr.y_scale), inset) —— 局部轴向世界投影长度
	const double ix = sx * std::hypot(wc, ws * b.ys);
	const double iy = sy * std::hypot(ws, wc * b.ys);
	const double sign = b.sub ? 1.0 : -1.0; // 普通框缩小、减算框放大
	const double hx = 0.5 + sign * inset_local(ix, inset_world);
	const double hy = 0.5 + sign * inset_local(iy, inset_world);
	if (b.hhx <= 1e-9 || b.hhy <= 1e-9) return false;
	return std::fabs(rx) / b.hhx <= hx * 2.0 && std::fabs(ry) / b.hhy <= hy * 2.0;
}

bool ChartPlayer::block_hit(Vector2 pos) {
	if (_blocks.empty()) return false;
	const double aspect = _cw / std::max(_ch, 1.0);
	// 像素 → 图面系必须是 _block_geom 正向映射的**严格逆**：
	//   qx = (wx+1)·W/2  ⇒  wx = 2·qx/W − 1
	//   qy = (1 − wy·aspect)·H/2  ⇒  wy = (1 − 2·qy/H)/aspect   ← 这个 2 以前漏了
	// 漏掉它等于把整屏高度映射成"图面上半截"（y=屏底被算成 y=0），于是可见噪域框
	// 与"按下会不会被感染"的区域上下错开一大截——用户报的「噪域判定区域不对」就是这条。
	const double x = (pos.x / _cw) * 2.0 - 1.0;
	const double y = (1.0 - 2.0 * pos.y / _ch) / aspect;
	const double inset = 0.05 * 2.0 / aspect; // touch_inset_world（屏高=2/aspect 图面单位）
	bool orig_non = false, ins_non = false;
	int orig_sub = 0, ins_sub = 0;
	for (const auto &b : _blocks) {
		if (b.phase != 2) continue; // 只 Active 拦触点
		if (_block_contains(b, x, y, 0.0)) {
			if (b.sub) orig_sub++;
			else orig_non = true;
		}
		if (_block_contains(b, x, y, inset)) {
			if (b.sub) ins_sub++;
			else ins_non = true;
		}
	}
	// 官方 TryGetBlockingBlock：normal XOR (subtract 奇偶)，整框与内缩框都成立才阻塞
	return (orig_non != (bool)(orig_sub & 1)) && (ins_non != (bool)(ins_sub & 1));
}

Array ChartPlayer::get_block_quads() {
	Array out;
	for (const auto &b : _blocks) {
		if (b.opacity <= 0.0 || b.phase == 0) continue;
		Dictionary d;
		d["sub"] = b.sub;
		d["alpha"] = b.opacity;
		d["phase"] = b.phase;
		d["ready"] = b.ready;
		// Line2Area 的矩形是"画布内旋转 → 再按视口纵向拉伸"，官方案没有这一步
		d["ys"] = b.ys;
		d["color"] = Vector3((real_t)b.cr, (real_t)b.cg, (real_t)b.cb);
		Array p;
		for (int i = 0; i < 4; i++) p.push_back(Vector2((real_t)b.qx[i], (real_t)b.qy[i]));
		d["p"] = p;
		out.push_back(d);
	}
	return out;
}

Array ChartPlayer::debug_blocks(double music_sec) {
	update_blocks(music_sec);
	Array out;
	for (size_t i = 0; i < _blocks.size(); i++) {
		const Block &b = _blocks[i];
		Dictionary d;
		d["i"] = (int)i;
		d["sub"] = b.sub;
		d["tr"] = Vector2((real_t)b.trx, (real_t)b.tr_y);
		d["bl"] = Vector2((real_t)b.blx, (real_t)b.bly);
		d["appear"] = b.appear;
		d["enable"] = b.enable;
		d["disable"] = b.disable;
		d["disappear"] = b.disappear;
		d["phase"] = b.phase;
		d["ready"] = b.ready;
		d["alpha"] = b.opacity;
		d["center"] = Vector2((real_t)b.ccx, (real_t)b.ccy);
		d["half"] = Vector2((real_t)b.hhx, (real_t)b.hhy);
		d["rot"] = b.rot_ccw;
		d["ys"] = b.ys;
		d["rpe"] = b.src_line;
	d["area"] = b.nx_area;
		d["color"] = Vector3((real_t)b.cr, (real_t)b.cg, (real_t)b.cb);
		Array p;
		for (int k = 0; k < 4; k++) p.push_back(Vector2((real_t)b.qx[k], (real_t)b.qy[k]));
		d["quad"] = p;
		out.push_back(d);
	}
	return out;
}

void ChartPlayer::_finalize() {
	_hold_span_max = 0;
	// 同拍多押标记（PhiTogether timeOfMulti：同 realTime 计数≥2 → HL 皮肤）。
	// 假音符同样参与分组与染色：装饰串和真音符同拍时一起用多押贴图。
	{
		std::vector<double> ts;
		ts.reserve(_total_notes > 0 ? (size_t)_total_notes : 64);
		for (auto &l : _lines)
			for (auto &n : l.notes) ts.push_back(std::round(n.t * 1e6) / 1e6);
		std::sort(ts.begin(), ts.end());
		for (auto &l : _lines)
			for (auto &n : l.notes) {
				double key = std::round(n.t * 1e6) / 1e6;
				auto r = std::equal_range(ts.begin(), ts.end(), key);
				n.multi = (r.second - r.first) >= 2;
			}
	}
	// 音符目标高度 = 各自时刻的 speed 积分
	for (auto &l : _lines) {
		l.cur_ev.assign(l.layers.size() * 4, 0);
		for (auto &L : l.layers)
			for (auto &e : L.speed) _prep_speed(e);
		l.n_lo = 1e18; l.n_hi = -1e18;
		l.h_spd_min = 1e18; l.h_yoff_abs = 0; l.h_delta_max = 0; l.has_static = false;
		for (auto &n : l.notes) {
			const double bt = l.bpmf == 1.0 ? n.t : n.t / l.bpmf; // 高度积分在事件时间域（t/bpmf）
			n.hT = n.has_fp ? n.fp : _height_at(l, bt);
			// 尾端 = 头端 + [t, t2] 的增量。以头端为基准累加，保证即便某张谱的
			// json.floorPosition 与积分不一致，hold 的头尾也自洽（不会分家）。
			// official 的 hold 走 rigid 偏移（见 load_official 注释）：身体长与线的
			// speed 曲线无关，所以这里不能再积分 ∫v dt。
			const double bt2 = l.bpmf == 1.0 ? n.t2 : n.t2 / l.bpmf;
			n.hT2 = n.rigid_tail ? n.hT + n.hold_off
					: (n.has_fp ? n.fp + (_height_at(l, bt2) - _height_at(l, bt))
								: _height_at(l, bt2));
			// 可见窗=谱面语义（visibleTime/负 alpha 编码），绝不可按“滑屏时长”
			// 收紧——bad apple 剪影整幅由提前可见的 hold 构成，收紧=黑屏（用户实证）。
			n.vis_lo = (float)(n.t - n.vtime);
			l.n_lo = std::min(l.n_lo, (double)n.vis_lo);
			l.n_hi = std::max(l.n_hi, n.t2 + 1.0);
			l.h_spd_min = std::min(l.h_spd_min, n.speed > 0 ? (double)n.speed : 1e18);
			if (n.speed <= 0.0) l.has_static = true; // rpe-next staticNotes：dist 恒为 0，hT 窗管不到
			l.h_yoff_abs = std::max(l.h_yoff_abs, (double)std::fabs(n.yoff));
			l.h_delta_max = std::max(l.h_delta_max, n.hT2 - n.hT);
			l.hold_span = std::max(l.hold_span, n.t2 - n.t);
		}
		// hT 随 t 单调 ⇒ notes（已按 t 升序）同时按 hT 升序，才能对 hT 二分。
		l.h_mono = !l.notes.empty() && l.h_spd_min < 1e17;
		l.t_mono = !l.notes.empty();
		for (size_t i = 1; i < l.notes.size(); i++) {
			if (l.notes[i].hT < l.notes[i - 1].hT - 1e-9) l.h_mono = false;
			if (l.notes[i].t < l.notes[i - 1].t - 1e-9) l.t_mono = false;
		}
		l.am_cur = 0;
		if (l.h_mono && l.h_delta_max < 0) l.h_delta_max = 0;
		if (!l.notes.empty() && l.h_spd_min >= 1e17) l.h_spd_min = 1;
		_hold_span_max = std::max(_hold_span_max, l.hold_span);
		if (l.notes.size() > 100000) UtilityFunctions::print("WIN notes=", (int)l.notes.size(),
				" spd_min=", l.h_spd_min, " yoff_abs=", l.h_yoff_abs, " delta_max=", l.h_delta_max,
				 " hold_span=", l.hold_span, " mono=", (int)l.h_mono, " tmono=", (int)l.t_mono);
	}
	// 深度桶先算好：nord 的计数排序要用它当下标表（原来在这之后的块里算）。
	//  线 = zIndex ?? 2 + precedence（calculatePrecedences：唯一 zOrder 升序 rank/len）
	//  音符容器 = zIndex ?? 优先级+2；命中特效容器 = zIndexHitEffects ?? 7
	_note_depths.clear();
	for (auto &l : _lines)
		for (auto &nn : l.notes)
			if (std::find(_note_depths.begin(), _note_depths.end(), _note_depth(nn)) == _note_depths.end())
				_note_depths.push_back(_note_depth(nn));
	std::sort(_note_depths.begin(), _note_depths.end());
	// 绘制序：player zIndex = data.zIndex ?? NOTE_PRIORITIES[type]+2（[0,3,1,4,2]），
	// 线内稳定排序（tie 保持文件序，与 Phaser 渲染列表一致）。
	// 深度值只有屈指可数的几种 ⇒ 用计数排序而不是 stable_sort：后者在 1093 万条上
	// 要按比较器随机访问 2.8GB 的音符表（实测 2.2 秒），计数排序是两趟线性扫。
	// 桶内按 i 升序填 ⇒ 与 stable_sort 逐元素等价。
	{
		const int D = (int)_note_depths.size();
		std::vector<int> off, cur;
		off.resize((size_t)D + 2);
		for (auto &l : _lines) {
			l.nord.resize(l.notes.size());
			l.nrank.resize(l.notes.size());
			if (D == 0 || l.notes.empty()) continue;
			std::fill(off.begin(), off.end(), 0);
			for (auto &n : l.notes) {
				int d = (int)(std::lower_bound(_note_depths.begin(), _note_depths.end(), _note_depth(n))
						- _note_depths.begin());
				off[d + 1]++;
			}
			for (int d = 1; d <= D; d++) off[d] += off[d - 1];
			cur = off;
			for (size_t i = 0; i < l.notes.size(); i++) {
				int d = (int)(std::lower_bound(_note_depths.begin(), _note_depths.end(),
						_note_depth(l.notes[i])) - _note_depths.begin());
				l.nord[cur[d]++] = (int)i;
			}
			// nrank = nord 的逆置换：二分出的候选（t 序）按它排序即还原绘制序
			for (size_t i = 0; i < l.nord.size(); i++) l.nrank[l.nord[i]] = (int)i;
		}
	}
	// 判定管线全局时间序表（非 fake 音符；匹配/控制激活的二分窗口用）
	_notes_by_time.clear();
	_notes_by_time.reserve(_total_notes > 0 ? (size_t)_total_notes : 64);
	for (size_t i = 0; i < _lines.size(); i++)
		for (size_t j = 0; j < _lines[i].notes.size(); j++) {
			const Note &n = _lines[i].notes[j];
			if (n.fake) continue;
			_notes_by_time.push_back({ (int)i, (int)j, n.t });
		}
	std::stable_sort(_notes_by_time.begin(), _notes_by_time.end(),
			[](const NT &a, const NT &b) { return a.t < b.t; });
	_jreset();
	// 深度桶（targetRange 路由，player 语义）：
	//  线 = zIndex ?? 2 + precedence（calculatePrecedences：唯一 zOrder 升序 rank/len）
	//  音符容器 = zIndex ?? 优先级+2；命中特效容器 = zIndexHitEffects ?? 7
	{
		std::vector<int> uz;
		for (auto &l : _lines)
			if (std::find(uz.begin(), uz.end(), l.zorder) == uz.end()) uz.push_back(l.zorder);
		std::sort(uz.begin(), uz.end());
		double n = std::max<size_t>(1, uz.size());
		for (auto &l : _lines) {
			if (l.zidx >= 0) l.depth = l.zidx;
			else l.depth = 2.0 + double(std::find(uz.begin(), uz.end(), l.zorder) - uz.begin()) / n;
		}
		// _note_depths 已在 nord 之前算好（计数排序要用它），这里只补特效桶
		_fx_depths.clear();
		for (auto &l : _lines)
			for (auto &nn : l.notes)
				if (std::find(_fx_depths.begin(), _fx_depths.end(), nn.zfx) == _fx_depths.end())
					_fx_depths.push_back(nn.zfx);
		std::sort(_fx_depths.begin(), _fx_depths.end());
	}
	// 线绘制序缓存（zorder 静态，_draw 每帧直接用，避免 vector 分配 + 排序）
	_draw_order.resize(_lines.size());
	for (size_t i = 0; i < _draw_order.size(); i++) _draw_order[i] = (int)i;
	std::stable_sort(_draw_order.begin(), _draw_order.end(), [&](int a, int b) {
		return _lines[a].zorder < _lines[b].zorder;
	});
	_loaded = true;
	UtilityFunctions::print("chart loaded: lines=", _lines.size(), " notes=", _total_notes,
			" dur=", _duration);
}

void ChartPlayer::_parse_ext(const Dictionary &ext, const char *key, std::vector<Event> &out) {
	Array arr = ext.get(key, Array());
	for (int i = 0; i < (int)arr.size(); i++) {
		Dictionary e = arr[i];
		Event ev;
		double sb = _beat_of(e.get("startTime", 0.0));
		double eb = _beat_of(e.has("endTime") ? e["endTime"] : e.get("startTime", 0.0));
		ev.s = _b2s(sb);
		ev.t = _b2s(std::max(sb, eb));
		Variant sv = e.get("start", 0.0);
		ev.color = sv.get_type() == Variant::ARRAY;
		if (ev.color) {
			_to_rgb(sv, ev.rgb0);
			_to_rgb(e.get("end", sv), ev.rgb1);
			ev.v0 = 0;
			ev.v1 = 1;
		} else {
			ev.v0 = _to_num(sv);
			ev.v1 = _to_num(e.get("end", sv));
		}
		ev.ease = (int)_to_num(e.get("easingType", 1));
		ev.el = _to_num(e.get("easingLeft", 0.0));
		ev.er = _to_num(e.get("easingRight", 1.0));
		out.push_back(ev);
	}
	std::sort(out.begin(), out.end(), [](const Event &a, const Event &b) { return a.s < b.s; });
}

void ChartPlayer::_parse_ctrl(const Dictionary &jd, const char *key, std::vector<Ctrl> &out) {
	double defv = 1.0;
	const char *vkey = "pos";
	if (!strcmp(key, "alphaControl")) { defv = 255; vkey = "alpha"; }
	else if (!strcmp(key, "sizeControl")) vkey = "size";
	else if (!strcmp(key, "skewControl")) { defv = 0; vkey = "skew"; }
	else if (!strcmp(key, "yControl")) vkey = "y";
	Array arr = jd.get(key, Array());
	for (int i = 0; i < (int)arr.size(); i++) {
		Dictionary c = arr[i];
		Ctrl n;
		n.x = _to_num(c.get("x", 0.0));
		n.v = _to_num(c.get(vkey, defv));
		n.ease = (int)_to_num(c.get("easing", 0));
		out.push_back(n);
	}
	std::sort(out.begin(), out.end(), [](const Ctrl &a, const Ctrl &b) { return a.x > b.x; });
	if (out.empty()) { // player parse 注入默认节点
		out.push_back({ 9999999, defv, 0 });
		out.push_back({ 0, defv, 0 });
	}
}

// ───────── 每帧 ─────────

// 窗口设置（ms）→ 秒 + 派生 B/F。clamp 照 player Preferences.svelte：
// P∈[5,150]、G∈[max(P+5,1.125P),300]（设置页还会再纠一次，这里防越界值直达判定）。
void ChartPlayer::set_judgment_windows(double p_ms, double g_ms) {
	_jp = clampd(p_ms, 5.0, 150.0) / 1000.0;
	double gmin = std::max(_jp * 1000.0 + 5.0, _jp * 1000.0 * 1.125);
	_jg = clampd(g_ms, gmin, 300.0) / 1000.0;
	_jb = _jg + jd::B_EXTRA;
	_jf = jd::FLICK_F * _jp;
}

Dictionary ChartPlayer::get_judgment_windows() const {
	Dictionary d;
	d["p"] = _jp * 1000.0;
	d["g"] = _jg * 1000.0;
	d["b"] = _jb * 1000.0;
	d["f"] = _jf * 1000.0;
	return d;
}

// 判定偏差读数（player StatisticsHandler.updateStats：mathjs std(...,'uncorrected')
// = 总体标准差 ⇒ 除以 n；且 deltas.length>1 才算，否则 0）
double ChartPlayer::get_avg_delta_ms() const {
	if (_jdeltas.empty()) return 0.0;
	double s = 0;
	for (double v : _jdeltas) s += v;
	return s / (double)_jdeltas.size() * 1000.0;
}

double ChartPlayer::get_std_dev_ms() const {
	if (_jdeltas.size() < 2) return 0.0;
	double m = 0;
	for (double v : _jdeltas) m += v;
	m /= (double)_jdeltas.size();
	double acc = 0;
	for (double v : _jdeltas) { double d = v - m; acc += d * d; }
	return std::sqrt(acc / (double)_jdeltas.size()) * 1000.0;
}

void ChartPlayer::reset_play_state() {
	_perfect = _good = _bad = _miss = _combo = _max_combo = 0;
	_good_early = _good_late = 0;
	_hitq.clear();
	_fx.clear();
	_jdeltas.clear();
	_pending_clicks.clear();
	_controls.clear();
	_ctl_cur = 0;
	_prev_now = -1e18;
	for (int i = 0; i < 16; i++) _fingers[i] = Finger();
	for (auto &l : _lines) l.am_cur = 0;
	for (auto &l : _lines) {
		for (auto &n : l.notes) {
			n.state = 0;
			n.finger = -1;
			n.jt = 0;
			n.fx_last = 0;
			n.click_matched = false;
			n.drag_marked = false;
			n.flick_matched = false;
			n.temp_state = 0;
			n.safe_frames = 0;
			n.hold_head = false;
			n.hold_missed = false;
			n.hold_over = false;
		}
	}
	queue_redraw();
}

void ChartPlayer::set_now(double sec) {
	if (_src) { queue_redraw(); return; } // 幽灵实例：状态实时读主实例，只需重画
	if (!_loaded) return;
	const double _pt = _prof_us();
	double now = sec - _offset - _user_offset; // player: timeSec = realTime − offset/1000
	_now = now;
	// bad apple（3.4 万线）实测：逐线 _b2s(_s2b(now)) 的重复二分+除法是 set_now 固定
	// 开销大头。bpmf=1（绝大多数谱）时全线共用同一 tsec，算一次即可。
	const double tsec0 = _b2s(_s2b(now));
	for (auto &l : _lines) {
		// bpmfactor：事件时间 = getTimeSec(beat / bpmfactor)
		double tsec = l.bpmf == 1.0 ? tsec0 : _b2s(_s2b(now) / l.bpmf);
		_update_line(l, tsec);
		l.esx = _ext_value(l.ext_sx, tsec, 1);
		l.esy = _ext_value(l.ext_sy, tsec, 1);
		l.einc = _ext_value(l.ext_incline, tsec, 0);
		double rgb[3] = { 255, 255, 255 };
		if (!l.ext_color.empty()) {
			int cur = 0;
			while (cur + 1 < (int)l.ext_color.size() && tsec >= l.ext_color[cur + 1].s) cur++;
			_event_color(l.ext_color[cur], tsec, rgb);
		}
		l.tr = rgb[0] / 255.0;
		l.tg = rgb[1] / 255.0;
		l.tb = rgb[2] / 255.0;
	}
	// 噪域时间轴 = 音乐秒原值（原版直接比 ProgressControl.nowTime，不减 offset）。
	// 必须排在 _update_line 之后：RPE 标记线的几何/颜色就是从线的当帧事件状态推的
	// （prpr 同一件事：Chart::update 先跑 object.set_time，再 update_marker_areas）。
	update_blocks(sec);
	_infect_fingers(); // 官方是每帧过滤触点表，不是只在按下时判一次
	// 父链合成（屏幕像素系；位置恒继承，旋转仅 rotateWithFather）。
	// player Line.update 先递归更新父线（this._parent?.update）——父线索引可以比孩子大
	// （ic: line0/4/5/6/7 的 father=24），必须按依赖解析，不能按索引序（旧 f<i 守卫=丢链 bug）
	// 帧间复用同一块缓冲（原来每帧 new 一次：160 线=160B memset + 分配，4000 线=4KB，
	// 而且这条链在 set_now 的关键路径上）。size 不同就 resize（会清零），相同就手动清零。
	if (_pc_done.size() != _lines.size()) {
		_pc_done.resize(_lines.size(), 0);
	} else {
		std::fill(_pc_done.begin(), _pc_done.end(), 0);
	}
	std::vector<unsigned char> &done = _pc_done;
	for (size_t i = 0; i < _lines.size(); i++) {
		if (done[i]) continue;
		_pc_chain.clear();
		std::vector<size_t> &chain = _pc_chain;
		size_t k = i;
		while (true) {
			Line &lk = _lines[k];
			int f = lk.father;
			if (done[k] || f < 0 || f >= (int)_lines.size() || f == (int)k || chain.size() > 64) break;
			chain.push_back(k);
			k = (size_t)f;
		}
		if (!done[k]) { // 根（或环兜底）：直接落位
			Line &l0 = _lines[k];
			l0.wx = _cx + l0.ox * _kx;
			l0.wy = _cy - l0.oy * _ky;
			l0.wrot = l0.rot_deg * M_PI / 180.0;
			done[k] = 1;
		}
		for (size_t r = chain.size(); r-- > 0;) {
			Line &l = _lines[chain[r]];
			int f = l.father;
			double lx = l.ox * _kx, ly = -l.oy * _ky;
			double lr = l.rot_deg * M_PI / 180.0;
			if (f >= 0 && f < (int)_lines.size()) {
				const Line &p = _lines[f];
				double c = std::cos(p.wrot), s = std::sin(p.wrot);
				l.wx = p.wx + lx * c - ly * s;
				l.wy = p.wy + lx * s + ly * c;
				l.wrot = p.rwith ? lr + p.wrot : lr;
			} else {
				l.wx = _cx + lx; l.wy = _cy + ly; l.wrot = lr;
			}
			done[chain[r]] = 1;
		}
	}
	// 手动判定管线（player：触发→匹配→评分；autoplay 走下方时间判，不跑这套）
	if (!_autoplay) {
		double dtf = (_prev_now < -1e17) ? 1.0 / 120.0 : now - _prev_now;
		if (dtf <= 1e-6) dtf = 1.0 / 120.0;
		_jkinem(now, dtf);
		for (int fi : _pending_clicks) _jcheck_note(fi, now);
		_pending_clicks.clear();
		for (int id = 0; id < 16; id++) {
			Finger &f = _fingers[id];
			if ((f.down || f.lifted) && f.new_flick) _jcheck_flick(id, now);
		}
		for (int id = 0; id < 16; id++) _fingers[id].lifted = false;
		// 时间大跳（seek/暂停恢复抖动）→ 清控制重建：被落下的音符在激活帧即判
		// Miss（player resolveUpTo 语义：seek 后统计立刻反映目标时刻）
		if (_prev_now > -1e17 && std::fabs(now - _prev_now) > 0.5) _jreset();
		const double horizon = now + std::max(_jb, _jf);
		while (_ctl_cur < (int)_notes_by_time.size() && _notes_by_time[_ctl_cur].t <= horizon) {
			Line &l = _lines[_notes_by_time[_ctl_cur].line];
			Note &n = l.notes[_notes_by_time[_ctl_cur].note];
			if (n.state == 0 && !n.hold_over) _controls.push_back({ &l, &n });
			_ctl_cur++;
		}
		if (_probe) { if ((int64_t)_controls.size() > _pb_ctl_max) _pb_ctl_max = (int64_t)_controls.size(); }
	for (size_t ci = _controls.size(); ci-- > 0;) {
			if (_jcontrol(*_controls[ci].first, *_controls[ci].second, now)) {
				_controls[ci] = _controls.back();
				_controls.pop_back();
			}
		}
		_prev_now = now;
	} else {
		_pending_clicks.clear(); // autoplay 吞掉输入（player pointerDown 直接 return）
	}
	// 自动 Miss（含 fade 结束）；autoplay=自动 Perfect（player autoplay：命中即音效+特效）
	// 千万音符谱上这里绝不能全表扫（实测 1093 万 note：每帧 133ms 就花在这两个循环）。
	// notes 按 t 升序 ⇒ 用每线一条**只前进的游标**：已判的直接跨过，未到点的停下，
	// 整曲总代价 O(N)；时间回跳由 _jreset 把游标归零重建（等价于原来的每帧重扫）。
	if (_autoplay) {
		for (auto &l : _lines) {
			// 线级窗闸只挡"整线还没到"：seek 大跳时 now 已越过 n_hi，若这里跳过就会
			// 把该线漏掉的音符整批吞掉（实测 seek 到 150s：combo 少 21、分数少 8536）。
			// 跳过后游标已经到底，普通帧里这条判断是 O(1)。
			if (now < l.n_lo) continue;
			if (!l.t_mono) { // 兜底：t 不单调（不该发生）就退回原全表扫
				for (auto &n : l.notes) {
					if (n.fake || n.state != 0) continue;
					if (now < n.t) continue;
					_auto_hit(l, n, now);
				}
				continue;
			}
			int &cur = l.am_cur;
			while (cur < (int)l.notes.size()) {
				Note &n = l.notes[cur];
				if (n.state != 0) { cur++; continue; }
				if (n.t > now) break;
				if (!n.fake) _auto_hit(l, n, now);
				cur++;
			}
		}
		// hold 尾判结算（autoplay）：按住中的 hold 一旦越过尾时刻就 +1 combo。
		// 候选窗 = [now - 最长身体 - 1s, now]，按 t 二分，不扫全表。
		for (auto &l : _lines) {
			if (now < l.n_lo) continue;
			int a = 0, b = (int)l.notes.size();
			if (l.t_mono) {
				const std::vector<Note> &ns = l.notes;
				const double lo2 = now - 1.0 - l.hold_span;
				a = (int)(std::lower_bound(ns.begin(), ns.end(), lo2,
						[](const Note &n, double v) { return n.t < v; }) - ns.begin());
				b = (int)(std::upper_bound(ns.begin(), ns.end(), now,
						[](double v, const Note &n) { return v < n.t; }) - ns.begin());
			}
			for (int i = a; i < b; i++) {
				Note &n = l.notes[i];
				if (n.type != 2 || n.fake || !n.hold_head || n.hold_over) continue;
				if (now < n.t2) continue;
				n.hold_over = true;
				_jcount(n, n.temp_state, n.t2);
			}
		}
	}
	// player 语义（JudgmentHandler.updateHoldingEffects）：按住 hold 期间在头部补命中特效，
	// 直到尾判/断连；kind 跟随当前暂判（Perfect 黄 / Good 蓝）。
	// 间隔（用户 2026-10-26 定案）：高 BPM 的 0.5 拍太密，把 BPM 按八度折到 ≤120
	// 的等价 BPM（200→100、240→120、300→75…），再按 0.5 拍补——密度跟着"降八度后的节奏"走。
	// 候选窗：活着的 hold 必然 t2 > now 且已被判（t ≤ now + 判定窗），
	// 又 t = t2 - 身体长 ≥ now - hold_span ⇒ 对 t 二分只取那一段。
	{
		const double lo = now - 1.0 - _hold_span_max;
		const double hi = now + std::max(_jb, _jf) + 0.5;
		const double spb_now = _spb_at(now);
		double bpm_eff = spb_now > 1e-9 ? (60.0 / spb_now) : 120.0;
		if (bpm_eff <= 0.0 || bpm_eff != bpm_eff) {
			bpm_eff = 120.0; // NaN/0 兜底（坏谱的 BPM 事件）
		}
		while (bpm_eff > 120.0) {
			bpm_eff *= 0.5; // 200→100、240→120、300→75（≤120 保留：120 本身不动）
		}
		const double fx_gap = 0.5 * (60.0 / bpm_eff);
		for (auto &l : _lines) {
			if (now < l.n_lo || now > l.n_hi) continue; // 线级音符窗闸
			int a = 0, b = (int)l.notes.size();
			if (l.t_mono) {
				const std::vector<Note> &ns = l.notes;
				a = (int)(std::lower_bound(ns.begin(), ns.end(), lo,
						[](const Note &n, double v) { return n.t < v; }) - ns.begin());
				b = (int)(std::upper_bound(ns.begin(), ns.end(), hi,
						[](double v, const Note &n) { return v < n.t; }) - ns.begin());
			}
			for (int i = a; i < b; i++) {
				Note &n = l.notes[i];
				if (n.type != 2 || (n.state != 1 && n.state != 2) || now >= n.t2) continue;
				if (now - n.fx_last < fx_gap) continue;
				n.fx_last = now;
				double c = std::cos(l.wrot), s = std::sin(l.wrot);
				double lx = n.x * _kx, ly = _note_ymod(n) * _ky * n.yoff;
				_fx.push_back(_make_fx(l.wx + lx * c - ly * s, l.wy + lx * s + ly * c, now, n.state == 1 ? 0 : 1, n, l.wrot));
			}
		}
	}
	// 特效过期清理
	_fx.erase(std::remove_if(_fx.begin(), _fx.end(),
					[&](const FX &f) { return now - f.t0 > 0.55; }),
			_fx.end());
	// 压力谱防御（1.pez：2400 note/s + 音频钟跳变 → 一帧可堆数千特效，
	// GPU overdraw 线性放大 → present 阻塞秒级=“画面完全不动”）。
	// 保留最新 400 个：常规谱并发特效 <300，封顶零视觉差异。
	if (_fx.size() > 400)
		_fx.erase(_fx.begin(), _fx.begin() + (int)(_fx.size() - 400));
	_prof_set_us += _prof_us() - _pt;
	queue_redraw();
}

// 事件数组按 .s 升序（load 时已 stable_sort）。二分=线性游标的等价式：
// 找最后一个满足 evs[i].s < tsec 的下标（tsec==下一事件起点时仍停在前一事件，
// 与 player 的 `beat > startBeat` 严格大于语义一致；全不满足时落 0）。
// bad apple（PE 谱，单线 17 万 cp 事件）实测线性扫描 133ms/帧=7fps 的真凶。
static inline int _ev_cursor(const std::vector<ChartPlayer::Event> &evs, double tsec) {
	int lo = 0, hi = (int)evs.size() - 1;
	int cur = 0;
	while (lo <= hi) {
		int mid = (lo + hi) >> 1;
		if (tsec > evs[mid].s) { cur = mid; lo = mid + 1; } else hi = mid - 1;
	}
	return cur;
}

// 游标推进版：单调帧只前移（O(1) 均摊）；回退 seek/越界/大跳（>8 事件）自动二分重锚。
// bad apple（3.4 万线×每线数千 cp 事件）逐帧 4×二分 = set_now 11ms 的主因。
static inline int _ev_cursor_adv(const std::vector<ChartPlayer::Event> &evs, int cur, double tsec) {
	if (cur < 0 || cur >= (int)evs.size() || tsec <= evs[cur].s ||
			(cur + 8 < (int)evs.size() && tsec > evs[cur + 8].s))
		return _ev_cursor(evs, tsec);
	while (cur + 1 < (int)evs.size() && tsec > evs[cur + 1].s) cur++;
	return cur;
}

void ChartPlayer::_update_line(Line &l, double tsec) {
	double a = 0, x = 0, y = 0, rot = 0, h = 0;
	// 瞬时事件缓存：两事件之间线状态不变 → 复用（回退 seek 强制重估）。
	const bool cached = l.ev_init && tsec >= l.last_tsec && tsec < l.ev_next;
	if (cached) {
		a = l.k_a; x = l.k_x; y = l.k_y; rot = l.k_r;
	} else {
		l.ev_next = 1e18;
		for (size_t i = 0; i < l.layers.size(); i++) {
			const Layer &L = l.layers[i];
			// 游标推进（见 _ev_cursor_adv）：alpha/mx/my/rot 四数组各持一条游标
			auto ev_c = [&](const std::vector<Event> &evs, int slot) -> double {
				if (evs.empty()) return 0.0;
				int &c = l.cur_ev[i * 4 + slot];
				c = _ev_cursor_adv(evs, c, tsec);
				// 缓存失效点=“值还会变的最早时刻”。三种情形：
				// ① tsec<事件起点：值恒为 v0，到本事件起点才变；
				// ② 缓动进行中(v0≠v1)：值每帧都在变——失效点=现在，即不缓存（错取 cur.t
				//    会把缓动段整段冻结、到点才跳一下=普通谱“判定线一秒动一次像PPT”，用户实证）；
				// ③ 缓动已完成/瞬时事件(v0==v1，bad apple 海量 cp)：值恒定到下一事件起点，可缓存。
				const Event &ce = evs[c];
				if (ce.traj >= 0) { l.ev_next = std::min(l.ev_next, tsec); return _traj_value(l, ce, tsec); }
				if (tsec < ce.s) l.ev_next = std::min(l.ev_next, ce.s);
				else if (ce.t > tsec && ce.v0 != ce.v1) l.ev_next = std::min(l.ev_next, tsec);
				else if (c + 1 < (int)evs.size()) l.ev_next = std::min(l.ev_next, evs[c + 1].s);
				return _event_value(evs[c], tsec);
			};
			a += ev_c(L.alpha, 0);
			x += ev_c(L.mx, 1);
			y += ev_c(L.my, 2);
			rot += ev_c(L.rot, 3);
		}
		l.k_a = a; l.k_x = x; l.k_y = y; l.k_r = rot;
		l.ev_init = true;
	}
	l.last_tsec = tsec;
	for (size_t i = 0; i < l.layers.size(); i++) {
		const Layer &L = l.layers[i];
		const std::vector<Event> &evs = L.speed;
		if (evs.empty()) continue;
		int &cur = l.cur_i[i];
		double &lasth = l.cur_h[i];
		// 回退 seek：游标已越过 tsec（其结算高度含未来位移）→ 从头重锚一次。
		// 单调帧不受影响；QA 探针/未来进度条 seek 的乱序 set_now 靠这里保正确（official 扫谱案）
		if (tsec < evs[cur].s) { cur = 0; lasth = 0; }
		// lasth 只在游标前进时结算一次；当前帧的部分积分即时算
		while (cur + 1 < (int)evs.size() && tsec > evs[cur + 1].s) {
			const Event &e = evs[cur];
			lasth += _event_integral(e, e.t - e.s, _speedMode);
			const Event &nx = evs[cur + 1];
			if (nx.s > e.t) lasth += e.v1 * (nx.s - e.t);
			cur++;
		}
		const Event &e = evs[cur];
		if (tsec > e.t) {
			h += lasth + _event_integral(e, e.t - e.s, _speedMode) + e.v1 * (tsec - e.t);
		} else if (tsec >= e.s) {
			h += lasth + _event_integral(e, tsec - e.s, _speedMode);
		} else {
			h += lasth;
		}
	}
	l.opa = a / 255.0;
	// player Line.ts:297（本地源码为准，用户拍板）：attachUI 线不画线精灵，
	// 除非 appearanceOnAttach 或带文字事件；部署版 player 画出白线属版本差异。
	// （textEvents 声明了但文字全空的线走 text_kind：_draw 里整条不画线精灵，
	//   alpha 照旧按 attach 规则掐 0，与改动前逐位一致。）
	if (l.ui_attach && l.aoe == 0 && !l.has_text) l.opa = 0;
	l.araw = a; // 镜像线语义按原始值 -1/-2 判断（player）
	// 文字透明度 = 线 alpha（rpe-next drawLine：globalAlpha = state.alpha/255，保持语义）。
	l.txt_opa = clampd(l.opa, 0.0, 1.0);
	// 文字线当前文本（rpe-next EventTrack.sample：事件内逐字打，事件后保持 end 文本）
	l.cur_text = _text_at(l.tx_ev, tsec);
	l.cur_font = "";
	if (!l.tx_ev.empty() && tsec >= l.tx_ev[0].t0) {
		size_t c = 0;
		for (size_t i = 0; i < l.tx_ev.size(); i++)
			if (tsec >= l.tx_ev[i].t0) c = i;
			else break;
		l.cur_font = l.tx_ev[c].font;
	}
	l.gif_prog = l.ext_gif.empty() ? -1.0f : (float)_ext_value(l.ext_gif, tsec, -1.0);
	l.ox = x;
	l.oy = y;
	l.rot_deg = rot; // 度
	l.height = h;
}

double ChartPlayer::_line_layer_value(const Line &l, int layer, const std::vector<Event> &evs, double tsec) const {
	if (evs.empty()) return 0;
	int cur = _ev_cursor(evs, tsec);
	(void)l;
	(void)layer;
	return _event_value(evs[cur], tsec);
}

double ChartPlayer::_ext_value(const std::vector<Event> &evs, double tsec, double defv) {
	if (evs.empty()) return defv;
	Event e = evs[_ev_cursor(evs, tsec)];
	e.ease = std::max(1, e.ease); // extended 事件 easing 语义同表
	return _event_value(e, tsec);
}

// control 数组：按 chartDist（线距离，1=屏高）在降序节点间插值
double ChartPlayer::_ctrl_value(const std::vector<Ctrl> &arr, double cd, double defv) {
	if (arr.empty()) return defv;
	for (size_t i = 0; i + 1 < arr.size(); i++) {
		double xa = arr[i].x, xb = arr[i + 1].x; // xa >= xb
		if (cd <= xa && cd >= xb) {
			double span = xa - xb;
			if (span <= 0) return arr[i].v;
			double raw = (cd - xb) / span; // 0@xb 1@xa
			// player getControlValue 与事件同一张 1 基 easing 表——不加偏移（旧 +1 使全部控制插值错位一档）
			double E = arr[i].ease <= 0 ? raw : _ease_fn(arr[i].ease, raw);
			return arr[i].v + (arr[i + 1].v - arr[i].v) * (1 - E);
		}
	}
	return cd > arr[0].x ? arr[0].v : arr.back().v;
}

double ChartPlayer::_height_at(const Line &l, double tsec) const {
	double total = 0;
	for (const Layer &L : l.layers) {
		const std::vector<Event> &evs = L.speed;
		if (evs.empty()) continue;
		double h = 0;
		for (size_t i = 0; i < evs.size(); i++) {
			const Event &e = evs[i];
			if (tsec <= e.s) break;
			if (tsec >= e.t) {
				h += _event_integral(e, e.t - e.s, _speedMode);
				// 事件间隙按上一事件末值延续（player handleSpeed end×Δt），恰好算一次
				double until = (i + 1 < evs.size()) ? std::min(tsec, evs[i + 1].s) : tsec;
				if (until > e.t) h += e.v1 * (until - e.t);
			} else {
				h += _event_integral(e, tsec - e.s, _speedMode);
				break;
			}
		}
		total += h;
	}
	return total;
}
// 每帧扫一遍按下的手指：进入 Active 噪域即上锁并当作松手（官方把触点从表里摘掉，
// 按住中的 hold 由中段无指保护自然断掉，音符保持 NotJudged 然后正常漏判——不是强制 Miss）。
void ChartPlayer::_infect_fingers() {
	if (_blocks.empty()) return;
	for (int id = 0; id < 16; id++) {
		Finger &f = _fingers[id];
		if (!f.down) continue;
		if (!f.blocked && block_hit(Vector2((float)f.x, (float)f.y))) {
			f.blocked = true;
			f.down = false;
			f.lifted = false;
		}
	}
}

void ChartPlayer::touch_down(int id, Vector2 pos) {
	if (_src) return;
	if (id < 0 || id >= 16) return;
	Finger &f = _fingers[id];
	// 每次按下都把这个槽**彻底重置**。上一根手指如果留下了 blocked=true（松手事件没送到：
	// 中途暂停、切后台、Android 丢事件），旧代码在这里只写 f.down、不清 f.blocked，
	// 于是感染锁永久卡住 → blocked_touch_count() 恒 >0 → 低通一直压在 1500Hz，
	// 用户实测就是"点过噪域之后声音没了，只有再点一次噪域（走完一次完整 down+up，
	// touch_up 才把 blocked 清掉）声音才回来"。
	const bool hit = block_hit(pos);
	f.blocked = hit;
	// 位置恒记一份给噪域 hover：感染中的手指拖出噪域后特效要跟手（官方"感染是手指生命周期"），
	// 但**只有 blocked 的手指才会进 TouchMask**（见 _bts_update 里对官方 blocked_touches 的考证），
	// 普通判定点击不出指尖特效。
	f.hx = pos.x;
	f.hy = pos.y;
	// 噪域拦截：Active 域内的触点不判定（玩法级干扰，非纯视觉）。手指仍登记为"未按下"，
	// 后续 move/up 走空转，不会误触发已按住音符的释放。上锁后整根手指生命周期内都失效。
	if (hit) {
		f.down = false;
		return;
	}
	f.down = true;
	f.x = f.x0 = f.px = pos.x;
	f.y = f.y0 = f.py = pos.y;
	f.t0 = _now;
	f.d0x = f.d0y = f.d1x = f.d1y = 0;
	f.stopped = true;
	f.lifted = false;
	f.new_flick = false;
	_pending_clicks.push_back(id); // player：按下不即判，下一 tick 匹配（帧内延迟语义）
}

void ChartPlayer::touch_move(int id, Vector2 pos) {
	if (_src) return;
	if (id < 0 || id >= 16) return;
	Finger &f = _fingers[id];
	f.hx = pos.x; // hover 跟手：感染中的手指不判定，但特效位置照更新
	f.hy = pos.y;
	if (f.blocked || !f.down) return; // 感染中的手指不再产生任何输入（含 flick 判定）
	f.x = pos.x;
	f.y = pos.y;
}

void ChartPlayer::touch_up(int id) {
	if (_src) return;
	if (id < 0 || id >= 16) return;
	Finger &f = _fingers[id];
	f.down = false;
	f.lifted = true; // 最后一次运动学结算留给本帧 _jkinem（同帧 划→松 不丢手势）
	// Ended/Cancelled 清除感染锁（官方 finger_infection_survives_field_disappearance_until_release）
	f.blocked = false;
}

ChartPlayer::FX ChartPlayer::_make_fx(double x, double y, double t0, int kind, const Note &n, double rot) {
	FX fx;
	fx.x = x; fx.y = y; fx.t0 = t0; fx.kind = kind;
	fx.rot = rot; // phira hitFxRotate：特效随线旋转（prpr 用 note 的 matrix）
	fx.depth = n.zfx; // player：hiteffects 容器深度 = zIndexHitEffects ?? 7
	if (n.has_fx_tint) { // hit(rgbToHex(note.tintHitEffects))：覆盖判定色（alpha 仍按判定）
		fx.has_tint = true;
		fx.tr = n.ftr; fx.tg = n.ftg; fx.tb = n.ftb;
	}
	static bool seeded = false;
	if (!seeded) {
		std::srand((unsigned)std::chrono::steady_clock::now().time_since_epoch().count());
		seeded = true;
	}
	for (int j = 0; j < 4; j++) {
		// MSVC rand()∈[0,32767]——必须除以 RAND_MAX 归一，%100000 会把角度截到 0~118°
		double r0 = rand() / (double)(RAND_MAX + 1);
		double r1 = rand() / (double)(RAND_MAX + 1);
		fx.pd[j] = r0;                               // PT: Math.random()（乘到 spread 上）
		fx.pa[j] = r1 * 2.0 * M_PI;                   // PT: Math.random()*2π 全向
	}
	return fx;
}

double ChartPlayer::_spb_at(double now) const {
	double spb = 0.5;
	for (size_t i = 0; i < _bpm_times.size(); i++)
		if (_bpm_times[i] <= now) spb = 1.0 / std::max(0.1, _bpm_bps[i]);
	return spb;
}

void ChartPlayer::_judge(Note &n, int st, double now, double delta) {
	n.state = st;
	n.jt = now;
	// player JudgmentHandler.hit→judge：只有蓝键（type 1）的 P/G/B 带 delta 入统计，
	// Miss/黄/红键不登记（hold 头在 _jcontrol 里另推，对应 onHoldHead）。
	if (delta < 1e17 && n.type == 1 && st >= 1 && st <= 3) _jdeltas.push_back(delta);
	if (st == 1) { _perfect++; _combo++; }
	else if (st == 2) { _good++; _combo++; if (delta > 0) _good_late++; else _good_early++; }
	else if (st == 3) { _bad++; _combo = 0; }
	else { _miss++; _combo = 0; }
	_max_combo = std::max(_max_combo, _combo);
	// 命中音效队列（player createHitsound：仅 Perfect/Good；bad/miss 无声）
	if (st == 1 || st == 2) _hitq.push_back({ n.type, n.hs });
}

Array ChartPlayer::take_hits() {
	Array out;
	for (auto &h : _hitq) {
		Array a;
		a.push_back(h.first);
		a.push_back(h.second);
		out.push_back(a);
	}
	_hitq.clear();
	return out;
}

Array ChartPlayer::get_sound_events() const {
	Array out;
	for (const auto &l : _lines) {
		for (const auto &n : l.notes) {
			if (n.fake) continue; // fake 音符不判定、不发声
			Array a;
			// player 的时钟是"音乐秒"，判定用 now = sec − offset − userOffset：
			// 音符的谱面时刻换算回音乐时间轴要加回来（这是录制音轨对齐的那一项）
			a.push_back(n.t + _offset + _user_offset);
			a.push_back((int)n.type);
			a.push_back(n.hs);
			out.push_back(a);
		}
	}
	return out;
}

void ChartPlayer::_jreset() {
	_pending_clicks.clear();
	_controls.clear();
	_ctl_cur = 0;
	// autoplay 的前向游标跟着控制一起重建：游标语义是「这段之前的音符已经处理过」，
	// 而 seek/回跳后这个前提不再成立（状态虽没清，重扫一遍才与全表扫描等价）。
	for (auto &l : _lines) l.am_cur = 0;
	// 偏差读数随控制一起重建：本作不做判定回退（seek 后旧判分不回滚），所以大跳
	// （seek/恢复）后从新段落重新统计，读数才对当前这一段有意义。
	// player 是 resetWindow→rewindDeltas(beat) 保留已越过时刻的记录。
	_jdeltas.clear();
	_prev_now = -1e18;
}

// autoplay 命中一条音符：判 Perfect 并在音符位置补一次命中特效（player autoplay：
// 命中即音效+特效）。原先内联在 set_now 的全表扫里，改成函数后游标版和兜底版共用。
void ChartPlayer::_auto_hit(Line &l, Note &n, double now) {
	double c = std::cos(l.wrot), s = std::sin(l.wrot);
	double lx = n.x * _kx, ly = _note_ymod(n) * _ky * n.yoff;
	if (n.type == 2) {
		// ▼ hold：**尾判才 +1 combo**（RPE/prpr/player 一致：onHoldHead 只记暂判，
		//   统计与连击在 judgeHold 的尾部结算里做）。以前 autoplay 在头就 _judge，
		//   所以同一时刻 PTN 的 combo 比 RPE 多出"当前还在按着的 hold 数"（用户实证 1309 vs 1306）。
		n.hold_head = true;
		n.temp_state = 1;
		n.state = 1;
		n.jt = n.t;
		n.fx_last = n.t;
		_hitq.push_back({ n.type, n.hs });
		_fx.push_back(_make_fx(l.wx + lx * c - ly * s, l.wy + lx * s + ly * c, n.t, 0, n, l.wrot));
		if (now >= n.t2 && !n.hold_over) { // seek 跳过整条：尾部已过，立即结算
			n.hold_over = true;
			_jcount(n, 1, n.t2);
		}
		return;
	}
	_judge(n, 1, n.t);
	_fx.push_back(_make_fx(l.wx + lx * c - ly * s, l.wy + lx * s + ly * c, n.t, 0, n, l.wrot));
	n.fx_last = n.t;
}

// 触发：手指逐帧位移向量（wu）+ 划动手势判定（player detectFlicks 语义）。
// k=60fps 归一；同向投影 ≥u 视为连划（旧手势延续，不产生新 flick），
// 否则本帧速度 ≥5u 起新手势；stopped 手指（静止过）重新达标也算新。
void ChartPlayer::_jkinem(double now, double dt) {
	double wu = std::max(_ch / 10.0, 1.0);
	double k = dt > 1e-6 ? 1.0 / (60.0 * dt) : 1.0;
	for (int id = 0; id < 16; id++) {
		Finger &f = _fingers[id];
		if (!f.down && !f.lifted) continue;
		f.d0x = f.d1x; f.d0y = f.d1y;
		f.d1x = (f.x - f.px) / wu;
		f.d1y = (f.y - f.py) / wu;
		f.px = f.x; f.py = f.y;
		double d0len = std::hypot(f.d0x, f.d0y);
		double vrel = d0len > jd::FLICK_PROJ_MIN ? (f.d0x * f.d1x + f.d0y * f.d1y) / d0len * k : 0.0;
		if (vrel < jd::FLICK_U || f.stopped) {
			double v = std::hypot(f.d1x, f.d1y) * k;
			f.new_flick = v >= jd::FLICK_U * jd::FLICK_K;
			f.stopped = !f.new_flick;
		} else {
			f.new_flick = false;
		}
	}
}

// 线系投影：手指相对线的 沿轴/垂直 距离（px）
static inline void _line_rel(const ChartPlayer::Line &l, double fx, double fy, double &ax, double &ay) {
	double c = std::cos(l.wrot), s = std::sin(l.wrot);
	double dpx = fx - l.wx, dpy = fy - l.wy;
	ax = dpx * c + dpy * s;
	ay = -dpx * s + dpy * c;
}

// 点击匹配（CheckNote）：一次按下至多认领一个音符。窗口 (-G, B]；
// dx>0.9wu 后 bad 上限按每 wu 收 0.5P 收缩；|dt| 优先（0.01s 容差内比加权度量）；
// 黄键保护：已选中的 tap/hold 不被 drag/flick 顶替；红键永不 clickMatched（点击作废）。
void ChartPlayer::_jcheck_note(int fi, double now) {
	if (fi < 0 || fi >= 16) return;
	Finger &f = _fingers[fi];
	double wu = std::max(_ch / 10.0, 1.0);
	const double B = _jb;
	int lo = 0, hi = (int)_notes_by_time.size();
	while (lo < hi) { int m = (lo + hi) >> 1; if (_notes_by_time[m].t <= now - _jg) lo = m + 1; else hi = m; }
	int start = lo;
	hi = (int)_notes_by_time.size();
	while (lo < hi) { int m = (lo + hi) >> 1; if (_notes_by_time[m].t < now + B) lo = m + 1; else hi = m; }
	int end = lo;
	int bi = -1; double babs = 1e9, bmetric = 1e9;
	for (int i = start; i < end; i++) {
		Line &l = _lines[_notes_by_time[i].line];
		Note &n = l.notes[_notes_by_time[i].note];
		if (n.click_matched || n.state != 0) continue;
		double ax, ay; _line_rel(l, f.x, f.y, ax, ay);
		double dx = std::fabs(ax - n.x * _kx);
		if (dx >= jd::X_TAP * wu) continue;
		double dt = n.t - now;
		double bad_limit = dx <= jd::X_SHRINK * wu ? B : B - (dx / wu - jd::X_SHRINK) * _jp * 0.5;
		if (dt > bad_limit) continue;
		double metric = dx + std::fabs(ay) / jd::METRIC_Y;
		if (bi >= 0) {
			if (dt >= babs + jd::T_EPS) continue; // 时刻更差（含早按过头）
			Note &bn = _lines[_notes_by_time[bi].line].notes[_notes_by_time[bi].note];
			if (bn.type != 3 && bn.type != 4) { // best 是 tap/hold
				if (n.type == 3 || n.type == 4) continue; // 黄键保护
				if (std::fabs(bn.t - n.t) > jd::T_EPS) continue; // 仅同刻并排才比度量
				if (metric >= bmetric) continue;
			}
		}
		bi = i; babs = std::fabs(dt); bmetric = metric;
	}
	if (bi < 0) return;
	Line &l = _lines[_notes_by_time[bi].line];
	Note &n = l.notes[_notes_by_time[bi].note];
	if (n.type != 3) n.click_matched = true; // 红键：点击被消耗但不认领
}

// 红键匹配（CheckFlick）：只找 type3、±F 窗、dx<2.1wu；命中后消耗该手势。
void ChartPlayer::_jcheck_flick(int fi, double now) {
	if (fi < 0 || fi >= 16) return;
	Finger &f = _fingers[fi];
	double wu = std::max(_ch / 10.0, 1.0);
	const double F = _jf;
	int lo = 0, hi = (int)_notes_by_time.size();
	while (lo < hi) { int m = (lo + hi) >> 1; if (_notes_by_time[m].t <= now - F) lo = m + 1; else hi = m; }
	int start = lo;
	hi = (int)_notes_by_time.size();
	while (lo < hi) { int m = (lo + hi) >> 1; if (_notes_by_time[m].t < now + F) lo = m + 1; else hi = m; }
	int end = lo;
	int bi = -1; double babs = 1e9, bmetric = 1e9;
	for (int i = start; i < end; i++) {
		Line &l = _lines[_notes_by_time[i].line];
		Note &n = l.notes[_notes_by_time[i].note];
		if (n.type != 3 || n.flick_matched || n.state != 0) continue;
		double ax, ay; _line_rel(l, f.x, f.y, ax, ay);
		double dx = std::fabs(ax - n.x * _kx);
		if (dx >= jd::X_WIDE * wu) continue;
		double dt = n.t - now;
		double metric = dx + std::fabs(ay) / jd::METRIC_Y;
		if (bi >= 0) {
			if (dt >= babs + jd::T_EPS) continue;
			Note &bn = _lines[_notes_by_time[bi].line].notes[_notes_by_time[bi].note];
			if (std::fabs(bn.t - n.t) > jd::T_EPS) continue;
			if (metric >= bmetric) continue;
		}
		bi = i; babs = std::fabs(dt); bmetric = metric;
	}
	if (bi < 0) return;
	Line &l = _lines[_notes_by_time[bi].line];
	Note &n = l.notes[_notes_by_time[bi].note];
	n.flick_matched = true;
	f.new_flick = false;
}

// 任意按住手指沿轴靠近音符（player anyFingerNear：只看线系 dx，y 不限）
bool ChartPlayer::_jnear(Note &n, Line &l, double range_wu) {
	double wu = std::max(_ch / 10.0, 1.0);
	for (int id = 0; id < 16; id++) {
		Finger &f = _fingers[id];
		if (!f.down || f.blocked) continue;
		double ax, ay; (void)ay; _line_rel(l, f.x, f.y, ax, ay);
		if (std::fabs(ax - n.x * _kx) < range_wu * wu) return true;
	}
	return false;
}

// 单控制评分（player *Control.Judge）。返回 true=控制终止。
// tap：clickMatched 后按 |dt| 落 P/G/B；未接住过窗即 Miss。
// drag：±0.1s 内任意近指即成，Perfect 落在音符时刻前 5ms。
// flick：需手势匹配；同上落分时刻。
// hold：头部 P/G 只作暂判（音效+特效即时），中段 2 帧抬指保护，
//       尾前 0.22s 提前结算（统计此刻才 +1），尾后 0.25s 无头判 Miss。
bool ChartPlayer::_jcontrol(Line &l, Note &n, double now) {
	double dt = n.t - now;
	switch (n.type) {
	case 1: {
		if (!n.click_matched) {
			if (dt < -_jg) _judge(n, 4, now);
			return dt < -_jg;
		}
		double ad = std::fabs(dt);
		int st = ad < _jp ? 1 : ad < _jg ? 2 : 3;
		_judge(n, st, now, -dt);
		if (st != 3) {
			double c = std::cos(l.wrot), s = std::sin(l.wrot);
			double lx = n.x * _kx, ly = _note_ymod(n) * _ky * n.yoff;
			_fx.push_back(_make_fx(l.wx + lx * c - ly * s, l.wy + lx * s + ly * c, now, st == 1 ? 0 : 1, n, l.wrot));
			n.fx_last = now;
		}
		return true;
	}
	case 4: {
		if (!n.drag_marked && std::fabs(dt) <= jd::DRAG_T && _jnear(n, l, jd::X_WIDE))
			n.drag_marked = true;
		if (!n.drag_marked) {
			if (dt < -jd::DRAG_T) _judge(n, 4, now);
			return dt < -jd::DRAG_T;
		}
		if (dt < jd::SCORE_EPS) {
			_judge(n, 1, now);
			double c = std::cos(l.wrot), s = std::sin(l.wrot);
			double lx = n.x * _kx, ly = _note_ymod(n) * _ky * n.yoff;
			// 特效延到音符时刻（player deferHitEffects：dueAt=hitTime）
			_fx.push_back(_make_fx(l.wx + lx * c - ly * s, l.wy + lx * s + ly * c, n.t, 0, n, l.wrot));
			return true;
		}
		return false;
	}
	case 3: {
		if (!n.flick_matched) {
			if (dt < -_jf) _judge(n, 4, now);
			return dt < -_jf;
		}
		if (dt < jd::SCORE_EPS) {
			_judge(n, 1, now);
			double c = std::cos(l.wrot), s = std::sin(l.wrot);
			double lx = n.x * _kx, ly = _note_ymod(n) * _ky * n.yoff;
			_fx.push_back(_make_fx(l.wx + lx * c - ly * s, l.wy + lx * s + ly * c, n.t, 0, n, l.wrot));
			return true;
		}
		return false;
	}
	default: break; // type 2 hold 在下方
	}
	// ── hold ──
	if (!n.hold_head && !n.hold_missed && !n.hold_over) {
		if (!n.click_matched) {
			// player judgeHold 头部：dt < -G 当场 judge(MISS) + holdMissed=true，控制仍活到尾部
			// （LongNote 只按 endBeat 收身/尾）→ 整条以 0.5 暗发继续画到尾，不是消失。
			// 旧实现只置标志不计数，尾部那条又被 !hold_missed 守卫跳过 ⇒ 未碰的 hold 从不计 Miss。
			if (dt < -_jg) {
				n.hold_missed = true;
				_jcount(n, 4, now);
			}
		} else {
			double ad = std::fabs(dt);
			if (ad < _jg) {
				n.hold_head = true;
				n.temp_state = ad < _jp ? 1 : 2;
				n.temp_late = dt < 0 ? 1 : 0; // dt<0 = 按在音符之后 = Late
				n.state = n.temp_state; // 绘制态=按住（HL/持续特效按 1/2）
				n.jt = now;
				n.fx_last = now;
				_hitq.push_back({ n.type, n.hs }); // 头部音效即时
				if (n.state == 1 || n.state == 2) _jdeltas.push_back(-dt); // player onHoldHead
				double c = std::cos(l.wrot), s = std::sin(l.wrot);
				double lx = n.x * _kx, ly = _note_ymod(n) * _ky * n.yoff;
				_fx.push_back(_make_fx(l.wx + lx * c - ly * s, l.wy + lx * s + ly * c, now,
						n.temp_state == 1 ? 0 : 1, n, l.wrot));
			}
			// G<=|dt|：接住太晚（late-Bad 匹配过但头部不成立）→ 等尾判
		}
	}
	if (n.hold_head && !n.hold_missed && !n.hold_over) {
		if (_jnear(n, l, jd::X_TAP)) n.safe_frames = jd::SAFE_FRAMES;
		else if (n.safe_frames <= 0) {
			n.hold_missed = true;
			n.state = 4;
			_jcount(n, 4, now); // 中段断：Miss 计数一次（player judge 在控制内）
		} else n.safe_frames--;
	}
	if (n.hold_head && !n.hold_missed && !n.hold_over && now > n.t2 - jd::TAIL_SETTLE) {
		n.hold_over = true;
		_jcount(n, n.temp_state, now, n.temp_late != 0); // 尾前结算：此刻才入统计（含早/晚）
	}
	if (now > n.t2 + jd::TAIL_MISS) {
		if (!n.hold_head && !n.hold_missed && !n.hold_over) {
			n.hold_over = true;
			n.state = 4;
			_jcount(n, 4, now); // 整条未接住：尾部后判 Miss
		}
		return true;
	}
	return n.hold_over;
}

void ChartPlayer::_jcount(Note &n, int st, double now, bool late) {
	n.state = st;
	n.jt = now;
	if (st == 1) { _perfect++; _combo++; }
	else if (st == 2) { _good++; _combo++; if (late) _good_late++; else _good_early++; }
	else if (st == 3) { _bad++; _combo = 0; }
	else { _miss++; _combo = 0; }
	_max_combo = std::max(_max_combo, _combo);
}

// 停靠在线上的音符：player 的 isCover 判据是 `dist*speed >= 0`（dist==0 也算可见，
// PlainNote.ts:137-141 / LongNote.ts:142）。线 height 与音符 hT 都是浮点累加，
// "正好停在线上"时偶尔差出 1e-11 量级的**符号噪声**：Pixel Journey 拼字段线 23 的 drag
// dist=-2.728e-11 → 被判成"还在线背面"→ 整条笔画消失（用户："I 少了一个 drag"）。
// 容差 1e-6 像素：比噪声大 5 个数量级，比任何真实"在线背面"小得多，只吃符号噪声。
static constexpr double COVER_DIST_EPS = 1e-6;

Array ChartPlayer::debug_drawn_notes(double tsec) {
	Array out;
	set_now(tsec);
	double cs_y = get_viewport_rect().size.y;
	if (cs_y < 10.0) cs_y = 900.0;
	double dScale = cs_y * 2.0 / 15.0;
	for (size_t i = 0; i < _lines.size(); i++) {
		Line &l = _lines[i];
		bool mirror = l.araw > -2.5 && l.araw < -1.5;
		if (l.araw < 0.0) continue; // rpe-next：负 alpha 整条（线+音符）隐藏
		for (auto &n : l.notes) {
			// 假 hold 照常可画；假普通音符过点即隐——与 _draw 门一致
			if (n.fake && n.type != 2 && tsec >= n.t) continue;
			if (n.state == 4 && n.type != 2) continue;
			if (n.state >= 1 && n.state <= 2 && n.type != 2) continue;
			if (tsec < n.t - n.vtime) continue;
			if (n.has_fp && n.t > tsec && l.height > n.mvp) continue; // official maxVisiblePos 门（与 _draw 同步）
			double dist = (n.hT - l.height) * n.speed * dScale + _ky * n.yoff;
			if (mirror && dist <= 0) continue;
			if (n.type == 2) {
				if (tsec > n.t2) continue;
				double d2 = (n.hT2 - l.height) * n.speed * dScale + _ky * n.yoff;
				if (n.rigid_tail && tsec > n.t) // official：头过线后尾端按 note.speed 线性收线
					d2 = std::max(0.0, n.hold_off - (tsec - n.t) * n.hold_rate) * dScale + _ky * n.yoff;
				if (l.cover && d2 * n.speed < 0) continue;
			}
			if (l.cover && n.state == 0 && dist * n.speed < -COVER_DIST_EPS && tsec < n.t) continue;
			Array a;
			a.push_back((int)i); a.push_back(n.type); a.push_back(n.t); a.push_back(n.x);
			a.push_back(dist); a.push_back(n.hT); a.push_back(l.height); a.push_back(n.state);
			a.push_back((int)(size_t)(&n - l.notes.data())); // [8] 音符下标（off_dump 断言可见性用）
			out.push_back(a);
		}
	}
	return out;
}

Array ChartPlayer::debug_overlay_notes() const {
	// F12 调试层：与 debug_note_worlds 同一套位置数学，但**不 set_now**，并且只报屏内的，
	// 免得 GDScript 每帧拿到几千条空记录。读的是上一帧 set_now 写好的 wx/wy/wrot/height。
	Array out;
	if (!_loaded) return out;
	const double dScale = _ch * 2.0 / 15.0;
	for (size_t i = 0; i < _lines.size(); i++) {
		const Line &l = _lines[i];
		double cosr = std::cos(l.wrot), sinr = std::sin(l.wrot);
		for (size_t j = 0; j < l.notes.size(); j++) {
			const Note &n = l.notes[j];
			// official 可见性门与 _draw 同步（sim-phi core.ts:475）：被线高越过的未到点音符不画，
			// 调试层也不该给它标号，否则画面是「有序号、没音符」。
			if (n.has_fp && n.t > _now && l.height > n.mvp) continue;
			double dist = (n.hT - l.height) * n.speed * dScale + _ky * n.yoff;
			double cd = dist * 900.0 / _ch;
			double ymod = _note_ymod(n);
			double lx = n.x * _kx * _ctrl_value(l.c_pos, cd, 1);
			if (l.einc != 0)
				lx += std::tan((n.x / 675.0) * (-l.einc) * M_PI / 180.0) * cd * _kx;
			double ly = ymod * dist * _ctrl_value(l.c_y, cd, 1);
			double wx = l.wx + lx * cosr - ly * sinr;
			double wy = l.wy + lx * sinr + ly * cosr;
			if (wx < -60.0 || wx > _cw + 60.0 || wy < -60.0 || wy > _ch + 60.0) continue;
			// 第 7 位=音符绘制宽度（用户要"音符序号=音符宽度的 20%"，字号必须按真实贴图宽算，
			// 不能按画布百分比猜：换皮肤/换 note.size 时两者会差好几倍）。
			// 与 _draw 同一公式 texW·(cw/8080)·noteScale·sizeCtrl·size；多押 HL 变体只宽 ~2.6%，取普通图。
			Ref<Texture2D> ntx;
			if (n.type == 1) ntx = _tex_tap;
			else if (n.type == 4) ntx = _tex_drag;
			else if (n.type == 3) ntx = _tex_flick;
			else ntx = _tex_hold_head;
			double sizeV = _ctrl_value(l.c_size, cd, 1);
			double nw;
			if (_phira_sizing) {
				// phira 规则（prpr note.rs）：宽=播放器宽度参数×(多押 ? mh宽/单押宽 : 1)，
				// 与贴图自身像素宽无关。这里必须跟 _draw 用同一条式子，否则 F12 调试层
				// 量的宽度不是屏幕上那个宽度（1080 宽的 click 会报 180 而不是 165）。
				nw = 989.0 * (_cw / 8080.0) * _noteScale * sizeV * n.size
						* (n.multi ? _mh_width_factor : 1.0);
			} else {
				nw = (ntx.is_valid() ? (double)ntx->get_width() : 989.0)
						* (_cw / 8080.0) * _noteScale * (sizeV * n.size);
			}
			Array a;
			a.push_back((int)i); a.push_back((int)j);
			a.push_back(wx); a.push_back(wy); a.push_back(n.type); a.push_back(n.state);
			a.push_back(n.fake ? 1 : 0);  // 调试层要能把假音符染成蓝色
			a.push_back(nw);
			out.push_back(a);
		}
	}
	return out;
}

static Ref<Texture2D> tex_from(const Variant &v); // 定义在文件后段（_draw 附近），此处前置声明

Array ChartPlayer::debug_overlay_lines() const {
	Array out;
	if (!_loaded) return out;
	for (size_t i = 0; i < _lines.size(); i++) {
		const Line &l = _lines[i];
		Ref<Texture2D> tx = _line_texs.has(l.texture) ? tex_from(_line_texs[l.texture]) : _tex_line;
		double w = tx.is_valid() ? (double)tx->get_width() * _kx * l.esx : 2000.0 * _kx;
		Array a;
		a.push_back((int)i); a.push_back(l.wx); a.push_back(l.wy);
		a.push_back(l.wrot); a.push_back(w);
		a.push_back(clampd(l.araw / 255.0, 0.0, 1.0));
		out.push_back(a);
	}
	return out;
}

Array ChartPlayer::debug_note_worlds(double tsec) {
	Array out;
	set_now(tsec);
	// 用 set_scale 存档画布（headless 视口恒 0×0，回退会伪装成几何 bug）
	double cs_y = _ch, cs_x = _cw;
	double dScale = cs_y * 2.0 / 15.0;
	for (size_t i = 0; i < _lines.size(); i++) {
		Line &l = _lines[i];
		double cosr = std::cos(l.wrot), sinr = std::sin(l.wrot);
		for (size_t j = 0; j < l.notes.size(); j++) {
			Note &n = l.notes[j];
			double dist = (n.hT - l.height) * n.speed * dScale + _ky * n.yoff;
			double cd = dist * 900.0 / cs_y;
			double ymod = _note_ymod(n);
			double lx = n.x * _kx * _ctrl_value(l.c_pos, cd, 1);
			if (l.einc != 0)
				lx += std::tan((n.x / 675.0) * (-l.einc) * M_PI / 180.0) * cd * _kx;
			double ly = ymod * dist * _ctrl_value(l.c_y, cd, 1);
			Array a;
			a.push_back((int)i); a.push_back((int)j);
			a.push_back(l.wx + lx * cosr - ly * sinr);
			a.push_back(l.wy + lx * sinr + ly * cosr);
			a.push_back(dist);
			out.push_back(a);
		}
	}
	return out;
}

Array ChartPlayer::debug_alpha_events(int idx) const {
	Array out;
	if (idx < 0 || idx >= (int)_lines.size()) return out;
	for (const Layer &L : _lines[idx].layers) {
		for (const Event &e : L.alpha) {
			Array a;
			a.push_back(e.bS); a.push_back(e.bT); a.push_back(e.s); a.push_back(e.t);
			a.push_back(e.v0); a.push_back(e.v1); a.push_back(e.ease);
			out.push_back(a);
		}
	}
	return out;
}

Array ChartPlayer::debug_notes() const {
	Array out;
	for (size_t i = 0; i < _lines.size(); i++) {
		const Line &l = _lines[i];
		for (size_t j = 0; j < l.notes.size(); j++) {
			const Note &n = l.notes[j];
			Array a;
			a.push_back((int)i); a.push_back((int)j);
			a.push_back(n.t); a.push_back(n.t2); a.push_back(n.x);
			a.push_back(n.type); a.push_back(n.above); a.push_back(n.fake ? 1 : 0);
			a.push_back(n.speed); a.push_back(n.size); a.push_back(n.yoff);
			a.push_back(n.alpha); a.push_back(n.vtime); a.push_back(n.hT); a.push_back(n.hT2);
			a.push_back(n.state); // 15=判定态 0未判 1P 2G 3B 4Miss——多押回归要逐条核对，聚合计数不够用
			out.push_back(a);
		}
	}
	return out;
}

Array ChartPlayer::debug_multi_counts() {	Array out;
	int rt = 0, rm = 0, ft = 0, fm = 0;
	for (auto &l : _lines)
		for (auto &n : l.notes) {
			if (n.fake) { ft++; if (n.multi) fm++; }
			else { rt++; if (n.multi) rm++; }
		}
	out.push_back(rt); out.push_back(rm); out.push_back(ft); out.push_back(fm);
	return out;
}

int ChartPlayer::blocked_touch_count() {
	int n = 0;
	for (int i = 0; i < 16; i++) if (_fingers[i].blocked) n++;
	return n;
}

int ChartPlayer::debug_fx_count() {
	return (int)_fx.size();
}

Array ChartPlayer::debug_hold_states(double tsec) {	Array out;
	set_now(tsec);
	double cs_y = get_viewport_rect().size.y;
	if (cs_y < 10.0) cs_y = 900.0;
	double dScale = cs_y * 2.0 / 15.0;
	for (size_t i = 0; i < _lines.size(); i++) {
		Line &l = _lines[i];
		for (auto &n : l.notes) {
			if (n.type != 2 || n.fake) continue;
			if (tsec < n.t - 2.0 || tsec > n.t2 + 0.5) continue;
			double dist = (n.hT - l.height) * n.speed * dScale + _ky * n.yoff;
			Array a;
			a.push_back((int)i); a.push_back(n.t); a.push_back(n.t2);
			a.push_back(n.state); a.push_back(l.araw); a.push_back(l.cover);
			a.push_back(dist); a.push_back(n.hT); a.push_back(l.height);
			a.push_back(n.size); a.push_back(n.multi ? 1 : 0);
			a.push_back(_tex_hold_head.is_valid()); a.push_back(_tex_hold.is_valid());
			out.push_back(a);
		}
	}
	return out;
}

int ChartPlayer::get_score() const {
	if (!_total_notes) return 0;
	double v = (900000.0 * _perfect + 585000.0 * _good + 100000.0 * _max_combo) / _total_notes;
	return (int)std::round(v);
}

// ───────── targetRange 深度路由 ─────────

double ChartPlayer::_note_depth(const Note &n) {
	static const double P[5] = { 0, 3, 1, 4, 2 }; // NOTE_PRIORITIES（player constants.ts）
	if (n.z >= 0) return n.z;
	int t = n.type;
	if (t < 0 || t > 4) t = 1;
	return P[t] + 2.0;
}

bool ChartPlayer::_depth_ok(double d) const {
	if (_src) {
		// 幽灵实例：keep 是白名单，空 = 什么都不画（该组只认领了 HUD/背景）
		for (double k : _keep) if (k == d) return true;
		return false;
	}
	if (!_skip.empty()) {
		for (double s : _skip) if (s == d) return false;
	}
	return true;
}

void ChartPlayer::set_state_source(Object *main) {
	_src = Object::cast_to<ChartPlayer>(main);
	_loaded = _loaded || (_src != nullptr);
}

void ChartPlayer::set_keep_depths(Array depths) {
	_keep.clear();
	for (int i = 0; i < (int)depths.size(); i++) _keep.push_back(_to_num(depths[i]));
}

void ChartPlayer::set_skip_depths(Array depths) {
	_skip.clear();
	for (int i = 0; i < (int)depths.size(); i++) _skip.push_back(_to_num(depths[i]));
}

Array ChartPlayer::get_line_depths() const {
	Array out;
	for (const Line &l : _lines) out.push_back(l.depth);
	return out;
}

Array ChartPlayer::get_note_depths() {
	Array out;
	for (double d : _note_depths) out.push_back(d);
	return out;
}

Array ChartPlayer::get_fx_depths() {
	Array out;
	for (double d : _fx_depths) out.push_back(d);
	return out;
}

bool ChartPlayer::load_extra(PackedByteArray bytes) {
	_effects.clear();
	if (bytes.size() == 0) return false;
	Variant v = JSON::parse_string(bytes.get_string_from_utf8());
	if (v.get_type() != Variant::DICTIONARY) return false;
	Dictionary d = v;
	Array effs = d.get("effects", Array());
	for (int i = 0; i < (int)effs.size(); i++) {
		Dictionary ed = effs[i];
		Effect ef;
		ef.s_sec = _b2s(_beat_of(ed.get("start", 0.0)));
		ef.e_sec = _b2s(_beat_of(ed.get("end", ed.get("start", 0.0))));
		ef.shader = (String)ed.get("shader", "");
		{
			Variant gv = ed.get("global", false);
			ef.glob = gv.get_type() == Variant::BOOL ? (bool)gv : _to_num(gv) != 0; // _to_num 不认 BOOL！
		}
		{	// targetRange（player Game.ts:857 缺省 {0,8}）：深度桶 [rmin,rmax)
			Variant rv = ed.get("targetRange", Variant());
			if (rv.get_type() == Variant::DICTIONARY) {
				Dictionary rd = rv;
				ef.rmin = _to_num(rd.get("minZIndex", 0.0));
				ef.rmax = _to_num(rd.get("maxZIndex", 8.0));
				Variant xv = rd.get("exclusive", false);
				ef.exclusive = xv.get_type() == Variant::BOOL ? (bool)xv : _to_num(xv) != 0;
			}
		}
		Dictionary vars = ed.get("vars", Dictionary());
		for (Variant key : vars.keys()) {
			String name = (String)key;
			EffectVar ev;
			ev.name = name;
			Variant vv = vars[name];
			if (vv.get_type() == Variant::INT || vv.get_type() == Variant::FLOAT) {
				ev.konst = true;
				ev.kv = _to_num(vv);
			} else if (vv.get_type() == Variant::STRING) {
				ev.konst = true;
				ev.ktex = true;
				ev.kstr = String(vv);
			} else {
				Dictionary holder;
				holder[name] = vv;
				_parse_ext(holder, name.utf8().ptr(), ev.evs);
			}
			ef.vars.push_back(ev);
		}
		_effects.push_back(ef);
	}
	UtilityFunctions::print("extra loaded: effects=", _effects.size());
	return true;
}

bool ChartPlayer::has_effects() const {
	return !_effects.empty() || !_chart_effects.empty();
}

Array ChartPlayer::get_effects(double sec) {
	Array out;
	// 无特效谱面的快路径：这两张表都是空的时候，原来每帧仍然要跑两次空循环 + 造一个空 Array，
	// 更贵的是 GD 那边拿到空数组以后还要分 global/非 global、建组、比链（perfR 实测这类谱面
	// "特效"栏仍有 0.15~0.33ms）。空表直接返回，配合 has_effects() 让调用方整个跳过。
	if (_effects.empty() && _chart_effects.empty()) return out;
	for (int list = 0; list < 2; list++) {
		const std::vector<Effect> &src = list == 0 ? _effects : _chart_effects;
		for (const Effect &ef : src) {
			if (sec <= ef.s_sec || sec > ef.e_sec) continue; // player detach(): beat>start && beat<=end（起始开、结束闭）
			Dictionary d;
			d["shader"] = ef.shader;
			d["global"] = ef.glob;
			d["rmin"] = ef.rmin;
			d["rmax"] = ef.rmax;
			d["s"] = ef.s_sec; // 激活时刻（player ShaderNode 嵌套序：后激活者包在先前者内层）
			d["order"] = ef.order;
			Dictionary params;
			params["time"] = sec; // player ShaderFilter.update 无条件喂场景时钟（random/gate/beam 的噪声都靠它）
			for (const EffectVar &ev : ef.vars) {
				if (ev.konst) {
					params[ev.name] = ev.ktex ? Variant(ev.kstr) : Variant(ev.kv);
					continue;
				}
				if (ev.karr) {
					// rpe-next vars 可以直接写常量数组（vec2/vec3/vec4）。
					// 颜色按 shader-pipeline.mjs normaliseUniformValue：4 分量且任一分量 >1
					// （或名字是 color / *Color）→ 视为 0..255，整体除以 255。
					if (ev.ka.size() == 2) params[ev.name] = Vector2(ev.ka[0], ev.ka[1]);
					else if (ev.ka.size() == 3) params[ev.name] = Vector3(ev.ka[0], ev.ka[1], ev.ka[2]);
					else if (ev.ka.size() == 4) {
						double c[4] = {ev.ka[0], ev.ka[1], ev.ka[2], ev.ka[3]};
						bool any255 = false;
						for (int j = 0; j < 4; j++) any255 = any255 || std::fabs(c[j]) > 1.0;
						// 与 rpe-next normaliseUniformValue 一致：4 分量任一 >1 ⇒ 0..255 口径
						if (any255)
							for (int j = 0; j < 4; j++) c[j] /= 255.0;
						params[ev.name] = Color(c[0], c[1], c[2], c[3]);
					}
					continue;
				}
				if (ev.evs.empty() || ev.evs[0].color) continue; // 颜色 vars 交 GDScript 默认值
				params[ev.name] = _ext_value(ev.evs, sec, ev.evs[0].v0);
			}
			d["params"] = params;
			out.push_back(d);
		}
	}
	return out;
}

// 谱内着色器事件（rpe-next src/core/shader-events.mjs）：三个根数组 + 每条线的 paintEvents，
// 事件形如 {shader, start/end, global, vars:{name: 常量 或 逐段轨道}, line, order, clone}。
void ChartPlayer::_parse_chart_effects(const Dictionary &d) {
	_chart_effects.clear();
	Array roots;
	auto add_root = [&](const Variant &v) {
		if (v.get_type() != Variant::ARRAY) return;
		Array a = v;
		for (int i = 0; i < (int)a.size(); i++) roots.push_back(a[i]);
	};
	add_root(d.get("effects", Variant()));
	add_root(d.get("shaderEvents", Variant()));
	Dictionary meta = d.get("META", Dictionary());
	add_root(meta.get("effects", Variant()));
	Array lines = d.get("judgeLineList", Array());
	for (int li = 0; li < (int)lines.size(); li++) {
		Dictionary L = lines[li];
		Dictionary ext = L.get("extended", Dictionary());
		Array pe = ext.get("paintEvents", Array());
		for (int i = 0; i < (int)pe.size(); i++) {
			if (pe[i].get_type() != Variant::DICTIONARY) continue;
			Dictionary e0 = pe[i];
			if (!e0.has("shader") && !e0.has("shaderType") && !e0.has("name")) continue; // rpe-next：无 shader 名的 paint 事件忽略
			Dictionary copy = e0.duplicate();
			copy["line"] = li;
			roots.push_back(copy);
		}
	}
	for (int i = 0; i < (int)roots.size(); i++) {
		if (roots[i].get_type() != Variant::DICTIONARY) continue;
		Dictionary ed = roots[i];
		Variant namev = ed.has("shader") ? ed["shader"] : (ed.has("shaderType") ? ed["shaderType"] : ed.get("name", Variant()));
		String nm = _canon_shader_name(namev);
		if (nm.is_empty()) continue;
		if (!nm.begins_with("/") && !nm.begins_with("\\")) {
			// rpe-next shaderIdentity：clone 事件且基础名在前 10 个里 → 用 _2 变体
			Variant cv = ed.get("clone", false);
			const bool clone = cv.get_type() == Variant::BOOL ? (bool)cv : (_to_num(cv) != 0);
			if (clone) {
				for (int k = 0; k < 10; k++)
					if (nm == _RPE_SHADER_NAMES[k]) { nm += "_2"; break; }
			}
		}
		Effect ef;
		ef.shader = nm;
		int li = -1;
		if (ed.has("line")) {
			li = (int)_to_num(ed["line"]);
		} else if (!lines.is_empty()) {
			// rpe-next shaderLine：没写 line 时用 shader 在 SHADER_NAMES 里的下标选线
			// （bpmfactor 取值依赖这条；clone 的 _2 在前 10 之后，同样按表下标）
			for (int k = 0; k < 50; k++)
				if (nm == _RPE_SHADER_NAMES[k]) { li = k % (int)lines.size(); break; }
		}
		if (li >= 0 && li < (int)lines.size()) {
			Dictionary LL = lines[li];
			ef.bpmf = std::max(0.01, _to_num(LL.get("bpmfactor", 1.0)));
		}
		Variant sv = ed.has("startTime") ? ed["startTime"] : ed.get("start", Variant(0.0));
		Variant evv = ed.has("endTime") ? ed["endTime"] : ed.get("end", ed.get("start", Variant(0.0)));
		ef.s_sec = _b2s(_beat_of(sv)) * ef.bpmf;
		ef.e_sec = _b2s(_beat_of(evv)) * ef.bpmf;
		Variant gv = ed.get("global", false);
		ef.glob = gv.get_type() == Variant::BOOL ? (bool)gv : (_to_num(gv) != 0);
		ef.order = (int)_to_num(ed.get("order", 0.0));
		Dictionary vars = ed.get("vars", Dictionary());
		Array keys = vars.keys();
		for (int k = 0; k < (int)keys.size(); k++) {
			const String name = String(keys[k]);
			Variant vv = vars[keys[k]];
			EffectVar var;
			var.name = name;
			const int t = vv.get_type();
			if (t == Variant::INT || t == Variant::FLOAT) {
				var.konst = true;
				var.kv = _to_num(vv);
			} else if (t == Variant::STRING) {
				var.konst = true;
				var.ktex = true;
				var.kstr = String(vv);
			} else if (t == Variant::ARRAY) {
				Array a = vv;
				if (a.size() > 0 && a[0].get_type() == Variant::DICTIONARY) {
					Dictionary holder;
					holder[name] = vv;
					_parse_ext(holder, name.utf8().ptr(), var.evs);
					for (Event &e2 : var.evs) { // rpe-next：时间 = seconds(beat, bpmfactor)
						e2.s *= ef.bpmf;
						e2.t *= ef.bpmf;
					}
				} else {
					var.karr = true;
					for (int j = 0; j < (int)a.size(); j++) var.ka.push_back(_to_num(a[j]));
				}
			} else {
				continue;
			}
			ef.vars.push_back(std::move(var));
		}
		_chart_effects.push_back(std::move(ef));
	}
	std::sort(_chart_effects.begin(), _chart_effects.end(), [](const Effect &a, const Effect &b) {
		return a.order != b.order ? a.order < b.order : a.s_sec < b.s_sec;
	});
	if (!_chart_effects.empty())
		UtilityFunctions::print("chart effects: n=", (int)_chart_effects.size());
}

// —— 视频层（player Video.ts）GDScript 侧接口 ——
static Ref<Texture2D> tex_from(const Variant &v); // 定义在后（_draw 附近），此处前置声明
double ChartPlayer::eval_events(Array events, double sec) {
	if (events.is_empty()) return 0.0;
	Dictionary holder;
	holder["ev"] = events;
	std::vector<Event> evs;
	_parse_ext(holder, "ev", evs);
	if (evs.empty()) return 0.0;
	return _ext_value(evs, sec, evs[0].v0);
}

void ChartPlayer::set_named_font(String name, Ref<Font> font) {
	if (name.strip_edges().is_empty() || !font.is_valid()) return;
	_fonts[name] = font;
}

Array ChartPlayer::get_touches() const {
	Array out;
	for (int i = 0; i < 16; i++) {
		const Finger &f = _fingers[i];
		// 噪域皮肤 touchPoints 要的是"物理按着的手指"：被 Active 域感染的手指
		// down=false 但 blocked=true，位置在 hx/hy（rpe-next 噪域皮肤按触点出特效）。
		if (!f.down && !f.blocked) continue;
		Array p;
		p.push_back(f.hx);
		p.push_back(f.hy);
		out.push_back(p);
	}
	return out;
}

Dictionary ChartPlayer::get_line_state(int idx) const {
	Dictionary d;
	if (idx < 0 || idx >= (int)_lines.size()) return d;
	const Line &l = _lines[idx];
	d["x"] = l.wx;
	d["y"] = l.wy;
	d["rot"] = l.wrot;
	d["alpha"] = clampd(l.araw / 255.0, 0.0, 1.0);
	d["txt_opa"] = l.txt_opa; // 文字线专用（渐消）透明度
	d["text"] = l.cur_text;   // 当前文字（打字/删字中间态）
	d["marker"] = l.block_marker; // 噪域标记线：绘制循环跳过（QA-RPE 用它验"引导图不画出来"）
	d["sx"] = l.esx;
	d["sy"] = l.esy;
	// 官方滚动高度（speed 对时间的积分）。导出器要靠它反推每条线逐段的 speed：
	// RPE 的 speedEvents 是被积函数，只有把 height 逐段差分回去才能保证音符落位一致。
	d["h"] = l.height;
	Ref<Texture2D> tx = _line_texs.has(l.texture) ? tex_from(_line_texs[l.texture]) : _tex_line;
	double w = tx.is_valid() ? (double)tx->get_width() * _kx * l.esx : 2000.0 * _kx;
	d["w"] = w;
	return d;
}

Array ChartPlayer::get_attachments() {	// player Line.updateAttachments：attach 线每帧把 {位置,旋转,alpha,extended scale} 传给对应 UI
	Array out;
	for (auto &l : _lines) {
		if (!l.ui_attach) continue;
		Dictionary d;
		d["ui"] = l.attach;
		d["x"] = l.wx;
		d["y"] = l.wy;
		d["rot"] = l.wrot;
		d["alpha"] = clampd(l.araw / 255.0, 0.0, 1.0);
		d["sx"] = l.esx;
		d["sy"] = l.esy;
		// player Line.ts:684-688 + GameUI.updateAttach → _text.setTint(line.tint)：
		// colorEvents 有值=线染色（テレパシ combo 数字紫色来源）；无 custom 贴图且
		// appearanceOnAttach=2 走 AP/FC 染色；其余保持 Phaser 默认白。
		double tr = 1.0, tg = 1.0, tb = 1.0;
		if (!l.ext_color.empty()) {
			tr = l.tr; tg = l.tg; tb = l.tb;
		} else if (l.texture == "line.png" && l.aoe == 2 && _fcApIndicator && _miss == 0 && _bad == 0) {
			Color jlc = _good == 0 ? _c_perfect : _c_good;
			tr = jlc.r; tg = jlc.g; tb = jlc.b;
		}
		d["tr"] = tr; d["tg"] = tg; d["tb"] = tb;
		out.push_back(d);
	}
	return out;
}

Array ChartPlayer::debug_line_state(int idx) const {
	Array out;
	if (idx < 0 || idx >= (int)_lines.size()) return out;
	const Line &l = _lines[idx];
	out.push_back(l.wx);
	out.push_back(l.wy);
	out.push_back(l.wrot);
	out.push_back(l.araw);
	out.push_back(l.height);
	return out;
}

// ───────── 绘制 ─────────

// hold 部件绘制：flip=true 时贴图垂直镜像（线下方音符），复刻 PhiTogether
// notesBelow 把整帧 cosr/sinr 取负 = 180° 旋转的效果。Godot 负高度 src 区域不可靠
// （会退化成单行采样 → 纯色盒子），改用 draw_polygon + 翻转 UV。
// 低端稳定 120 帧关键：镜像 quad 的顶点/UV/色缓冲用 static 复用，避免每个下方
// hold 每帧 3 次 Packed*Array 堆分配（hold 密集谱面 = 每帧上百次 malloc = p1 尖峰）。
// _draw 只在主线程跑，static 安全；UV 恒定只建一次。
static void draw_hold_tex(ChartPlayer *cp, const Ref<Texture2D> &tex, const Rect2 &r,
		const Color &mod, bool flip, bool tile = false) {
	if (!tex.is_valid()) return;
	if (!flip) { cp->draw_texture_rect(tex, r, tile, mod); return; }
	static PackedVector2Array s_uv;
	static bool uv_ready = false;
	if (!uv_ready) {
		s_uv.resize(4);
		s_uv.set(0, Vector2(0, 1));
		s_uv.set(1, Vector2(1, 1));
		s_uv.set(2, Vector2(1, 0));
		s_uv.set(3, Vector2(0, 0));
		uv_ready = true;
	}
	static PackedVector2Array s_uv_tile;
	static PackedVector2Array s_v;
	static PackedColorArray s_c;
	if (s_v.size() != 4) s_v.resize(4);
	if (s_c.size() != 4) s_c.resize(4);
	float x0 = r.position.x, y0 = r.position.y, x1 = r.position.x + r.size.x, y1 = r.position.y + r.size.y;
	s_v.set(0, Vector2(x0, y0));
	s_v.set(1, Vector2(x1, y0));
	s_v.set(2, Vector2(x1, y1));
	s_v.set(3, Vector2(x0, y1));
	s_c.set(0, mod);
	s_c.set(1, mod);
	s_c.set(2, mod);
	s_c.set(3, mod);
	const PackedVector2Array *uv = &s_uv;
	if (tile) {   // phira holdRepeat：V 方向铺 rect高/贴图高 份（与 draw_texture_rect(tile=true) 同语义）
		if (s_uv_tile.size() != 4) s_uv_tile.resize(4);
		double vs = std::abs(r.size.y) / (double)std::max(1, tex->get_height());
		s_uv_tile.set(0, Vector2(0, vs));
		s_uv_tile.set(1, Vector2(1, vs));
		s_uv_tile.set(2, Vector2(1, 0));
		s_uv_tile.set(3, Vector2(0, 0));
		uv = &s_uv_tile;
	}
	cp->draw_polygon(s_v, s_c, *uv, tex);
}

static double tex_aspect(const Ref<Texture2D> &t) {
	if (t.is_valid() && t->get_width() > 0) return (double)t->get_height() / (double)t->get_width();
	return 0.1;
}

// Dictionary 取值 → Ref<Texture2D>（Variant 只隐式转 Object*，Ref 需显式构造）
static Ref<Texture2D> tex_from(const Variant &v) {
	Object *o = v;
	return Ref<Texture2D>(Object::cast_to<Texture2D>(o));
}

void ChartPlayer::_draw() {
	// 幽灵实例（targetRange 深度路由）：绘制状态实时读主实例，画布命令仍归自己
	ChartPlayer *S = _src ? _src : this;
	if (!S->_loaded) return;
	_dbg_lines_drawn = 0; _dbg_tex_draws = 0; _dbg_line_skip_opa = 0; _dbg_tex_invalid = 0;
	const double _pt0 = _prof_us();
	Vector2 cs = Vector2(S->_cw, S->_ch); // 与 set_scale 存档一致（headless/窗口缩放同源）
	double base = cs.x / 8080.0 * S->_noteScale; // PhiTogether sim-phi 音符基准：noteScaleRatio = cw/8080
												// ×设置页「音符大小」（只缩放贴图，位置/判定不动）
	double dScale = cs.y * 2.0 / 15.0;
	const std::vector<int> &order = S->_draw_order; // _finalize 缓存的线绘制序（静态，不每帧重排）
	// 音符类型层序：hold < drag < tap < flick（player NOTE_PRIORITIES）
	static const int TYPE_ORDER[4] = { 2, 4, 1, 3 };
	// player getLineColor(fcApStatus)：无 colorEvent 的线按判定状态染色（AP 淡黄/FC 淡蓝/破线白）
	// player getLineColor：无 colorEvent 的线按判定状态染色。颜色=**这个包**的
	// colorPerfect/colorGood（prpr game.rs:1028-1034：no bad & no miss 且开了 AP/FC 指示时，
	// good==0 → colorPerfect，否则 colorGood；其余 WHITE）。以前这里写死 PT 那对淡黄/淡蓝，
	// 换 phira 包不变（用户："colorPerfect/colorGood 判定线颜色也没做"）。
	double sr = 1.0, sg = 1.0, scb = 1.0, sa = 1.0;
	if (S->_fcApIndicator && S->_miss == 0 && S->_bad == 0) {
		Color jlc = S->_good == 0 ? S->_c_perfect : S->_c_good;
		sr = jlc.r; sg = jlc.g; scb = jlc.b; sa = jlc.a;
	}
	// 第一遍：所有线精灵（player 里音符容器深度恒高于全部线）
	const double _pl0 = _prof_us();
	for (int idx : order) {
		Line &l = S->_lines[idx];
		if (!_depth_ok(l.depth)) continue; // targetRange 深度路由
		_dbg_lines_drawn++;
		// 噪域标记线（isSubtract0/1.png）：prpr line.rs:318-323 —— 引导图不是运行时材质，
		// 画出来会把"编码用的方块贴图"直接盖在渲染好的噪域上。几何/颜色已经交给 _blocks。
		if (l.block_marker) continue;
		if (l.opa <= 0.0) { _dbg_line_skip_opa++; continue; }
		draw_set_transform(Vector2(l.wx, l.wy), (float)l.wrot, Vector2(1, 1));
		// player Line.ts:686：attach/文字线不设默认线色（贴图原色=白）；普通无色线走 AP/FC/白。
		// 自定义贴图线：白/灰蒙版类贴图（数字、图案）可按判定色染色（S->_lineTexTintMode，用户方案），
		// 复杂彩图保持原色；谱面 colorEvents 永远优先（作者意图）
		bool custom_tex = l.texture != "line.png";
		Color lcol = l.ext_color.empty()
				? (l.ui_attach || l.has_text ? Color(1, 1, 1, 1) : Color(sr, sg, scb, sa))
				: Color(l.tr, l.tg, l.tb, sa);   // 作者 colorEvent 只管 rgb，AP/FC 的 alpha 仍生效
		Ref<Texture2D> defline = S->_tex_line;
		if (S->_line_texs.has("line.png"))
			defline = tex_from(S->_line_texs["line.png"]); // 谱包自带 line.png（player asset-line.png 优先）
		if (l.has_text || l.text_kind) {
			// 文字线 = Text 精灵（player Line.ts:266 / prpr JudgeLineKind::Text）：**只有字**，
			// 永远不画线精灵。文字为空（事件之前、或删字删到空）时画面上什么都没有；
			// 以前落到 line.png 分支 = 屏幕正中一条 3 屏宽白线（用户报的"59/60 显示在中间"）。
			// text_kind：textEvents 声明了但文字全空也算文字线 —— 这种线整条隐藏（用户口径）。
			Ref<Font> f = ThemeDB::get_singleton()->get_fallback_font();
			if (!l.cur_font.is_empty() && S->_fonts.has(l.cur_font)) {
				Ref<Font> nf = S->_fonts[l.cur_font];
				if (nf.is_valid()) f = nf;
			}
			if (f.is_valid() && !l.cur_text.is_empty()) {
				// player：fontSize p(100)、净缩放 p(50)/p(100)，再乘 extended scaleX/scaleY
				// （非等比缩放必须走 transform，不然 1.5× 的文字宽度画不出来）
				// rpe-next lineTextLayout：反斜杠 n 分行、整块按 anchor 居中；行高 = ascent+descent
				double fs = 50.0 * S->_kx;
				const int fsi = (int)std::max(1.0, fs);
				const double asc = f->get_ascent(fsi), desc = f->get_descent(fsi);
				const double line_h = asc + desc;
				const PackedStringArray lines = l.cur_text.split("\n");
				const int nl = std::max(1, (int)lines.size());
				const double y0 = -(double)nl * line_h * 0.5 + asc; // 首行基线（整块垂直居中）
				draw_set_transform(Vector2(l.wx, l.wy), (float)l.wrot, Vector2(l.esx, l.esy));
				const Color tc(lcol.r, lcol.g, lcol.b, clampd(l.txt_opa, 0.0, 1.0));
				for (int li = 0; li < (int)lines.size(); li++) {
					const String ln = lines[li];
					if (ln.is_empty()) continue;
					const double tw = f->get_string_size(ln, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fsi).x;
					draw_string(f, Vector2(-tw * 0.5, y0 + (double)li * line_h), ln,
							HORIZONTAL_ALIGNMENT_LEFT, -1.0, fsi, tc);
				}
				draw_set_transform(Vector2(l.wx, l.wy), (float)l.wrot, Vector2(1, 1));
			}
		} else if (custom_tex) {
			Ref<Texture2D> tx = S->_line_texs.has(l.texture)
					? tex_from(S->_line_texs[l.texture])
					: defline; // player getLineTexture：缺文件回退 asset-line.png
			if (tx.is_valid()) {
				Color ccol = lcol;
				if (l.ext_color.empty() && !l.ui_attach) {
					bool tintable = false;
					if (S->_lineTexTintMode == 2) tintable = true;
					else if (S->_lineTexTintMode == 0 && S->_line_tex_tint.has(l.texture))
						tintable = (bool)S->_line_tex_tint[l.texture];
					if (!tintable) ccol = Color(1, 1, 1); // 彩图/跟随 player：原色输出
				}
				// 自定义贴图：两轴都按 p(1)（1 贴图像素 = 1 谱面单位），不走 o(1)×粗细
				// gif/apng 动画：竖排帧条，按 _now·fps 取当前帧的源矩形
				double fh = (double)tx->get_height();
				int fi = -1;
				if (S->_line_tex_anim.has(l.texture)) {
					Array av = S->_line_tex_anim[l.texture];
					const int an = std::max(1, (int)av[0]);
					if (l.gif_prog >= 0.0f) {
						// rpe-next TextureGif：gifEvents 值 = 播放进度 0..1
						fi = (int)std::floor(clampd((double)l.gif_prog, 0.0, 1.0) * (double)(an - 1) + 0.5);
					} else {
						fi = (int)(S->_now * (double)av[1]);
					}
					fi = ((fi % an) + an) % an;
					fh /= (double)an;
				}
				// extended scaleX/scaleY 可为负（テレパシ 走路回镜 -0.3：Phaser T·R·S
				// 负比例=贴图翻转+锚点跨度同步镜像）。带符号宽度的 Rect 会把贴图
				// 甩到锚点另一侧（人物从左边瞬移到右边）→ 镜像必须走 transform：
				// draw_set_transform(pos, rot, (sgn,sgn)) 与 Phaser T·R·S 同构，
				// 局部矩形恒用正宽高+原锚点，镜像后跨度=[pos-(1-a)|w|, pos+a|w|]。
				double wsg = l.esx < 0.0 ? -1.0 : 1.0;
				double ysg = l.esy < 0.0 ? -1.0 : 1.0;
				double w = (double)tx->get_width() * S->_kx * fabs(l.esx);
				double h = fh * S->_kx * fabs(l.esy);
				Color lmod(ccol.r, ccol.g, ccol.b, clampd(l.opa, 0.0, 1.0) * ccol.a);
				draw_set_transform(Vector2(l.wx, l.wy), (float)l.wrot, Vector2(wsg, ysg));
				Rect2 dst(-l.ax * w, -l.ay * h, w, h);  // anchor 锚点（Phaser origin 同构）
				if (fi >= 0)
					draw_texture_rect_region(tx, dst, Rect2(0.0, (double)fi * fh, (double)tx->get_width(), fh), lmod);
				else
					draw_texture_rect(tx, dst, false, lmod);
				draw_set_transform(Vector2(l.wx, l.wy), (float)l.wrot, Vector2(1, 1));
			}
		} else if (defline.is_valid()) {
			_dbg_tex_draws++;
			double w_full = (double)defline->get_width() * S->_kx * l.esx;
			double h = std::max(2.0, (double)defline->get_height() * S->_ky * 1.35 * l.esy);
			Color lc(lcol.r, lcol.g, lcol.b, clampd(l.opa, 0.0, 1.0) * lcol.a);
			draw_texture_rect(defline, Rect2(-l.ax * w_full, -l.ay * h, w_full, h), false, lc);
		} else {
			_dbg_tex_invalid++;
			double half = 2000.0 * S->_kx; // 缺省贴图也按 ~3 屏宽
			draw_line(Vector2(-half, 0), Vector2(half, 0),
					Color(lcol.r, lcol.g, lcol.b, clampd(l.opa, 0.0, 1.0)),
					std::max(2.0, cs.y / 900.0 * 6.75), true);
		}
		draw_set_transform(Vector2(), 0, Vector2(1, 1)); // 复位=单位缩放（Vector2() 是 0 缩放，会吞掉后续绘制）
	}
	// 实例层是"每个绘制节点自己的"：主实例与各深度幽灵实例都各自建一组子节点，
	// 否则幽灵层的音符会画到主实例的过滤链外面。状态取 S，节点取 this。
	// 开关一律读 S（幽灵实例自己没有这个开关），特效层与开关无关所以无条件建。
	// 两条路径**都**填同一份实例缓冲：旧路径照旧逐 quad 画，同时把"本来会写进实例的
	// 那条 quad"记下来。对拍因此能直接比"旧路径画了什么" vs "实例里有什么"，
	// 这也是验收要求的逐帧 quad 数一致（不然只能靠像素猜）。
	_ph_lines_us += _prof_us() - _pl0;
	const double _pn0 = _prof_us();
	_vpx = cs.x; _vpy = cs.y;   // 视口剔除用的画布尺寸（幽灵实例也要用主实例的）
	_mm_ensure(S);
	const bool use_mm = S->_note_mm && _mm_ok;
	const bool rec = use_mm || _mm_rec;
	if (rec) _mm_reset();
	for (int idx : order) {
		Line &l = S->_lines[idx];
		if (S->_now < l.n_lo || S->_now > l.n_hi) continue; // 线级音符窗闸（bad apple：3.4万线×1note）
		double cosr = std::cos(l.wrot), sinr = std::sin(l.wrot);
		draw_set_transform(Vector2(l.wx, l.wy), (float)l.wrot, Vector2(1, 1));
		// 镜像线语义（player LongNote/PlainNote）：仅 lineOpacity === -2 是镜像；
		// 其余负值（如 -255/-1）= 线与其音符整体隐藏
		bool mirror = l.araw > -2.5 && l.araw < -1.5;
		// 官谱幽灵线（ハテ AT 实测 t=136.6 屏内 50 个音符里 45 个挂在 alpha=0 的线上，
		// 且这些线的 speedEvents 前段是 0 → 音符定在上线不动）就是用户报的"tap/flick 定住"。
		bool notes_hidden = l.araw < 0.0; // rpe-next：alpha<0 = 线与其音符整体隐藏（无 -2 例外）
		(void)mirror; // 2026-10-05 试加过"官谱线 alpha=0 → 音符同隐"，
		// 实机结果是音符整段消失（官谱大量线只在个别瞬间闪 alpha），那条推断已回退，别再照抄。
		// 每帧只扫「高度候选窗」而不是整条线的音符表（用户实测：1093 万 note 的 .pe 谱
		// 全表扫描 = 每帧 151ms，而真正落 quad 的只有 ~190 个）。
		// 音符上屏的判据是 |dist| = |(hT-height)·speed·dScale + ky·yoff| ≤ cull
		// （普通音符 yscr 剔 / hold 的 isNoteInCullArea 都是它的同式变形），
		// 反解成 hT 区间：用全线最小 speed、最大 |yoff| 放宽，hold 再按最大身体长
		// h_delta_max 把左界外移。notes 按 t 升序且 hT 随 t 单调（h_mono，_finalize 校验），
		// 所以这个区间就是数组上一段连续下标 ⇒ 两次二分。
		// 线接近水平旋转（cosr→0）时 yscr 与 dist 无关，窗无从反解，老实回退全表。
		const std::vector<int> *seq = &l.nord;
		double _wl = -1e18, _wh = 1e18;   // 探针用：本帧该线候选窗（未窗化时=全域）
		// 近竖直的线（cosr→0）：音符的屏幕 y 与 dist 无关（yscr≈l.wy），y 窗无从反解，
		// 但屏幕 **x** = l.wx − sinr·ymod·dist 完全由 dist 决定 ⇒ 同一个窗改用 x 轴反解。
		// 这条分支只在"以前只能全表扫"的那一类线上生效，所以对其它谱零影响。
		// 实测（1093 万音符谱，唯一一条线 rot≈90°）：不窗化时每帧落 10,935,342 个 quad
		// = 2187 万图元/帧 = 上屏 2.7 秒；窗化后只剩屏内那些。
		// 近竖直判据：**剔除**只看几何（屏幕 x 由 dist 决定），与 h_mono 无关；
		// 候选窗还额外要求 hT 单调（不单调就只能全表扫，但剔除照样生效）。
		const bool vert = std::fabs(cosr) < 1e-4 && std::fabs(sinr) >= 1e-4;
		bool xwin = false;                 // 本帧这条线走 x 轴窗
		if (l.has_static) {
			seq = &l.nord;                 // speed=0 音符 dist 恒为 yoff，hT 窗反解不成立 → 全表扫
			l.h_mono = l.h_mono;           // （保持原标记，其它分支不受影响）
		} else if (l.h_mono) {
			double ac = std::fabs(cosr), as = std::fabs(sinr);
			if (vert) xwin = true;
			if (ac < 1e-4 && !xwin) { seq = &l.nord; }
			else {
				double cull_ = xwin ? (cs.x + cs.y * 0.5 * ac) : (cs.y + cs.x * 0.5 * as);
				double off = xwin ? std::fabs(l.wx - cs.x * 0.5) : std::fabs(l.wy - cs.y * 0.5);
				double r = ((cull_ + off) / (xwin ? as : ac) + S->_ky * l.h_yoff_abs)
						/ (l.h_spd_min * dScale);
				_wl = l.height - r - l.h_delta_max; _wh = l.height + r;
				const std::vector<Note> &ns = l.notes;
				int a = (int)(std::lower_bound(ns.begin(), ns.end(), _wl,
						[](const Note &n, double v) { return n.hT < v; }) - ns.begin());
				int b = (int)(std::upper_bound(ns.begin(), ns.end(), _wh,
						[](double v, const Note &n) { return v < n.hT; }) - ns.begin());
				std::vector<int> &cd = S->_cand;
				cd.clear();
				if (b > a) {
					cd.reserve((size_t)(b - a));
					for (int i = a; i < b; i++) cd.push_back(l.nrank[i]); // 先取绘制位次
					std::sort(cd.begin(), cd.end());                      // 位次升序 = nord 序
					for (size_t k = 0; k < cd.size(); k++) cd[k] = l.nord[cd[k]];
				}
				seq = &cd;
			}
		}
		if (S->_probe) {
			S->_pb_scanned += (int64_t)seq->size();          // 本帧真正进循环的音符
			S->_pb_win += (int64_t)l.notes.size();           // 若不窗化要扫的音符（对照）
		}
		for (int oi : *seq) {
			Note &n = l.notes[oi];
			double ndp = _note_depth(n);
			if (!_depth_ok(ndp)) continue; // 音符桶路由
			const int bkt = _mm_bucket(S->_note_depths, ndp);   // 实例化分组：深度桶
			int type = n.type;
			for (int ti = 0; ti < 1; ti++) {
				if (n.type != type) continue;
				// 假音符（player 语义）：正常绘制、不参与判定/漏判；
				// 普通假音符过自身时间即隐藏（PlainNote setVisible(false)），假 hold 到 t2
				if (n.fake && n.type != 2 && S->_now >= n.t) continue;
				if (notes_hidden) continue;
				// 便宜时间闸前置（bad apple 3.4 万 hold：未到可见窗/尾已过/已判的
				// 先出局，dist/ctrl/tan 只算幸存者）
				if (S->_now < n.vis_lo) continue;
				// official 可见性门（sim-phi core.ts:475-476 `isHidden = maxVisiblePos < line.positionY2`）：
				// 音符还没到点，但它的 floorPosition 已经被判定线的当前高度越过 ⇒ 整条（含 hold 身体）不可见。
				// ハテ AT t=37.55 实测有 8 条这种音符（14/15/16/17 线，|距线|≤21px），我们没这条门
				// ⇒ 用户看到的「提前出现在线附近 + 定住不动」，sim-phi 实跑那边 alpha=0。
				// 别和「value=0 平台段」混为一谈：平台段上 fp == 线高，而 maxVisiblePos = fp + ε > 线高，
				// 所以那种贴线静止**不会被隐藏**——它是 official 真行为（sim-phi 实跑同样静止）。
				if (n.has_fp && n.t > S->_now && l.height > n.mvp) continue;
				if (n.state == 4 && n.type != 2) continue; // 漏判 hold 仍以 0.5 alpha 画到尾部
				if (n.state >= 1 && n.state <= 2 && n.type != 2) continue; // 已判普通音符隐藏
				if (n.state == 3 && S->_now - n.jt > 0.5) continue;
				if (n.type == 2 && S->_now > n.t2) continue; // hold 尾已过
				double dist = (n.hT - l.height) * n.speed * dScale + S->_ky * n.yoff;
				if (mirror && dist <= 0) continue; // 只留接近侧
				if (l.cover && (n.state == 0) && dist * n.speed < -COVER_DIST_EPS && S->_now < n.t) continue;
				// player 的可见性判据（PlainNote.ts:137-141 / LongNote.ts:142）：
				//   visible && songTime >= hitTime − visibleTime
				//             && (judgmentProgress > 0 || dist*speed >= 0 || !isCover)
				// dist==0 落在 `>= 0` 一侧 → **贴在线上的音符是可见的**。
				// 原先那条"离判定还很久就剔掉"是我为了压住 AT 幽灵线上的静止音符
				// 自创的，不属于 player 语义，已按用户裁定撤掉；
				// isCover 分支就是上面那行 l.cover 判据。
				// 屏幕系剔除（player cullBound，Line.ts 剔除统一用严格 ===1）
				double cullmod = n.above == 1 ? -1 : 1;
				double yscr = l.wy + cullmod * dist * cosr;
				double cull = cs.y + (cs.x * 0.5) * std::abs(sinr);
				if (n.type != 2 && std::abs(yscr - cs.y * 0.5) > cull) continue;
				// 近竖直的线：屏幕 y 与 dist 无关（y 剔不掉任何东西），改按屏幕 x 剔。
				// 被剔掉的本来越出视口，GPU 也不产生像素 ⇒ 画面逐像素不变（A/B 台证）。
				if (n.type != 2 && vert
						&& std::fabs(l.wx - cullmod * dist * sinr - cs.x * 0.5)
								> cs.x + (cs.y * 0.5) * std::fabs(cosr)) continue;
				if (S->_probe && n.type != 2) { S->_pb_kept++; if (n.hT < _wl || n.hT > _wh) S->_pb_out++; }
				double ymod = _note_ymod(n);
				double cd = dist * 900.0 / cs.y; // chartDist（1=屏高）
				double na = clampd(n.alpha * _ctrl_value(l.c_alpha, cd, 255) / 255.0, 0.0, 1.0);
				if (n.state == 0 && !n.fake && n.type != 2 && S->_now > n.t) { // 蓝键过线淡出（hold 无此淡出）
					// player 的 missWindow 按类型不同（PlainNote.missWindow：drag=DRAG_TIME_RANGE
					// 恒 0.1；flick=perfectJudgment×1.75；tap/hold=goodJudgment）——淡出窗跟着判定窗口设置走。
					// prpr 那边是全类型统一 0.16（note.rs:9 FADEOUT_TIME），按用户裁定不采用。
					double mw = n.type == 4 ? jd::DRAG_T : (n.type == 3 ? S->_jf : S->_jg);
					na *= std::max(0.0, 1.0 - (S->_now - n.t) / mw);
				}
				if (n.state == 3) na *= std::max(0.0, 1.0 - (S->_now - n.jt) / 0.5);
				if (n.state == 4 && n.type == 2) na *= 0.5; // 漏判 hold：player 容器 alpha 0.5
				// 多押提示开关（player Game.ts:748：simultaneousNoteHint 关 ⇒ moments=[]
				// ⇒ Line.ts:388 highlight 恒 false ⇒ 一律用普通贴图）
				const bool mm = n.multi && S->_multiHint;
				double posV = _ctrl_value(l.c_pos, cd, 1);
				double sizeV = _ctrl_value(l.c_size, cd, 1) * n.size;
				double yV = _ctrl_value(l.c_y, cd, 1);
				double lx = n.x * S->_kx * posV;
				// 透视倾斜（incline）：x += tan((xMod·posX/675)·(−incline)°)·chartDist
				if (l.einc != 0)
					lx += std::tan((n.x / 675.0) * (-l.einc) * M_PI / 180.0) * cd * S->_kx;
				double ly = ymod * dist * yV;
				// 制谱器取景裁切（用户 2026-10-27："3:2 范围之外的表演音符提前出现"）。
				// 开关=设置→游玩→取景口径：开=注重演出（本段生效），关=注重游玩（框外也画）。
				// 拖尾距离是**按高度**换算的（cd 就是"编辑器 px"），线自身位置是**按宽**换算的
				// （_kx），16:9 下两套尺度差 1.185 倍 ⇒ 旋转线上的表演音符会露到制谱器根本
				// 看不见的地方（Hello (BPM) 2024 线 23 的 #5/#6：编辑器 x=−215 在框外，
				// 我们 x=+36 在框内，于是提前 75 秒杵在左边）。这里把音符折回"编辑器 px"
				// 求横坐标，超出 ±675 就不画。rot=0/180 时该判据与"出屏"逐位等价 ⇒ 零影响。
				double lxu = n.x * posV;
				if (l.einc != 0)
					lxu += std::tan((n.x / 675.0) * (-l.einc) * M_PI / 180.0) * cd;
				const double lyu = n.type == 2 ? ymod * cd : ymod * cd * yV;
				const double cxu = l.ox + lxu * cosr - lyu * sinr;
				if (n.type != 2 && S->_frame_cull && std::fabs(cxu) > 675.0) continue;
				// 音符 tint（player setTint(rgbToHex(data.tint))）；bad 判定红色覆盖
				double ntr = n.has_tint ? n.tr : 1.0, ntg = n.has_tint ? n.tg : 1.0,
				       ntb = n.has_tint ? n.tb : 1.0;
				Color tint(ntr, ntg, ntb, na);
				if (n.state == 3) tint = Color(0x6b / 255.0, 0x3b / 255.0, 0x3a / 255.0, na);
				if (n.type == 2) {
					// hold 无 control 数组（player LongNote）；头过线后钉住、头贴图隐藏（holdKeepHead=false）
					double d2 = (n.hT2 - l.height) * n.speed * dScale + S->_ky * n.yoff;
					if (n.rigid_tail && S->_now > n.t) // official：头过线后尾端按 note.speed 线性收线
						d2 = std::max(0.0, n.hold_off - (S->_now - n.t) * n.hold_rate) * dScale + S->_ky * n.yoff;
					if (S->_now > n.t2) continue; // 尾已过
					// isCover 线：tailDist*speed<0（尾端过线）即整体隐藏（player LongNote vis）
					if (l.cover && d2 * n.speed < 0) continue;
					// hold 要头尾**都**出框、且在同一侧才剔：身体横跨画框的那条不能整条抹掉
					{
						const double lyu2 = ymod * (d2 * 900.0 / cs.y);
						const double ctxu = l.ox + lxu * cosr - lyu2 * sinr;
						if (S->_frame_cull && std::fabs(cxu) > 675.0 && std::fabs(ctxu) > 675.0
								&& (cxu > 0.0) == (ctxu > 0.0)) continue;
					}
					// 这里**不做**任何"把尾端钳到屏边"的处理：player 的 LongNote 是
					// bodyHeight = max(0, tailDist − headDist)、setY(headDist)（LongNote.ts:167-171），超出部分交给 GPU 裁剪。
					// 我之前自作主张钳过一次，钳完的尾端可能落到头部以下，
					// 画出来就是一根脱离头部、悬在屏中间的条（用户 17_25_37 那张 INTERCELL 截图）。
					double hd = S->_now > n.t ? S->_ky * n.yoff : dist;
					if (l.cover) hd = std::max(0.0, hd);
					double ya = ymod * hd, yb = ymod * d2;
					// player isNoteInCullArea(LongNote)：整条身体 minY/maxY 出屏即剔
					// （bad apple 3.3 万 hold 不剔=10 万 quad/帧，GPU present 拖满 100ms）
					{
						double sya = l.wy + ya * cosr, syb = l.wy + yb * cosr;
						double cy = cs.y * 0.5;
						if (std::max(sya, syb) < cy - cull || std::min(sya, syb) > cy + cull) continue;
						if (S->_probe) { S->_pb_kept++; if (n.hT < _wl || n.hT > _wh) S->_pb_out++; }
					}
					Ref<Texture2D> head = mm && S->_tex_hold_head_hl.is_valid() ? S->_tex_hold_head_hl : S->_tex_hold_head;
					Ref<Texture2D> body = mm && S->_tex_hold_hl.is_valid() ? S->_tex_hold_hl : S->_tex_hold;
					// 多押长条的尾帽：prpr 从 hold_mh.png 的图集里切（单独一张图）；
					// PT/内置没这一槽 → 回落普通尾帽，行为与改动前逐位一致
					Ref<Texture2D> tail = mm && S->_tex_hold_end_hl.is_valid() ? S->_tex_hold_end_hl : S->_tex_hold_end;
					// 自定义包可以只给身体不给头/尾帽（例如 PT customRes 的鱼形 hold）：
					// 有身体就画，缺帽就只画身体，绝不回落到内置帽（用户定案）。
					if (body.is_valid()) {
						// 每部件按自身贴图宽高 × base × size（player LongNote resize 语义）。
						// PT ResourcePack/index.ts 非 prpr 分支：HoldHL/HoldHeadHL 加载时乘
						// 8080/7875≈1.026——HL 亮边芯宽 958 被抬到 983，与 Hold/HoldEnd 的
						// 983 亮边对齐；缺这个因子时多押 hold 的尾部会比身体宽 ~2px/侧。
						bool head_hl = mm && S->_tex_hold_head_hl.is_valid();
						bool body_hl = mm && S->_tex_hold_hl.is_valid();
						const int k_body = body_hl ? MK_HOLD_BODY_HL : MK_HOLD_BODY;
						const int k_head = head_hl ? MK_HOLD_HEAD_HL : MK_HOLD_HEAD;
						const double FH = 8080.0 / 7875.0;
						const bool head_ok = head.is_valid();
						double hw = 0.0, hh = 0.0, bw = 0.0;
						if (S->_phira_sizing) {
							// prpr note.rs：三段同宽=播放器宽度参数×(多押 ? mh宽/单押宽 : 1)，高按各部件贴图自身比例
							double pw = 989.0 * base * n.size * (mm ? S->_mh_width_factor : 1.0);
							bw = pw;
							if (head_ok) {
								hw = pw;
								hh = pw * (double)head->get_height() / (double)std::max(1, head->get_width());
							}
						} else {
							if (head_ok) {
								hw = (double)head->get_width() * base * n.size * (head_hl ? FH : 1.0);
								hh = (double)head->get_height() * base * (head_hl ? FH : 1.0); // player setScale(size·base, base)——Y 不含 size
							}
							bw = (double)body->get_width() * base * n.size * (body_hl ? FH : 1.0);
						}
						// holdCompact（phira 可选，默认 false）：帽从"贴在端点侧"改成"绕端点居中"
						const double hcoff = (S->_phira_sizing && S->_hold_compact) ? hh * 0.5 : 0.0;
						Color bc(ntr, ntg, ntb, na * 0.9);
						// PhiTogether Hold.ts/scaledNote：body 在头尾位置之间拉伸；
						// head 帽从头部位置朝"线"方向延伸 hh（.head: [0,dh]），
						// tail 帽从尾部位置朝"离线"方向延伸 th（.tail: [-L-dh,-L]）。
						// 远离线方向 = +ymod，朝线 = −ymod。above=0（ymod>0）整体 180° 翻（贴图垂直镜像）。
						bool flip = ymod > 0.0;
						if (rec) _mm_quad(bkt, k_body, l, cosr, sinr, lx, (ya + yb) * 0.5, bw,
								std::abs(yb - ya) * (flip ? -1.0 : 1.0), 0, bc);
						if (!use_mm)
							draw_hold_tex(this, body, Rect2(lx - bw * 0.5, std::min(ya, yb), bw, std::abs(yb - ya)), bc, flip,
															S->_hold_repeat);
						// player LongNote：头过线即隐（keepHead=false）；phira 包 holdKeepHead=true 时不隐；尾与身体同寿命到 t2，
						// 绝不因头被判定/漏判而消失
						if (head_ok && (S->_hold_keep_head || S->_now <= n.t) && !(l.cover && dist * n.speed < -COVER_DIST_EPS)) {
							double htop = (ymod > 0.0 ? ya - hh : ya) + (ymod > 0.0 ? hcoff : -hcoff); // 帽朝线延伸
							if (rec) _mm_quad(bkt, k_head, l, cosr, sinr, lx, htop + hh * 0.5, hw,
									hh * (flip ? -1.0 : 1.0), 0, tint);
							if (!use_mm)
								draw_hold_tex(this, head, Rect2(lx - hw * 0.5, htop, hw, hh), tint, flip);
						}
						if (tail.is_valid()) {
							double tw, th;
							if (S->_phira_sizing) {
								// 尾帽与头/身体同宽（prpr 三段都用同一个 scale）
								tw = 989.0 * base * n.size * (mm ? S->_mh_width_factor : 1.0);
								th = tw * (double)tail->get_height() / (double)std::max(1, tail->get_width());
							} else {
								tw = (double)tail->get_width() * base * n.size;
								th = (double)tail->get_height() * base; // player setScale(size·base, base)
							}
							// holdCompact：帽绕端点居中（与身体重叠一半）
							const double tcoff = (S->_phira_sizing && S->_hold_compact) ? th * 0.5 : 0.0;
							double ttop = (ymod > 0.0 ? yb : yb - th) + (ymod > 0.0 ? -tcoff : tcoff);
							if (rec) _mm_quad(bkt, mm && S->_tex_hold_end_hl.is_valid() ? MK_HOLD_TAIL_HL : MK_HOLD_TAIL, l, cosr, sinr, lx, ttop + th * 0.5, tw,
									th * (flip ? -1.0 : 1.0), 0, tint);
							if (!use_mm)
								draw_hold_tex(this, tail, Rect2(lx - tw * 0.5, ttop, tw, th), tint, flip);
						}
					}
					// body 也缺（正常不会：SkinPack.apply_to 会回落内置身体）→ 什么都不画，
					// 绝不再出现蓝色占位矩形（用户："不是鱼吗，怎么变成蓝色矩形了"）。
					continue;
				}
				Ref<Texture2D> tex;
				if (n.type == 1) tex = mm && S->_tex_tap_hl.is_valid() ? S->_tex_tap_hl : S->_tex_tap;
				else if (n.type == 4) tex = mm && S->_tex_drag_hl.is_valid() ? S->_tex_drag_hl : S->_tex_drag;
				else tex = mm && S->_tex_flick_hl.is_valid() ? S->_tex_flick_hl : S->_tex_flick;
				if (tex.is_valid()) {
					double nw, nh;
					if (S->_phira_sizing) {
						// prpr 规则（用户贴的官方文档同句）：单押等宽高比缩到"播放器宽度参数"为宽，
						// 双押再乘(双押贴图宽/单押贴图宽)。也就是说 1080×1080 的 click.png 不能画成 1080 宽。
						// sizeV 在这条路上**已经含了 n.size**（上面 sizeV = sizeCtrl·n.size），
						// 再乘一次就是双倍缩放——夹具 n.size=1 时看不出来，谱面一给 size 就炸。
						nw = 989.0 * base * sizeV * (mm ? S->_mh_width_factor : 1.0);
						nh = nw * (double)tex->get_height() / (double)std::max(1, tex->get_width());
					} else {
						// player resize：sx = size·sizeCtrl·base，sy = sizeCtrl·base（高度不含 data.size！）
						double ctrlS = sizeV / n.size;
						nw = (double)tex->get_width() * base * sizeV;
						nh = (double)tex->get_height() * base * ctrlS;
					}
					if (rec) {   // 两条路径都记录（见 _draw 开头的对拍说明）
						int kind = n.type == 1 ? (mm ? MK_TAP_HL : MK_TAP)
								: (n.type == 4 ? (mm ? MK_DRAG_HL : MK_DRAG) : (mm ? MK_FLICK_HL : MK_FLICK));
						double sk = std::tan(-n.x * _ctrl_value(l.c_skew, cd, 0) * M_PI / 180.0);
						_mm_quad(bkt, kind, l, cosr, sinr, lx, ly, nw, nh, sk, tint);
					}
					if (use_mm) continue;
					// skewX（player applySkewX(-xMod·posX·skewCtrl)）：绕音符中心剪切 x += y·tan(deg)
					double skewDeg = -n.x * _ctrl_value(l.c_skew, cd, 0);
					if (std::abs(skewDeg) > 1e-6) {
						double tanS = std::tan(skewDeg * M_PI / 180.0);
						Transform2D shear(Vector2(1, 0), Vector2(tanS, 1), Vector2(lx, ly));
						draw_set_transform_matrix(
								Transform2D((float)l.wrot, Vector2(l.wx, l.wy)) * shear);
						draw_texture_rect(tex, Rect2(-nw * 0.5, -nh * 0.5, nw, nh), false, tint);
						draw_set_transform(Vector2(l.wx, l.wy), (float)l.wrot, Vector2(1, 1));
					} else {
						draw_texture_rect(tex, Rect2(lx - nw * 0.5, ly - nh * 0.5, nw, nh), false, tint);
					}
				} else {
					double nw = 989 * base * sizeV, nh = nw * 0.1;
					Color col = tint * Color(0.25, 0.55, 1.0, 1);
					if (n.type == 4) col = tint * Color(0.95, 0.85, 0.3, 1);
					else if (n.type == 3) col = tint * Color(1.0, 0.45, 0.2, 1);
					draw_rect(Rect2(lx - nw * 0.5, ly - nh * 0.5, nw, nh), col);
				}
			}
		}
		draw_set_transform(Vector2(), 0, Vector2(1, 1)); // 复位=单位缩放（Vector2() 是 0 缩放，会吞掉后续绘制）
	}
	if (rec) _mm_commit(use_mm);   // 旧路径帧填缓冲但节点收起；生产旧路径连填都不填
	_ph_notes_us += _prof_us() - _pn0;
	_ph_frames++;
	// 命中特效搬进子节点 ChartFxLayer（z=2）：音符实例化后是 _cp 的子节点，
	// 特效若还画在本节点自己的命令表里就会压在音符下面，与 player 的
	// 线 < 音符 < 特效 层序相反。
	if (_fxl != nullptr) _fxl->queue_redraw();
	// 浮空判定字/判定线逐判变色：用户裁定原版无此表现，不做（表现层以 player/PT 既有链路为准）
	if (S->_probe) S->_pb_frames++;
	_prof_draw_us += _prof_us() - _pt0;
	_prof_n++;
}

// phira 资源包的命中表现 = prpr 的 ParticleEmitter（resource.rs:309-350 + particle.rs:660-690），
// 与 PT 的 HitParticleLayer 是两套模型。用户："phira 打击粒子大小与范围不对"：
//   * 特效贴图 1 颗：半边长 = hitFxScale·note_scale/5 世界单位，随线转，颜色 = 判定色；
//   * 方块 4 颗：半边长 = hitFxScale·note_scale/44（±30%），方向全向，
//     初速 2.5·note_scale（±10%），速度按 v *= (1−6·dt) 衰减 ⇒ 位移 = v0·(1−e^{−6t})/6；
//   * 两者都活 hitFxDuration，alpha 曲线 1 → 0.7 → 0，rgb = colorPerfect/colorGood；
//   * 1 世界单位 = 0.4645·画布宽（由 prpr note_width=0.13175016 与 989/8080 对齐反推）。
void ChartPlayer::_draw_prpr_fx(CanvasItem *ci, ChartPlayer *S, const FX &fx,
		int cols, int rows, int total, int fw, int fh) {
	double age = S->_now - fx.t0;
	double life = S->_fx_duration;
	if (age < 0.0 || age >= life || total <= 0) return;
	double ageT = age / life;
	double fade = ageT < 0.5 ? 1.0 - 0.3 * (ageT / 0.5) : 0.7 * (1.0 - (ageT - 0.5) / 0.5);
	Color c0 = S->_c_perfect, c1 = S->_c_good;
	if (!S->_fx_tinted) { c0 = Color(1, 1, 1, 1); c1 = Color(1, 1, 1, 1); }
	Color base = fx.kind == 0 ? c0 : c1;
	if (fx.has_tint) base = Color(fx.tr, fx.tg, fx.tb, base.a);
	const double wpx = 0.4645 * (double)S->_cw;
	const double ns = S->_noteScale;
	// 特效贴图（prpr 把它当一颗无速度的粒子：rotation 恒等于线的角度）
	int fr = std::clamp((int)(ageT * total), 0, total - 1);
	Rect2 src((fr % cols) * fw, (fr / cols) * fh, fw, fh);
	double fsz = (S->_fx_scale * ns / 5.0) * wpx * S->_fxUserScale;
	Color tc(base.r, base.g, base.b, base.a * fade);
	ci->draw_set_transform(Vector2((float)fx.x, (float)fx.y), (float)fx.rot, Vector2(1, 1));
	ci->draw_texture_rect_region(S->_tex_fx, Rect2(-fsz, -fsz, fsz * 2.0, fsz * 2.0), src, tc);
	ci->draw_set_transform(Vector2(), 0.0f, Vector2(1, 1));
	if (S->_hide_particles) return;
	double dist = (1.0 - std::exp(-6.0 * age)) / 6.0 * wpx * S->_fxUserScale;
	for (int j = 0; j < 4; j++) {
		double r0 = fx.pd[j];
		double vf = 2.5 * ns * (1.0 - 0.1 * r0);
		double hs = (S->_fx_scale * ns / 44.0) * (1.0 - 0.3 * r0) * wpx * S->_fxUserScale;
		Vector2 c(fx.x + vf * dist * std::cos(fx.pa[j]), fx.y + vf * dist * std::sin(fx.pa[j]));
		Color pc(base.r, base.g, base.b, base.a * fade);
		ci->draw_rect(Rect2(c - Vector2((float)hs, (float)hs),
				Vector2((float)hs * 2.0f, (float)hs * 2.0f)), pc);
	}
}

// 命中特效层的全部绘制。原本内联在 _draw 末尾，音符搬进 MultiMesh 子节点后必须
// 独立成一个排在音符之后的子节点（见 _draw 里那条注释）。几何状态仍取主实例 S。
void ChartPlayer::draw_fx_into(CanvasItem *ci) {
	ChartPlayer *S = _src ? _src : this;
	if (!S->_loaded) return;
	Vector2 cs = Vector2(S->_cw, S->_ch);
	// 命中特效：帧表由资源包声明（phira info.yml 的 hitFx=[列,行]，元·菱简 5400×3240=10×6）。
	// 没声明才按内置那张 PT clickRaw（256 宽竖排 30 帧）自己数；时长=hitFxDuration（默认 0.5s），
	// 帧率 = 总帧数/时长，与 prpr 一致。
	if (S->_tex_fx.is_valid()) {
		int tw = S->_tex_fx->get_width(), th = S->_tex_fx->get_height();
		int cols, rows;
		if (S->_fx_cols > 0 && S->_fx_rows > 0) {
			cols = S->_fx_cols; rows = S->_fx_rows;
		} else {
			cols = std::max(1, tw / 256); rows = std::max(1, th / 256);
		}
		cols = std::clamp(cols, 1, std::max(1, tw));
		rows = std::clamp(rows, 1, std::max(1, th));
		int total = cols * rows;
		double fps = total / S->_fx_duration;
		int fw = std::max(1, tw / cols), fh = std::max(1, th / rows);
		double sc = (256.0 / fw) * (1.1 * cs.x / 1350.0) * S->_fx_scale * S->_fxUserScale;
		for (auto &fx : S->_fx) {
			if (!_depth_ok(fx.depth)) continue; // 命中特效桶路由
			if (S->_fx_prpr) {   // phira：两套模型，别混着算
				_draw_prpr_fx(ci, S, fx, cols, rows, total, fw, fh);
				continue;
			}
			int fr = (int)((S->_now - fx.t0) * fps);
			if (fr < 0 || fr >= total) continue;
			Rect2 src((fr % cols) * fw, (fr / cols) * fh, fw, fh);
			// 判定色：phira 用包里的 colorPerfect/colorGood（ARGB，alpha 也是它给的），
			// hitFxTinted=false 时 prpr 直接给 WHITE；谱面 tintHitEffects 优先级最高（player 语义）
			Color tc = fx.kind == 0 ? S->_c_perfect : S->_c_good;
			if (!S->_fx_tinted) tc = Color(1, 1, 1, 1);
			// player HitEffects.hit(tint)：setTint 只换 rgb，alpha 保持判定色语义
			if (fx.has_tint) tc = Color(fx.tr, fx.tg, fx.tb, tc.a);
			// hitFxRotate：绕特效中心转到生成那一帧的线角（prpr 的 FX 在 note matrix 里）
			const bool rot_on = S->_fx_rotate;
			if (rot_on) ci->draw_set_transform(Vector2((float)fx.x, (float)fx.y), (float)fx.rot, Vector2(1, 1));
			if (rot_on) {
				ci->draw_texture_rect_region(S->_tex_fx, Rect2(-fw * sc * 0.5, -fh * sc * 0.5, fw * sc, fh * sc), src, tc);
				ci->draw_set_transform(Vector2(), 0.0f, Vector2(1, 1));
			} else {
				ci->draw_texture_rect_region(S->_tex_fx, Rect2(fx.x - fw * sc * 0.5, fx.y - fh * sc * 0.5, fw * sc, fh * sc), src, tc);
			}
			// 判定粒子 = PT HitParticleLayer 原式（.tmp_charts/pz/HitEffects.ts）：
			//   生命期 600ms（:33 PARTICLE_LIFETIME，到点回收）；
			//   位置 = 800ms 时间轴上的 Quintic.easeOut：posT = 1−(1−age/0.8)^5（:136-138）；
			//   射程 = Math.random()×(scale×HIT_EFFECTS_PARTICLE_SPREAD_RANGE=400)（:62-66），
			//          scale 就是命中特效自身缩放 sc（spawn 传的是 this.scale）；
			//   缩放 = 0→1 用 300ms Cubic.easeOut、1→0 用 500ms Cubic.easeIn（:140-142）；
			//   半径 = _baseScale(=scale×HIT_EFFECTS_PARTICLE_SIZE=27)×√½ × 缩放（:110）；
			//   alpha = 1−(age/0.6)^3（:143）。
			// 原来这三处都不对：500ms 生命期、射程写成 185+rand·80 的圆环（既飞不远又留空洞）、
			// alpha 线性 —— 就是用户报的「判定粒子与 PT 的范围不一样」。
			double age = S->_now - fx.t0;
			if (!S->_hide_particles && age >= 0.0 && age < 0.6) {
				double t8 = age / 0.8;
				double posT = 1.0 - std::pow(1.0 - t8, 5.0);
				double sT = age < 0.3 ? 1.0 - std::pow(1.0 - age / 0.3, 3.0)
						: 1.0 - std::pow((age - 0.3) / 0.5, 3.0);
				sT = std::max(0.0, sT);
				double palpha = std::max(0.0, 1.0 - std::pow(age / 0.6, 3.0));
				double pr = sc * 27.0 * 0.70710678 * sT;
				Color pc = fx.kind == 0 ? Color(1.0, 236 / 255.0, 160 / 255.0, palpha)
										: Color(180 / 255.0, 225 / 255.0, 1.0, palpha);
				if (fx.has_tint) pc = Color(fx.tr, fx.tg, fx.tb, palpha); // 粒子同 tintHitEffects
				int np = fx.kind == 0 ? 4 : 3;
				double spread = sc * 400.0 * posT;
				// PT 官方包在 meta.json 里自带粒子绘制代码（hitEvtDrawer=ctx.fillRect(...,r3,r3)）
				// ⇒ 方块；内置与 prpr/phira 那套是圆。fillRect 的边长 r3 = 圆的直径基准
				// （pr = r3×√½），所以方块半宽 = pr×√½，两种形状视觉重量相当。
				const bool square = S->_fx_particle_shape == 1;
				const double hs = pr * 0.70710678;
				for (int j = 0; j < np; j++) {
					double ds = fx.pd[j] * spread;
					Vector2 c(fx.x + ds * std::cos(fx.pa[j]), fx.y + ds * std::sin(fx.pa[j]));
					if (square) ci->draw_rect(Rect2(c - Vector2(hs, hs), Vector2(hs * 2.0, hs * 2.0)), pc);
					else ci->draw_circle(c, pr, pc);
				}
			}
		}
	}
}

// ───────── 绑定 ─────────

void ChartPlayer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_chart_json", "bytes"), &ChartPlayer::load_chart_json);
	ClassDB::bind_method(D_METHOD("load_extra", "bytes"), &ChartPlayer::load_extra);
	ClassDB::bind_method(D_METHOD("get_effects", "sec"), &ChartPlayer::get_effects);
	ClassDB::bind_method(D_METHOD("set_state_source", "main"), &ChartPlayer::set_state_source);
	ClassDB::bind_method(D_METHOD("set_keep_depths", "depths"), &ChartPlayer::set_keep_depths);
	ClassDB::bind_method(D_METHOD("set_skip_depths", "depths"), &ChartPlayer::set_skip_depths);
	ClassDB::bind_method(D_METHOD("get_line_depths"), &ChartPlayer::get_line_depths);
	ClassDB::bind_method(D_METHOD("get_note_depths"), &ChartPlayer::get_note_depths);
	ClassDB::bind_method(D_METHOD("get_fx_depths"), &ChartPlayer::get_fx_depths);
	ClassDB::bind_method(D_METHOD("get_attachments"), &ChartPlayer::get_attachments);
	ClassDB::bind_method(D_METHOD("eval_events", "events", "sec"), &ChartPlayer::eval_events);
	ClassDB::bind_method(D_METHOD("beat_to_sec", "beat"), &ChartPlayer::beat_to_sec);
	ClassDB::bind_method(D_METHOD("debug_lines_drawn"), &ChartPlayer::debug_lines_drawn);
	ClassDB::bind_method(D_METHOD("debug_keep"), &ChartPlayer::debug_keep);
	ClassDB::bind_method(D_METHOD("debug_draw_counts"), &ChartPlayer::debug_draw_counts);
	ClassDB::bind_method(D_METHOD("debug_skip"), &ChartPlayer::debug_skip);
	ClassDB::bind_method(D_METHOD("get_line_state", "idx"), &ChartPlayer::get_line_state);
	ClassDB::bind_method(D_METHOD("set_now", "sec"), &ChartPlayer::set_now);
	ClassDB::bind_method(D_METHOD("reset_play_state"), &ChartPlayer::reset_play_state);
	ClassDB::bind_method(D_METHOD("set_scale", "canvas_w", "canvas_h"), &ChartPlayer::set_scale);
	ClassDB::bind_method(D_METHOD("touch_down", "id", "pos"), &ChartPlayer::touch_down);
	ClassDB::bind_method(D_METHOD("touch_move", "id", "pos"), &ChartPlayer::touch_move);
	ClassDB::bind_method(D_METHOD("touch_up", "id"), &ChartPlayer::touch_up);
	ClassDB::bind_method(D_METHOD("set_skin", "name", "tex"), &ChartPlayer::set_skin);
	ClassDB::bind_method(D_METHOD("set_pack_options", "opts"), &ChartPlayer::set_pack_options);
	ClassDB::bind_method(D_METHOD("get_pack_options"), &ChartPlayer::get_pack_options);
	ClassDB::bind_method(D_METHOD("get_judge_line_color"), &ChartPlayer::get_judge_line_color);
	ClassDB::bind_method(D_METHOD("set_block_cell", "px"), &ChartPlayer::set_block_cell);
	ClassDB::bind_method(D_METHOD("get_block_cell"), &ChartPlayer::get_block_cell);
	ClassDB::bind_method(D_METHOD("debug_block_phases_reset"), &ChartPlayer::debug_block_phases_reset);
	ClassDB::bind_method(D_METHOD("block_hover_active"), &ChartPlayer::block_hover_active);
	// QA/换包判据：把 13 个皮肤槽读回来，调用方才能证明"屏幕上真的是这个包"而不是自证
	ClassDB::bind_method(D_METHOD("get_skin_textures"), &ChartPlayer::get_skin_textures);
	ClassDB::bind_method(D_METHOD("set_hit_particle_shape", "kind"), &ChartPlayer::set_hit_particle_shape);
	ClassDB::bind_method(D_METHOD("get_hit_particle_shape"), &ChartPlayer::get_hit_particle_shape);
	ClassDB::bind_method(D_METHOD("set_line_texture", "name", "tex", "tintable", "frames", "fps"),
			&ChartPlayer::set_line_texture, DEFVAL(0), DEFVAL(0.0));
	ClassDB::bind_method(D_METHOD("set_line_tex_tint_mode", "mode"), &ChartPlayer::set_line_tex_tint_mode);
	ClassDB::bind_method(D_METHOD("get_line_tex_tint_mode"), &ChartPlayer::get_line_tex_tint_mode);
	ClassDB::bind_method(D_METHOD("get_line_textures"), &ChartPlayer::get_line_textures);
	ClassDB::bind_method(D_METHOD("get_meta_background"), &ChartPlayer::get_meta_background);
	ClassDB::bind_method(D_METHOD("set_fc_ap_indicator", "on"), &ChartPlayer::set_fc_ap_indicator);
	ClassDB::bind_method(D_METHOD("get_fc_ap_indicator"), &ChartPlayer::get_fc_ap_indicator);
	ClassDB::bind_method(D_METHOD("set_autoplay", "on"), &ChartPlayer::set_autoplay);
	ClassDB::bind_method(D_METHOD("set_judgment_windows", "perfect_ms", "good_ms"),
			&ChartPlayer::set_judgment_windows);
	ClassDB::bind_method(D_METHOD("get_judgment_windows"), &ChartPlayer::get_judgment_windows);
	ClassDB::bind_method(D_METHOD("set_chart_offset_ms", "ms"), &ChartPlayer::set_chart_offset_ms);
	ClassDB::bind_method(D_METHOD("get_chart_offset_ms"), &ChartPlayer::get_chart_offset_ms);
	ClassDB::bind_method(D_METHOD("set_multi_hint", "on"), &ChartPlayer::set_multi_hint);
	ClassDB::bind_method(D_METHOD("set_frame_cull", "on"), &ChartPlayer::set_frame_cull);
	ClassDB::bind_method(D_METHOD("get_frame_cull"), &ChartPlayer::get_frame_cull);
	ClassDB::bind_method(D_METHOD("get_multi_hint"), &ChartPlayer::get_multi_hint);
	ClassDB::bind_method(D_METHOD("set_note_scale", "v"), &ChartPlayer::set_note_scale);
	ClassDB::bind_method(D_METHOD("get_note_scale"), &ChartPlayer::get_note_scale);
	ClassDB::bind_method(D_METHOD("set_fx_user_scale", "v"), &ChartPlayer::set_fx_user_scale);
	ClassDB::bind_method(D_METHOD("get_fx_user_scale"), &ChartPlayer::get_fx_user_scale);
	ClassDB::bind_method(D_METHOD("get_delta_count"), &ChartPlayer::get_delta_count);
	ClassDB::bind_method(D_METHOD("get_avg_delta_ms"), &ChartPlayer::get_avg_delta_ms);
	ClassDB::bind_method(D_METHOD("get_std_dev_ms"), &ChartPlayer::get_std_dev_ms);
	ClassDB::bind_method(D_METHOD("get_autoplay"), &ChartPlayer::get_autoplay);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "fc_ap_indicator"), "set_fc_ap_indicator", "get_fc_ap_indicator");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "note_scale"), "set_note_scale", "get_note_scale");
	ClassDB::bind_method(D_METHOD("take_hits"), &ChartPlayer::take_hits);
	ClassDB::bind_method(D_METHOD("get_sound_events"), &ChartPlayer::get_sound_events);
	ClassDB::bind_method(D_METHOD("hit_count"), &ChartPlayer::hit_count);
	ClassDB::bind_method(D_METHOD("has_effects"), &ChartPlayer::has_effects);
	ClassDB::bind_method(D_METHOD("get_prof_draw_us"), &ChartPlayer::get_prof_draw_us);
	ClassDB::bind_method(D_METHOD("get_prof_set_us"), &ChartPlayer::get_prof_set_us);
	ClassDB::bind_method(D_METHOD("get_prof_n"), &ChartPlayer::get_prof_n);
	ClassDB::bind_method(D_METHOD("prof_reset"), &ChartPlayer::prof_reset);
	ClassDB::bind_static_method("ChartPlayer", D_METHOD("decode_flac", "bytes"), &ChartPlayer::decode_flac);
	ClassDB::bind_method(D_METHOD("set_note_multimesh", "on"), &ChartPlayer::set_note_multimesh);
	ClassDB::bind_method(D_METHOD("get_note_multimesh"), &ChartPlayer::get_note_multimesh);
	ClassDB::bind_method(D_METHOD("mm_debug_groups"), &ChartPlayer::mm_debug_groups);
	ClassDB::bind_method(D_METHOD("set_mm_record", "on"), &ChartPlayer::set_mm_record);
	ClassDB::bind_method(D_METHOD("probe_set", "on"), &ChartPlayer::probe_set);
	ClassDB::bind_method(D_METHOD("probe_report"), &ChartPlayer::probe_report);
	ClassDB::bind_method(D_METHOD("mem_report"), &ChartPlayer::mem_report);
	ClassDB::bind_method(D_METHOD("probe_reset"), &ChartPlayer::probe_reset);
	ClassDB::bind_method(D_METHOD("debug_line_state", "idx"), &ChartPlayer::debug_line_state);
	ClassDB::bind_method(D_METHOD("debug_hold_states", "tsec"), &ChartPlayer::debug_hold_states);
	ClassDB::bind_method(D_METHOD("debug_multi_counts"), &ChartPlayer::debug_multi_counts);
	ClassDB::bind_method(D_METHOD("debug_fx_count"), &ChartPlayer::debug_fx_count);
	ClassDB::bind_method(D_METHOD("blocked_touch_count"), &ChartPlayer::blocked_touch_count);
	ClassDB::bind_method(D_METHOD("debug_notes"), &ChartPlayer::debug_notes);
	ClassDB::bind_method(D_METHOD("debug_alpha_events", "idx"), &ChartPlayer::debug_alpha_events);
	ClassDB::bind_method(D_METHOD("debug_note_worlds", "tsec"), &ChartPlayer::debug_note_worlds);
	ClassDB::bind_method(D_METHOD("debug_overlay_notes"), &ChartPlayer::debug_overlay_notes);
	ClassDB::bind_method(D_METHOD("debug_overlay_lines"), &ChartPlayer::debug_overlay_lines);
	ClassDB::bind_method(D_METHOD("debug_drawn_notes", "tsec"), &ChartPlayer::debug_drawn_notes);
	ClassDB::bind_method(D_METHOD("has_blocks"), &ChartPlayer::has_blocks);
	ClassDB::bind_method(D_METHOD("get_block_quads"), &ChartPlayer::get_block_quads);
	ClassDB::bind_method(D_METHOD("block_hit", "pos"), &ChartPlayer::block_hit);
	ClassDB::bind_method(D_METHOD("debug_blocks", "music_sec"), &ChartPlayer::debug_blocks);
	ClassDB::bind_method(D_METHOD("set_block_noise", "rgba", "w", "h"), &ChartPlayer::set_block_noise);
	ClassDB::bind_method(D_METHOD("set_block_hover", "rgba", "w", "h"), &ChartPlayer::set_block_hover);
	ClassDB::bind_method(D_METHOD("debug_hover_at", "u", "v", "aspect"), &ChartPlayer::debug_hover_at);
	ClassDB::bind_method(D_METHOD("debug_touch_slots"), &ChartPlayer::debug_touch_slots);
	ClassDB::bind_method(D_METHOD("debug_block_phases"), &ChartPlayer::debug_block_phases);
	ClassDB::bind_method(D_METHOD("debug_force_blocked", "id", "on", "pos"), &ChartPlayer::debug_force_blocked);
	ClassDB::bind_method(D_METHOD("build_block_mask"), &ChartPlayer::build_block_mask);
	ClassDB::bind_method(D_METHOD("build_block_mask_layer", "li"), &ChartPlayer::build_block_mask_layer);
	ClassDB::bind_method(D_METHOD("build_block_mask_bits", "li"), &ChartPlayer::build_block_mask_bits);
	ClassDB::bind_method(D_METHOD("set_named_font", "name", "font"), &ChartPlayer::set_named_font);
	ClassDB::bind_method(D_METHOD("get_touches"), &ChartPlayer::get_touches);
	ClassDB::bind_method(D_METHOD("get_block_layers"), &ChartPlayer::get_block_layers);
	ClassDB::bind_method(D_METHOD("set_block_warp", "v"), &ChartPlayer::set_block_warp);
	ClassDB::bind_method(D_METHOD("get_block_warp"), &ChartPlayer::get_block_warp);
	ClassDB::bind_method(D_METHOD("get_perfect"), &ChartPlayer::get_perfect);
	ClassDB::bind_method(D_METHOD("get_good"), &ChartPlayer::get_good);
	ClassDB::bind_method(D_METHOD("get_good_early"), &ChartPlayer::get_good_early);
	ClassDB::bind_method(D_METHOD("get_good_late"), &ChartPlayer::get_good_late);
	ClassDB::bind_method(D_METHOD("get_bad"), &ChartPlayer::get_bad);
	ClassDB::bind_method(D_METHOD("get_miss"), &ChartPlayer::get_miss);
	ClassDB::bind_method(D_METHOD("get_combo"), &ChartPlayer::get_combo);
	ClassDB::bind_method(D_METHOD("get_max_combo"), &ChartPlayer::get_max_combo);
	ClassDB::bind_method(D_METHOD("get_total_notes"), &ChartPlayer::get_total_notes);
	ClassDB::bind_method(D_METHOD("get_score"), &ChartPlayer::get_score);
	ClassDB::bind_method(D_METHOD("get_accuracy"), &ChartPlayer::get_accuracy);
	ClassDB::bind_method(D_METHOD("get_song_name"), &ChartPlayer::get_song_name);
	ClassDB::bind_method(D_METHOD("get_level"), &ChartPlayer::get_level);
	ClassDB::bind_method(D_METHOD("get_duration"), &ChartPlayer::get_duration);
}
