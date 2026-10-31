shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/scanline.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float power = 0.03;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}



void fragment()
{
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;
    // 读取当前像素的颜色
    vec4 color = _fxs( uv);
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;
    
    // 获取当前像素的y坐标（范围是0到1）
    float scanline = sin((uv.y * 800.0 + u_time * 5.0) * 3.14159 * 2.0); // 模拟扫描线
    float intensity = 1.0 - power * (scanline * 0.5 + 0.5);
    
    // 将扫描线的效果应用到颜色上
    color.rgb *= intensity;
    
    COLOR = color;
	COLOR.a = 1.0;

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
