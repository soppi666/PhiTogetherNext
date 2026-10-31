shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/oil_painting.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float radius = 15.0;
uniform float sampleCount = 3.0;

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
		return vec4(0.0, 0.0, 0.0, 1.0);
}

void fragment()
{
	vec2 v_texCoord = UV;

    // 计算步长，基于采样次数
    float stepW = radius / (sampleCount);
    float stepH = radius / (sampleCount);

    // 存储采样颜色
    vec3 colorSum = vec3(0.0);
    vec3 maxColor = vec3(0.0);
    int maxCount = 0;
	
	vec2 uv = v_texCoord;
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;

    // 模拟多个方向上的采样，创造出模糊的“笔触”效果
    for (float i = -sampleCount; i <= sampleCount; i++)
    {
        for (float j = -sampleCount; j <= sampleCount; j++)
        {
            // 计算采样的偏移量
            vec2 offset = vec2(i * stepW, j * stepH);
            vec3 sampleColor = getcolor(uv + offset).rgb;

            // 累计颜色
            colorSum += sampleColor;

            // 记录出现最多的颜色
            int count = 0;
            for (float m = -1.0; m <= 1.0; m++)
            {
                for (float n = -1.0; n <= 1.0; n++)
                {
                    vec3 compareColor = getcolor(uv + vec2(m * stepW, n * stepH)).rgb;
                    if (distance(sampleColor, compareColor) < 0.1)
                    {
                        count++;
                    }
                }
            }

            if (count > maxCount)
            {
                maxCount = count;
                maxColor = sampleColor;
            }
        }
    }

    // 将最多颜色与整体颜色混合，形成油画效果
    vec3 finalColor = mix(colorSum / float((2.0 * sampleCount + 1.0) * (2.0 * sampleCount + 1.0)), maxColor, 0.6);
    COLOR = vec4(finalColor, 1.0);

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
