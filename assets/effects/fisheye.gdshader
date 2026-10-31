shader_type canvas_item;
// 移植自 player static/game/shaders/fisheye.glsl —— extra.json effect "fisheye"
uniform sampler2D fx_src;
uniform float power = -0.1;

vec4 _fxs(vec2 __u){
	return texture(fx_src, __u);
}

void fragment() {
	vec2 ss = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 p = vec2(UV.x, UV.y * ss.y / ss.x);
	float aspect = ss.x / ss.y;
	vec2 m = vec2(0.5, 0.5 / aspect);
	vec2 d = p - m;
	float r = sqrt(dot(d, d));
	float np = (2.0 * 3.141592 / (2.0 * sqrt(dot(m, m)))) * power;
	float bind = np > 0.0 ? sqrt(dot(m, m)) : (aspect < 1.0 ? m.x : m.y);
	vec2 nuv;
	if (np > 0.0) {
		nuv = m + normalize(d) * tan(r * np) * bind / tan(bind * np);
	} else {
		nuv = m + normalize(d) * atan(r * -np * 10.0) * bind / atan(-np * bind * 10.0);
	}
	COLOR = vec4(_fxs(vec2(nuv.x, nuv.y * aspect)).rgb, _fxs(UV).a);


	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
