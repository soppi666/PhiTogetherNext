shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/flare.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform vec2 lightpos = vec2(0.5, 0.5);
uniform float power = 0.03;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}



void fragment()
{
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;

    vec4 color = _fxs( uv);
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;
    
    // 根据屏幕分辨率调整uv坐标的比例，保持宽高比
    vec2 norm_uv = (uv * resolution - resolution * 0.5) / resolution.y;
    vec2 norm_lightpos = (lightpos * resolution - resolution * 0.5) / resolution.y;

    // 计算当前像素与光源位置的距离
    float distance = length(norm_uv - norm_lightpos);

    // 根据距离计算炫光效果，距离越近效果越强
    float glow = power / (distance * distance);

    // 混合炫光效果和原始颜色
    vec3 finalColor = color.rgb + vec3(glow);

    // 输出最终颜色
    COLOR = vec4(finalColor, 1.0);

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
