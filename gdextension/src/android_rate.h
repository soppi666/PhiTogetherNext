#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// ── 高帧率投票（荣耀/安卓自适应刷新率的"没触摸就压 60"对策）──────────────────
// 这台 ROD-W09 的实测行为：面板 supportedModes 有 60/90/120/144，但空闲策略停在 60，
// 只有触摸事件才抬到 120，停手 ~6s 又掉回 60；而 Godot 在第一次 present 时把节拍锁在
// 当时的屏刷新率上（冷启动在 60 → 整局 60，即使中途面板被触摸抬到 120 也不跟着走）。
// 所以要在启动时就以 app 的身份把面板钉住，只能走 Java/Native 的帧率投票：
//   ANativeWindow_setFrameRate(surface, 120, DEFAULT, ALWAYS)
// ——这是 NDK 给游戏内容用的公开 API（注释原文："This value should be used when
// displaying game content"），GDScript 侧没有任何等价入口（Engine.max_fps / vsync
// 组合实测四种都不抬屏，见 scripts/game.gd 的投票实验）。
//
// 用法（GDScript）：
//   var rate = AndroidRate.new()
//   print(rate.vote(120.0))          # 返回值是整条反射链的诊断文本，失败也返回原因
//   print(rate.prefer_mode(3))       # 备选路线：WindowManager.LayoutParams.preferredDisplayModeId
//   print(rate.probe())              # 不投票，只报告 surface/activity 拿不拿得到
class AndroidRate : public RefCounted {
	GDCLASS(AndroidRate, RefCounted)

public:
	String vote(double p_hz);
	String prefer_mode(int p_mode_id);
	String probe();
	static void _bind_methods();

private:
	String _trace;
};

} // namespace godot
