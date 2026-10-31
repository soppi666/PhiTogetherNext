shader_type canvas_item;
render_mode unshaded;

// 噪域掩码的 GPU 版（CPU 那份 build_block_mask 是逐格扫的：全屏 + 上百个区 5~13ms）。
// 两趟靠 uPass 分，**没有中间视口**（单趟里直接算位移后的取样点）：
//   0 = 掩码：位移 + 9 邻域逐级膨胀 → R=compose G=第一圈 B=权重 A=disabled
//   1 = aux：B=disabled（ready/hover 这版不产出，遇到就回退 CPU）
// 输入 zone 由 GDScript 用**加法混合多边形**铺好：R=Active 普通 G=Active 减算 B=Disabled 普通 A=Disabled 减算。
// 坐标约定：整张网格 = 0..1；格子中心 = (floor(UV*grid)+0.5)/grid。

uniform sampler2D uZone : filter_nearest;
uniform sampler2D uNoise : filter_linear;
uniform int uPass = 0;
uniform vec2 uGrid = vec2(1.0);
uniform vec2 uNoiseSize = vec2(1.0);
uniform float uNoiseT = 0.0;
uniform float uWarp = 1.0;

const float D = 0.35355339059;    // 0.5 * medium(1/√0.5)

float fold1(float v) {
	float m = mod(v, 2.0);
	if (m < 0.0) m += 2.0;
	return m > 1.0 ? 2.0 - m : m;
}

vec2 noise_pair(float u, float v) {
	int nw = max(int(uNoiseSize.x), 1);
	int nh = max(int(uNoiseSize.y), 1);
	float dt = D * (uNoiseT / 20.0 * 2.59);
	int x1 = clamp(int(floor(fold1(dt + u * 2.13) * float(nw))), 0, nw - 1);
	int x2 = clamp(int(floor(fold1(-dt + u * 2.13) * float(nw))), 0, nw - 1);
	int y  = clamp(int(floor(fold1(dt + v * 1.02) * float(nh))), 0, nh - 1);
	vec2 t1 = (vec2(float(x1), float(y)) + 0.5) / uNoiseSize;
	vec2 t2 = (vec2(float(x2), float(y)) + 0.5) / uNoiseSize;
	return vec2(texture(uNoise, t1).r, texture(uNoise, t2).r);
}

// 单格：x = compose（|Active - 减算|），y = disabled
vec2 cell_compose(vec2 cell_uv) {
	vec4 z = texture(uZone, cell_uv);
	float sub_on = (z.g >= 0.09 && z.g < 0.12) ? 1.0 : 0.0;
	float compose = abs(z.r - sub_on);
	float l2 = z.b;
	float l3 = z.a;
	float rawg = z.a;                       // opacity=1 时 rawg 与 L3 相等
	float t = clamp((rawg - 0.2) * -10.0, 0.0, 1.0);
	float rr = (l3 >= 0.09 && l3 < 0.12 ? 1.0 : 0.0) + t * t * (3.0 - 2.0 * t);
	float sr = clamp(rr, 0.0, 1.0);
	float sg = clamp(rawg * rr * 10.0, 0.0, 1.0);
	float dis = (l2 > 0.0 || l3 > 0.0 || rawg > 0.0) ? abs(sr * sg - l2) : 0.0;
	return vec2(compose, dis);
}

// 这一格按噪声位移后的取样点（src 与 cell 同一套 UV）
vec2 warped_cell(vec2 cell) {
	vec2 n = noise_pair(cell.x, cell.y);
	float a = n.x - 0.5;
	float b = n.y - 0.5;
	float amp = 0.1 * uWarp;
	vec2 duv = vec2((D * a - D * b) * amp + cell.x, (D * a + D * b) * amp + cell.y);
	return (floor(clamp(duv, vec2(0.0), vec2(0.9999)) * uGrid) + 0.5) / uGrid;
}

float ring_weight(int d) {
	float sum = 0.0;
	for (int k = 1; k <= 6; k++) sum += pow(float(k), 2.65);
	return pow(float(6 - (d - 1)), 2.65) / sum;
}

void fragment() {
	vec2 cell = (floor(UV * uGrid) + 0.5) / uGrid;
	vec2 cd = cell_compose(warped_cell(cell));
	if (uPass == 0) {
		float g = 0.0;
		float bb = 0.0;
		if (cd.x < 0.5) {
			for (int d = 1; d <= 6; d++) {
				bool hit = false;
				for (int dy = -d; dy <= d; dy++) {
					for (int dx = -d; dx <= d; dx++) {
						if (max(abs(dx), abs(dy)) != d) continue;
						vec2 n = cell + vec2(float(dx), float(dy)) / uGrid;
						if (n.x < 0.0 || n.y < 0.0 || n.x > 1.0 || n.y > 1.0) continue;
						if (cell_compose(warped_cell(n)).x >= 0.5) { hit = true; break; }
					}
					if (hit) break;
				}
				if (hit) {
					if (d == 1) g = 1.0;
					bb = ring_weight(d);
					break;
				}
			}
		}
		// alpha 恒 1：SubViewport 贴图预乘，a=0 会把 RGB 乘没
		COLOR = vec4(cd.x, g, bb, 1.0);
	} else {
		// aux：disabled 用不位移的那份（CPU 也是先写 disabled 再 warp）
		COLOR = vec4(0.0, 0.0, cell_compose(cell).y, 1.0);
	}
}
