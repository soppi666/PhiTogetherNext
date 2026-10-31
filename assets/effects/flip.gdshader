shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/flip.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float direction = 1.0;
uniform float progress = 0.2;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}

// 传入的方向：0 表示水平翻转，1 表示垂直翻转
// 翻转进度，0 表示未翻转，1 表示翻转完成
// 纹理
// 纹理坐标

const vec2 rectMin = vec2(0.0, 0.0);
const vec2 rectMax = vec2(1.0, 1.0);

void fragment() {
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;

	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;
	
	if (direction == 0.0) {
        // 水平翻转
        // 在 progress 为 0 时保持正常, progress 为 1 时完全翻转
		float adjusted_x;

		if (progress < 0.5) {
			adjusted_x = 0.5 + (uv.x - 0.5) / (0.5 - progress);
		} else if (progress == 0.5) {
			adjusted_x = (uv.x < 0.5) ? -1.0 / 0.0 : 1.0 / 0.0; 
		} else {
			adjusted_x = mix(0.5 + (uv.x - 0.5) / (0.5 - progress), 1.0 - uv.x, (progress - 0.5) * 2.0);
		}

		uv.x = mix(uv.x, adjusted_x, progress);
    } else {
        // 垂直翻转
        // 在 progress 为 0 时保持正常, progress 为 1 时完全翻转
		float adjusted_y;

		if (progress < 0.5) {
			adjusted_y = 0.5 + (uv.y - 0.5) / (0.5 - progress);
		} else if (progress == 0.5) {
			adjusted_y = (uv.y < 0.5) ? -1.0 / 0.0 : 1.0 / 0.0; 
		} else {
			adjusted_y = mix(0.5 + (uv.y - 0.5) / (0.5 - progress), 1.0 - uv.y, (progress - 0.5) * 2.0);
		}
		
		uv.y = mix(uv.y, adjusted_y, progress);
    }
	

	uv.x = uv.x * 1.0;
	uv.y = uv.y / 1.0 + 0.0;

	if (uv.x >= rectMin.x && uv.x <= rectMax.x && uv.y >= rectMin.y && uv.y <= rectMax.y) {
		// 如果在矩形内，取样纹理颜色
		vec4 color = _fxs( uv);
		COLOR = color;
		COLOR.a = 1.0;
	} else {
		// 如果在矩形外，置为黑色
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	}

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
