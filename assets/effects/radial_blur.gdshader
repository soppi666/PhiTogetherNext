shader_type canvas_item;
// 移植自 player static/game/shaders/radialBlur.glsl —— extra.json effect "radialBlur"
uniform sampler2D fx_src;
uniform float centerX = 0.5;
uniform float centerY = 0.5;
uniform float power = 0.01;
uniform float sampleCount = 6.0;

vec4 _fxs(vec2 __u){
	return texture(fx_src, __u);
}

void fragment() {
	vec2 dir = UV - vec2(centerX, centerY);
	vec4 c = vec4(0.0);
	float n = clamp(sampleCount, 1.0, 64.0);
	float f = 1.0 / n;
	for (int i = 0; i < 64; i++) {
		if (float(i) >= n) { break; }
		c += _fxs(UV - power * dir * float(i)) * f;
	}
	// player 原版只累加 .rgb、alpha 根本不写（它跑在不透明全屏上，alpha 无意义）。我们这条链
	// 是"预乘 + 回贴盖现场"，alpha 必须一起模糊才是能量守恒的：rgb 被摊薄而 alpha 还取中心点
	// ⇒ 回贴时按 a 擦掉现场、却只加回摊薄后的 rgb ⇒ 光晕变黑晕
	// （Designant 尾段"白色 Bloom 变黑色"就是这个，实测 a 比 max(RGB) 平均高 13/255）。
	COLOR = c;


	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
