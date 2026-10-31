shader_type canvas_item;
// Ported from rpe-next assets/rpe/shaders/heat_distortion.glsl
// rpe-next (kclg-YSJ) is licensed under PolyForm Noncommercial 1.0.0.
render_mode unshaded;

uniform sampler2D fx_src;
uniform float fx_stage = 1.0;
uniform float u_time = 0.0;
uniform vec2 resolution = vec2(1350.0, 900.0);
uniform float strength = 1.0;
uniform float frequency = 10.0;

vec4 _fxs(vec2 p) {
    vec4 c = texture(fx_src, p);
    return c.a > 0.0001 ? vec4(c.rgb / c.a, c.a) : c;
}


// 生成噪声函数（类似于简单的Perlin噪声）
float rand(vec2 co)
{
    return fract(sin(dot(co.xy ,vec2(12.9898, 78.233))) * 43758.5453);
}

// 生成二维噪声
float noise(vec2 pos)
{
    vec2 i = floor(pos);
    vec2 f = fract(pos);
    
    // 使用不同的随机种子生成不同的噪声值
    float a = rand(i);
    float b = rand(i + vec2(1.0, 0.0));
    float c = rand(i + vec2(0.0, 1.0));
    float d = rand(i + vec2(1.0, 1.0));
    
    // 进行插值来平滑噪声
    vec2 u = f*f*(3.0-2.0*f);
    
    return (mix(a, b, u.x) + (c - a)* u.y * (1.0 - u.x) + (d - b) * u.x * u.y) * 2.0 - 1.0;
}

const vec2 rectMin = vec2(0.0, 0.0);
const vec2 rectMax = vec2(1.0, 1.0);

void fragment()
{
	vec2 v_texCoord = UV;

	vec2 uv = v_texCoord;
	vec4 oriColor = _fxs( uv);
	
	uv.x = uv.x / 1.0;
	uv.y =(uv.y - 0.0) * 1.0;
	
    // 使用时间和纹理坐标生成动态噪声
    vec2 noiseCoord = uv * 5.0 + vec2(u_time * frequency, u_time * frequency);  // 缩放噪声纹理
    float noiseValue = noise(noiseCoord);
    
    // 使用噪声值生成扰动
    vec2 distortedTexCoords = uv + vec2(noiseValue) * strength;
	
	uv.x = distortedTexCoords.x * 1.0;
	uv.y = distortedTexCoords.y / 1.0 + 0.0;

	if (uv.x >= rectMin.x && uv.x <= rectMax.x && uv.y >= rectMin.y && uv.y <= rectMax.y) 
	{
		COLOR = _fxs( uv);
	}
	else
	{
		COLOR = vec4(0, 0, 0, 1);
	}
	COLOR.a = 1.0;

	if (fx_stage < 0.5) { COLOR.a = _fxs(UV).a; }
	float __s = max(max(COLOR.r, COLOR.g), COLOR.b);
	float __a = max(COLOR.a, __s);
	COLOR.rgb = __a > 0.0001 ? COLOR.rgb / __a : vec3(0.0);
	COLOR.a = __a;
}
