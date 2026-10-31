shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/hologram.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform vec4 hologramColor = vec4(0.0, 1.0, 1.0, 1.0);

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
    
    // 颜色分离模拟 RGB 光的衍射效果
    float offset = sin(uv.y * 40.0 + u_time * 5.0) * 0.004;
    vec4 color;
    color.r = getcolor(uv + vec2(offset, 0.0)).r;
    color.g = getcolor(uv + vec2(0.0, 0.0)).g;
    color.b = getcolor(uv + vec2(offset, 0.0)).b;
    
    // 加入扫描线效果
    float scanline = sin((uv.y + u_time * 0.5) * 100.0) * 0.1;
    color.rgb -= scanline;
    
    // 应用 Hologram 颜色调制
    color *= hologramColor;

    // 模拟全息静电噪声
    float noise = fract(sin(dot(uv * u_time, vec2(12.9898, 78.233))) * 43758.5453);
    color.rgb += noise * 0.05;
    
    // 输出最终效果
    COLOR = color;
	COLOR.a = 1.0;

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
