shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/flowing.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float speed = 1.0;
uniform float power = 0.03;
uniform float width = 0.1;
uniform vec4 color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec2 direction = vec2(1.0, 0.0);

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}



void fragment() {
	vec2 v_texCoord = UV;

	vec3 lightColor = color.rgb;

    vec2 uv = v_texCoord;
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;

    float lightPos = mod(u_time * speed, 1.0);
    float halfWidth = width / 2.0;

    float dist = abs(dot(uv - vec2(lightPos, lightPos), direction));

    float intensity = smoothstep(halfWidth, 0.0, dist) * power;
	
	uv.x = uv.x * 1.0;
	uv.y = uv.y / 1.0 + 0.0;

    vec4 _srcColor = _fxs( uv);

    vec3 resultColor = _srcColor.rgb + lightColor * intensity;

    COLOR = vec4(clamp(resultColor, 0.0, 1.0), 1.0);

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
