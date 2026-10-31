shader_type canvas_item;
// 移植自 player static/game/shaders/chromatic.glsl —— extra.json effect "chromatic"
uniform sampler2D fx_src;
uniform float sampleCount = 3.0;
uniform float power = 0.01;

vec4 _fxs(vec2 __u){
	return texture(fx_src, __u);
}

void fragment() {
	int n = int(clamp(sampleCount, 1.0, 64.0));
	vec3 sum = vec3(0.0);
	vec3 c = vec3(0.0);
	vec2 offset = (UV - vec2(0.5)) * vec2(1.0, -1.0);
	for (int i = 0; i < 64; i++) {
		if (i >= n) { break; }
		float t = 2.0 * float(i) / float(max(n - 1, 1));
		vec3 slice = max(vec3(1.0 - t, 1.0 - abs(t - 1.0), t - 1.0), vec3(0.0));
		sum += slice;
		c += slice * _fxs(UV + (t - 1.0) * power * offset).rgb;
	}
	COLOR = vec4(c / sum, 1.0);


	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
