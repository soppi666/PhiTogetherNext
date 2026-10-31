shader_type canvas_item;
// 官方混合是 (ONE, ONE_MINUS_SRC_ALPHA)：rgb 不加权直接叠上、只按 alpha 压暗背景，
// 所以噪域是浓红而非半透明罩纱。Godot 对应 render_mode blend_premul_alpha。
render_mode blend_premul_alpha;
// 官方谱 blockArea（噪域）表现层 —— 移植自 Phira-Pro 的 prpr `core/block_shader_full.frag`
// （Unity 导出 GLSL 的反编译，SSA 已还原成表达式）。uniform 数值全部照抄 block_shader.rs 的
// FLOATS/COLORS 表，形状（掩码/位移/膨胀环）由 C++ `build_block_mask()` 逐帧算好后当纹理喂进来。
//
// 本文件只实现 uLayer=3 Active（后处理层，官屏实证盖在音符与 HUD 之上）。
// uLayer=0 Disabled（预警）是官方同一份 shader 编出来的另一条 pass，见
// shaders/block_area_disabled.gdshader（采现场 + 位移 + 火花，但不读 Edge/Glow、
// 换 uDisabled* 一套常量、premultiplied 混合）。Godot 的 render_mode 是编译期的，
// 没法用一个 uniform 切两条 pass，所以拆成两个文件——改一条要记得对另一条。
// UV 约定：官方 fieldUV/sceneUV 是 y 向上的，Godot 的 UV 是 y 向下的 → 统一用 fuv 变量。

uniform sampler2D uMasks : filter_linear;      // R=位移后合成 G=Edge B=Glow A=Disabled（1/4 屏网格）
uniform sampler2D uAuxMasks : filter_linear;   // R=ready 普通 G=ready 减算 B=disabled

uniform sampler2D uDisplaceTex : filter_nearest; // BlockNoise1（Mirror：折叠在 CPU 侧做过，这里靠 clamp）
uniform sampler2D uSparkTex : filter_nearest, repeat_enable; // PointNoise
// 官方 uScene 快照 = **游玩画布的离屏图**（prpr 的 res.chart_target，不是 backbuffer）。
// 这里不再用 hint_screen_texture，改由 chart_stage 显式喂 _csv 的纹理：
//   ① 语义更对——官方快照本来就不含 game 层的暂停压暗/结算页；
//   ② hint_screen_texture 是「本帧第一个采样控件处拷贝一次」，挂层次序一变就读到旧帧；
//   ③ 只有显式纹理才能进离屏，这是噪域被特效链认领的前提（targetRange 深度 16）。
// 采样用画布 UV（puv，y 向下），不是本矩形的屏幕 UV——宽屏时两者差一个 uField 偏移。
uniform sampler2D uSceneTex : filter_linear;
// ── 逐区配色（RPE 标记线的 colorEvents）：prpr block_color.rs 生成两张调色板纹理，
// uColored==0 时**完全不采**（官方把 blockPalette(name,rgb) 直接替换成 name，连分支都不留），
// 所以官方红/未配色的谱与改动前逐像素一致。Nearest：颜色网格=效果网格，不能插值糊边。
uniform int uColored = 0;
uniform sampler2D uActiveColors : filter_nearest;
// Recorder beta3 的 ready 分支画两遍（ReadyBlock + ActiveBlock 内那条），官方把第二遍
// 的量做成 uniform 常量：有 line2area（RPE 标记噪域）的谱给 1，官方案给 0（prpr:705）
uniform float uReadyExtra = 0.0;
uniform float uTime = 0.0;                 // 音乐秒（官方是 _Time.y，这里取确定性时钟）
uniform vec2 uScreen = vec2(1280.0, 720.0);        // 本层矩形的像素尺寸（背景快照按它吸附）
uniform vec2 uFieldScreen = vec2(1280.0, 720.0);   // 游玩画布的像素尺寸（场内位移噪声按它吸附）
uniform vec4 uField = vec4(0.0, 0.0, 1.0, 1.0);    // 画布在本层 UV 里的矩形 x,y,w,h（y 向下）
uniform vec4 uETS = vec4(0.0029762, 0.0044643, 336.0, 224.0); // 1/EW,1/EH,EW,EH（每帧覆写） // _EffectRT_TexelSize
uniform float uAlphaMul = 1.0;

// ── 触摸 SDF（官方 _TouchPos*：ActiveBlock 里给场色加一圈"按下去"的高亮）──
// 常量取 block_shader.rs FLOATS 原值；坐标空间 = 画布 uv×(aspect,1)、原点左下。
uniform int uTouchCount = 0;
uniform vec2 uTouchPos[10];
uniform float uTouchPosShine = 0.0;
const float TOUCH_POS_RADIUS = 0.5;
const float TOUCH_POS_SDF_SMOOTHNESS = 0.47;
const float TOUCH_POS_SDF_FALLOFF = 0.41;
// 指尖局部光（官方 hover 那条 pass：frag:191 采样 + 356-524 整层）
uniform vec4 _TouchDisplaceDirection = vec4(1.0, 1.0, 0.0, 0.0);
uniform float _TouchDisplaceSpeed = 2.9;
uniform float _TouchDisplaceStrength = 0.08;
uniform float _TouchBackgroundPixelScale = 8.0;
uniform vec4 _TouchGlowColor = vec4(1.0, 0.0, 0.0, 1.0);
// 指尖层自己的细胞噪声（block_shader.rs FLOATS 原值）：官方在 hover 覆盖的区域里
// 用一套 11% 屏高的活动细胞 + FD_Noise 抖动生成 base，再和 _TouchGlowColor 做 Overlay。
uniform sampler2D uNoiseTex : filter_nearest;      // FD_Noise_00000（官方 Mirror，这里靠 mirror_fold）
uniform float _NoiseEvoSpeed = 0.03;
uniform float _NoiseDirChangeSpeed = 60.0;
uniform float _NoiseDisplaceStrength = 1.0;
uniform float _NoiseRadius = 0.48;
uniform float _NoiseSmoothness = 1.0;
uniform float _SDFCellSize = 0.11;
uniform float _SDFSmoothness = 0.63;
uniform float _SDFFalloff = 0.34;
uniform float _SDFMoveSpeed = 9.3;
uniform vec4 _NoiseTint = vec4(1.0, 0.0, 0.0, 1.0);

// ── 官方材质参数（block_shader.rs FLOATS/COLORS 原值）──
uniform vec4 _EdgeColor : source_color = vec4(1.0, 0.33018857, 0.33018857, 1.0);
uniform float _EdgeOpacity = 0.8;
uniform vec4 _FillColor : source_color = vec4(0.7132075, 0.23549296, 0.23549296, 1.0);
uniform float _FillStrength = 0.667;
uniform float _FillOpacity = 0.667;
uniform vec4 _GlowColor : source_color = vec4(1.0, 0.17924517, 0.17924517, 1.0);
uniform float _GlowIntensity = 0.8;
uniform vec3 _SparkTint = vec3(1.0, 0.28490567, 0.28490567);
uniform float _SparkMapOpacity = 5.69;
uniform float _SparkHueShiftAmount = 0.2;
uniform float _SparkDisplaceIntensity = 2.39;
uniform float _DisplaceBlendIntensity = 0.411;
uniform float _DisplaceSpeed = 1.5;
uniform float _DisplaceStrength = 0.15;
uniform vec4 _DisplaceDirection = vec4(1.0, 1.0, 0.0, 0.0);
uniform float _BackgroundPixelScale = 6.0;
uniform float _ShineSpeed = 37.9;
uniform float _ShineBrightness = 0.12;
uniform vec4 _ShineColor : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// Mirror 包裹（官方 uDisplaceTex 用 TextureWrap::Mirror，Godot 纹理默认 CLAMP）：
// 不做折叠的话，位移采样点随时间滑出 [0,1] 后被钳死 → 几秒后噪声恒定 = 动画"跑没了"。
vec2 mirror_fold(vec2 p) {
	p = mod(p, 2.0);
	return mix(p, 2.0 - p, step(vec2(1.0), p));
}

const vec3 DEFAULT_BLOCK_COLOR = vec3(1.0, 84.0 / 255.0, 84.0 / 255.0);

// 官方 blockPalette（block_shader_full.frag:551-560，逐式）：把"原生红材质"的
// 饱和度/明度搬到作者要的颜色上，而不是简单乘一遍色——白/黑都是合法颜色，
// 直接乘会把灰度信息全丢掉。默认红走原算术，一条指令都不多。
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

vec2 snap_eff(vec2 uv) {
	return (floor(uv * uETS.zw) + 0.5) / uETS.zw;
}

// 画布像素网格吸附（S=6 ⇒ 每 6×6 像素共享一个采样点）。位移噪声与背景快照都走这一套：
// 官方那两处用的本来就是同一个渲染目标，我们没有「屏幕==画布」这个巧合，必须显式选画布。
vec2 snap_px_f(vec2 uv, float s) {
	vec2 grid = max(floor(uFieldScreen / max(s, 1.0)), vec2(1.0));
	return (floor(uv * grid) + 0.5) / grid;
}

// snapshotSample（frag:568-573）：1/6 网格再吸附 = 官方 BlockRender.Start 的整数除法快照
vec4 snapshot_sample(vec2 cuv) {
	vec2 g = max(floor(uFieldScreen / 6.0), vec2(1.0));
	return texture(uSceneTex, (floor(clamp(cuv, vec2(0.0), vec2(1.0)) * g) + 0.5) / g);
}

vec3 rgb2hsv(vec3 c) {
	vec4 k = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, k.wz), vec4(c.gb, k.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb_m(vec3 c, out vec3 m) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	m = clamp(p - 1.0, 0.0, 1.0);
	return c.z * mix(vec3(1.0), m, c.y);
}

// 官方 SSA（block_shader_full.frag 的 _TouchPosCount 分支）逐式翻译：
// 链式 SDF 并集 → (R−acc)/R 钳位 → smoothstep → pow(·, falloff)
// 官方 hoverSample（frag:543-547）：aux.a 里的触摸掩码，网格=效果网格×0.5（1/8 屏），
// 走**画布 UV**（官方是屏幕 UV 且刻意不经过 chart 翻转模型；我们画布高=屏幕高 ⇒ 同值）
float hover_sample(vec2 uv) {
	vec2 size = uETS.zw * 0.5;
	return texture(uAuxMasks, (floor(uv * size) + 0.5) / size).a;
}

// 官方按 _TouchBackgroundPixelScale 做屏幕像素吸附（frag:363-377）：
// (floor(uv*screen/S) + 0.5)*S/screen —— 除数是 S 本身，不是 floor(screen/S)
vec2 snap_px_t(vec2 uv, float s) {
	vec2 sc = max(vec2(s), vec2(1.0));
	return (floor(uv * uFieldScreen / sc) + 0.5) * sc / uFieldScreen;
}

// ShaderGraph 的 Hash 节点。p3 的三个分量是 (x, y, x)，且**进来时已经乘过 0.1031 并 fract**
// （frag:458-465 是先乘先 fract、再走 hash 体；hash 体内部不再乘第二次）
float hash_raw(vec3 p3) {
	float d = dot(p3, p3.yzx + vec3(33.3300018));
	p3 += vec3(d);
	return fract((p3.x + p3.y) * p3.z);
}

float hash12(vec2 p) {
	return hash_raw(fract(vec3(p.xyx) * 0.1031));
}

// frag:391-406 —— 标量→二维随机向量（两个常数种子 0.38147 / 0.93821）
vec2 hash11to2(float s) {
	float a = fract(s * 0.1031);
	return vec2(hash_raw(vec3(a, 0.38147, a)), hash_raw(vec3(a, 0.93821, a)));
}

vec3 touch_hover_layer(vec2 fuv, float dt, vec3 rgb) {
	// ── 位移重取 hover（frag:358-383）──
	vec2 tdir = normalize(_TouchDisplaceDirection.xy);
	vec2 tperp = vec2(-tdir.y, tdir.x);
	float tt = dt * _TouchDisplaceSpeed;          // uUnityTime.x = time/20
	vec2 tduv = fuv * vec2(0.55, 0.3);            // touchDisplaceUV（vert:29，不是 displaceUV 的 0.8/0.3）
	float tapb = texture(uDisplaceTex, mirror_fold(snap_px_t(tduv + tt * tperp, _TouchBackgroundPixelScale))).r;
	vec2 ta = snap_px_t(tduv + tt * tdir, _TouchBackgroundPixelScale);
	float tapa = texture(uDisplaceTex, mirror_fold(ta)).r;
	vec2 tdisp = tdir * (tapa - 0.5) + tperp * (tapb - 0.5);
	float hov = hover_sample(fuv + tdisp * _TouchDisplaceStrength);
	// ── 每 1/60 秒换一个随机方向去推 FD_Noise 采样点（frag:385-430）──
	float dc = uTime * _NoiseDirChangeSpeed;
	float df = fract(dc);
	vec2 dn = mix(hash11to2(ta.x + 1.0), hash11to2(ta.x + 2.0), df * df * (3.0 - 2.0 * df)) * 2.0 - 1.0;
	vec2 n = texture(uNoiseTex, mirror_fold(dn * _NoiseEvoSpeed + fuv * vec2(1.5, 1.46))).xy - 0.5;
	// ── 细胞 SDF（frag:441-502）──
	float cell_px = uFieldScreen.y * _SDFCellSize;
	vec2 cuv = fuv + 2.0 * n * _NoiseDisplaceStrength * cell_px / uFieldScreen;
	vec2 grid = cuv * uFieldScreen / cell_px;
	vec2 cid = floor(grid) + vec2(floor(uTime * _SDFMoveSpeed));
	vec2 cf = fract(grid);
	float mf = fract(uTime * _SDFMoveSpeed);
	// 每格两个随机分量（frag:458-488）：A=(hash12(cid), hash12(cid+17.17))、
	// B=(hash12(cid+1), hash12(cid+18.17))，按 _SDFMoveSpeed 的小数部插值 ⇒ 细胞会漂移
	vec2 ra = vec2(hash12(cid), hash12(cid + vec2(17.17)));
	vec2 rb = vec2(hash12(cid + vec2(1.0)), hash12(cid + vec2(18.17)));
	vec2 ro = mix(ra, rb, mf * mf * (3.0 - 2.0 * mf));
	float x2 = clamp((length(cf - ro) - _SDFFalloff) / _SDFSmoothness, 0.0, 1.0);
	float sdf = x2 * x2 * (3.0 - 2.0 * x2);
	vec3 g = clamp(sdf * blockPalette(_NoiseTint.rgb, rgb) + vec3(sdf), 0.0, 1.0);
	// ── hover 阈值（frag:431-440）与 Overlay 混合（frag:503-524）──
	float x1 = clamp((hov - (_NoiseRadius - _NoiseSmoothness)) / (2.0 * _NoiseSmoothness), 0.0, 1.0);
	vec3 base = (x1 * x1 * (3.0 - 2.0 * x1)) * g;
	float hs = clamp(hov, 0.0, 1.0);
	hs = hs * hs * (3.0 - 2.0 * hs);
	vec3 glow = hs * blockPalette(_TouchGlowColor.rgb, rgb);
	vec3 hi = 2.0 * base * glow;
	vec3 lo = 1.0 - 2.0 * (1.0 - base) * (1.0 - glow);
	return clamp(mix(hi, lo, step(vec3(0.5), base)), 0.0, 1.0) + 0.5 * glow;
}

float touch_sdf(vec2 p) {
	if (uTouchCount <= 0) {
		return 0.0;
	}
	float acc = 1.0;
	for (int i = 0; i < 10; i++) {
		if (i >= uTouchCount) {
			break;
		}
		float d = length(p - uTouchPos[i]);
		float ring = max(TOUCH_POS_SDF_SMOOTHNESS - abs(acc - d), 0.0) / TOUCH_POS_SDF_SMOOTHNESS;
		ring = ring * ring * TOUCH_POS_SDF_SMOOTHNESS;
		acc = min(d, acc) - 0.25 * ring;
	}
	float x = clamp((TOUCH_POS_RADIUS - acc) / TOUCH_POS_RADIUS, 0.0, 1.0);
	x = x * x * (3.0 - 2.0 * x);
	return pow(max(x, 0.0), TOUCH_POS_SDF_FALLOFF);
}

void fragment() {
	// 噪域只属于 16:9 游玩画布。Active 层的矩形是**整屏**（背景快照要按屏幕像素吸附），
	// 所以先把整屏 UV 折进画布 UV，落在画布外的直接丢弃 ⇒ 宽屏（21:9 等）时左右两条
	// 曲绘带上不再铺红场。16:9 窗口下 uField=(0,0,1,1)、uFieldScreen=uScreen，
	// 与改动前逐像素等价（官屏对帧那批截图全是这个比例，不会被动到）。
	// 官方那边不需要这一步：prpr 用 clipHalfWidth = uView.y*0.888889/uView.x 把场
	// 横向裁在 16:9 居中框里，而它的 uView 恒等于整个渲染目标；我们把画布矩形显式传进来，
	// 语义相同但不再依赖"窗口比例恰好等于画布比例"。
	vec2 puv = (UV - uField.xy) / max(uField.zw, vec2(1e-5));
	if (puv.x < 0.0 || puv.x > 1.0 || puv.y < 0.0 || puv.y > 1.0) {
		discard;
	}
	vec2 fuv = vec2(puv.x, 1.0 - puv.y); // 官方 y 向上
	float dt = uTime / 20.0;
	float c0 = texture(uMasks, snap_eff(fuv)).r;
	float e0 = texture(uMasks, snap_eff(fuv)).g;
	float g0 = texture(uMasks, fuv).b;
	vec4 ax = texture(uAuxMasks, snap_eff(fuv));
	float ready_gate = ax.b * abs(ax.g - ax.r);
	// 反编译里 discard 用的是 total+ready+hover（frag:195-199 把 191 的 hoverSample 也加进
	// 门里），而**分支门只看 total**（`u_xlatb1 = 1e-4 < u_xlat16_50`，u_xlat16_50 =
	// glow+edge+mask，不含 ready）。ready 单独亮时走 else：rgb=0、alpha=0，只有 shine 加进去。
	// hover 进 discard 门这一条很关键：它让场体之外的指尖也留得住像素（alpha=0、纯加色），
	// 官方"手指拖出噪域仍然拖着一团红"就是靠它，之前漏了 ⇒ 用户实测"拿出来没有红光"。
	float total = g0 + e0 + c0;
	// 逐区配色：调色板纹理按效果网格 Nearest 存每个像素归属噪域的 RGB（默认红）。
	// prpr 的 uColored==0 专化版会把 blockPalette(name,rgb) 整条替换成 name，
	// 所以未配色的谱在这里连一次采样都不做。
	vec3 rgb_zone = uColored == 0 ? DEFAULT_BLOCK_COLOR : texture(uActiveColors, fuv).rgb;
	float hov_gate = hover_sample(fuv);
	if (total + ready_gate + hov_gate - 1e-4 < 0.0) {
		discard;
	}
	float edge_strength = e0 * _EdgeOpacity;
	// ⚠ 这里**故意不照抄 prpr 的反编译字面式**。prpr 的 SSA 读作
	// glowMix = glow + (edge + mask)·(1 − glow)，mask=1 的内部 → glowMix=1 →
	// alpha=0.8+0.667 钳到 1（完全不透明）、rgb 再吃一整份 GlowColor×0.8 ⇒ (247,39,39) 亮红。
	// 但官屏实测ハテ AT 的场体内部 = (49,7,11)（140909 那张，边界内侧多点平均），
	// 用本式（glow 只取辉光通道自身）算出 (46,7,10) —— 差 ≤3；用 prpr 字面式差 5 倍。
	// 也就是说 prpr 这条要么与官游有出入、要么它的 mask 语义与官游不同。以官屏为准。
	float glow_amt = g0 * (1.0 - min(c0 + e0, 1.0)) * _GlowIntensity;

	vec2 dir = normalize(_DisplaceDirection.xy);
	vec2 perp = vec2(-dir.y, dir.x);
	float t = dt * _DisplaceSpeed;
	vec2 duv = fuv * vec2(0.8, 0.3);
	float a = texture(uDisplaceTex, mirror_fold(snap_px_f(duv + t * dir, _BackgroundPixelScale))).r;
	float b = texture(uDisplaceTex, mirror_fold(snap_px_f(duv + t * perp, _BackgroundPixelScale))).r;
	float noise_avg = (a + b) * 0.5;
	vec2 disp = dir * (a - 0.5) + perp * (b - 0.5);

	// 背景快照：uSceneTex 和 Godot 的 UV 一样是 y 向下的，而掩码/位移是 y 向上的官方约定
	// → 采样前把 disp.y 翻回去，否则背景色块上下错位。
	vec3 bg = snapshot_sample(snap_px_f(puv, _BackgroundPixelScale)
			+ vec2(disp.x, -disp.y) * _DisplaceStrength).rgb;
	float spark = texture(uSparkTex, disp * _SparkDisplaceIntensity + fuv * vec2(3.0, 1.2)).r;
	// 火花亮度 = PointNoise 的稀疏点 × BlockNoise1 均值（官方 ⑥ 项：漏掉 spark 采样会把
	// overlay 推到饱和，整片变黄白；PointNoise 大部分像素是 0，所以常态下 fill 保持暗红）
	vec3 spark_amount = vec3(spark) * blockPalette(_SparkTint, rgb_zone) * _SparkMapOpacity * vec3(noise_avg);
	// HSV 的三个分量各被 sparkAmount 对应通道偏移 0.2（不是位移向量），overlay 的分支
	// 条件在**底色** hsv2 上（step(0.5, hsv2)），不是 hsv2rgb 的通道斜坡。
	// 官方把 HSV 三分量的偏移拆开：hue/value 用原系数，只有 saturation 乘 paletteSaturation
	// （frag:316-318）。白色/灰色火花不该把原生红材质的饱和度搬过去。
	vec3 hsv_shift = spark_amount * _SparkHueShiftAmount;
	hsv_shift.y *= uColored == 0 ? 1.0
			: (max(rgb_zone.r, max(rgb_zone.g, rgb_zone.b)) - min(rgb_zone.r, min(rgb_zone.g, rgb_zone.b)))
					/ max(max(rgb_zone.r, max(rgb_zone.g, rgb_zone.b)), 0.00001) / (1.0 - 84.0 / 255.0);
	vec3 shifted = rgb2hsv(bg) + hsv_shift;
	vec3 m;
	vec3 hsv2 = hsv2rgb_m(shifted, m);
	vec3 lo = 1.0 - 2.0 * (1.0 - hsv2) * (1.0 - spark_amount);
	vec3 hi = 2.0 * spark_amount * hsv2;
	vec3 spark_col = clamp(hi + step(vec3(0.5), hsv2) * (lo - 2.0 * hsv2 * spark_amount), vec3(0.0), vec3(1.0));

	vec3 fill_base = blockPalette(_FillColor.rgb, rgb_zone) - noise_avg * _DisplaceBlendIntensity;
	vec3 fill = fill_base + _FillStrength * (spark_col - fill_base);
	// 分支门：total 不够大时整段 else（rgb=0 / alpha=0），ready 的 shine 之后照样加
	bool has_field = 1e-4 < total;
	vec3 rgb = vec3(0.0);
	float alpha = 0.0;
	if (has_field) {
		rgb = fill * c0 + blockPalette(_EdgeColor.rgb, rgb_zone) * edge_strength
				+ blockPalette(_GlowColor.rgb, rgb_zone) * glow_amt;
		// 官方：u_xlat16_50 = sdf×_TouchPosShine + 1 ⇒ 只乘 rgb、不乘 alpha（frag:337-338）
		rgb *= 1.0 + touch_sdf(vec2(fuv.x * (uFieldScreen.x / max(uFieldScreen.y, 1.0)), fuv.y))
				* uTouchPosShine;
		alpha = glow_amt + c0 * _FillOpacity + edge_strength;
	}
	// 指尖层是**独立加色层**（frag:356-524 算出 u_xlat16_8，531 `result.xyz = 这一层 + 现场`），
	// 不在 has_field 分支里：官方在噪域外 alpha=0 时照样把它加到场景上。
	// 上一版把 hover 直接 Overlay 到现场 rgb 上，两处必错：_TouchGlowColor=(1,0,0) 让
	// G/B 在 base<0.5 时被 2·base·0 清零 ⇒ 按下去出现"透明洞"；红又只乘不加 ⇒ 看不到红光。
	if (hov_gate > 9.99999975e-05) {
		rgb += touch_hover_layer(fuv, dt, rgb_zone);
	}

	// 官方 SSA（block_shader_full.frag:195-196 定义 gate、353-360 加 shine）：
	//   readyGate = aux.b(=composedDisabled) × |readyNormal − readySub|
	//   rgb += _ShineBrightness × _ShineColor × (sin(uUnityTime.y×_ShineSpeed)×0.5+1) × gate
	// 它**只进 rgb、不进 alpha**（alpha 只在 baseSum>0 分支里算）。所以预警阶段
	// （场体为空、alpha=0）这层白色高光是原样加到现场上的——这不是 bug，官方就这样。
	// 我之前给它乘过 has_field 来"治白色遮罩"，那是找错了地方：真正的原因是 Disabled 层
	// 自己没在画（_bdis 尺寸 0），那片区域只剩这层高光 ⇒ 看着就是纯白纱。
	// Disabled 层按官方式补回来之后，底子有暗红+火花，这层高光才回到它本来的作用。
	// 官方 SSA（frag:353-367 定值、542 合成）：shine = 亮度×色×振荡×rd，最后再乘 (rd + uReadyExtra)。
	// 官方案 uReadyExtra=0 ⇒ rd²（rd 在预警内部恒 1，所以与旧写法同值；只有边缘不同）。
	// 有 RPE 标记噪域时官方给 1 ⇒ 这层白高光按 rd×(rd+1) 再叠一遍（Recorder beta3 实测）。
	float osc = sin(uTime * _ShineSpeed) * 0.5 + 1.0;
	rgb += _ShineBrightness * _ShineColor.rgb * osc * ready_gate * (ready_gate + uReadyExtra);

	COLOR = vec4(rgb, clamp(alpha, 0.0, 1.0) * uAlphaMul);
}
