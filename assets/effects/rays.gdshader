shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/rays.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform vec2 lightpos = vec2(0.5, 0.5);
uniform float exposure = 1.0;
uniform float decay = 1.0;
uniform float density = 1.0;
uniform float weight = 0.5;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}
// GodRays.frag



const vec2 rectMin = vec2(0.0, 0.0);
const vec2 rectMax = vec2(1.0, 1.0);
vec4 getcolor(vec2 uv)
{
	uv.x = uv.x * 1.0;
	uv.y = uv.y / 1.0 + 0.0;
	
	if (uv.x >= rectMin.x && uv.x <= rectMax.x && uv.y >= rectMin.y && uv.y <= rectMax.y)
		return _fxs( uv);
	else
		return vec4(0.0, 0.0, 0.0, 1.0);
}


void fragment()
{
	vec2 v_texCoord = UV;

    // 从纹理中获取当前像素的颜色
    vec4 color = _fxs( v_texCoord);
	
	vec2 uv = v_texCoord;
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;

    // 光源到当前像素的方向
    vec2 deltaTexCoord = uv - lightpos;

    // 迭代次数决定光束的长度
    float illuminationDecay = 1.0;
    vec4 godRays = vec4(0.0);

    // 采样次数，可以根据需要调整
    const int samples = 100;

    for (int i = 0; i < samples; i++)
    {
        // 沿光束方向逐渐采样
        uv -= deltaTexCoord * density;
        vec4 sampleColor = getcolor(uv);

        // 逐步衰减
        sampleColor *= illuminationDecay * weight;

        // 累加结果
        godRays += sampleColor;

        // 计算衰减
        illuminationDecay *= decay;
    }

    // 将 God Rays 叠加到原始颜色上
    color += godRays * exposure;

    COLOR = color;
	COLOR.a = 1.0;

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
