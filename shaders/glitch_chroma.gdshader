shader_type canvas_item;

// fluXis「???」按钮故障特效移植：整屏 ColorRect 采样屏幕纹理，
// 把 sh_Glitch.fs（按块随机 UV 偏移）+ sh_ChromaticAberration.fs（R/B 水平色散）合并成一趟。
// 峰值全部衰减回 0 时输出 = 原屏幕画面，GlitchFx 检测到即隐藏本节点（空闲零开销）。
// 注意：4.7 hint_screen_texture 无 mipmaps，只做逐像素采样，不做 textureLod 模糊。

uniform sampler2D u_screen : hint_screen_texture, filter_linear_mipmap;
uniform float u_chroma = 0.0;      // chroma.Strength（R/B 单边偏移 = 0.001×强度，uv 单位）
uniform float u_glitch_x = 0.0;    // glitch.Strength（水平抖动 = 强度/10，uv 单位）
uniform float u_glitch_y = 0.0;    // glitch.Strength2（垂直抖动）
uniform float u_block = 0.0;       // glitch.Strength3（块边长 = 1px 与 min(屏宽,屏高) 的线性插值）
uniform vec2 u_screen_size = vec2(1280.0, 720.0);

highp float rnd(highp vec2 st, float seed)
{
    return fract(sin(dot(st.xy, vec2(12.9898, 78.233) + seed)) * 43758.5453123);
}

void fragment()
{
    vec2 uv = SCREEN_UV;
    float sx = u_glitch_x / 10.0;
    float sy = u_glitch_y / 10.0;
    if (sx > 0.0 || sy > 0.0)
    {
        float blocks = mix(1.0, min(u_screen_size.x, u_screen_size.y), u_block);
        vec2 buv = floor(uv * blocks) / blocks;
        // fluXis 用毫秒时钟 %10000 作种子：每帧每个块重抽一次偏移
        float seed = floor(mod(TIME * 1000.0, 10000.0));
        uv += vec2((rnd(buv, seed) - 0.5) * sx, (rnd(buv + vec2(5.0), seed) - 0.5) * sy);
    }
    vec2 off = vec2(0.001 * u_chroma, 0.0);
    vec4 c = texture(u_screen, uv);
    c.r = texture(u_screen, uv + off).r;
    c.b = texture(u_screen, uv - off).b;
    COLOR = c;
}
