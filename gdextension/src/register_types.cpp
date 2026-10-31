#include "register_types.h"

#include "chart_player.h"
#include "video_enc.h"
#include "android_rate.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_chart_ext_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<ChartPlayer>();
	ClassDB::register_class<ChartFxLayer>();   // 音符实例化后的命中特效层（必须排在音符之后）
	ClassDB::register_class<NativeVideoEncoder>();  // 渲染录制：进程内 H.264/AAC 编码（Android MediaCodec）
	ClassDB::register_class<AndroidRate>();         // 高帧率投票（Android 自适应刷新率不抬档的对策）
}

void uninitialize_chart_ext_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT chart_ext_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_chart_ext_module);
	init_obj.register_terminator(uninitialize_chart_ext_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
