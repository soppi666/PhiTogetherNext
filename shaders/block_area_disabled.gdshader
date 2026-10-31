shader_type canvas_item;
// 预警层（blockArea 的 Disabled 相）—— 逐式移植 Phira-Pro 的
// `prpr/src/core/block_shader_full.frag` 里的 `disabledColor(float mask)`
// （uLayer==0 分支；main() 就一句 `gl_FragColor = disabledColor(disabledMask) * color`）。
//
// 官方原式（已把 SSA 还原成表达式）：
//   rgb   = 常量 (1, 84/255, 84/255)（uColored==0；带逐区配色时改采样 uDisabledColors）
//   mask  = uMasks.a 按效果网格吸附；mask<1e-4 ⇒ discard
//   t     = uUnityTime.x * uDisabledSpeed            ← 预警自己的位移速度 0.3
//   a,b   = uDisplaceTex(disabledDisplaceUV + t·dir / + t·perp)
//   avg   = (a+b)*0.5
//   disp  = dir*(b-0.5) + perp*(a-0.5)
//   spark = uSparkTex(disp*uDisabledSparkIntensity + sparkUV)
//   grain = spark * uDisabledSparkTint * avg * uDisabledSparkOpacity
//   fill  = uDisabledFillColor * uDisabledFillOpacity
//   result.rgb = mask * (grain + fill)；result.a = 1.0
// ⇒ **这一层完全不采现场**（没有 uScene / snapshotSample），mask 乘在 rgb 上、
//   alpha 恒 1，配合"源因子 ONE"就是纯加色。所以预警是"淡红底 + 会动的火花"，
//   不是压暗、也不是半透明纱。
//
// 我在这条上连翻三次车，记录一下免得再犯：
//   ① 平涂纯红 (1,0,0)×0.5 不读现场 —— 不是官方写法；
//   ② blend_add + "uDisabledFillColor × 采到的现场" —— 现场乘进去就变成整片提亮/发灰，
//      官方根本没有这次采样（那次 WebFetch 摘要给的 "uDisabledFillColor.xyz * sampled_scene"
//      是错的，拿到 .frag 原文才对上）；
//   ③ premul + 乘现场 —— 变成一层均匀的暗纱，就是用户说的"纯色遮罩、没有纹理"。
// 纹理感来自 grain：PointNoise 的稀疏亮点 × BlockNoise 的局部均值，随 uDisabledSpeed 漂。
//
// Godot 的内置 blend_add = (SRC_ALPHA, ONE)，官方这里 alpha 恒 1 ⇒ 等价于直接加 rgb。
render_mode blend_add;

uniform sampler2D uMasks : filter_linear;          // A = disabled 合成掩码（R/G/B 是 Active 的，这里不读）
uniform sampler2D uDisplaceTex : filter_nearest;   // BlockNoise1
uniform sampler2D uSparkTex : filter_nearest, repeat_enable; // PointNoise
uniform float uTime = 0.0;
uniform vec2 uScreen = vec2(1280.0, 720.0);
uniform vec4 uETS = vec4(0.0029762, 0.0044643, 336.0, 224.0);
uniform float uAlphaMul = 1.0;
// 逐区配色（同 Active 层，另一张调色板：Disabled 层用的是**未位移**的 disabled 掩码，
// 所以颜色播种走 layer=1（普通 L2 / 减算 L3 + rawg 的 SubtractBlockBlender 结果）
uniform int uColored = 0;
uniform sampler2D uDisabledColors : filter_nearest;

// ── 官方常量（prpr/src/core/block_shader.rs 的 COLORS/FLOATS 表）──
uniform vec4 uDisabledFillColor : source_color = vec4(0.49705882, 0.13725491, 0.13725491, 1.0);
uniform float uDisabledFillOpacity = 0.4;
uniform vec3 uDisabledSparkTint = vec3(0.311, 0.078, 0.078);
uniform float uDisabledSparkOpacity = 3.5;
uniform float uDisabledSparkIntensity = 2.29;
uniform float uDisabledSpeed = 0.3;
// uColored==0 时的默认区色：DEFAULT_BLOCK_COLOR = [1, 84/255, 84/255]
uniform vec3 DEFAULT_BLOCK_COLOR = vec3(1.0, 0.32941176, 0.32941176);

// 官方 blockPalette（frag:551-560）：把原生红材质的饱和度/明度搬到目标色上。
// uColored==0 或目标色就是默认红 ⇒ 原样返回 native（prpr 干脆把整条调用替换掉）。
vec3 blockPalette(vec3 nativeColor, vec3 rgb) {
	if (uColored == 0 || all(lessThan(abs(rgb - DEFAULT_BLOCK_COLOR), vec3(0.001)))) {
		return nativeColor;
	}
	float high = max(rgb.r, max(rgb.g, rgb.b));
	float low = min(rgb.r, min(rgb.g, rgb.b));
	float delta = high - low;
	if (delta < 0.00001) {
		return vec3(nativeColor.r * high);
	}
	vec3 hue = (rgb - low) / delta;
	float saturation = (1.0 - nativeColor.g / max(nativeColor.r, 0.00001))
			* (delta / max(high, 0.00001)) / (1.0 - 84.0 / 255.0);
	return nativeColor.r * high * mix(vec3(1.0), hue, clamp(saturation, 0.0, 1.0));
}
// 位移方向与 Active 同一条（_DisplaceDirection=(1,1,0,0)）
uniform vec4 _DisplaceDirection = vec4(1.0, 1.0, 0.0, 0.0);

vec2 mirror_fold(vec2 p) {
	p = mod(p, 2.0);
	return mix(p, 2.0 - p, step(vec2(1.0), p));
}

vec2 base_pixel_uv(vec2 uv) {
	return (floor(uv * uETS.zw) + 0.5) / uETS.zw;
}

void fragment() {
	vec2 fuv = vec2(UV.x, 1.0 - UV.y);   // 官方 fieldUV 是 y 向上
	// 官方 clipHalfWidth = uView.y*0.888889/uView.x：横向约束在 16:9 居中框内
	float clip_half_width = (uScreen.y / uScreen.x) * (16.0 / 18.0);
	if (clip_half_width - abs(fuv.x - 0.5) < 0.0) {
		discard;
	}
	float mask = texture(uMasks, base_pixel_uv(fuv)).a;
	if (mask - 1e-4 < 0.0) {
		discard;
	}
	// 官方 blockPalette(native, rgb)：uColored==0 时原样返回 native
	vec2 dir = normalize(_DisplaceDirection.xy);
	vec2 perp = vec2(-dir.y, dir.x);
	float t = uTime * uDisabledSpeed;      // 注意：Active 那边是 uTime/20*speed，这里官方直接用时间×speed
	vec2 duv = fuv * vec2(0.8, 0.3);       // 与 Active 同一个位移采样域（disabledDisplaceUV）
	float a = texture(uDisplaceTex, mirror_fold(duv + t * dir)).r;
	float b = texture(uDisplaceTex, mirror_fold(duv + t * perp)).r;
	float avg = (a + b) * 0.5;
	vec2 disp = dir * (b - 0.5) + perp * (a - 0.5);
	vec2 spark_uv = disp * uDisabledSparkIntensity + fuv * vec2(3.0, 1.2);
	float spark = texture(uSparkTex, mirror_fold(spark_uv)).r;
	// 官方 frag:134/169/171 —— 区色只喂给 blockPalette，**不**再乘一遍默认红：
	// uDisabledSparkTint/uDisabledFillColor 本身就是最终材质色（prpr:330 直接 set_uniform
	// (0.31132078, 0.077830195, 0.077830195)），上一版这里多乘了个 DEFAULT_BLOCK_COLOR，
	// G/B 被压到 1/3，预警看着比 phira-Pro 深一档。
	vec3 rgb = uColored == 0 ? DEFAULT_BLOCK_COLOR : texture(uDisabledColors, fuv).rgb;
	vec3 grain = vec3(spark) * blockPalette(uDisabledSparkTint, rgb) * avg * uDisabledSparkOpacity;
	vec3 fill = blockPalette(uDisabledFillColor.rgb, rgb) * uDisabledFillOpacity;
	COLOR = vec4(mask * (grain + fill) * uAlphaMul, 1.0);
}
