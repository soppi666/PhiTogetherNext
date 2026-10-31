shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/camera.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float zoom = 1.0;
uniform vec2 offset = vec2(0.0, 0.0);
uniform float rotation = 0.0;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}



// 控制变量：缩放倍率、中心偏移、旋转角度

const vec2 rectMin = vec2(0.0, 0.0);
const vec2 rectMax = vec2(1.0, 1.0);

void fragment()
{
	vec2 v_texCoord = UV;

	vec2 uv = v_texCoord;
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;

    vec2 centeredCoord = uv - vec2(0.5, 0.5);
	float scale = resolution.y / resolution.x;
	centeredCoord.x = centeredCoord.x / scale;

    centeredCoord /= zoom;

    float sinAngle = sin(rotation * 3.1415926 / 180.0);
    float cosAngle = cos(rotation * 3.1415926 / 180.0);
    vec2 rotatedCoord = vec2(
        cosAngle * centeredCoord.x - sinAngle * centeredCoord.y,
        sinAngle * centeredCoord.x + cosAngle * centeredCoord.y
    );
	
	rotatedCoord.x = rotatedCoord.x * scale;

    rotatedCoord -= offset;

    uv = rotatedCoord + vec2(0.5, 0.5);
	
	uv.x = uv.x * 1.0;
	uv.y = uv.y / 1.0 + 0.0;
	
	if (uv.x >= rectMin.x && uv.x <= rectMax.x && uv.y >= rectMin.y && uv.y <= rectMax.y) 
	{
		COLOR = _fxs( uv);
		COLOR.a = 1.0;
	} 
	else 
	{
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	}

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
