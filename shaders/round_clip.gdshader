shader_type canvas_item;

// 圆角裁剪：把矩形内容的四角按半径抹掉。
// PT 结算页的插图是用 globalCompositeOperation="destination-in" 套一个 roundRect 剪出来的
// （ResultPage.ts:42-52），Godot 的 clip_contents 只认方框，所以四角要靠这个 shader 抹。
// 注意裁剪对象是**卡片矩形**，不是插图自身：PT 的插图盒子（1200×1200 设计单位）比卡
// （890×700）大一圈，超出卡边的部分整条被剪掉——所以要把卡在插图局部系里的位置传进来。
uniform vec2 item_size = vec2(890.0, 700.0);  // 本控件（插图盒）的像素尺寸，用于把 uv 还原成 px
uniform vec2 card_pos = vec2(0.0, 0.0);       // 卡片左上角在插图局部系里的位置
uniform vec2 card_size = vec2(890.0, 700.0);  // 卡片像素尺寸
uniform float radius = 30.0;                  // 卡片圆角半径（px）

void fragment() {
	vec2 p = UV * item_size - card_pos - card_size * 0.5;
	vec2 q = abs(p) - (card_size * 0.5 - vec2(radius));
	float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
	COLOR = texture(TEXTURE, UV) * COLOR;
	COLOR.a *= clamp(0.5 - d, 0.0, 1.0);  // 1px 宽的过渡边，等价于 canvas 路径的抗锯齿
}
