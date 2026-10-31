shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/night_vision.glsl
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



// 生成随机噪声
float random(vec2 uv) {
    return fract(sin(dot(uv.xy, vec2(12.9898, 78.233))) * 43758.5453123);
}

void fragment() {
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;
	vec4 color = _fxs( uv);

	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;

    // 将颜色转换为灰度
    float gray = dot(color.rgb, vec3(0.299, 0.587, 0.114));

    // 添加绿色滤镜
    vec3 nightVisionColor = vec3(0.1, 1.0, 0.1) * gray;

    // 添加随机噪点
    float noise = random(uv + u_time * 0.1);
    nightVisionColor += noise * 0.1;

    // 使用传入的 power 变量来增强亮度
    nightVisionColor = clamp(nightVisionColor * power, 0.0, 1.0);

    // 计算当前像素到屏幕中心的距离
    vec2 center = vec2(0.5, 0.5);
    float dist = distance(uv, center);

    // 控制 vignette 渐晕效果的强度和大小
    float vignette = smoothstep(0.4, 0.8, dist);

    // 将 vignette 效果应用到颜色上，边缘颜色变暗
    nightVisionColor *= (1.0 - vignette * 0.8);

    // 输出最终的颜色
    COLOR = vec4(nightVisionColor, 1.0);

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
