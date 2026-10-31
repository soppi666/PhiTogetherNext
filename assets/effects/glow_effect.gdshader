shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/glow_effect.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float intensity = 1.0;
uniform float threshold = 0.5;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}



const vec2 rectMin = vec2(0.0, 0.0);
const vec2 rectMax = vec2(1.0, 1.0);
vec4 getcolor(vec2 uv)
{
	uv.x = uv.x * 1.0;
	uv.y = uv.y / 1.0 + 0.0;
	
	if (uv.x >= rectMin.x && uv.x <= rectMax.x && uv.y >= rectMin.y && uv.y <= rectMax.y)
		return _fxs( uv);
	else
		return vec4(0, 0, 0, 1);
}

float calculateLuminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

void fragment() {
	vec2 v_texCoord = UV;

    vec2 uv = v_texCoord;
    vec3 color = _fxs( uv).rgb;
	
    uv.x = uv.x / 1.0;
    uv.y = (uv.y - 0.0) * 1.0;

    float luminance = calculateLuminance(color);
  
    vec3 bloom = vec3(0.0);
    
    if (luminance > threshold) {
        for (int x = -2; x <= 2; x++) {
            for (int y = -2; y <= 2; y++) {
                vec2 offset = vec2(float(x), float(y)) / resolution;
                vec3 sampleColor = getcolor(uv + offset).rgb;
                bloom += sampleColor;
            }
        }
        bloom /= 25.0;
        bloom *= intensity;
    }
	
    vec3 finalColor = color + bloom;
    
    COLOR = vec4(finalColor, 1.0);

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
