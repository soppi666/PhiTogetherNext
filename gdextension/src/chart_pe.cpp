// PhiEditer .pe 文本谱面解析（PZ 老谱）——单位换算/事件补齐语义按 player
// converters/phiediter 的事实实现（非抄码）。首行 = 偏移(ms)，META.offset = v-175。
//
// 全程在**字节上**扫，一行都不构造 Godot String。真因是用户那张 357MB / 1093 万行的
// .pe 谱：原先 txt.split("\n") + 每行 replace/strip_edges/split(" ") 光解析就 24 秒，
// 还瞬时多占 ~1.5GB（Godot String 是 4 字节/字符，1093 万个 String 就是那么多）。
// 现在是两遍字节扫：第一遍只为按线 reserve，第二遍建表。
#include "chart_player.h"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>

using namespace godot;

namespace {
// 一行 = 空格分隔的 token，PE 最多用到 7 段（cm: 命令 id start end x y ease）。
// token 只记指针+长度、不复制；数值用局部 NUL 结尾小缓冲走 strtod。
struct PeLine {
	const char *tk[10];
	short tl[10];
	int n = 0;
	void add(const char *b, int len) {
		if (n >= 10) return;
		tk[n] = b; tl[n] = (short)len; n++;
	}
	int size() const { return n; }
	double num(int i, double dfl = 0.0) const {
		if (i >= n || tl[i] <= 0) return dfl;
		char tmp[40];
		int L = tl[i];
		if (L >= (int)sizeof(tmp)) return dfl;
		std::memcpy(tmp, tk[i], (size_t)L);
		tmp[L] = 0;
		char *end = nullptr;
		double v = std::strtod(tmp, &end);
		return end == tmp ? dfl : v;
	}
	int inum(int i) const { return (int)num(i); }
};

// 逐行回调 [b,e)：剥行尾 \r、跳过空行；前 skip_first 行不回调（首行=偏移）
template <class F>
static void _pe_each_line(const char *p, size_t len, F &&cb, size_t skip_first) {
	size_t i = 0, seen = 0;
	while (i < len) {
		size_t j = i;
		while (j < len && p[j] != '\n') j++;
		size_t e = j;
		if (e > i && p[e - 1] == '\r') e--;
		if (seen >= skip_first && e > i) cb(p + i, e - i);
		i = j + 1;
		seen++;
	}
}

// 切 token：跳前导空白、不产空 token —— 与 String::split(" ", false)（allow_empty=false）同语义
static void _pe_tokenize(const char *b, size_t len, PeLine &out) {
	out.n = 0;
	size_t i = 0;
	while (i < len) {
		while (i < len && (b[i] == ' ' || b[i] == '\t')) i++;
		size_t s = i;
		while (i < len && b[i] != ' ' && b[i] != '\t') i++;
		if (i > s) out.add(b + s, (int)(i - s));
	}
}

// 命令名比对（PE 的命令是 1~2 字符）
static bool _pe_is(const PeLine &l, const char *op) {
	if (l.n < 1) return false;
	size_t k = std::strlen(op);
	return (size_t)l.tl[0] == k && std::memcmp(l.tk[0], op, k) == 0;
}

// 拍号 "bar,分,母"。与旧 String 版 _pe_beat 逐支等价：split(",", false) 丢空段，
// 只有满 3 段才折小节拍，否则取**首段**（旧代码就是 a[0].to_float()）。
// 所以 "1,2" 这种残段仍旧是 1，绝不会算成 3。
static double _pe_beat(const PeLine &l, int idx) {
	if (idx >= l.n || l.tl[idx] <= 0) return 0.0;
	const char *b = l.tk[idx];
	int len = l.tl[idx];
	int seg_s[3], seg_e[3], ns = 0;
	int s = 0;
	for (int i = 0; i <= len; i++) {
		if (i == len || b[i] == ',') {
			if (i > s && ns < 3) { seg_s[ns] = s; seg_e[ns] = i; ns++; }
			s = i + 1;
		}
	}
	if (ns == 0) return 0.0;
	char tmp[40];
	auto part = [&](int a, int e) -> double {
		int L = e - a;
		if (L <= 0 || L >= (int)sizeof(tmp)) return 0.0;
		std::memcpy(tmp, b + a, (size_t)L);
		tmp[L] = 0;
		char *end = nullptr;
		double v = std::strtod(tmp, &end);
		return end == tmp ? 0.0 : v;
	};
	if (ns >= 3)
		return part(seg_s[0], seg_e[0]) + part(seg_s[1], seg_e[1]) / std::max(1.0, part(seg_s[2], seg_e[2]));
	return part(seg_s[0], seg_e[0]);
}

struct PeEv {
	double b1 = 0, b2 = -1, v0 = 0, v1 = 0;
	int ease = 1;
	bool nan0 = false; // 时长事件缺起始值：start = 上一事件 end（默认值兜底）
	bool instant = false; // cp/cd/ca/cv：player 里 endBeat=NaN → 由下一事件起点延续；cm/cr/cf 保持自身 end
};
struct PeNote {
	double b1 = 0, b2 = 0, x = 0, spd = 1, sz = 1;
	int type = 1, above = 1;
	bool fake = false;
};
struct Acc {
	std::vector<PeEv> alpha, mx, my, rot, speed;
	std::vector<PeNote> notes;
};
} // namespace

bool ChartPlayer::load_pe_bytes(const uint8_t *data, size_t len) {
	_official_fmt = false; // .pe 走 RPE 语义（藏线留音符合法）
	_lines.clear();
	_blocks.clear(); // .pe 没有噪域
	_fx.clear();
	_hitq.clear();
	_total_notes = 0;
	_perfect = _good = _bad = _miss = _combo = _max_combo = 0;
	_duration = 0;
	_name = "";
	_level = "";
	const char *p = (const char *)data;
	if (len < 4) return false;

	// 首行 = 偏移(ms)：player phiediter converter 固定减 175
	{
		size_t i = 0;
		while (i < len && (p[i] == ' ' || p[i] == '\t')) i++;
		size_t j = i;
		while (j < len && p[j] != '\n' && p[j] != '\r') j++;
		char tmp[32];
		size_t L = j - i;
		if (L == 0 || L >= sizeof(tmp)) return false;
		std::memcpy(tmp, p + i, L);
		tmp[L] = 0;
		char *end = nullptr;
		double v = std::strtod(tmp, &end);
		if (end == tmp) return false;
		_offset = (v - 175.0) / 1000.0;
	}

	// 第一遍只数「每线几条音符」，用来 reserve：1093 万条 push_back 挤在同一条线上时，
	// std::vector 的几何扩容要把 ~2.8GB 来回搬十几遍——那是加载耗时和内存峰值的大头。
	std::map<int, int> cnt;
	_pe_each_line(p, len, [&](const char *b, size_t n) {
		size_t k = 0;
		while (k < n && (b[k] == ' ' || b[k] == '\t')) k++;
		if (!(n - k >= 2 && b[k] == 'n' && b[k + 1] >= '1' && b[k + 1] <= '4'
				&& (n - k == 2 || b[k + 2] == ' ' || b[k + 2] == '\t'))) return;
		PeLine l;
		_pe_tokenize(b + k, n - k, l);
		if (l.size() >= 5) cnt[l.inum(1)]++;
	}, 1);
	std::map<int, Acc> acc;
	for (auto &kv : cnt) acc[kv.first].notes.reserve((size_t)kv.second);

	std::vector<std::pair<double, double>> bpms;
	bpms.reserve(64);
	std::pair<int, size_t> last_note = { -1, 0 }; // '#'/'&' 作用于全局最后推入的音符
	_pe_each_line(p, len, [&](const char *b, size_t n) {
		PeLine l;
		_pe_tokenize(b, n, l);
		if (l.n < 1) return;
		if (_pe_is(l, "bp") && l.size() >= 3) {
			bpms.push_back({ _pe_beat(l, 1), l.num(2) });
		} else if ((_pe_is(l, "n1") || _pe_is(l, "n3") || _pe_is(l, "n4")) && l.size() >= 5) {
			int id = l.inum(1);
			PeNote pn;
			pn.b1 = _pe_beat(l, 2);
			pn.b2 = pn.b1;
			pn.x = l.num(3) / 1024.0 * 675.0;
			pn.above = l.inum(4) == 1 ? 1 : 0;
			pn.fake = l.size() > 5 && l.inum(5) != 0;
			pn.type = _pe_is(l, "n1") ? 1 : (_pe_is(l, "n3") ? 3 : 4);
			last_note = { id, acc[id].notes.size() };
			acc[id].notes.push_back(pn);
		} else if (_pe_is(l, "n2") && l.size() >= 6) {
			int id = l.inum(1);
			PeNote pn;
			pn.b1 = _pe_beat(l, 2);
			pn.b2 = _pe_beat(l, 3);
			pn.x = l.num(4) / 1024.0 * 675.0;
			pn.above = l.inum(5) == 1 ? 1 : 0;
			pn.fake = l.size() > 6 && l.inum(6) != 0;
			pn.type = 2;
			last_note = { id, acc[id].notes.size() };
			acc[id].notes.push_back(pn);
		} else if (_pe_is(l, "#") && l.size() >= 2 && last_note.first >= 0) {
			acc[last_note.first].notes[last_note.second].spd = std::max(0.0001, l.num(1));
		} else if (_pe_is(l, "&") && l.size() >= 2 && last_note.first >= 0) {
			acc[last_note.first].notes[last_note.second].sz = std::max(0.0001, l.num(1));
		} else if (_pe_is(l, "cv") && l.size() >= 4) {
			PeEv e;
			e.b1 = _pe_beat(l, 2);
			e.b2 = e.b1;
			e.instant = true;
			e.v0 = e.v1 = l.num(3) * 9.0 / 14.0;
			acc[l.inum(1)].speed.push_back(e);
		} else if (_pe_is(l, "cm") && l.size() >= 7) {
			Acc &a = acc[l.inum(1)];
			PeEv ex, ey;
			ex.b1 = ey.b1 = _pe_beat(l, 2);
			ex.b2 = ey.b2 = _pe_beat(l, 3);
			ex.v1 = (l.num(4) / 2048.0 - 0.5) * 1350.0;
			ey.v1 = (l.num(5) / 1400.0 - 0.5) * 900.0;
			ex.nan0 = ey.nan0 = true;
			ex.ease = ey.ease = l.inum(6);
			a.mx.push_back(ex);
			a.my.push_back(ey);
		} else if (_pe_is(l, "cp") && l.size() >= 5) {
			Acc &a = acc[l.inum(1)];
			PeEv ex, ey;
			ex.b1 = ex.b2 = ey.b1 = ey.b2 = _pe_beat(l, 2);
			ex.instant = ey.instant = true;
			ex.v0 = ex.v1 = (l.num(3) / 2048.0 - 0.5) * 1350.0;
			ey.v0 = ey.v1 = (l.num(4) / 1400.0 - 0.5) * 900.0;
			a.mx.push_back(ex);
			a.my.push_back(ey);
		} else if (_pe_is(l, "cr") && l.size() >= 6) {
			Acc &a = acc[l.inum(1)];
			PeEv e;
			e.b1 = _pe_beat(l, 2);
			e.b2 = _pe_beat(l, 3);
			e.v1 = l.num(4);
			e.nan0 = true;
			e.ease = l.inum(5);
			a.rot.push_back(e);
		} else if (_pe_is(l, "cd") && l.size() >= 4) {
			Acc &a = acc[l.inum(1)];
			PeEv e;
			e.b1 = e.b2 = _pe_beat(l, 2);
			e.instant = true;
			e.v0 = e.v1 = l.num(3);
			a.rot.push_back(e);
		} else if (_pe_is(l, "cf") && l.size() >= 5) { // cf line start end value ——共 5 段，无 easing
			Acc &a = acc[l.inum(1)];
			PeEv e;
			e.b1 = _pe_beat(l, 2);
			e.b2 = _pe_beat(l, 3);
			e.v1 = l.num(4);
			e.nan0 = true;
			a.alpha.push_back(e);
		} else if (_pe_is(l, "ca") && l.size() >= 4) {
			Acc &a = acc[l.inum(1)];
			PeEv e;
			e.b1 = e.b2 = _pe_beat(l, 2);
			e.instant = true;
			e.v0 = e.v1 = l.num(3);
			a.alpha.push_back(e);
		}
	}, 1);
	if (bpms.empty()) bpms.push_back({ 0, 120 });
	std::sort(bpms.begin(), bpms.end());
	_bpm_n = (int)bpms.size();
	_bpm_beats.assign(_bpm_n, 0);
	_bpm_times.assign(_bpm_n, 0);
	_bpm_bps.assign(_bpm_n, 0);
	for (int i = 0; i < _bpm_n; i++) {
		_bpm_beats[i] = bpms[i].first;
		_bpm_bps[i] = std::max(0.0001, bpms[i].second / 60.0);
		_bpm_times[i] = i == 0 ? 0.0
			: _bpm_times[i - 1] + (bpms[i].first - bpms[i - 1].first) / std::max(0.0001, bpms[i - 1].second / 60.0);
	}

	for (auto &kv : acc) {
		Acc &a = kv.second;
		Line l;
		l.cover = true; // player pushEventToLine 建线默认 isCover: 1——过线音符即隐
		Layer L;
		auto cvt = [&](std::vector<PeEv> &src, std::vector<Event> &dst, double defv) {
			// 稳定排序：PE 的 ca/cf、cp/cm 常在同一拍成对出现，player 的 sortEvent（V8 稳定）
			// 保留文件顺序；非稳定序会让游标/tie 后 v0 继承落到错误事件上（线忽隐忽现）
			std::stable_sort(src.begin(), src.end(), [](const PeEv &x, const PeEv &y) { return x.b1 < y.b1; });
			dst.reserve(src.size());
			for (size_t i = 0; i < src.size(); i++) {
				Event e;
				double b1 = src[i].b1;
				double b2 = src[i].b2 < 0 ? b1 : src[i].b2;
				// player parseLineEvents：endBeat=NaN（瞬时/cv）→ 下一事件起点，最后一条到 9999；
				// cm/cr/cf 有显式 end——绝不外延，否则缓动到达时刻被拉长（线移动"慢半拍"）
				if (src[i].instant)
					b2 = (i + 1 < src.size()) ? std::max(b2, src[i + 1].b1) : std::max(b2, 9999.0);
				e.s = _b2s(b1);
				e.t = _b2s(b2);
				e.bS = b1;
				e.bT = b2;
				e.v1 = src[i].v1;
				e.v0 = src[i].nan0 ? (i ? src[i - 1].v1 : defv) : src[i].v0;
				e.ease = src[i].ease <= 1 ? 1 : src[i].ease;
				dst.push_back(e);
			}
			std::stable_sort(dst.begin(), dst.end(), [](const Event &x, const Event &y) { return x.s < y.s; });
		};
		cvt(a.alpha, L.alpha, 255);
		cvt(a.mx, L.mx, 0);
		cvt(a.my, L.my, 0);
		cvt(a.rot, L.rot, 0);
		cvt(a.speed, L.speed, 0);
		l.layers.push_back(std::move(L));
		// 先排**小的**：PeNote 48B/条，排序临时缓冲最多几十 MB；而 Note 有 304B，
		// std::stable_sort 要按区间大小再要一份缓冲——1093 万条就是 3.3GB，
		// 实测加载峰值 5.8GB / 稳态 3.6GB 的差额几乎全是它。排完 b1 再顺序转换，
		// 大数组一次成型、永不重排（b1→t 是单调映射，tie 保持文件序=原语义）。
		std::stable_sort(a.notes.begin(), a.notes.end(),
				[](const PeNote &x, const PeNote &y) { return x.b1 < y.b1; });
		l.notes.reserve(a.notes.size());
		for (auto &pn : a.notes) {
			Note n;
			n.t = _b2s(pn.b1);
			n.t2 = std::max(n.t, _b2s(std::max(pn.b1, pn.b2)));
			n.x = pn.x;
			n.type = pn.type;
			n.speed = pn.spd;
			n.size = pn.sz;
			n.above = pn.above;
			n.fake = pn.fake;
			n.jsize = pn.sz; // player PE 转换器：judgeSize = '&' 值
			_duration = std::max(_duration, n.t2);
			if (!n.fake) _total_notes++;
			l.notes.push_back(n);
		}
		// 这份 525MB 的中间表到这儿就没用了，当场还给系统（map 会活到函数结尾，
		// 不清的话它和 3.3GB 的音符表同时在峰值里）
		std::vector<PeNote>().swap(a.notes);
		l.cur_h.assign(l.layers.size() + 1, 0);
		l.cur_i.assign(l.layers.size() + 1, 0);
		_lines.push_back(std::move(l));
	}

	// 负 alpha 编码可见时间——逐步对齐 player phiediter converter 的 advanced-alpha 语义：
	// 用事件在音符时刻的插值 currentValue 折 visibleBeat=-(v+100)/10 拍；
	// 拍→秒：单 bpm 直接 beat*60/bpm；多 bpm 仅当音符恰在 bpm 分段点上才生效，否则 9999999（不限可见）。
	// 遇 currentValue>=-100 或 0 即 break；事件值随后归 0/-1。
	for (auto &l : _lines) {
		for (auto &L : l.layers) {
			for (auto &e : L.alpha) {
				bool has = false;
				if (e.v0 < -100 && e.v0 >= -1000) {
					for (auto &n : l.notes) { // 已按 t 升序
						if (n.t < e.s) continue;
						if (n.t > e.t) break;
						double cur = _event_value(e, n.t);
						if (cur == 0.0 || cur >= -100) break;
						double vis_beat = -(cur + 100.0) / 10.0;
						double nb = _s2b(n.t);
						double secs = 9999999.0;
						if (_bpm_n == 1) {
							secs = vis_beat / std::max(0.0001, _bpm_bps[0]);
						} else {
							for (int i = 0; i < _bpm_n; i++) {
								double d = _bpm_beats[i] - nb;
								if (d < -1e-6) continue;
								if (d > 1e-6) break;
								secs = vis_beat / std::max(0.0001, _bpm_bps[i]);
								break;
							}
						}
						n.vtime = secs;
						has = true;
					}
					e.v0 = has ? 0 : -1;
				} else if (e.v1 < -1000) {
					e.v0 = 0; // player 原样（其分支写的是 event.start）
				}
				if (e.v1 < -100 && e.v1 >= -1000) e.v1 = has ? 0 : -1;
				else if (e.v1 < -1000) e.v0 = 0;
			}
		}
	}
	_finalize();
	return true;
}
