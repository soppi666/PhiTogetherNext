shader_type canvas_item;
// 噪域特效链的**链尾复位**（不是作者能选特效，而是我们自己的必需尾层）。
//
// 为什么要它：assets/effects 里那些 stock 滤镜是从 player 抄来的，输入按"整块画面"设计，
// 尾巴统一写 `COLOR.a = max(a, max(rgb))` ⇒ 喂给它们一张**大部分像素透明**的噪域层时，
// 它们会把整屏 alpha 拉成 1，回贴时就把游玩画面糊成黑底。
// 不改那些 shader（它们对既有链是 player 口径），改成在链尾用噪域自己的 alpha 复位一次：
//   rgb = 链输出（已被滤镜处理，预乘语义）× 噪域自己的 alpha
//   a   = 噪域自己的 alpha（官方 Active 层"擦掉现场"的那一份）
// 这样官方 Active 的 premultiplied 语义（ONE, ONE_MINUS_SRC_ALPHA）原样保留，
// 场内的位移背景仍然被压住，只是颜色经过了作者的滤镜。

render_mode blend_premul_alpha;
uniform sampler2D uSrc : filter_linear;   // 链输出
uniform sampler2D uMask : filter_linear;  // 未滤镜的噪域层（只取它的 alpha）

void fragment() {
	vec4 s = texture(uSrc, UV);
	vec4 m = texture(uMask, UV);
	COLOR = vec4(s.rgb * m.a, m.a);
}
