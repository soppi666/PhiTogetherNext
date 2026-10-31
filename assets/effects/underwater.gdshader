shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/underwater.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}


void fragment() {
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;
	vec4 color = _fxs( uv);
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;
	
    float wave = sin(uv.y * 10.0 + u_time * 5.0) * 0.01;
    uv.x += wave;

    // 为水下效果添加蓝绿色调
    vec3 underwaterColor = vec3(0.0, 0.4, 0.6);
    color.rgb = mix(color.rgb, underwaterColor, 0.4);

    // 添加一些模糊来模拟水的光线散射
    float blur = sin(u_time * 1.5) * 0.005;
	uv = uv + vec2(blur, blur);
	
	uv.x = uv.x * 1.0;
	uv.y = uv.y / 1.0 + 0.0;
	
    vec4 blurColor = _fxs( uv) * 0.9;
    color = mix(color, blurColor, 0.5);

    // 输出最终颜色
    COLOR = color;
	COLOR.a = 1.0;

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
