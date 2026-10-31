shader_type canvas_item;
// 背景模糊链的最后一级：放大到显示尺寸 + 把压暗烘进像素 + 叠一层 ±1.25 级噪声。
//
// 为什么要在这里做压暗：player 的语义是"rgba(0,0,0,1-luminance) 盖一层"，我们先前把它
// 做成 TextureRect.modulate。8bit 下乘 0.5 会把相邻两级并成一级 ⇒ 渐变台阶直接翻倍
// （实测渲染图里同值游程 34~54px，而烘焙图只有 14px）——那就是"层纹"最狠的一条。
// 亮度在这里乘完，`_bg.modulate` 之后恒为 1，抖动又是**最后**一步，噪声不会被压暗腰斩。
uniform float lum : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	c.rgb *= lum;
	// 便宜的整数哈希：同一个像素永远同一个噪声值（背景是静帧，闪就穿帮了）
	vec2 p = floor(FRAGCOORD.xy);
	float h = fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
	c.rgb += (h - 0.5) * (2.5 / 255.0);
	COLOR = c;
}
