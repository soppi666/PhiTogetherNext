shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/bokeh.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float blurRadius = 1.0;
uniform float intensity = 1.0;
uniform vec2 center = vec2(0.5, 0.5);
uniform float radius = 15.0;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}



// 计算基于焦点的模糊强度
float computeBlurRadius(vec2 uv) {
    // 计算当前像素位置与焦点的距离
    float distanceToFocus = distance(uv, center);
    
    // 通过焦点半径控制模糊，距离焦点越远模糊越大
    float normalizedDistance = clamp((distanceToFocus - radius) / (1.0 - radius), 0.0, 1.0);
    
    return blurRadius * normalizedDistance;
}

// 高斯模糊核权重
float gaussian(vec2 offset, float rad) {
    return exp(-dot(offset, offset) / (2.0 * rad * rad)) / (2.0 * 3.14159265359 * rad * rad);
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

// 模糊函数
vec4 blur(vec2 uv, float rad) {
	if (rad <= 0.5) {
        return getcolor(uv + vec2(0, 0));
    }
    vec4 color = vec4(0.0);
    float total = 0.0;

    for (float x = -rad; x <= rad; x++) {
        for (float y = -rad; y <= rad; y++) {
            vec2 offset = vec2(x, y) / resolution;
            float weight = gaussian(vec2(x, y), rad);
            color += getcolor(uv + offset * intensity) * weight;
            total += weight;
        }
    }

    return color / total;
}


void fragment() {
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;
    uv.x = uv.x / 1.0;
    uv.y = (uv.y - 0.0) * 1.0;
	
    float adaptiveBlurRadius = computeBlurRadius(uv); // 计算自适应模糊半径
    vec4 blurredColor = blur(uv, adaptiveBlurRadius); // 使用自适应模糊
    COLOR = blurredColor;
	COLOR.a = 1.0;

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
