shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/rainbow.glsl
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
    // 从纹理获取图像的颜色
    vec4 textureColor = _fxs( uv);
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;

    // 获取纹理坐标的横纵比例
    float coordFactor = mod(uv.x + uv.y, 1.0);
    
    // 生成彩虹色光效果
    vec3 rainbowColor = vec3(sin(6.2831 * coordFactor), sin(6.2831 * (coordFactor + 0.33)), sin(6.2831 * (coordFactor + 0.66)));
    
    // 调整彩虹色的强度
    rainbowColor = 0.5 * rainbowColor + 0.5;

    // 通过 power 控制叠加彩虹色的强度
    vec4 finalColor = vec4(mix(textureColor.rgb, rainbowColor, power), textureColor.a);
    
    COLOR = finalColor * vec4(1.0);
	COLOR.a = 1.0;

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
