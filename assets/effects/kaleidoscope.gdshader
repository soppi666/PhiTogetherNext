shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/kaleidoscope.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float segments = 8.0;
uniform vec2 center = vec2(0.5, 0.5);
uniform float angle = 0.0;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}


const vec2 rectMin = vec2(0.0, 0.0);
const vec2 rectMax = vec2(1.0, 1.0);


void fragment() {
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;
	
	uv = uv - center;  // 转换坐标到中心点
    float theta = atan(uv.y, uv.x) + angle;  // 计算角度并加入旋转
    float radius = length(uv);  // 计算半径

    // 计算角度映射到分段的区域
    float segAngle = 3.1415926 * 2.0 / segments;
    theta = mod(theta, segAngle);
    theta = abs(theta - segAngle / 2.0);  // 镜像变换

    // 重新计算 UV 坐标
    vec2 newUV = vec2(cos(theta), sin(theta)) * radius + center;
	
	newUV.x = newUV.x * 1.0;
	newUV.y = newUV.y / 1.0 + 0.0;
	
	if (newUV.x >= rectMin.x && newUV.x <= rectMax.x && newUV.y >= rectMin.y && newUV.y <= rectMax.y) {
		vec4 color = _fxs( newUV);
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
