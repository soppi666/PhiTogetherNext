// 内存按容器拆开算账（诊断专用，产品路径一行都不碰）。
//
// 为什么要它：1093 万音符的谱常驻 2.2GB，"降内存"这句话没有账就无从下手——
// 是 Note 结构本身、还是那两份索引数组、还是每线的事件表？量出来才知道砍哪。
// 顺带把两个"能不能整块删掉"的判据一起数出来：
//   nord 是否恒等（绘制序=数组序 ⇒ 索引数组可以省）；
//   冷字段是否恒默认（⇒ Note 可以拆成热核+冷表）。
#include "chart_player.h"

#include <godot_cpp/variant/dictionary.hpp>

#include <algorithm>

using namespace godot;

static Dictionary row(const String &n, int64_t cnt, int64_t bytes, int64_t cap = -1) {
	Dictionary d;
	d["name"] = n;
	d["count"] = cnt;
	d["bytes"] = bytes;
	d["mb"] = (double)bytes / (1024.0 * 1024.0);
	if (cap >= 0) d["cap_bytes"] = cap;
	return d;
}

template <class V> static int64_t vbytes(const V &v) {
	return (int64_t)v.capacity() * (int64_t)sizeof(typename V::value_type);
}

Array ChartPlayer::mem_report() const {
	Array out;
	const int64_t nln = (int64_t)_lines.size();
	out.push_back(row("Note.sizeof", 1, (int64_t)sizeof(Note)));

	int64_t ncnt = 0, nby = 0, ncap = 0;
	int64_t nord_by = 0, nrank_by = 0, ev_by = 0, ctrl_by = 0, lay_by = 0, txt_by = 0;
	int64_t id_lines = 0, lines_with_notes = 0;
	int64_t cold_all = 0, hs_n = 0, tint_n = 0, zc_n = 0, vtime_n = 0, holdpair_n = 0;
	int64_t hold_n = 0, fp_n = 0, z_n = 0, zfx_n = 0, jsize_n = 0, t2_n = 0, hT2_n = 0, spd0_n = 0;
	double spd_min = 1e18, spd_max = -1e18, ht_min = 1e18, ht_max = -1e18;
	double tmin = 1e18, tmax = -1e18;
	int64_t hist[12] = {0};
	for (const Line &l : _lines) {
		ncnt += (int64_t)l.notes.size();
		nby += (int64_t)l.notes.size() * (int64_t)sizeof(Note);
		ncap += vbytes(l.notes);
		nord_by += vbytes(l.nord);
		nrank_by += vbytes(l.nrank);
		if (!l.notes.empty()) {
			lines_with_notes++;
			bool id = ((int64_t)l.nord.size() == (int64_t)l.notes.size());
			for (size_t i = 0; id && i < l.nord.size(); i++)
				if (l.nord[i] != (int)i) id = false;
			if (id) id_lines++;
		}
		for (const Layer &la : l.layers) {
			lay_by += vbytes(la.alpha) + vbytes(la.mx) + vbytes(la.my) + vbytes(la.rot)
					+ vbytes(la.speed);
		}
		ev_by += vbytes(l.ext_sx) + vbytes(l.ext_sy) + vbytes(l.ext_color) + vbytes(l.ext_incline);
		ctrl_by += vbytes(l.c_alpha) + vbytes(l.c_pos) + vbytes(l.c_size) + vbytes(l.c_skew)
				+ vbytes(l.c_y);
		txt_by += vbytes(l.tx_ev);
		for (const Note &n : l.notes) {
			bool cold = n.z == -1 && n.zfx == 7 && n.jsize == -1 && n.vtime == 999999
					&& n.temp_state == 0 && n.temp_late == 0 && n.safe_frames == 0
					&& n.fx_last == 0 && !n.has_tint && !n.has_fx_tint && !n.hold_head
					&& !n.hold_missed && !n.hold_over && !n.click_matched && !n.drag_marked
					&& !n.flick_matched && n.hs.is_empty()
					&& (!n.rigid_tail || (n.hold_off == 0 && n.hold_rate == 0));
			if (cold) cold_all++;
			if (!n.hs.is_empty()) hs_n++;
			if (n.has_tint || n.has_fx_tint) tint_n++;
			if (n.z != -1 || n.zfx != 7 || n.jsize != -1) zc_n++;
			if (n.vtime != 999999) vtime_n++;
			if (n.rigid_tail) holdpair_n++;
			if (n.type == 2) hold_n++;
			if (n.has_fp) fp_n++;
			if (n.z != -1) z_n++;
			if (n.zfx != 7) zfx_n++;
			if (n.jsize != -1) jsize_n++;
			if (n.t2 != n.t) t2_n++;
			if (n.hT2 != n.hT) hT2_n++;
			if (n.speed == 0) spd0_n++;
			if (n.speed < spd_min) spd_min = n.speed;
			if (n.speed > spd_max) spd_max = n.speed;
			if (n.hT < ht_min) ht_min = n.hT;
			if (n.hT > ht_max) ht_max = n.hT;
			if (n.t < tmin) tmin = n.t;
			if (n.t > tmax) tmax = n.t;
			{
				// 直方图只回答"hT 是不是挤在一起"：窗化能不能救这张谱全看这个分布。
				int64_t hb = (int64_t)((n.hT - 20.0) / 80.0 * 12);
				hist[(size_t)std::max<int64_t>(std::min<int64_t>(hb, 11), 0)]++;
			}
		}
	}
	out.push_back(row("notes_x_sizeof", ncnt, nby, ncap));
	out.push_back(row("Line", nln, nln * (int64_t)sizeof(Line)));
	out.push_back(row("line.nord", ncnt, nord_by));
	out.push_back(row("line.nrank", ncnt, nrank_by));
	out.push_back(row("line.layers", lay_by / (int64_t)sizeof(Event), lay_by));
	out.push_back(row("line.ext_*", ev_by / (int64_t)sizeof(Event), ev_by));
	out.push_back(row("line.ctrl_*", ctrl_by / (int64_t)sizeof(Ctrl), ctrl_by));
	out.push_back(row("line.texts", txt_by / (int64_t)sizeof(Line::TxtEv), txt_by));
	out.push_back(row("_notes_by_time", (int64_t)_notes_by_time.size(), vbytes(_notes_by_time)));
	out.push_back(row("_cand", (int64_t)_cand.size(), vbytes(_cand)));
	out.push_back(row("_fx", (int64_t)_fx.size(), vbytes(_fx)));
	out.push_back(row("_hitq", (int64_t)_hitq.size(), vbytes(_hitq)));
	out.push_back(row("_jdeltas", (int64_t)_jdeltas.size(), vbytes(_jdeltas)));
	int64_t mm_by = 0, mm_n = 0;
	for (const MmGroup &g : _mmg) {
		mm_by += vbytes(g.xf) + vbytes(g.col);
		mm_n += (int64_t)g.col.size();
	}
	out.push_back(row("_mmg xf+col", mm_n, mm_by));
	// 判据行：这两条决定"能不能整块删"，不是内存量
	out.push_back(row("ID:nord_identity_lines", id_lines, 0));
	out.push_back(row("ID:lines_with_notes", lines_with_notes, 0));
	out.push_back(row("ID:cold_all_default", cold_all, 0));
	out.push_back(row("ID:hs_nonempty", hs_n, 0));
	out.push_back(row("ID:has_tint", tint_n, 0));
	out.push_back(row("ID:z_or_zfx_or_jsize_nondefault", zc_n, 0));
	out.push_back(row("ID:vtime_nondefault", vtime_n, 0));
	out.push_back(row("ID:rigid_tail", holdpair_n, 0));
	out.push_back(row("ID:type2_hold", hold_n, 0));
	out.push_back(row("ID:has_fp", fp_n, 0));
	out.push_back(row("ID:z_nondefault", z_n, 0));
	out.push_back(row("ID:zfx_nondefault", zfx_n, 0));
	out.push_back(row("ID:jsize_nondefault", jsize_n, 0));
	out.push_back(row("ID:t2_ne_t", t2_n, 0));
	out.push_back(row("ID:hT2_ne_hT", hT2_n, 0));
	out.push_back(row("ID:speed_eq_0", spd0_n, 0));
	out.push_back(row("ID:speed_min", 0, (int64_t)(spd_min * 1000)));
	out.push_back(row("ID:speed_max", 0, (int64_t)(spd_max * 1000)));
	out.push_back(row("ID:hT_min", 0, (int64_t)ht_min));
	out.push_back(row("ID:hT_max", 0, (int64_t)ht_max));
	out.push_back(row("ID:t_min_ms", 0, (int64_t)(tmin * 1000)));
	out.push_back(row("ID:t_max_ms", 0, (int64_t)(tmax * 1000)));
	out.push_back(row("ID:t_span_s", 0, (int64_t)(tmax - tmin)));
	out.push_back(row("ID:notes_per_second", 0, (int64_t)((double)_total_notes
			/ std::max(1.0, tmax - tmin))));
	for (int i = 0; i < 12; i++) out.push_back(row(String("ID:hist_hT_") + String::num_int64(i),
			hist[i], 0));
	// _draw 分相（µs/帧）+ 高水位浪费比：cap_written/n_used 就是"每帧白写多少实例"
	if (_ph_frames > 0) {
		const double f = (double)_ph_frames;
		out.push_back(row("US/frame lines", _ph_frames, (int64_t)(_ph_lines_us / f)));
		out.push_back(row("US/frame notes_total", _ph_frames, (int64_t)(_ph_notes_us / f)));
		out.push_back(row("US/frame commit", _ph_frames, (int64_t)(_ph_commit_us / f)));
		out.push_back(row("cap_written_per_frame", _ph_frames, (int64_t)(_ph_cap_written / f)));
		out.push_back(row("n_used_per_frame", _ph_frames, (int64_t)(_ph_n_used / f)));
	}
	return out;
}
