// 噪域（blockArea）掩码构建 —— CPU 复刻 Phira-Pro 的 prpr `src/core/block_mask.rs`。
//
// 为什么在 CPU：官方效果是「1/4 屏效果网格 → 位移 warp 取邻居纹素 → 9 邻域逐级膨胀出
// EdgeMask/GlowMask 环」。膨胀是迭代过程（每环基于上一环），单趟 shader 做不了；warp 又要在
// 每步保留 binary16 舍入（差一个 ulp，格边界 floor 就会翻到别的纹素 → 边缘逐帧乱闪）。
// 网格只有 ~336×224，逐帧算完上传一张 RGBA8 纹理，比多趟全屏 pass 便宜得多。
//
// 输出通道语义（与 prpr 上传的 uMasks/uAuxMasks 一致）：
//   masks.R = 位移后的 Active 合成掩码（普通 或 XOR 减算阈值窗）
//   masks.G = EdgeMask（外扩 1 环，二值 255）
//   masks.B = GlowMask（再外扩环，权重 (6−k)^2.65/Σ）
//   masks.A = Disabled 合成掩码（不受 warp 影响，逐帧静止）
//   aux.R/G = 仅 Ready 层的普通/减算、aux.B = 同一个 disabled、aux.A = hover（未实现，恒 0）
#include "chart_player.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <cstring>

using namespace godot;

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static double clampd2(double v, double a, double b) { return v < a ? a : (v > b ? b : v); }

static unsigned char bm_unorm(double v) {
	return (unsigned char)std::lround(clampd2(v, 0.0, 1.0) * 255.0);
}

/// binary16 舍入（10 位尾数、ties-to-even）——prpr medium() 的同款位运算
static float bm_medium(float value) {
	uint32_t bits;
	std::memcpy(&bits, &value, 4);
	bits = (bits + 0xfff + ((bits >> 13) & 1u)) & ~0x1fffu;
	float out;
	std::memcpy(&out, &bits, 4);
	return out;
}

/// Mirror 包裹的一维折叠（prpr noise_index 的 rem_euclid(2) + >1 折回）
static double bm_fold(double v) {
	v = std::fmod(v, 2.0);
	if (v < 0.0) v += 2.0;
	return v > 1.0 ? 2.0 - v : v;
}

static int bm_index(double v, int size) {
	return (int)std::floor(bm_fold(v) * size);
}

/// ring 位图里最低置位位的下标（MSVC 没有 __builtin_ctzll）
static int bm_ctz(uint64_t v) {
	int n = 0;
	while ((v & 1u) == 0) {
		v >>= 1;
		n++;
	}
	return n;
}

/// 空帧也要把"配色/line2area"两个开关交出去，否则上一帧的 uColored=1 会挂在材质上，
/// 而两张调色板纹理还是旧尺寸 ⇒ shader 采到越界纹素（Godot 采样器越界钳边=一条纯色带）。
static void bm_push_colors(Array &out, bool colored, bool any_rpe) {
	out.push_back(PackedByteArray());
	out.push_back(PackedByteArray());
	out.push_back(colored ? 1 : 0);
	out.push_back(any_rpe ? 1 : 0);
}

void ChartPlayer::set_block_noise(PackedByteArray rgba, int w, int h) {
	_blk_nw = w > 0 ? w : 0;
	_blk_nh = h > 0 ? h : 0;
	_blk_noise.assign((size_t)std::max(0, _blk_nw * _blk_nh), 0);
	const int total = std::max(0, _blk_nw * _blk_nh);
	const int have = std::min((int)rgba.size() / 4, total);
	for (int i = 0; i < have; i++) {
		const int x = i % _blk_nw, y = i / _blk_nw;
		// prpr 上传前 flip_vertical（GL 纹素原点在左下）；这里等价地把行序翻回来
		_blk_noise[(size_t)i] = rgba[(size_t)((h - 1 - y) * _blk_nw + x) * 4];
	}
}

double ChartPlayer::bm_noise(double u, double v) const {
	if (_blk_nw <= 0 || _blk_nh <= 0) return 0.0;
	int x = std::min(std::max(bm_index(u, _blk_nw), 0), _blk_nw - 1);
	int y = std::min(std::max(bm_index(v, _blk_nh), 0), _blk_nh - 1);
	return _blk_noise[(size_t)y * _blk_nw + x] / 255.0;
}

// ── 旋转矩形逐行扫描（prpr raster_rows 原式）──
// field UV：x∈[-1,1] → 列 [0,width]；y·aspect∈[-1,1] → 行 [0,height]
// ys≠1 是 RPE 标记线（Line2Area）：**旋转发生在纵向拉伸之前**，所以行高范围乘 ys、
// 而行内的 dy 先除以 ys 回到"画布系"再解 slab（prpr block_mask.rs:688/694）。
template <typename Fn>
static void bm_raster_rows(int width, int height, double aspect, const ChartPlayer::Block &z, Fn &&write) {
	if (z.hhx <= 0. || z.hhy <= 0.) return;
	const double rad = z.rot_ccw * M_PI / 180.0;
	const double s = std::sin(rad), c = std::cos(rad);
	const double y_half = (std::fabs(s) * z.hhx + std::fabs(c) * z.hhy) * z.ys;
	const double row0 = std::ceil(clampd2((z.ccy - y_half) * aspect + 1.0, -1e9, 1e9) * height * 0.5 - 0.5);
	const double row1 = std::floor(clampd2((z.ccy + y_half) * aspect + 1.0, -1e9, 1e9) * height * 0.5 - 0.5) + 1.0;
	const int start = (int)clampd2(row0, 0.0, height);
	const int end = (int)clampd2(row1, 0.0, height);
	for (int y = start; y < end; y++) {
		const double dy = (((y + 0.5) * 2.0 / height - 1.0) / aspect - z.ccy) / z.ys;
		double lo = -1.0, hi = 1.0;
		const double slab[2][3] = { { c, s * dy, z.hhx }, { -s, c * dy, z.hhy } };
		bool empty = false;
		for (int k = 0; k < 2; k++) {
			const double a = slab[k][0], b = slab[k][1], half = slab[k][2];
			if (std::fabs(a) < 1e-7) {
				if (std::fabs(b) > half) {
					empty = true;
					break;
				}
				continue;
			}
			const double a0 = (-half - b) / a + z.ccx;
			const double a1 = (half - b) / a + z.ccx;
			lo = std::max(lo, std::min(a0, a1));
			hi = std::min(hi, std::max(a0, a1));
		}
		if (empty || lo > hi) continue;
		const double col0 = std::ceil(clampd2((lo + 1.0) * 0.5 * width - 0.5, 0.0, width));
		const double col1 = std::floor(clampd2((hi + 1.0) * 0.5 * width - 0.5, -1e9, 1e9)) + 1.0;
		const int first = (int)col0;
		const int last = (int)clampd2(col1, 0.0, width);
		if (first < last) write(y, first, last);
	}
}

/// 官方 SubtractBlockBlender pass0：阈值窗而非奇偶（每个减算 sprite alpha=0.1，
/// R8 量化后恰好"只有 1 层减算"落进 [0.09,0.12) 才生效）
static double bm_sub_enabled(unsigned char red, bool ignore_triple = false) {
	const double r = red / 255.0;
	if (ignore_triple) return r > 0.04 ? 1.0 : 0.0; // 任意层数重叠都算反置（忽略第三层抵消）
	return (r >= 0.09 && r < 0.12) ? 1.0 : 0.0;
}

static void bm_sub_disabled(unsigned char red, unsigned char green, double &out_r, double &out_g, bool ignore_triple = false) {
	const double g = green / 255.0;
	const double t = clampd2((g - 0.2) * -10.0, 0.0, 1.0);
	// 官方 r 可以是 2（阈值窗命中 1 + smoothstep 1），**不能提前钳到 1**：prpr 的单测
	// initial_subtract_show_fades_green_while_alpha_stays_point_one 期望
	// rawg=6、L3=26 ⇒ rgba.a = 120；提前钳会算成 60（= 预警暗一半）。unorm() 才是钳位处。
	const double r = bm_sub_enabled(red, ignore_triple) + t * t * (3.0 - 2.0 * t);
	out_r = bm_unorm(r) / 255.0;
	out_g = bm_unorm(g * r * 10.0) / 255.0;
}

/// prpr Masks::color_source —— 原生减算之后"谁还看得见"，只有它贡献颜色。
/// 覆盖相等 = 洞，不是颜色种子（否则被抵消的框会把色渗进别人的边/辉光）。
/// 返回 -1 无主、0 普通侧胜出、1 减算侧胜出。
static int bm_color_source(const unsigned char *layers, const unsigned char *rawg,
		size_t n, int layer, size_t i, bool ignore_triple = false) {
	const unsigned char normal = layers[(size_t)layer * 2 * n + i];
	const unsigned char subtract = layers[((size_t)layer * 2 + 1) * n + i];
	int inverse;
	if (layer == 0) {
		inverse = (subtract >= 23 && subtract <= 30) ? 255 : 0; // 官方阈值窗（0.09..0.12）
	} else {
		double r, g;
		bm_sub_disabled(subtract, rawg[i], r, g, ignore_triple);
		inverse = (int)bm_unorm(r * g);
	}
	if (normal == inverse) return -1;
	return normal < inverse ? 1 : 0;
}

Array ChartPlayer::build_block_mask() {
	std::vector<const Block *> list;
	list.reserve(_blocks.size());
	for (const Block &b : _blocks) list.push_back(&b);
	return _build_block_mask_impl(list, _bmb);
}

Array ChartPlayer::build_block_mask_layer(int li) {
	if (li < 0 || li >= (int)_block_layers.size() || _block_layers.size() <= 1) return build_block_mask();
	if ((int)_bml.size() != (int)_block_layers.size()) _bml.resize(_block_layers.size());
	std::vector<const Block *> list;
	for (const Block &b : _blocks)
		if (b.layer == li) list.push_back(&b);
	return _build_block_mask_impl(list, _bml[li]);
}

// 噪域皮肤协议（rpe-next noise-skin-renderer geometryMask）：
// blockMask 是 R8，每像素 6 个 bit：0=Active 普通 1=Active 倒置 2=非Active 普通
// 3=非Active 倒置 4=ready 普通 5=ready 倒置。这里从六层栅格直接打包（>0 即覆盖）。
Array ChartPlayer::build_block_mask_bits(int li) {
	build_block_mask_layer(li); // 确保本层栅格是当帧
	BlockMaskBuf &m = (li < 0 || _block_layers.size() <= 1 || li >= (int)_bml.size()) ? _bmb : _bml[li];
	if (m.bw <= 0 || m.bh <= 0 || m.l.size() < (size_t)m.bw * m.bh * 6) return Array();
	const size_t n = (size_t)m.bw * m.bh;
	PackedByteArray out;
	out.resize((int)(n * 4));
	unsigned char *o = out.ptrw();
	for (size_t i = 0; i < n; i++) {
		unsigned char v = 0;
		for (int b = 0; b < 6; b++)
			if (m.l[(size_t)b * n + i] > 0) v |= (unsigned char)(1 << b);
		o[i * 4 + 0] = v;
		o[i * 4 + 1] = 0;
		o[i * 4 + 2] = 0;
		o[i * 4 + 3] = 255;
	}
	Array r;
	r.push_back(m.bw);
	r.push_back(m.bh);
	r.push_back(out);
	return r;
}

Array ChartPlayer::get_block_layers() const {
	Array out;
	for (const BlockLayer &l : _block_layers) {
		Dictionary d;
		d["id"] = l.id;
		d["name"] = l.name;
		d["skin"] = l.skin;
		d["channel"] = l.channel;
		d["parameters"] = l.params;
		out.push_back(d);
	}
	if (out.is_empty()) {
		Dictionary d;
		d["id"] = "default"; d["name"] = "默认层"; d["skin"] = ""; d["channel"] = "normal"; d["parameters"] = Dictionary();
		out.push_back(d);
	}
	return out;
}

Array ChartPlayer::_build_block_mask_impl(const std::vector<const Block *> &list, BlockMaskBuf &m) {
	// 网格密度由 _blk_cell 定（默认 4 画布 px = 原来的 (cw/8)*2）。
	// 成本≈网格面积 × 可见区数，2560 宽下 109 区就是 28M 次混合 ≈ 9ms。
	const int bw = std::max(1, (int)std::round(_cw / _blk_cell));
	const int bh = std::max(1, (int)std::round(_ch / _blk_cell));
	const double aspect = _cw / std::max(_ch, 1.0);
	// 分阶段计时：只累计真的走完构建的帧（早退帧不计数，否则被 60% 的空帧稀释）
	double ph_t = now_us();
	auto ph = [this, &ph_t](int i) { const double t = now_us(); _blk_ph[i] += t - ph_t; ph_t = t; };
	const size_t n = (size_t)bw * bh;
	if (m.bw != bw || m.bh != bh) {
		m.bw = bw;
		m.bh = bh;
		m.l.assign(6 * n, 0);
		m.rawg.assign(n, 0);
		m.readyg.assign(n, 0);
		m.compose.assign(n, 0);
		m.disabled.assign(n, 0);
		m.rgba.assign(n * 4, 0);
		m.aux.assign(n * 4, 0);
		m.d0.assign((size_t)(bw + 1) * bh, 0);
		m.d1.assign((size_t)(bw + 1) * bh, 0);
		m.empty_last = false;   // 网格变了 ⇒ 即使"全空"也要重传一次
		m.lay_valid = false;      // 网格变了 ⇒ 六层缓冲全被重分配，签名对应的内存不再是那一版
	}
	// 触摸 hover：状态机每帧都要推进（哪怕这帧没有可见噪域，消失动画也得继续）
	_bts_update(_now);
	m.hw = std::max(1, bw / 2);
	m.hh = std::max(1, bh / 2);
	m.hover.assign((size_t)m.hw * m.hh, 0);
	m.hover_any = false;
	for (const auto &s : _bts)
		if (s.scale > 0.0) { m.hover_any = true; break; }
	if (m.hover_any) {
		for (int gy = 0; gy < m.hh; gy++) {
			const double v = (gy + 0.5) / m.hh;
			for (int gx = 0; gx < m.hw; gx++)
				m.hover[(size_t)gy * m.hw + gx] = _hover_at((gx + 0.5) / m.hw, v, aspect);
		}
	}
	ph(0);
	// ───────── 行段签名：几何没跨过像素边界 ⇒ 下面三段整段跳过 ─────────
	// 方向取自 prpr 的 Masks::render_displaced（`last_zones == zones` 命中就不重铺栅格），
	// 但判据换成栅格的**输出**：每区逐行的 [first,last) 行段。实测用浮点几何当签名，
	// ハテ AT 上 240 帧只命中 1 帧——move/rotate 每帧都在插值；而 1/120s 里绝大多数帧的
	// 行段根本没变。行段一致 ⇒ 六层与两张行差分数组逐字节一致 ⇒ 合成/disabled 一致。
	// 代价是每帧多算一遍行段（就是 栅格 那一段的量，实测 50~114µs），命中帧省 ~0.7~1.1ms。
	// 比较仍然是逐字段相等，不做哈希：哈希撞一次就是"某一帧画错了"这种查不出来的 bug。
	bool any_zone = false, any_dis = false, any_ready = false;
	bool any_r = false, any_a = false;   // 出口标志：R/A 有没有非零格（GDScript 据此关掉整层）
	m.lay_sig.clear();   // 复用成员缓冲，免得每帧 new 一个 vector
	for (const Block *bp_ : list) { const Block &b = *bp_;
		if (b.phase == 0 || b.opacity <= 0.0) continue;
		any_zone = true;
		if (!any_dis && b.phase == 1) any_dis = true;
		if (!any_ready && b.ready) any_ready = true;
		// 与下面栅格循环里那句二值快路径判据**必须完全一致**：
		// 快路径只看行段（透明度的具体值不进像素），软路径要把透明度累加进 R8，所以多存一项。
		const bool fast = b.phase == 2 && (b.sub || b.opacity == 1.0);
		int64_t head = (b.phase == 2 ? 1 : 0) | (b.sub ? 2 : 0) | (b.ready ? 4 : 0)
				| (b.src_line >= 0 ? 8 : 0) | (fast ? 0 : 0x100);
		m.lay_sig.push_back(head);
		if (!fast) {
			int64_t bits = 0;
			std::memcpy(&bits, &b.opacity, sizeof(bits));
			m.lay_sig.push_back(bits);
		}
		const size_t cnt_at = m.lay_sig.size();
		m.lay_sig.push_back(0);
		int64_t spans = 0;
		bm_raster_rows(bw, bh, aspect, b, [&](int y, int first, int last) {
			m.lay_sig.push_back(int64_t(y));
			m.lay_sig.push_back(int64_t(first));
			m.lay_sig.push_back(int64_t(last));
			spans++;
		});
		m.lay_sig[cnt_at] = spans;
	}
	const bool geom_same = m.lay_valid && m.lay_sig == m.lay_prev;
	m.lay_n++;
	if (geom_same) m.lay_hits++;
	// 行差分缓冲**复用**：这里原先是每帧 `std::vector<int> diff0((bw+1)*bh)` —— 2560×1440 下
	// 两块 923KB 的 malloc/free + 首次触碰缺页，是手机长尾帧（41ms）的来源之一。
	// 声明挪到函数域：只有重建那几帧才填它们。
	std::vector<int> &diff0 = m.d0;
	std::vector<int> &diff1 = m.d1;
	unsigned char sub_values[11] = { 0 };   // 减算叠加的 R8 阶梯（同样只在重建时算）
	if (!geom_same) {
		std::fill(m.l.begin(), m.l.end(), 0);
		std::fill(m.rawg.begin(), m.rawg.end(), 0);
		std::fill(m.readyg.begin(), m.readyg.end(), 0);
		std::fill(diff0.begin(), diff0.end(), 0);
		std::fill(diff1.begin(), diff1.end(), 0);
		sub_values[0] = 0;
		for (int i = 1; i < 11; i++) sub_values[i] = bm_unorm(sub_values[i - 1] / 255.0 + 0.1);
	}

	ph(1);
	// 六层：0=Active 普通 1=Active 减算 2=Disabled 普通 3=Disabled 减算 4/5=Ready 普通/减算
	if (!geom_same) {
		for (const Block *bp_ : list) { const Block &b = *bp_;
			if (b.phase == 0 || b.opacity <= 0.0) continue;
			const bool active = b.phase == 2;
			const int layer = active ? (b.sub ? 1 : 0) : (b.sub ? 3 : 2);
			const double opacity = b.sub ? 0.1 : b.opacity; // 官方减算 sprite 的 alpha 恒 0.1
			if (active && (b.sub || b.opacity == 1.0)) {    // 二值快路径：行差分 + 前缀和
				std::vector<int> &diff = b.sub ? diff1 : diff0;
				bm_raster_rows(bw, bh, aspect, b, [&](int y, int first, int last) {
					diff[(size_t)y * (bw + 1) + first] += 1;
					diff[(size_t)y * (bw + 1) + last] -= 1;
				});
				continue;
			}
			unsigned char *base = m.l.data();
			unsigned char *dst = base + (size_t)layer * n;
			unsigned char *dst_ready = base + (size_t)(4 + (b.sub ? 1 : 0)) * n;
			// 整数增量：x 是 0..255 的整数 ⇒ bm_unorm(x/255 + op) ≡ clamp(x + round(op*255), 0, 255)，
			// 逐格省掉一次除法/钳位。109 区 × 25 万格叠着铺时，光这一项就是「栅格」9ms 里的大头。
			const int oi = (int)std::lround(clampd2(opacity, 0.0, 1.0) * 255.0);
			const int si = (int)std::lround(clampd2(0.1 * b.opacity, 0.0, 1.0) * 255.0);
			bm_raster_rows(bw, bh, aspect, b, [&](int y, int first, int last) {
				for (int x = first; x < last; x++) {
					const size_t i = (size_t)y * bw + x;
					int v = (int)dst[i] + oi;
					dst[i] = (unsigned char)(v > 255 ? 255 : v);
					if (b.sub && !active) {
						int g = (int)m.rawg[i] + si;
						m.rawg[i] = (unsigned char)(g > 255 ? 255 : g);
					}
					if (b.ready) {
						int r = (int)dst_ready[i] + oi;
						dst_ready[i] = (unsigned char)(r > 255 ? 255 : r);
						if (b.sub) {
							int g2 = (int)m.readyg[i] + si;
							m.readyg[i] = (unsigned char)(g2 > 255 ? 255 : g2);
						}
					}
				}
			});
		}
	}

	ph(2);
	if (!any_zone) { // 一帧都没有可见噪域（ハTE 全程约 60% 的时间）
		if (!m.hover_any) {
			// 既没有场体也没有 hover ⇒ 和上一帧交出去的"全空"一模一样 ⇒ **什么都不传**。
			// 原来这 60% 的帧仍然要 memset 1.84MB + 分配两份 PackedByteArray + memcpy +
			// 两张纹理上传，是手机长尾帧（41ms）与平均帧超预算的主要来源。
			// 返回空 Array = "无变化"，GDScript 侧跳过 set_data/update（uTime 仍每帧同步）。
			if (m.empty_last) return Array();
			m.empty_last = true;
			PackedByteArray zero, zero2;
			zero.resize((int)n * 4);
			zero2.resize((int)n * 4);
			Array out;
			out.push_back(bw);
			out.push_back(bh);
			out.push_back(zero);
			out.push_back(zero2);
			bm_push_colors(out, false, false);
			out.push_back(0);
			out.push_back(0);
			return out;
		}
		// ⚠ 但 hover 不能跟着场体一起丢：感染是**手指生命周期**（judge.rs:1037），按住之后
		// 噪域整段消失、或手指拖到没有场体的地方，指尖特效仍要一直亮到抬起。
		// 官方就是这么分的：TouchMask 每帧无条件 update，只有 Active 层的掩码为空。
		m.empty_last = false;
		std::fill(m.aux.begin(), m.aux.end(), 0);
		for (int y = 0; y < bh; y++) {
			for (int x = 0; x < bw; x++) {
				const size_t i = (size_t)y * bw + x;
				m.aux[i * 4 + 3] = m.hover[(size_t)(y / 2) * m.hw
						+ std::min(x / 2, m.hw - 1)];
			}
		}
		PackedByteArray z1, a2;
		z1.resize((int)n * 4);
		a2.resize((int)n * 4);
		std::memcpy(a2.ptrw(), m.aux.data(), n * 4);
		Array out;
		out.push_back(bw);
		out.push_back(bh);
		out.push_back(z1);
		out.push_back(a2);
		bm_push_colors(out, false, false);
		out.push_back(1);   // hover 只有 Active 层，且必须留
		out.push_back(0);
		return out;
	}
	m.empty_last = false;
	if (!geom_same) {
		// 前缀和 + 合成/禁用在**同一趟**里做完。这两段本来就是逐行自足的：
		// 前缀和只吃 diff[..][x] 的同一行，合成只吃刚写下的 L0/L1 和更早的 L3/rawg，
		// 拆成两趟等于白白多扫一遍 23 万像素（实测"前缀"488µs + "配色"之前那段）。
		{
			unsigned char *L0 = m.l.data(), *L1 = L0 + n, *L2 = L1 + n, *L3 = L2 + n;
			for (int y = 0; y < bh; y++) {
				int cnt[2] = { 0, 0 };
				const size_t row = (size_t)y * bw, drow = (size_t)y * (bw + 1);
				for (int x = 0; x < bw; x++) {
					const size_t i = row + x;
					cnt[0] += diff0[drow + x];
					cnt[1] += diff1[drow + x];
					if (cnt[0] > 0) L0[i] = 255;
					L1[i] = sub_values[std::min(std::max(cnt[1], 0), 10)];
					m.compose[i] = (unsigned char)std::abs((int)L0[i] - (bm_sub_enabled(L1[i], _noise_ignore_triple) == 1.0 ? 255 : 0));
					if (!any_dis) {
						m.disabled[i] = 0;
					} else {
						double sr, sg;
						bm_sub_disabled(L3[i], m.rawg[i], sr, sg, _noise_ignore_triple);
						m.disabled[i] = (L2[i] != 0 || L3[i] != 0 || m.rawg[i] != 0) ? bm_unorm(std::fabs(sr * sg - L2[i] / 255.0)) : 0;
					}
				}
			}
		}
		m.lay_prev = m.lay_sig;   // 记下的就是这次真正铺出来的行段集合
		m.lay_valid = true;
	}

	const unsigned char *L4 = m.l.data() + 4 * n, *L5 = L4 + n;

	ph(3);
	// ───────── 逐区配色（prpr block_color.rs 的 Colors::update）─────────
	// 只有"存在非默认区色"的谱才走这条路：官方红（1, 84/255, 84/255）保持原算术、
	// 既不建调色板也不多传一张纹理。配色不改覆盖/减算/触点/透明度——它只是一层查表。
	bool colored = false, any_rpe = false;
	for (const Block *bp_ : list) { const Block &b = *bp_;
		if (b.phase == 0 || b.opacity <= 0.0) continue;
		if (b.src_line >= 0) any_rpe = true; // uReadyExtra：Recorder 的 ready 分支要画两遍
		if (b.cr != 1.0 || b.cg != 84.0 / 255.0 || b.cb != 84.0 / 255.0) colored = true;
	}
	if (colored) {
		std::vector<BlockMaskBuf::ColZone> sig;
		for (const Block *bp_ : list) { const Block &b = *bp_;
			if (b.phase == 0 || b.opacity <= 0.0) continue;
			sig.push_back({ b.ccx, b.ccy, b.hhx, b.hhy, b.rot_ccw, b.ys, b.opacity,
					(b.phase == 2 ? 1 : 0) | (b.sub ? 2 : 0) |
					((b.cr != 1.0 || b.cg != 84.0 / 255.0 || b.cb != 84.0 / 255.0) ? 4 : 0) });
		}
		const bool same = sig == m.col_zones && m.col_w == bw && m.col_h == bh && m.col_aspect == aspect;
		if (!same) {
			m.seeds.resize(n);
			m.owners.resize(n);
			m.col0.assign(n * 4, 0);
			m.col1.assign(n * 4, 0);
			for (int layer = 0; layer < 2; layer++) {
				unsigned char *dst = (layer == 0 ? m.col0 : m.col1).data();
				std::fill(m.seeds.begin(), m.seeds.end(), (size_t)-1);
				std::fill(m.owners.begin(), m.owners.end(), (size_t)-1);
				// 先减算后普通：同一像素上后写者胜（prpr "within the visible kind,
				// later z-order wins"，_blocks 已经是 zIndex 合成序）
				for (int invert = 1; invert >= 0; invert--) {
					for (size_t zi = 0; zi < list.size(); zi++) {
						const Block &z = *list[zi];
						if (z.phase == 0 || z.opacity <= 0.0) continue;
						if ((z.phase == 2 ? 1 : 0) != (layer == 0 ? 1 : 0)) continue;
						if ((z.sub ? 1 : 0) != invert) continue;
						bm_raster_rows(bw, bh, aspect, z, [&](int y, int first, int last) {
							for (int x = first; x < last; x++) {
								const size_t i = (size_t)y * bw + x;
								if (bm_color_source(m.l.data(), m.rawg.data(), n, layer, i, _noise_ignore_triple) == invert) {
									m.seeds[i] = i;
									m.owners[i] = zi;
								}
							}
						});
					}
				}
				// 两次 chamfer 扫描（正向+反向，各看 4 个已扫到的邻居）= O(像素) 最近种子
				for (int reverse = 0; reverse < 2; reverse++) {
					for (size_t cnt = 0; cnt < n; cnt++) {
						const size_t i = reverse ? (n - 1 - cnt) : cnt;
						if (m.seeds[i] == i) continue;
						const int x = (int)(i % bw), y = (int)(i / bw);
						auto dist = [&](size_t seed) -> long long {
							if (seed == (size_t)-1) return 0x7fffffffffffffffLL;
							const long long ax = std::abs(x - (int)(seed % bw));
							const long long ay = std::abs(y - (int)(seed / bw));
							return ax * ax + ay * ay;
						};
						size_t best = m.seeds[i];
						long long bd = dist(best);
						const int sdy = reverse ? 1 : -1;
						const int offs[4][2] = { { sdy, 0 }, { -1, sdy }, { 0, sdy }, { 1, sdy } };
						for (const auto &o : offs) {
							const long long nx = x + o[0], ny = y + o[1];
							if (nx < 0 || ny < 0 || nx >= bw || ny >= bh) continue;
							const size_t seed = m.seeds[(size_t)ny * bw + nx];
							const long long dd = dist(seed);
							if (dd < bd) { best = seed; bd = dd; }
						}
						m.seeds[i] = best;
					}
				}
				for (size_t i = 0; i < n; i++) {
					const size_t sd = m.seeds[i];
					double cr = 1.0, cg = 84.0 / 255.0, cb = 84.0 / 255.0;
					if (sd != (size_t)-1) {
						const Block &zb = *list[m.owners[sd]];
						cr = zb.cr; cg = zb.cg; cb = zb.cb;
					}
					dst[i * 4 + 0] = bm_unorm(cr);
					dst[i * 4 + 1] = bm_unorm(cg);
					dst[i * 4 + 2] = bm_unorm(cb);
					dst[i * 4 + 3] = 255;
				}
			}
			m.raw_active = m.col0;
			m.col_warp = false;
			for (size_t i = 1; i < n; i++) {
				if (std::memcmp(&m.raw_active[i * 4], &m.raw_active[0], 4) != 0) { m.col_warp = true; break; }
			}
			m.col_zones = std::move(sig);
			m.col_w = bw;
			m.col_h = bh;
			m.col_aspect = aspect;
		}
	} else {
		m.col_zones.clear(); // 下一帧只要有一个非默认色就得重新播种（尺寸/区集合缓存失效）
		m.col_w = 0;
	}

	ph(4);
	// 位移 warp：compose_uv 原式，逐步保留 binary16 舍入；结果取"邻居纹素原值"→ 边缘是抖动硬格。
	// 噪声采样按轴可分（fold(u)、fold(v) 独立）→ 行列索引各算一次，逐像素只做两次查表
	// （prpr warp_x/warp_y 同款优化；实测逐像素现算 fold 要吃掉 2/3 的构建时间）。
	static float centered[256];
	static bool centered_init = false;
	if (!centered_init) {
		centered_init = true;
		for (int v = 0; v < 256; v++) centered[v] = bm_medium(bm_medium(v / 255.0f) - 0.5f);
	}
	const float d = bm_medium(0.5f * bm_medium(1.0f / std::sqrt(0.5f)));
	const double dt = d * (_now_music / 20.0 * 2.59);
	// 没喂位移图（探针/素材缺失）时整段退化为"不置换"——早先这里直接对空 vector 取
	// .data() 再下标，headless 探针一跑就段错误。
	const bool has_noise = _blk_nw > 0 && _blk_nh > 0;
	std::vector<int> col_a(bw), col_b(bw), row_of(bh);
	if (has_noise) {
		for (int x = 0; x < bw; x++) {
			const double u = (x + 0.5) / bw;
			col_a[x] = std::min(std::max(bm_index(dt + u * 2.13, _blk_nw), 0), _blk_nw - 1);
			col_b[x] = std::min(std::max(bm_index(-dt + u * 2.13, _blk_nw), 0), _blk_nw - 1);
		}
		for (int y = 0; y < bh; y++) {
			const double v = (y + 0.5) / bh;
			row_of[y] = std::min(std::max(bm_index(dt + v * 1.02, _blk_nh), 0), _blk_nh - 1) * _blk_nw;
		}
	}
	for (int y = 0; y < bh; y++) {
		const double v = (y + 0.5) / bh;
		const unsigned char *nrow = has_noise ? _blk_noise.data() + row_of[y] : nullptr;
		for (int x = 0; x < bw; x++) {
			const double u = (x + 0.5) / bw;
			const size_t i = (size_t)y * bw + x;
			const double a = has_noise ? centered[nrow[col_a[x]]] : 0.0;
			const double b = has_noise ? centered[nrow[col_b[x]]] : 0.0;
			// 0.1 = prpr/官方 BlockCompose 的原值（单位是整个 UV，即最大约 7% 屏宽的推移）。
			// 做成可调：调小=边缘只在原地抖动，调大=整块随噪声推移（"向左右跑"）。
			const double amp = 0.1 * _blk_warp;
			const double du = (d * a - d * b) * amp + u;
			const double dv = (d * a + d * b) * amp + v;
			const int sx = (int)clampd2(std::floor(du * bw), 0.0, bw - 1.0);
			const int sy = (int)clampd2(std::floor(dv * bh), 0.0, bh - 1.0);
			m.rgba[i * 4 + 0] = m.compose[(size_t)sy * bw + sx];
			// Active 层的颜色跟着位移走（prpr Colors::warp：取同一个源像素的调色板纹素），
			// 否则红框被推走了、颜色还留在原地 → 拼缝两侧串色。整块同色时不用做（col_warp）。
			if (colored && m.col_warp) {
				const size_t src = ((size_t)sy * bw + sx) * 4;
				for (int c = 0; c < 4; c++) m.col0[i * 4 + c] = m.raw_active[src + c];
			}
			m.rgba[i * 4 + 3] = m.disabled[i];
			if (m.rgba[i * 4] != 0) any_r = true;
			if (m.rgba[i * 4 + 3] != 0) any_a = true;
			// G/B 是膨胀环的输出通道：必须每帧清零，否则环像素跨帧累积，
			// 跑几百帧后整屏都成"边缘"→ 用户实测"前几帧对、随后越来越红"（定帧脚本只跑
			// 几帧所以从没暴露）。
			m.rgba[i * 4 + 1] = 0;
			m.rgba[i * 4 + 2] = 0;
			m.aux[i * 4 + 0] = any_ready ? L4[i] : 0;
			if (any_ready) {
				double sr2, sg2;
				bm_sub_disabled(L5[i], m.readyg[i], sr2, sg2, _noise_ignore_triple);
				m.aux[i * 4 + 1] = bm_unorm(sg2);
			} else {
				m.aux[i * 4 + 1] = 0;
			}
			m.aux[i * 4 + 2] = m.disabled[i];
			// 1/8 网格的值复制成 2×2 塞进 1/4 尺寸的 aux.a（官方 touch camera 的打包）
			m.aux[i * 4 + 3] = m.hover_any
					? m.hover[(size_t)(y / 2) * m.hw + std::min(x / 2, m.hw - 1)]
					: 0;
		}
	}

	ph(5);
	// EdgeMask / GlowMask：9 邻域逐级膨胀成环（pass0 → G=255，每 pass → B=权重）
	{
		const int stride = (bw + 63) / 64;
		std::vector<uint64_t> ping((size_t)stride * bh, 0), pong((size_t)stride * bh, 0);
		for (int y = 0; y < bh; y++) {
			for (int x = 0; x < bw; x++) {
				if (m.rgba[((size_t)y * bw + x) * 4] != 0) {
					ping[(size_t)y * stride + x / 64] |= 1ull << (x % 64);
				}
			}
		}
		double sum = 0;
		for (int k = 1; k <= 6; k++) sum += std::pow((double)k, 2.65);
		const uint64_t last_mask = ~0ull >> ((64 - bw % 64) % 64);
		for (int pass = 0; pass < 6; pass++) {
			const double weight = std::pow((double)(6 - pass), 2.65) / sum;
			if (weight < 0.01) break;
			for (int y = 0; y < bh; y++) {
				for (int w = 0; w < stride; w++) {
					uint64_t value = 0;
					for (int row = std::max(0, y - 1); row <= std::min(bh - 1, y + 1); row++) {
						const uint64_t mid = ping[(size_t)row * stride + w];
						const uint64_t left = w > 0 ? ping[(size_t)row * stride + w - 1] >> 63 : 0;
						const uint64_t right = w + 1 < stride ? ping[(size_t)row * stride + w + 1] << 63 : 0;
						value |= mid | (mid << 1) | (mid >> 1) | left | right;
					}
					pong[(size_t)y * stride + w] = w + 1 == stride ? (value & last_mask) : value;
				}
			}
			for (int y = 0; y < bh; y++) {
				for (int w = 0; w < stride; w++) {
					uint64_t ring = pong[(size_t)y * stride + w] & ~ping[(size_t)y * stride + w];
					while (ring != 0) {
						const int bit = bm_ctz(ring);
						const int x = w * 64 + bit;
						ring &= ring - 1;
						if (x >= bw) continue;
						const size_t dst = ((size_t)y * bw + x) * 4;
						if (pass == 0) m.rgba[dst + 1] = 255;
						m.rgba[dst + 2] = bm_unorm(weight);
					}
				}
			}
			ping.swap(pong);
			std::fill(pong.begin(), pong.end(), 0);
		}
	}
	ph(6);
	PackedByteArray bytes, aux;
	bytes.resize((int)n * 4);
	std::memcpy(bytes.ptrw(), m.rgba.data(), n * 4);
	aux.resize((int)n * 4);
	std::memcpy(aux.ptrw(), m.aux.data(), n * 4);
	Array out; // [w, h, masks RGBA8, aux RGBA8, 配色 Active, 配色 Disabled, colored, line2area]
	out.push_back(bw);
	out.push_back(bh);
	out.push_back(bytes);
	out.push_back(aux);
	if (colored) {
		PackedByteArray c0, c1;
		c0.resize((int)n * 4);
		c1.resize((int)n * 4);
		std::memcpy(c0.ptrw(), m.col0.data(), n * 4);
		std::memcpy(c1.ptrw(), m.col1.data(), n * 4);
		out.push_back(c0);
		out.push_back(c1);
	} else {
		out.push_back(PackedByteArray());
		out.push_back(PackedByteArray());
	}
	out.push_back(colored ? 1 : 0);
	out.push_back(any_rpe ? 1 : 0);
	out.push_back(any_r ? 1 : 0);
	out.push_back(any_a ? 1 : 0);
	ph(7);
	_blk_ph_n++;
	return out;	out.push_back(any_rpe ? 1 : 0);
	return out;
}

// ───────── 噪域触摸特效（官方 block_touch.rs 的 TouchMask）─────────
// 官方每个按下的手指画一张 Round10_Blur4（44×44、PPU=100、prefab size=11.5、
// 正交相机 size=5 ⇒ 屏高占比 44/100×11.5/10 = 0.506）：Show 从 0 线性长到 1、
// Hide 从当前值线性回 0，各 0.1s（Animation.MoveNext RVA 0x1D708D0，线性钳位插值）。
// 光栅目标是**点采样的 R8 touch camera**，混合是 Sprites/Default 的
// (One, OneMinusSrcAlpha) 且 RGB 乘纹理 alpha，每次混合后按 R8 量化。
// hoverSample 用 _EffectRT_TexelSize.zw×0.5 采样 ⇒ 这张图是 1/8 屏网格，
// 塞进效果尺寸（1/4 屏）的 aux.a 时每个值复制成 2×2。
static const double BTS_DUR = 0.1;
static const double BTS_H = 44.0 / 100.0 * 11.5 / 10.0;

void ChartPlayer::set_block_hover(PackedByteArray rgba, int w, int h) {
	if (w <= 0 || h <= 0 || rgba.size() < w * h * 4) {
		UtilityFunctions::push_warning("block hover 贴图尺寸/格式不对，触摸特效不显示");
		return;
	}
	_hover_src = rgba;
	_hover_w = w;
	_hover_h = h;
}

static inline double bts_clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); }

void ChartPlayer::_bts_update(double time) {
	if (!std::isfinite(time)) return;
	if (time < _bts_last) {
		// 确定性回放可以倒着 seek：官方实例是初始化时重置，不保留"未来"的缩放
		for (auto &s : _bts) s = BTouchSlot();
	}
	_bts_last = time;
	for (auto &s : _bts) {
		const double t = bts_clamp01((time - s.t0) / BTS_DUR);
		s.scale = s.s0 + (s.s1 - s.s0) * t;
		s.seen = false;
	}
	int used = 0;
	for (int id = 0; id < 16 && used < 10; id++) {
		const Finger &f = _fingers[id];
		// 官方喂给 TouchMask 的是 **chart.blocked_touches**（judge.rs:1039-1049 只往里 push
		// "落进 Active 域"的手指，game.rs:1459 暂停即清空），不是原始触点表。
		// ⇒ 只有**按在噪域上**的那根手指才有指尖特效；普通判定点击一律不出特效。
		// 感染是"手指生命周期"而不是"场生命周期"（judge.rs:1037 注释），所以按住后拖出
		// 噪域仍然亮着，直到 Ended/Cancelled 才清 blocked ⇒ 抬起即消失。
		if (!f.blocked) continue;
		used++;
		const double u = f.hx / std::max(_cw, 1.0);
		const double v = 1.0 - f.hy / std::max(_ch, 1.0); // 原点左下
		if (!std::isfinite(u) || !std::isfinite(v)) continue;
		int have = -1, freei = -1;
		for (int k = 0; k < 10; k++) {
			if (_bts[k].finger == id) { have = k; break; }
			if (freei < 0 && _bts[k].finger < 0) freei = k;
		}
		if (have >= 0) {
			_bts[have].cx = u;
			_bts[have].cy = v;
			_bts[have].seen = true;
		} else if (freei >= 0) {
			// 复用到正在消失的槽也要从 0 重来（官方 show 的语义，单测覆盖）
			BTouchSlot &s = _bts[freei];
			s.finger = id; s.cx = u; s.cy = v; s.seen = true;
			s.t0 = time; s.s0 = 0.0; s.s1 = 1.0; s.scale = 0.0;
		}
	}
	for (auto &s : _bts)
		if (s.finger >= 0 && !s.seen) {
			s.finger = -1;
			s.t0 = time;
			s.s0 = s.scale;
			s.s1 = 0.0;
		}
}

static inline double bts_px(const PackedByteArray &src, int w, int h, long x, long y, int ch) {
	x = x < 0 ? 0 : (x >= w ? w - 1 : x);
	y = y < 0 ? 0 : (y >= h ? h - 1 : y);
	return src[((size_t)y * w + x) * 4 + ch] / 255.0;
}

unsigned char ChartPlayer::_hover_at(double u, double v, double aspect) const {
	if (_hover_w <= 0 || _hover_h <= 0) return 0;
	double result = 0.0;
	for (const auto &s : _bts) {
		if (s.scale <= 0.0) continue;
		const double size = BTS_H * s.scale;
		const double su = (u - s.cx) * aspect / size + 0.5;
		const double sv = (v - s.cy) / size + 0.5;
		if (su < 0.0 || su > 1.0 || sv < 0.0 || sv > 1.0) continue;
		// 双线性 + clamp；PNG 行是 y 向下，官方精灵 UV 是 y 向上
		const double x = su * _hover_w - 0.5;
		const double y = (1.0 - sv) * _hover_h - 0.5;
		const long x0 = (long)std::floor(x), y0 = (long)std::floor(y);
		const double fx = x - std::floor(x), fy = y - std::floor(y);
		const PackedByteArray &src = _hover_src;
		const int w = _hover_w, h = _hover_h;
		auto bilin = [&](int ch) {
			const double bot = bts_px(src, w, h, x0, y0, ch) * (1.0 - fx) + bts_px(src, w, h, x0 + 1, y0, ch) * fx;
			const double top = bts_px(src, w, h, x0, y0 + 1, ch) * (1.0 - fx) + bts_px(src, w, h, x0 + 1, y0 + 1, ch) * fx;
			return bot * (1.0 - fy) + top * fy;
		};
		const double red = bilin(0), alpha = bilin(3);
		const double mixed = std::round(std::clamp(red * alpha + result * (1.0 - alpha), 0.0, 1.0) * 255.0) / 255.0;
		result = mixed;
	}
	return (unsigned char)std::lround(bts_clamp01(result) * 255.0);
}

unsigned char ChartPlayer::debug_hover_at(double u, double v, double aspect) {
	return _hover_at(u, v, aspect);
}

Array ChartPlayer::debug_touch_slots() {
	Array out;
	for (const auto &s : _bts) {
		if (s.finger < 0 || s.scale <= 0.0) continue; // 官方：只有还按着的手指进 _TouchPos[]
		out.push_back(s.cx);
		out.push_back(s.cy);
		out.push_back(s.scale);
	}
	return out;
}

// 只给单测用：官方 block_touch.rs 的三个单测是直接调 update_fingers(任意坐标) 的，
// 不经过 judge 的"按进 Active 域才算感染"那一步；我们这里 TouchMask 的入口被
// f.blocked 把着（那正是官方语义），所以测试需要一个把 blocked 钉住的口子。
void ChartPlayer::debug_force_blocked(int id, bool on, Vector2 pos) {
	if (id < 0 || id >= 16) return;
	Finger &f = _fingers[id];
	f.hx = pos.x;
	f.hy = pos.y;
	f.blocked = on;
}

// 8 段平均 µs：0=hover 栅格 1=清零 2=区栅格 3=前缀和+合成 4=逐区配色 5=位移 6=膨胀 7=打包
Array ChartPlayer::debug_block_phases() {
	Array out;
	const double k = _blk_ph_n > 0 ? 1.0 / _blk_ph_n : 0.0;
	for (int i = 0; i < 8; i++) out.push_back(_blk_ph[i] * k);
	out.push_back(_blk_ph_n);
	// 末尾两项：区集合签名的判定次数与命中次数（命中 = 清零/栅格/合成三段整段跳过）。
	out.push_back(_bmb.lay_n);
	out.push_back(_bmb.lay_hits);
	return out;
}
