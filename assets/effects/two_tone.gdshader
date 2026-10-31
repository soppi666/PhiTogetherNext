shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/two_tone.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform vec4 color1 = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 color2 = vec4(1.0, 1.0, 1.0, 1.0);
uniform float threshold = 0.5;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}



void fragment() {
	vec2 v_texCoord = UV;

    vec4 texColor = _fxs( v_texCoord);  // 获取纹理颜色
    float brightness = dot(texColor.rgb, vec3(0.299, 0.587, 0.114));  // 计算亮度

    vec4 finalColor = brightness < threshold ? color1 : color2;  // 根据亮度应用不同颜色
    // 使用纹理的透明度来调整最终的 alpha
    COLOR = vec4(finalColor.rgb, 1.0);

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
