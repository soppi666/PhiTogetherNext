shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/burn.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float progress = 0.2;
uniform vec4 burnColor = vec4(1.0, 0.2, 0.0, 1.0);

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}


// 生成伪随机数
float random(vec2 co) {
    return fract(sin(dot(co.xy, vec2(12.9898, 78.233))) * 43758.5453);
}

// 噪声函数，基于 uv 坐标生成噪声
float noise(vec2 uv) {
    vec2 p = floor(uv);
    vec2 f = fract(uv);
    // 使用双线性插值平滑噪声
    float a = random(p);
    float b = random(p + vec2(1.0, 0.0));
    float c = random(p + vec2(0.0, 1.0));
    float d = random(p + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

void fragment() {
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;
    vec4 color = _fxs( uv);
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;

    // 动态噪声，使用 uv 坐标和时间生成不规则噪声
    float burnNoise = noise(uv * 10.0 + vec2(u_time * 0.5, u_time * 0.5));
    
    // 控制燃烧效果的进展
    float burnFactor = progress - burnNoise;


    if (burnFactor < 0.0) {
        // 未燃烧部分，保留原始颜色
        COLOR = color;
		COLOR.a = 1.0;
    } else {
        // 燃烧中的区域，渐变为燃烧颜色并逐渐透明
        vec4 burnedColor = mix(color, burnColor, burnFactor);
        burnedColor.a = mix(1.0, 0.0, burnFactor);
        COLOR = burnedColor;
    }

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
