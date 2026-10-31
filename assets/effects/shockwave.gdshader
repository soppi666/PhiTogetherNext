shader_type canvas_item;
// 移植自 player static/game/shaders/shockwave.glsl —— extra.json effect "shockwave"
uniform sampler2D fx_src;
uniform float progress = 0.2;
uniform float centerX = 0.5;
uniform float centerY = 0.5;
uniform float width = 0.1;
uniform float distortion = 0.8;
uniform float expand = 10.0;

vec4 _fxs(vec2 __u){
	return texture(fx_src, __u);
}

void fragment() {
	vec2 ss = 1.0 / SCREEN_PIXEL_SIZE;
	float aspect = ss.y / ss.x;
	vec2 center = vec2(centerX, (centerY - 0.5) * aspect + 0.5);
	vec2 tc = vec2(UV.x, (UV.y - 0.5) * aspect + 0.5);
	float dist = distance(tc, center);
	if (progress - width <= dist && dist <= progress + width) {
		float diff = dist - progress;
		float scale_diff = 1.0 - pow(abs(diff * expand), distortion);
		float dt = diff * scale_diff;
		vec2 dir = normalize(tc - center);
		tc += (dir * dt) / max(progress * dist * 40.0, 0.0001);
		vec4 col = texture(fx_src, vec2(tc.x, (tc.y - 0.5) / aspect + 0.5));
		col += (col * scale_diff) / max(progress * dist * 40.0, 0.0001);
		COLOR = vec4(col.rgb, _fxs(UV).a);
	} else {
		COLOR = vec4(texture(fx_src, vec2(tc.x, (tc.y - 0.5) / aspect + 0.5)).rgb, _fxs(UV).a);
	}


	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
