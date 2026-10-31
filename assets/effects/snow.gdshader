shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/snow.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float speedx = 1.0;
uniform float speedy = 1.0;
uniform float snowCount = 100.0;
uniform float size = 3.0;
uniform vec4 color = vec4(0.0, 0.0, 0.0, 1.0);

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}


// 随机函数，用于生成雪花随机位置
float random(vec2 st) {
    return fract(sin(dot(st.xy, vec2(12.9898, 78.233))) * 43758.5453123);
}

// 模拟雪花飘落
void fragment() {
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;

    // 获取背景颜色
    vec4 bgColor = _fxs( uv);
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;

    // 初始化颜色
    vec4 snowColor = color; // 白色雪花，透明度为0表示未覆盖
	bool cover = false;

    // 遍历雪花
    for (float i = 0.0; i < snowCount; i++) {
        // 基于时间和索引生成随机雪花位置
        float xRandom = random(vec2(i, i)) * resolution.x;
        float yRandom = random(vec2(i, i)) * resolution.y;

        // 雪花的初始位置
		vec2 snowPos = vec2(
			mod(xRandom + sin(u_time + i) * speedx * (1.0 + random(vec2(i, i)) / 5.0), resolution.x), // 基于传入的横向速度
			mod(resolution.y - mod(u_time * speedy + yRandom + i * 30.0, resolution.y), resolution.y) * (1.0 + random(vec2(i + 1.0, i + 1.0)) / 5.0) // 基于传入的纵向速度
		);

		float baseSize = size; // 基础大小
        float sizeVariation = 0.004; // 大小变化幅度
        float _size = baseSize + sizeVariation * sin(u_time + i);

        // 计算当前像素与雪花位置的距离
        float dist = distance(uv * resolution, snowPos);

        // 如果像素位于雪花内，则设置雪花颜色
        if (dist < _size * resolution.x) {
            float alpha = smoothstep(_size * resolution.x, 0.0, dist);
            snowColor = mix(snowColor, vec4(1.0, 1.0, 1.0, alpha), alpha);
			cover = true;
        }
    }

	if(cover == true)
	{
		// 将雪花叠加到背景图片上
		COLOR = mix(bgColor, snowColor, snowColor.a);
		COLOR.a = 1.0;
	}
	else
	{
		COLOR = bgColor;
		COLOR.a = 1.0;
	}

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
