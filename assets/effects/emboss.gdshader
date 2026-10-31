shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/emboss.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float strength = 1.0;

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
void fragment()
{
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;
	vec4 originalColor = _fxs( uv);
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;
	
    // 获取纹理像素的偏移量
    vec2 offset = vec2(1.0 / resolution.x, 1.0 / resolution.y);

    // 获取周围的像素颜色
    vec4 colorTL = getcolor(uv + vec2(-offset.x, -offset.y)); // 左上
    vec4 colorBR = getcolor(uv + vec2(offset.x, offset.y));   // 右下

    // Emboss 卷积核计算
    vec4 embossColor = colorTL - colorBR;

    // 调整对比度
    embossColor += vec4(0.5, 0.5, 0.5, 1.0);
	
	embossColor = clamp(embossColor, 0.0, 1.0);
	
	vec4 finalColor = mix(originalColor, embossColor, strength);
    COLOR = finalColor;
	
	COLOR.a = 1.0;

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
