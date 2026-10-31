// Stripes（改）— 基于 godotshaders.com/shader/stripes (CC0)
// 曲库带专属：斜 60° 两档交错（透明 / 50% 黑），周期=屏高5%
shader_type canvas_item;
uniform float band_px = 45.0;
uniform float time_per_cycle = 8.0;
uniform float band_alpha = 0.5;
uniform float ang = 60.0;  // 条纹与竖直方向的夹角（度）

void fragment() {
	vec2 dir = vec2(sin(radians(ang)), cos(radians(ang)));
	float s = dot(FRAGCOORD.xy, vec2(dir.y, -dir.x)) + TIME * (band_px / time_per_cycle);
	float idx = floor(s / band_px);
	float a = 0.0;
	if (mod(idx, 2.0) < 1.0) {
		a = band_alpha;
	}
	COLOR = vec4(0.0, 0.0, 0.0, a);
}
