shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/distortion.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float progress = 0.2;
uniform float power = 0.03;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}



const vec2 rectMin = vec2(0.0, 0.0);
const vec2 rectMax = vec2(1.0, 1.0);

void fragment()
{
	vec2 v_texCoord = UV;

    // 图像中心坐标
    vec2 center = vec2(0.5, 0.5);
	
	vec2 uv = v_texCoord;
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;
    
    // 计算当前纹理坐标到中心的向量
    vec2 direction = uv - center;
    
    // 计算距离与方向的旋转角度
    float distance = length(direction);
    
    // 控制扭曲效果，progress 控制强度
    float angle = progress * distance * power; // 调整 10.0 来控制最大扭曲
    
    // 计算旋转后的纹理坐标
    float sinAngle = sin(angle);
    float cosAngle = cos(angle);
    vec2 twistedCoord = vec2(
        direction.x * cosAngle - direction.y * sinAngle,
        direction.x * sinAngle + direction.y * cosAngle
    );
    
    // 应用扭曲后的坐标
    uv = center + twistedCoord;
	uv.x = uv.x * 1.0;
	uv.y = uv.y / 1.0 + 0.0;

	if (uv.x >= rectMin.x && uv.x <= rectMax.x && uv.y >= rectMin.y && uv.y <= rectMax.y) {
		vec4 color = _fxs( uv);
		COLOR = color;
		COLOR.a = 1.0;
	} else {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	}

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
