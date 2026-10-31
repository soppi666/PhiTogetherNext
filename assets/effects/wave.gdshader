shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/wave.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float speed = 1.0;
uniform vec2 direction = vec2(1.0, 0.0);
uniform float frequency = 10.0;
uniform float amplitude = 0.02;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}


const vec2 rectMin = vec2(0.0, 0.0);
const vec2 rectMax = vec2(1.0, 1.0);
vec4 getcolor(vec2 uv)
{
	uv.x = uv.x * 1.0;
	uv.y = uv.y / 1.0 + 0.0;
	
	if (uv.x >= rectMin.x && uv.x <= rectMax.x && uv.y >= rectMin.y && uv.y <= rectMax.y)
		return _fxs( uv);
	else
		return vec4(0, 0, 0, 1);
}

void fragment() {
	vec2 v_texCoord = UV;


	vec2 uv = v_texCoord;
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;
	
    // 计算方向向量影响下的波动
    float wave = sin(dot(uv, direction * frequency) + u_time * speed) * amplitude;

    // 将波动效果应用到纹理坐标上，使其沿给定方向和速度波动
    vec2 distortedTexCoord = vec2(uv.x + wave, uv.y + wave);

    COLOR = getcolor(distortedTexCoord);
	COLOR.a = 1.0;

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
