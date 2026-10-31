shader_type canvas_item;
// 可分离高斯单程（9 taps，sigma≈4px）；大半径靠多次迭代 + 降采样达成
// （player 语义 = canvas ctx.filter blur 一次烘焙，这里用 GPU 烘焙替代）
uniform vec2 step_uv = vec2(0.0, 0.0);

void fragment() {
	const float W0 = 0.227027;
	const float W1 = 0.1945946;
	const float W2 = 0.1216216;
	const float W3 = 0.054054;
	const float W4 = 0.016216;
	vec3 c = texture(TEXTURE, UV).rgb * W0;
	c += texture(TEXTURE, UV + step_uv).rgb * W1;
	c += texture(TEXTURE, UV - step_uv).rgb * W1;
	c += texture(TEXTURE, UV + step_uv * 2.0).rgb * W2;
	c += texture(TEXTURE, UV - step_uv * 2.0).rgb * W2;
	c += texture(TEXTURE, UV + step_uv * 3.0).rgb * W3;
	c += texture(TEXTURE, UV - step_uv * 3.0).rgb * W3;
	c += texture(TEXTURE, UV + step_uv * 4.0).rgb * W4;
	c += texture(TEXTURE, UV - step_uv * 4.0).rgb * W4;
	COLOR = vec4(c, 1.0);
}
