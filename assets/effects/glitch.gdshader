shader_type canvas_item;
// 移植自 player static/game/shaders/glitch.glsl —— extra.json effect "glitch"
// time：player 由场景时钟驱动；这里默认用引擎 TIME，vars 若给 time 则覆盖
uniform sampler2D fx_src;
uniform float time = 0.0;
uniform float power = 0.03;
uniform float rate : hint_range(0.0, 1.0) = 0.6;
uniform float speed = 5.0;
uniform float blockCount = 30.5;
uniform float colorRate : hint_range(0.0, 1.0) = 0.01;

vec4 _fxs(vec2 __u){
	return texture(fx_src, __u);
}

float my_trunc(float x) { return x < 0.0 ? -floor(-x) : floor(x); }
float rnd1(float sd) { return fract(543.2543 * sin(dot(vec2(sd, sd), vec2(3525.46, -54.3415)))); }

void fragment() {
	float t = time > 0.0 ? time : TIME;
	float enable = float(rnd1(my_trunc(t * speed)) < rate);
	vec2 fuv = UV;
	fuv.x += (rnd1(my_trunc(UV.y * blockCount) / blockCount + t) - 0.5) * power * enable;
	vec4 pc = _fxs(fuv);
	pc.r = mix(pc.r, _fxs(fuv + vec2(colorRate, 0.0)).r, enable);
	pc.b = mix(pc.b, _fxs(fuv + vec2(-colorRate, 0.0)).b, enable);
	COLOR = vec4(pc.rgb, _fxs(UV).a);


	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
