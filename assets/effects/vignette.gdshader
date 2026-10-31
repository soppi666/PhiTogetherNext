shader_type canvas_item;

// 移植自 PhiZone/player static/game/shaders/vignette.glsl（CC0，Adapted from shadertoy lsKSWR）
// extra.json effect: "vignette"——四角压暗。extend=0 无效果，越大暗角越重。

uniform sampler2D fx_src;
uniform vec4 color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float extend : hint_range(0.0, 1.0) = 0.25;
uniform float radius = 15.0;

vec4 _fxs(vec2 __u){
	return texture(fx_src, __u);
}

void fragment() {
	vec2 new_uv = UV * (1.0 - UV.yx);
	float vig = pow(new_uv.x * new_uv.y * radius, extend);
	COLOR = mix(color, _fxs(UV), vig);


	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
