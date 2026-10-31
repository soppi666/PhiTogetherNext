// GPU 实例化音符层：分组、几何换算、批量写入都在这一个文件。
// 与 chart_player.cpp 的判定/门控无耦合：那边算好每个四边形的世界基向量后 _mm_push 进来。
#include "chart_player.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/canvas_item.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance2d.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/texture2d.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

using namespace godot;

// 单位 quad（1x1，中心在原点），**UV 按 CanvasItem 的约定**：v 随局部 y 增大。
// 不能用 QuadMesh：它的 v 与 2D 贴图绘制相反（tests/mm_uv_rule_probe.gd 实测：
// 同一基向量下 QuadMesh 必须把 Y 轴取负才逐像素等于 draw_texture_rect）。
// 而"取负 Y 轴"只在不剪切时无害——by=R·(shear·h,h) 的 X 分量会跟着反号，
// 带 skew 的音符会朝反方向倒（AT t=88.4 实测差 616 像素就是这么来的）。
// 所以把 UV 约定搬进网格里，几何保持与旧路径逐点同式。
// 每个组各建一份（不缓存成 static：函数内 static Ref 会在 RenderingServer 拆掉之后
// 才析构，退出时喷 "~ArrayMesh: Parameter RenderingServer::get_singleton() is null"）。
static Ref<ArrayMesh> _mm_quad_mesh() {
	PackedVector3Array verts;
	verts.push_back(Vector3(-0.5f, -0.5f, 0));
	verts.push_back(Vector3(0.5f, -0.5f, 0));
	verts.push_back(Vector3(0.5f, 0.5f, 0));
	verts.push_back(Vector3(-0.5f, 0.5f, 0));
	PackedVector2Array uvs;
	uvs.push_back(Vector2(0, 0));
	uvs.push_back(Vector2(1, 0));
	uvs.push_back(Vector2(1, 1));
	uvs.push_back(Vector2(0, 1));
	PackedInt32Array idx;
	idx.push_back(0); idx.push_back(1); idx.push_back(2);
	idx.push_back(0); idx.push_back(2); idx.push_back(3);
	Array arr;
	arr.resize(Mesh::ARRAY_MAX);
	arr[Mesh::ARRAY_VERTEX] = verts;
	arr[Mesh::ARRAY_TEX_UV] = uvs;
	arr[Mesh::ARRAY_INDEX] = idx;
	Ref<ArrayMesh> m;
	m.instantiate();
	m->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arr);
	return m;
}

int ChartPlayer::_mm_bucket(const std::vector<double> &ds, double depth) {
	auto it = std::lower_bound(ds.begin(), ds.end(), depth);
	int i = (int)(it - ds.begin());
	return i < (int)ds.size() ? i : 0;
}

// 子节点只在第一次 _draw 时建（那时 CanvasItem 已在树里）。状态一律取 S（幽灵实例
// 自己没有音符表），节点一律归 this：主实例与各深度幽灵实例各自持有一组，才不被甩出
// 各自的过滤链。特效层 _fxl 无条件建——它和实例化开关无关，关掉 MM 也得有个地方画特效。
// 深度桶数 × 类别数超过一次能建的节点上限时 _mm_ok=false：音符必须整体退回旧路径，
// 绝不能"节点没建就把 quad 丢掉"（那是静默丢音符，比慢严重得多）。
void ChartPlayer::_mm_ensure(ChartPlayer *S) {
	int nb = (int)S->_note_depths.size();
	// 换谱后深度桶数可能变（同一节点二次 load 的保险）：桶数不一致时旧的分组表会越界，
	// 必须拆掉重建，而不是拿旧 size 当下标。
	if (_mm_nodes && _mmg.size() != (size_t)nb * MK_N) {
		for (auto &g : _mmg) {
			if (g.node != nullptr) {
				g.node->set_visible(false);
				g.node->queue_free();
			}
		}
		_mmg.clear();
		_mm_nodes = false;
		_mm_ok = false;
	}
	if (!_mm_nodes) {
		_mm_nodes = true;
		if (nb > 0 && nb * MK_N <= 260) {
			_mm_ok = true;
			_mmg.resize((size_t)nb * MK_N);
			for (int b = 0; b < nb; b++) {
				for (int k = 0; k < MK_N; k++) {
					MmGroup &g = _mmg[(size_t)b * MK_N + k];
					g.mm.instantiate();
					g.mm->set_transform_format(MultiMesh::TRANSFORM_2D);
					g.mm->set_use_colors(true);
					// 单位 quad（UV 走 CanvasItem 约定，见 _mm_quad_mesh）：实例缩放即像素尺寸
					g.mm->set_mesh(_mm_quad_mesh());
					g.mm->set_visible_instance_count(-1);   // 恒"全画"：instance_count 已经逐帧等于 n，
																				// 这里若留一个旧的上限，缩回去的那几帧会静默少画
					g.node = memnew(MultiMeshInstance2D);
					g.node->set_multimesh(g.mm);
					g.tex = S->_mm_tex(k);
					g.node->set_texture(g.tex);
					g.node->set_z_index(1);
					g.node->set_visible(false);
					add_child(g.node);   // 交给树管生命周期
				}
			}
		}
	}
	else {
		// 换皮：MultiMesh 节点的贴图是**建节点那一刻写死**的
		// （g.node->set_texture 只在建时调一次）。不每帧对一下的话，
		// 设置页换包后演示带/舞台仍然画着上一包的图
		// （用户："演示区域全部都是 PT 的皮肤，完全没有根据换的皮肤包改变"）。
		// 注意：幾何（nw/nh）是逐实例算的，只有贴图是写死的，
		// 所以贴图没跟上时看起来就是"比例不对"（旧图被拉进新尺寸）。
		for (size_t gi = 0; gi < _mmg.size(); gi++) {
			MmGroup &g = _mmg[gi];
			Ref<Texture2D> nt = S->_mm_tex((int)(gi % (size_t)MK_N));
			if (g.tex != nt) {
				g.tex = nt;
				if (g.node != nullptr) g.node->set_texture(nt);
			}
		}
	}
	if (_fxl == nullptr) {
		_fxl = memnew(ChartFxLayer);
		_fxl->owner = this;
		_fxl->set_z_index(2);            // 排在所有音符节点之后
		add_child(_fxl);
	}
}

void ChartPlayer::_mm_reset() {
	for (auto &g : _mmg) { g.xf.clear(); g.col.clear(); }
}

void ChartPlayer::_mm_push(int bucket, int kind, const Vector2 &bx, const Vector2 &by,
		const Vector2 &origin, const Color &c) {
	if (_mmg.empty()) return;              // 深度桶过多 ⇒ 已决定留在旧路径
	MmGroup &g = _mmg[(size_t)bucket * MK_N + kind];
	g.xf.push_back(bx);
	g.xf.push_back(by);
	g.xf.push_back(origin);
	g.col.push_back(c);
}

// 每帧只写"这一帧真正要画的实例"：instance_count 与两条数组都按 n 给。
// 原来按高水位 cap 写（本意是少改 instance_count），代价是**一帧密集就永久变贵**：
// cap 只涨不落，之后每一帧都要重新分配并拷 cap·3 个 Vector2 + cap 个 Color。
// 实测 1093 万音符谱上 commit 单独占 1.86s/帧（整帧 2.59s），而真正有用的实例
// 就那么多 ⇒ 成本必须跟着画面密度走，不能跟着历史峰值走。
// show=false 用于旧路径帧：缓冲照样填（对拍要读），但节点收起来，绝不允许
// "两条路径同时画"——那会让参考帧自己就是错的。
void ChartPlayer::_mm_commit(bool show) {
	const double t0 = now_us();
	int64_t cap_sum = 0, n_sum = 0;
	for (auto &g : _mmg) {
		if (g.node == nullptr) continue;
		int n = (int)g.col.size();
		if (n == 0) { g.node->set_visible(false); g.cap = 0; continue; }
		g.node->set_visible(show);
		cap_sum += n; n_sum += n;
		g.cap = n;
		g.mm->set_instance_count(n);
		PackedVector2Array tv;
		tv.resize((size_t)n * 3);
		std::memcpy(tv.ptrw(), g.xf.data(), (size_t)n * 3 * sizeof(Vector2));
		PackedColorArray cv;
		cv.resize(n);
		std::memcpy(cv.ptrw(), g.col.data(), (size_t)n * sizeof(Color));
		g.mm->set("transform_2d_array", tv);
		g.mm->set("color_array", cv);
	}
	_ph_commit_us += now_us() - t0;
	_ph_cap_written += cap_sum;
	_ph_n_used += n_sum;
}

Ref<Texture2D> ChartPlayer::_mm_tex(int kind) {
	switch (kind) {
		case MK_HOLD_BODY: return _tex_hold;
		case MK_HOLD_HEAD: return _tex_hold_head;
		case MK_HOLD_TAIL: return _tex_hold_end;
		case MK_HOLD_TAIL_HL: return _tex_hold_end_hl;
		case MK_DRAG: return _tex_drag;
		case MK_TAP: return _tex_tap;
		case MK_FLICK: return _tex_flick;
		case MK_HOLD_BODY_HL: return _tex_hold_hl;
		case MK_HOLD_HEAD_HL: return _tex_hold_head_hl;
		case MK_DRAG_HL: return _tex_drag_hl;
		case MK_TAP_HL: return _tex_tap_hl;
		default: return _tex_flick_hl;
	}
}

Array ChartPlayer::mm_debug_groups() const {
	static const float FMAX = std::numeric_limits<float>::max();
	Array out;
	for (size_t i = 0; i < _mmg.size(); i++) {
		const MmGroup &g = _mmg[i];
		int n = (int)g.col.size();
		if (n == 0) continue;
		Dictionary d;
		// bad = 转成 float32 之后不是有限值、或大到超出 float 范围的实例数。
		// 一个 NaN 顶点会让整批实例在驱动侧消失（不是少一个音符，是一个都不画），
		// 所以这个计数必须按组统计，而不是只看第一条。
		int bad = 0, huge = 0;
		double worst = 0;
		for (int k = 0; k < n; k++) {
			for (int j = 0; j < 3; j++) {
				const Vector2 &v = g.xf[(size_t)k * 3 + j];
				for (int c = 0; c < 2; c++) {
					double a = c == 0 ? v.x : v.y;
					if (std::fabs(a) > worst) worst = std::fabs(a);
					if (!std::isfinite(a) || std::fabs(a) > FMAX) bad++;
					else if (std::fabs(a) > 1e6) huge++;
				}
			}
		}
		d["bad"] = bad;
		d["huge"] = huge;
		d["worst"] = worst;
		d["kind"] = (int)(i % MK_N);
		d["bucket"] = (int)(i / MK_N);
		d["n"] = n;
		d["cap"] = g.cap;
		d["vis"] = g.node != nullptr ? g.node->is_visible() : false;
		d["tex"] = g.tex.is_valid()
				? String::num_int64(g.tex->get_width()) + "x" + String::num_int64(g.tex->get_height())
				: String("null");
		d["bx"] = g.xf[0];
		d["by"] = g.xf[1];
		d["o"] = g.xf[2];
		const Color &c = g.col[0];
		d["col"] = String::num(c.r) + "," + String::num(c.g) + "," + String::num(c.b) + "," + String::num(c.a);
		out.push_back(d);
	}
	return out;
}

void ChartFxLayer::_draw() {
	if (owner != nullptr) owner->draw_fx_into(this);
}

// 线局部空间的"中心矩形"→ 实例基向量。与 draw_set_transform(线) + draw_texture_rect(中心矩形)
// 逐点等价：bx=R·(w,0)，by=R·(shear·h, h)，o=线位置+R·(cx,cy)。
// UV 约定由 _mm_quad_mesh 自己带（不是 QuadMesh），所以这里**不许**再对任何轴取负来"翻贴图"：
// 一翻就会连 skew 的方向一起翻掉（斜体音符朝反方向倒）。
// h 取负 = above=0 的贴图垂直镜像（draw_hold_tex 的 flip 分支就是 UV v 翻转，
// 而矩形关于自身中心对称，两种做法重合）。
void ChartPlayer::_mm_quad(int bucket, int kind, const Line &l, double cosr, double sinr,
		double cx, double cy, double w, double h, double shear, const Color &c) {
	double ex = shear * h;                       // Y 轴在局部空间被剪切成 (shear,1)·h
	Vector2 bx(cosr * w, sinr * w);
	Vector2 by(cosr * ex - sinr * h, sinr * ex + cosr * h);
	Vector2 o(l.wx + cosr * cx - sinr * cy, l.wy + sinr * cx + cosr * cy);
	// 视口剔除（外接框）：|bx|+|by| 是该 quad 在 x/y 方向的半跨度和（旋转+剪切都算进去），
	// 整块落在画布外就一条实例都不写。判据只可能剔掉"本来就采不到像素"的 quad。
	if (_vpx > 0.0) {
		double ex = (std::fabs(bx.x) + std::fabs(by.x)) * 0.5;
		if (o.x + ex < 0.0 || o.x - ex > _vpx) { _vcull_drop++; return; }
		double ey = (std::fabs(bx.y) + std::fabs(by.y)) * 0.5;
		if (o.y + ey < 0.0 || o.y - ey > _vpy) { _vcull_drop++; return; }
	}
	_mm_push(bucket, kind, bx, by, o, c);
}

void ChartFxLayer::_bind_methods() {}
