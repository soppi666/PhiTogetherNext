shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/liquid.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float frequency = 10.0;
uniform float amplitude = 0.02;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}



void fragment()
{
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;

    vec2 offset = vec2(sin(uv.y * frequency + u_time) * amplitude, cos(uv.x * frequency + u_time) * amplitude);

    vec2 distortedUV = uv + offset;
	
	distortedUV.x = distortedUV.x * 1.0;
	distortedUV.y = distortedUV.y / 1.0 + 0.0;

    vec4 color = _fxs( distortedUV);

    COLOR = vec4(1.0) * color;
	COLOR.a = 1.0;

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
