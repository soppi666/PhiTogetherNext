// 整体轨迹（rpe-next src/core/curve-trajectory.mjs + batch-script.mjs compileExpression）
// RPE 1.7/2.x 的 moveXEvents 事件可带 `trajectory`：事件在 [start,end] 内按曲线取 (x,y[,rotation])，
// 而不是在 start/end 两个数之间插值。曲线由表达式定义（parametric / polar / star / random-polygon），
// 这里实现与 rpe-next 同语法的小表达式编译器（后缀程序）＋采样器。
#include "chart_player.h"

#include <algorithm>
#include <cmath>

namespace godot {

namespace {

constexpr double TRAJ_PI = 3.14159265358979323846;

static double _num(const Variant &v) {
	switch (v.get_type()) {
		case Variant::INT: return (double)(int64_t)v;
		case Variant::FLOAT: return (double)v;
		case Variant::BOOL: return (bool)v ? 1.0 : 0.0;
		default: return 0.0;
	}
}
static double _clamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

enum {
	OP_CONST = 0, OP_VAR = 1,
	OP_ADD = 2, OP_SUB = 3, OP_MUL = 4, OP_DIV = 5, OP_MOD = 6, OP_POW = 7,
	OP_NEG = 8, OP_NOT = 9,
	OP_ABS = 20, OP_MIN = 21, OP_MAX = 22, OP_FLOOR = 23, OP_CEIL = 24, OP_ROUND = 25,
	OP_SIN = 26, OP_COS = 27, OP_TAN = 28, OP_SQRT = 29, OP_POW2 = 30, OP_CLAMP = 31,
	OP_LERP = 32, OP_EASE = 33,
	OP_LT = 40, OP_GT = 41, OP_LE = 42, OP_GE = 43, OP_EQ = 44, OP_NE = 45, OP_AND = 46, OP_OR = 47,
	OP_TERN = 50,
};

struct Tok {
	int kind = 0;   // 0=数字 1=标识符 2=符号
	double num = 0;
	String name;
};

static String _normalize_expr(const String &src) {
	String s = src.strip_edges();
	s = s.replace("$t$", "t");
	s = s.replace("θ", "theta");
	s = s.replace("π", "pi");
	s = s.replace("Π", "pi");
	s = s.replace("，", ",");
	s = s.replace("（", "(");
	s = s.replace("）", ")");
	String out;
	for (int i = 0; i < s.length();) {
		const char32_t c = s[i];
		const bool letter = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
		if ((c == 'P' || c == 'p') && i + 1 < s.length() && (s[i + 1] == 'i' || s[i + 1] == 'I')) {
			const bool prev_ok = (i == 0) || !((s[i - 1] >= 'A' && s[i - 1] <= 'Z') || (s[i - 1] >= 'a' && s[i - 1] <= 'z') ||
					(s[i - 1] >= '0' && s[i - 1] <= '9') || s[i - 1] == '_');
			const bool next_ok = (i + 2 >= s.length()) || !((s[i + 2] >= 'A' && s[i + 2] <= 'Z') || (s[i + 2] >= 'a' && s[i + 2] <= 'z') ||
					(s[i + 2] >= '0' && s[i + 2] <= '9') || s[i + 2] == '_');
			if (prev_ok && next_ok) {
				out += "pi";
				i += 2;
				continue;
			}
		}
		out += String::chr(c);
		(void)letter;
		i++;
	}
	return out;
}

static bool _is_alpha(char32_t c) {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}
static bool _is_digit(char32_t c) { return c >= '0' && c <= '9'; }

static bool _tokenize(const String &src, std::vector<Tok> &out) {
	int i = 0;
	const int n = src.length();
	while (i < n) {
		const char32_t c = src[i];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { i++; continue; }
		if (_is_digit(c) || (c == '.' && i + 1 < n && _is_digit(src[i + 1]))) {
			const int s = i;
			while (i < n && (_is_digit(src[i]) || src[i] == '.')) i++;
			if (i < n && (src[i] == 'e' || src[i] == 'E')) {
				const int save = i;
				i++;
				if (i < n && (src[i] == '+' || src[i] == '-')) i++;
				if (i < n && _is_digit(src[i])) { while (i < n && _is_digit(src[i])) i++; }
				else i = save;
			}
			Tok t;
			t.kind = 0;
			t.num = src.substr(s, i - s).to_float();
			out.push_back(t);
			continue;
		}
		if (_is_alpha(c)) {
			const int s = i;
			while (i < n && (_is_alpha(src[i]) || _is_digit(src[i]))) i++;
			Tok t;
			t.kind = 1;
			t.name = src.substr(s, i - s);
			out.push_back(t);
			continue;
		}
		if (i + 1 < n) {
			const String two = src.substr(i, 2);
			if (two == "**" || two == "&&" || two == "||" || two == "==" || two == "!=" || two == "<=" || two == ">=") {
				Tok t;
				t.kind = 2;
				t.name = two;
				out.push_back(t);
				i += 2;
				continue;
			}
		}
		if (String("+-*/%^<>()!,?:").contains(String::chr(c))) {
			Tok t;
			t.kind = 2;
			t.name = String::chr(c);
			out.push_back(t);
			i++;
			continue;
		}
		return false;
	}
	return true;
}

static int _op_prec(const String &s) {
	if (s == "||") return 1;
	if (s == "&&") return 2;
	if (s == "==" || s == "!=") return 3;
	if (s == "<" || s == ">" || s == "<=" || s == ">=") return 4;
	if (s == "+" || s == "-") return 5;
	if (s == "*" || s == "/" || s == "%") return 6;
	if (s == "^" || s == "**") return 7;
	return -1;
}

static int _bin_op(const String &s) {
	if (s == "+") return OP_ADD;
	if (s == "-") return OP_SUB;
	if (s == "*") return OP_MUL;
	if (s == "/") return OP_DIV;
	if (s == "%") return OP_MOD;
	if (s == "^" || s == "**") return OP_POW;
	if (s == "<") return OP_LT;
	if (s == ">") return OP_GT;
	if (s == "<=") return OP_LE;
	if (s == ">=") return OP_GE;
	if (s == "==") return OP_EQ;
	if (s == "!=") return OP_NE;
	if (s == "&&") return OP_AND;
	if (s == "||") return OP_OR;
	return -1;
}

class TrajParser {
public:
	TrajParser(const std::vector<Tok> &toks, const std::vector<std::pair<String, int>> &vars, ChartPlayer::TrajProg &prog) :
			toks_(toks), vars_(vars), prog_(prog) {}

	bool run() {
		if (toks_.empty()) return false;
		if (!expr(0)) return false;
		return ok_ && pos_ == (int)toks_.size();
	}

private:
	const std::vector<Tok> &toks_;
	const std::vector<std::pair<String, int>> &vars_;
	ChartPlayer::TrajProg &prog_;
	int pos_ = 0;
	bool ok_ = true;

	void emit(int op, double num = 0, int var = 0, int argc = 0) {
		ChartPlayer::TrajOp o;
		o.op = op;
		o.num = num;
		o.var = var;
		o.argc = argc;
		prog_.ops.push_back(o);
	}

	int find_var(const String &name) const {
		for (size_t i = 0; i < vars_.size(); i++)
			if (vars_[i].first == name) return vars_[i].second;
		return -1;
	}

	bool atom() {
		if (pos_ >= (int)toks_.size()) { ok_ = false; return false; }
		const Tok t = toks_[pos_++];
		if (t.kind == 2 && (t.name == "+" || t.name == "-" || t.name == "!")) {
			if (!atom()) return false;
			if (t.name == "-") emit(OP_NEG);
			else if (t.name == "!") emit(OP_NOT);
			return true;
		}
		if (t.kind == 2 && t.name == "(") {
			if (!expr(0)) return false;
			if (pos_ >= (int)toks_.size() || toks_[pos_].kind != 2 || toks_[pos_].name != ")") { ok_ = false; return false; }
			pos_++;
			return true;
		}
		if (t.kind == 0) { emit(OP_CONST, t.num); return true; }
		if (t.kind == 1) {
			if (pos_ < (int)toks_.size() && toks_[pos_].kind == 2 && toks_[pos_].name == "(") {
				const String fn = t.name;
				pos_++;
				int argc = 0;
				if (pos_ < (int)toks_.size() && toks_[pos_].kind == 2 && toks_[pos_].name == ")") {
					pos_++;
				} else {
					while (true) {
						if (!expr(0)) return false;
						argc++;
						if (pos_ < (int)toks_.size() && toks_[pos_].kind == 2 && toks_[pos_].name == ",") { pos_++; continue; }
						break;
					}
					if (pos_ >= (int)toks_.size() || toks_[pos_].kind != 2 || toks_[pos_].name != ")") { ok_ = false; return false; }
					pos_++;
				}
				int op = -1;
				if (fn == "abs" && argc == 1) op = OP_ABS;
				else if (fn == "min" && argc >= 1) op = OP_MIN;
				else if (fn == "max" && argc >= 1) op = OP_MAX;
				else if (fn == "floor" && argc == 1) op = OP_FLOOR;
				else if (fn == "ceil" && argc == 1) op = OP_CEIL;
				else if (fn == "round" && argc == 1) op = OP_ROUND;
				else if (fn == "sin" && argc == 1) op = OP_SIN;
				else if (fn == "cos" && argc == 1) op = OP_COS;
				else if (fn == "tan" && argc == 1) op = OP_TAN;
				else if (fn == "sqrt" && argc == 1) op = OP_SQRT;
				else if (fn == "pow" && argc == 2) op = OP_POW2;
				else if (fn == "clamp" && argc == 3) op = OP_CLAMP;
				else if (fn == "lerp" && argc == 3) op = OP_LERP;
				else if (fn == "ease" && (argc == 1 || argc == 2)) {
					if (argc == 1) { emit(OP_CONST, 1); argc = 2; } // JS 默认 type=1
					op = OP_EASE;
				}
				if (op < 0) { ok_ = false; return false; }
				emit(op, 0, 0, argc);
				return true;
			}
			if (t.name == "pi") { emit(OP_CONST, TRAJ_PI); return true; }
			if (t.name == "true") { emit(OP_CONST, 1); return true; }
			if (t.name == "false") { emit(OP_CONST, 0); return true; }
			const int slot = find_var(t.name);
			if (slot < 0) { ok_ = false; return false; }
			emit(OP_VAR, 0, slot);
			return true;
		}
		ok_ = false;
		return false;
	}

	bool expr(int minimum) {
		if (!atom()) return false;
		while (pos_ < (int)toks_.size() && toks_[pos_].kind == 2) {
			const String opname = toks_[pos_].name;
			const int prec = _op_prec(opname);
			if (prec < 0 || prec < minimum) break;
			pos_++;
			const bool right_assoc = (opname == "^" || opname == "**");
			if (!expr(prec + (right_assoc ? 0 : 1))) return false;
			emit(_bin_op(opname));
		}
		if (minimum == 0 && pos_ < (int)toks_.size() && toks_[pos_].kind == 2 && toks_[pos_].name == "?") {
			pos_++;
			if (!expr(0)) return false;
			if (pos_ >= (int)toks_.size() || toks_[pos_].kind != 2 || toks_[pos_].name != ":") { ok_ = false; return false; }
			pos_++;
			if (!expr(0)) return false;
			emit(OP_TERN, 0, 0, 3);
		}
		return true;
	}
};

static double _eval(const ChartPlayer::TrajProg &p, const double *slots, int nslots) {
	double st[512];
	int sp = 0;
	for (size_t i = 0; i < p.ops.size(); i++) {
		const ChartPlayer::TrajOp &o = p.ops[i];
		switch (o.op) {
			case OP_CONST: st[sp++] = o.num; break;
			case OP_VAR: st[sp++] = (o.var >= 0 && o.var < nslots) ? slots[o.var] : 0.0; break;
			case OP_ADD: st[sp - 2] += st[sp - 1]; sp--; break;
			case OP_SUB: st[sp - 2] -= st[sp - 1]; sp--; break;
			case OP_MUL: st[sp - 2] *= st[sp - 1]; sp--; break;
			case OP_DIV: st[sp - 2] /= st[sp - 1]; sp--; break;
			case OP_MOD: st[sp - 2] = std::fmod(st[sp - 2], st[sp - 1]); sp--; break;
			case OP_POW: st[sp - 2] = std::pow(st[sp - 2], st[sp - 1]); sp--; break;
			case OP_NEG: st[sp - 1] = -st[sp - 1]; break;
			case OP_NOT: st[sp - 1] = st[sp - 1] == 0.0 ? 1.0 : 0.0; break;
			case OP_ABS: st[sp - 1] = std::fabs(st[sp - 1]); break;
			case OP_MIN: {
				double v = st[sp - o.argc];
				for (int a = 1; a < o.argc; a++) v = std::min(v, st[sp - o.argc + a]);
				sp -= o.argc - 1;
				st[sp - 1] = v;
				break;
			}
			case OP_MAX: {
				double v = st[sp - o.argc];
				for (int a = 1; a < o.argc; a++) v = std::max(v, st[sp - o.argc + a]);
				sp -= o.argc - 1;
				st[sp - 1] = v;
				break;
			}
			case OP_FLOOR: st[sp - 1] = std::floor(st[sp - 1]); break;
			case OP_CEIL: st[sp - 1] = std::ceil(st[sp - 1]); break;
			case OP_ROUND: st[sp - 1] = std::floor(st[sp - 1] + 0.5); break;
			case OP_SIN: st[sp - 1] = std::sin(st[sp - 1]); break;
			case OP_COS: st[sp - 1] = std::cos(st[sp - 1]); break;
			case OP_TAN: st[sp - 1] = std::tan(st[sp - 1]); break;
			case OP_SQRT: st[sp - 1] = std::sqrt(std::max(0.0, st[sp - 1])); break;
			case OP_POW2: st[sp - 2] = std::pow(st[sp - 2], st[sp - 1]); sp--; break;
			case OP_CLAMP: {
				const double hi = st[sp - 1], lo = st[sp - 2], v = st[sp - 3];
				sp -= 2;
				st[sp - 1] = std::max(lo, std::min(hi, v));
				break;
			}
			case OP_LERP: {
				const double t = st[sp - 1], b = st[sp - 2], a = st[sp - 3];
				sp -= 2;
				st[sp - 1] = a + (b - a) * t;
				break;
			}
			case OP_EASE: {
				const double type = st[sp - 1], x = st[sp - 2];
				sp -= 1;
				st[sp - 1] = ChartPlayer::traj_ease((int)type, x);
				break;
			}
			case OP_LT: st[sp - 2] = st[sp - 2] < st[sp - 1] ? 1.0 : 0.0; sp--; break;
			case OP_GT: st[sp - 2] = st[sp - 2] > st[sp - 1] ? 1.0 : 0.0; sp--; break;
			case OP_LE: st[sp - 2] = st[sp - 2] <= st[sp - 1] ? 1.0 : 0.0; sp--; break;
			case OP_GE: st[sp - 2] = st[sp - 2] >= st[sp - 1] ? 1.0 : 0.0; sp--; break;
			case OP_EQ: st[sp - 2] = st[sp - 2] == st[sp - 1] ? 1.0 : 0.0; sp--; break;
			case OP_NE: st[sp - 2] = st[sp - 2] != st[sp - 1] ? 1.0 : 0.0; sp--; break;
			case OP_AND: st[sp - 2] = (st[sp - 2] != 0.0 && st[sp - 1] != 0.0) ? 1.0 : 0.0; sp--; break;
			case OP_OR: st[sp - 2] = (st[sp - 2] != 0.0 || st[sp - 1] != 0.0) ? 1.0 : 0.0; sp--; break;
			case OP_TERN: {
				const double no = st[sp - 1], yes = st[sp - 2], cond = st[sp - 3];
				sp -= 2;
				st[sp - 1] = cond != 0.0 ? yes : no;
				break;
			}
			default: st[sp++] = 0.0; break;
		}
		if (sp < 0) sp = 0;
		if (sp > 500) sp = 500;
	}
	return sp > 0 ? st[sp - 1] : 0.0;
}

static bool _compile_expr(const String &src, const std::vector<std::pair<String, int>> &vars, ChartPlayer::TrajProg &out) {
	out.ops.clear();
	const String norm = _normalize_expr(src);
	std::vector<Tok> toks;
	if (!_tokenize(norm, toks)) return false;
	TrajParser p(toks, vars, out);
	return p.run() && !out.ops.empty();
}

// 轨迹原始点（不含 alignStart 平移、含 rotation/scale 变换）
static void _traj_raw(const ChartPlayer::Traj &tr, double progress, const double *slots, int ns, double &x, double &y) {
	const double unit = tr.trim0 + (tr.trim1 - tr.trim0) * progress;
	const double cx = tr.begin + (tr.finish - tr.begin) *
			(tr.easeX <= 1 ? unit : ChartPlayer::traj_ease(tr.easeX, unit));
	const double cy = tr.begin + (tr.finish - tr.begin) *
			(tr.easeY <= 1 ? unit : ChartPlayer::traj_ease(tr.easeY, unit));
	double hx = 0, hy = 0;
	if (tr.shape) {
		double radius = 200.0, points = 5.0, inner = 0.4;
		for (auto &p : tr.params) {
			if (p.first == "radius") radius = p.second;
			else if (p.first == "points") points = p.second;
			else if (p.first == "inner") inner = p.second;
		}
		const int sides = std::max(3, std::min(40, (int)std::floor(points + 0.5))) * (tr.shape == 1 ? 2 : 1);
		const double amount = (unit - std::floor(unit)) * sides;
		const int index = (int)std::floor(amount);
		const double frac = amount - index;
		auto vertex = [&](int step, double &vx, double &vy) {
			int wrapped = step % sides;
			if (wrapped < 0) wrapped += sides;
			double r = radius;
			if (tr.shape == 1) r = radius * ((wrapped % 2) ? inner : 1.0);
			else {
				const double noise = std::sin(wrapped * 127.1 + tr.seed * 311.7) * 43758.5453;
				r = radius * (1.0 - tr.randomness * (noise - std::floor(noise)));
			}
			const double ang = 2.0 * TRAJ_PI * wrapped / sides;
			vx = r * std::cos(ang);
			vy = r * std::sin(ang);
		};
		double x0, y0, x1, y1;
		vertex(index, x0, y0);
		vertex(index + 1, x1, y1);
		hx = x0 + (x1 - x0) * frac;
		hy = y0 + (y1 - y0) * frac;
	} else if (tr.mode == 1) {
		double s[5 + 32];
		std::copy(slots, slots + ns, s);
		s[0] = unit;
		s[1] = progress;
		s[2] = cx;
		const double r = _eval(tr.pr, s, ns);
		hx = r * std::cos(cx);
		hy = r * std::sin(cx);
	} else {
		double s[5 + 32];
		std::copy(slots, slots + ns, s);
		s[1] = progress;
		s[0] = cx;
		hx = _eval(tr.px, s, ns);
		s[0] = cy;
		hy = _eval(tr.py, s, ns);
	}
	const double ang = tr.rot * TRAJ_PI / 180.0;
	const double sxv = hx * tr.sx, syv = hy * tr.sy;
	x = sxv * std::cos(ang) - syv * std::sin(ang);
	y = sxv * std::sin(ang) + syv * std::cos(ang);
}

static double _traj_tangent(const ChartPlayer::Traj &tr, double progress, const double *slots, int ns, bool &ok) {
	const double deltas[4] = { 0.00001, 0.0001, 0.001, 0.01 };
	for (int d = 0; d < 4; d++) {
		double ax, ay, bx, by;
		_traj_raw(tr, std::max(0.0, progress - deltas[d]), slots, ns, ax, ay);
		_traj_raw(tr, std::min(1.0, progress + deltas[d]), slots, ns, bx, by);
		const double dx = bx - ax, dy = by - ay;
		if (std::sqrt(dx * dx + dy * dy) > 1e-9) {
			ok = true;
			return -std::atan2(dy, dx) * 180.0 / TRAJ_PI;
		}
	}
	ok = false;
	return 0.0;
}

} // namespace

// 解析一个 trajectory 对象（event["trajectory"]）；成功返回线内轨迹下标，失败 -1。
int ChartPlayer::_parse_trajectory(const Variant &tv, Line &line) {
	if (tv.get_type() != Variant::DICTIONARY) return -1;
	Dictionary td = tv;
	Variant ov = td.get("options", Variant());
	if (ov.get_type() != Variant::DICTIONARY) return -1;
	Dictionary o = ov;

	Traj tr;
	tr.mode = String(o.get("mode", "parametric")) == "polar" ? 1 : 0;
	const String shape = String(o.get("shape", ""));
	tr.shape = shape == "star" ? 1 : (shape == "random-polygon" ? 2 : 0);

	Variant pv = o.get("parameters", Variant());
	if (pv.get_type() == Variant::DICTIONARY) {
		Dictionary pd = pv;
		Array keys = pd.keys();
		for (int i = 0; i < (int)keys.size() && tr.params.size() < 32; i++) {
			const String k = String(keys[i]);
			if (k.is_empty() || !(_is_alpha(k[0]))) continue;
			tr.params.push_back({ k, _num(pd[keys[i]]) });
		}
	}

	std::vector<std::pair<String, int>> vars = { { "t", 0 }, { "u", 1 }, { "theta", 2 }, { "seed", 3 }, { "randomness", 4 } };
	for (size_t i = 0; i < tr.params.size(); i++) vars.push_back({ tr.params[i].first, (int)(5 + i) });

	auto num_or_expr = [&](const Variant &v, double fallback) -> double {
		if (v.get_type() == Variant::NIL) return fallback;
		if (v.get_type() == Variant::STRING) {
			TrajProg prog;
			if (!_compile_expr((String)v, vars, prog)) return fallback;
			double slots[5 + 32] = { 0 };
			slots[3] = tr.seed;
			slots[4] = tr.randomness;
			for (size_t i = 0; i < tr.params.size(); i++) slots[5 + i] = tr.params[i].second;
			return _eval(prog, slots, 5 + (int)tr.params.size());
		}
		return _num(v);
	};

	tr.seed = num_or_expr(o.get("seed", Variant()), 1.0);
	tr.randomness = num_or_expr(o.get("randomness", Variant()), 0.0);
	tr.trim0 = _clamp(num_or_expr(o.get("trimStart", Variant()), 0.0), 0.0, 1.0);
	tr.trim1 = _clamp(num_or_expr(o.get("trimEnd", Variant()), 1.0), 0.0, 1.0);
	if (tr.trim1 <= tr.trim0) tr.trim1 = std::min(1.0, tr.trim0 + 1e-6);
	tr.rot = num_or_expr(o.get("rotation", Variant()), 0.0);
	tr.sx = num_or_expr(o.get("scaleX", Variant()), 1.0);
	tr.sy = num_or_expr(o.get("scaleY", Variant()), 1.0);
	tr.startX = num_or_expr(o.get("startX", Variant()), 0.0);
	tr.startY = num_or_expr(o.get("startY", Variant()), 0.0);
	tr.align = (bool)o.get("alignStart", false);
	tr.tangent = (bool)o.get("tangentRotation", false);
	tr.easeX = std::max(1, (int)num_or_expr(o.get("easingX", Variant()), 1.0));
	tr.easeY = std::max(1, (int)num_or_expr(o.get("easingY", Variant()), 1.0));
	if (tr.mode == 1) {
		tr.begin = num_or_expr(o.get("angleStart", Variant()), 0.0);
		tr.finish = num_or_expr(o.get("angleEnd", Variant()), 2.0 * TRAJ_PI);
	} else {
		tr.begin = num_or_expr(o.get("parameterStart", Variant()), 0.0);
		tr.finish = num_or_expr(o.get("parameterEnd", Variant()), 1.0);
	}

	bool ok = true;
	if (tr.shape) {
		// star / random-polygon：不需要表达式
	} else if (tr.mode == 1) {
		ok = _compile_expr(String(o.get("radiusExpression", "200")), vars, tr.pr);
	} else {
		ok = _compile_expr(String(o.get("xExpression", "200*cos(2*pi*t)")), vars, tr.px) &&
				_compile_expr(String(o.get("yExpression", "200*sin(2*pi*t)")), vars, tr.py);
	}
	const String dir = String(o.get("rotationExpression", ""));
	if (dir.strip_edges() != "" && _compile_expr(dir, vars, tr.pdir)) tr.has_dir = true;
	tr.ok = ok && (tr.shape || tr.mode == 1 || (!tr.px.ops.empty() && !tr.py.ops.empty()));
	if (!tr.ok) {
		UtilityFunctions::push_warning("trajectory: 表达式编译失败，事件按普通线性处理");
		return -1;
	}

	double slots[5 + 32] = { 0 };
	slots[3] = tr.seed;
	slots[4] = tr.randomness;
	for (size_t i = 0; i < tr.params.size(); i++) slots[5 + i] = tr.params[i].second;
	const int ns = 5 + (int)tr.params.size();

	if (tr.align || tr.tangent) {
		_traj_raw(tr, 0.0, slots, ns, tr.firstX, tr.firstY);
	}
	if (tr.tangent) {
		tr.angles.assign(1025, 0.0);
		for (int i = 0; i <= 1024; i++) {
			bool got = false;
			const double a = _traj_tangent(tr, i / 1024.0, slots, ns, got);
			const double prev = i ? tr.angles[i - 1] : 0.0;
			tr.angles[i] = i ? a + 360.0 * std::floor((prev - a) / 360.0 + 0.5) : a;
			if (!got && i) tr.angles[i] = prev;
		}
	}

	line.trajs.push_back(std::move(tr));
	return (int)line.trajs.size() - 1;
}

// 事件在某时刻的轨迹分量（axis 0=x 1=y 2=rotation）。
double ChartPlayer::_traj_value(const Line &l, const Event &e, double tsec) const {
	if (e.traj < 0 || e.traj >= (int)l.trajs.size()) return 0;
	const Traj &tr = l.trajs[e.traj];
	if (!tr.ok) return 0;
	const double progress = (e.t - e.s) > 1e-9 ? _clamp((tsec - e.s) / (e.t - e.s), 0.0, 1.0) : 1.0;

	double slots[5 + 32] = { 0 };
	slots[3] = tr.seed;
	slots[4] = tr.randomness;
	for (size_t i = 0; i < tr.params.size(); i++) slots[5 + i] = tr.params[i].second;
	const int ns = 5 + (int)tr.params.size();

	if (e.traj_axis == 2) {
		if (tr.has_dir) {
			double s[5 + 32];
			std::copy(slots, slots + ns, s);
			const double unit = tr.trim0 + (tr.trim1 - tr.trim0) * progress;
			const double cx = tr.begin + (tr.finish - tr.begin) *
					(tr.easeX <= 1 ? unit : traj_ease(tr.easeX, unit));
			s[0] = tr.mode == 1 ? unit : cx;
			s[1] = progress;
			s[2] = cx;
			return _eval(tr.pdir, s, ns);
		}
		if (tr.tangent && tr.angles.size() == 1025) {
			bool got = false;
			const double a = _traj_tangent(tr, progress, slots, ns, got);
			const double ref = tr.angles[std::max(0, std::min(1024, (int)std::floor(progress * 1024.0 + 0.5)))];
			if (!got) return ref;
			return a + 360.0 * std::floor((ref - a) / 360.0 + 0.5);
		}
		return 0;
	}

	double x = 0, y = 0;
	_traj_raw(tr, progress, slots, ns, x, y);
	if (tr.align) {
		x += tr.startX - tr.firstX;
		y += tr.startY - tr.firstY;
	}
	if (!(std::isfinite(x) && std::isfinite(y))) return 0;
	return e.traj_axis == 1 ? y : x;
}

} // namespace godot
