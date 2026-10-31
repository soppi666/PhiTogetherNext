shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/sobel.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float strength = 1.0;

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

void fragment()
{
	vec2 v_texCoord = UV;

    // Sobel 核
    float kernelX[9];
    float kernelY[9];

    kernelX[0] = -1.0; kernelX[1] = 0.0; kernelX[2] = 1.0;
    kernelX[3] = -2.0; kernelX[4] = 0.0; kernelX[5] = 2.0;
    kernelX[6] = -1.0; kernelX[7] = 0.0; kernelX[8] = 1.0;

    kernelY[0] = -1.0; kernelY[1] = -2.0; kernelY[2] = -1.0;
    kernelY[3] = 0.0;  kernelY[4] = 0.0;  kernelY[5] = 0.0;
    kernelY[6] = 1.0;  kernelY[7] = 2.0;  kernelY[8] = 1.0;

    vec2 texOffset[9];
    texOffset[0] = vec2(-1.0, -1.0) / resolution;
    texOffset[1] = vec2( 0.0, -1.0) / resolution;
    texOffset[2] = vec2( 1.0, -1.0) / resolution;
    texOffset[3] = vec2(-1.0,  0.0) / resolution;
    texOffset[4] = vec2( 0.0,  0.0) / resolution;
    texOffset[5] = vec2( 1.0,  0.0) / resolution;
    texOffset[6] = vec2(-1.0,  1.0) / resolution;
    texOffset[7] = vec2( 0.0,  1.0) / resolution;
    texOffset[8] = vec2( 1.0,  1.0) / resolution;

    float sumX = 0.0;
    float sumY = 0.0;
	
	vec2 uv = v_texCoord;
	vec3 originalColor = _fxs( uv).rgb;
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;
    
    for (int i = 0; i < 9; i++) {
        vec4 color = getcolor(uv + texOffset[i]);
        float intensity = dot(color.rgb, vec3(0.299, 0.587, 0.114));  // 转为灰度
        sumX += intensity * kernelX[i];
        sumY += intensity * kernelY[i];
    }

    float sobelValue = sqrt(sumX * sumX + sumY * sumY);
	
	vec3 finalColor = mix(originalColor, vec3(sobelValue), strength);
	
    COLOR = vec4(finalColor, 1.0);

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
