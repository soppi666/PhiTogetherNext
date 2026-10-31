shader_type canvas_item;
// 移植自 player static/game/shaders/noise.glsl —— extra.json effect "noise"
uniform sampler2D fx_src;
uniform float seed = 81.0;
uniform float power : hint_range(0.0, 1.0) = 0.03;

vec4 _fxs(vec2 __u){
	return texture(fx_src, __u);
}

vec2 rnd(vec2 pos) {
	return fract(sin(vec2(dot(pos, vec2(12.9898, 78.233)), dot(pos, vec2(-148.998, -65.233)))) * 43758.5453);
}

void fragment() {
	vec2 new_uv = UV + (rnd(UV + vec2(seed, 0.0)) - 0.5) * power;
	COLOR = vec4(_fxs(new_uv).rgb, _fxs(UV).a);


	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
