shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/image_noise.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float power = 0.2;
uniform float density = 400.0;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}


float rand(vec2 co) {
    return fract(sin(dot(co.xy * u_time * 0.05, vec2(12.9898, 78.233))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 ip = floor(p);
    vec2 u = fract(p);
    u = u*u*(3.0-2.0*u);
    
    float res = mix(
        mix(rand(ip), rand(ip + vec2(1.0, 0.0)), u.x),
        mix(rand(ip + vec2(0.0, 1.0)), rand(ip + vec2(1.0, 1.0)), u.x),
        u.y
    );
    return res;
}

void fragment() {
	vec2 v_texCoord = UV;

	vec2 uv = v_texCoord;
    vec4 color = _fxs( v_texCoord);
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;
    
    // 噪点随时间变化，加入uv扰动
    float noisyFactor = noise(uv * density + u_time * 0.1) * 2.0 - 1.0;
    
    // 添加噪点
    vec4 noisyColor = color + vec4(vec3(noisyFactor) * power, 0.0);
    
    COLOR = noisyColor;
    COLOR.a = 1.0;

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}