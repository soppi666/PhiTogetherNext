shader_type canvas_item;
// 移植自 player static/game/shaders/circleBlur.glsl —— extra.json effect "circleBlur"
// 注意：size 是逐像素双重循环半径，player 也仅小范围用；上限钳到 12 防跑飞
uniform sampler2D fx_src;
uniform float size = 10.0;

vec4 _fxs(vec2 __u){
	return texture(fx_src, __u);
}

void fragment() {
	vec4 c = _fxs(UV);
	float len = dot(c, c);
	vec2 px = SCREEN_PIXEL_SIZE;
	int r = int(clamp(size, 0.0, 12.0));
	for (int x = -r; x <= r; x++) {
		for (int y = -r; y <= r; y++) {
			if (float(x * x + y * y) > float(r * r)) { continue; }
			vec4 nc = texture(fx_src, UV + px * vec2(float(x), float(y)));
			float nl = dot(nc, nc);
			if (nl > len) { len = nl; c = nc; }
		}
	}
	// 这是"邻域最亮纹素"选择器，不是平均：选中的那个纹素要整体搬走（含它的 alpha），
	// 配中心点 alpha 同样会擦得比加得多（黑晕），理由见 radialBlur 的注释。
	COLOR = c;


	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
