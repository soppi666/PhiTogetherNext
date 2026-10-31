shader_type canvas_item;

// 移植自 player static/game/shaders/grayscale.glsl —— extra.json effect "grayscale"
uniform sampler2D fx_src;
uniform float factor : hint_range(0.0, 1.0) = 1.0;

vec4 _fxs(vec2 __u){
	return texture(fx_src, __u);
}

void fragment() {
	vec4 c = _fxs(UV);
	vec3 gray = vec3(dot(vec3(0.299, 0.587, 0.114), c.rgb));
	COLOR = vec4(mix(c.rgb, gray, factor), _fxs(UV).a);


	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
