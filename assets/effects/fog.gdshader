shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/fog.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform vec4 fogColor = vec4(0.5, 0.5, 0.5, 1.0);
uniform float fogStart = 0.0;
uniform float fogEnd = 1.0;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}



void fragment() {
	vec2 v_texCoord = UV;

    // 读取纹理颜色
	vec2 uv = v_texCoord;
    vec4 color = _fxs( uv);
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;

    // 使用Y坐标计算雾的基础浓度
    float fogFactor = clamp((fogEnd - uv.y) / (fogEnd - fogStart), 0.0, 1.0);


    // 将雾的颜色与原始颜色混合
    vec4 finalColor = mix(fogColor, color, fogFactor);

    COLOR = vec4(finalColor.rgb, 1.0); // 最终颜色，使用原始透明度

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
