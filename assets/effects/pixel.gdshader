shader_type canvas_item;
// 移植自 player static/game/shaders/pixel.glsl —— extra.json effect "pixel"
uniform sampler2D fx_src;
uniform float size = 10.0;

vec4 _fxs(vec2 __u){
	return texture(fx_src, __u);
}

void fragment() {
	vec2 factor = (1.0 / SCREEN_PIXEL_SIZE) / max(size, 0.001);
	vec2 q = floor(UV * factor + 0.5) / factor;
	COLOR = vec4(_fxs(q).rgb, _fxs(UV).a);


	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
