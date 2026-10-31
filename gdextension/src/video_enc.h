#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <vector>

namespace godot {

// ── 进程内视频编码器（渲染录制用） ──────────────────────────────────────────
// 桌面端本来就走系统 ffmpeg（外部进程）；Android 起不了子进程，所以这里用系统自带的
// MediaCodec（H.264 硬件编码）+ MediaMuxer（MP4 封装）+ MediaCodec(AAC) 做音轨，
// 全部在同一个 .so 里完成——不依赖任何外部可执行文件，也不额外增大安装包。
//
// 用法（GDScript）：
//   var e = NativeVideoEncoder.new()
//   if e.available():
//       e.open(path, w, h, fps, kbps)      # 0 = ok
//       e.set_audio(song_path)             # 可选，先把整首歌编成 AAC 缓存在内存
//       for each frame: e.push_frame(bytes, 3 /*rgb24*/ or 4 /*rgba*/)
//       e.finish()
// 任何一步失败都只返回非 0 错误码并记 last_error()，绝不让调用方崩溃。
class NativeVideoEncoder : public RefCounted {
	GDCLASS(NativeVideoEncoder, RefCounted)

public:
	bool available() const;   // 本平台/本次构建有没有可用的编码器
	// p_mbps = 兆比特/秒（与设置页「码率」同一单位）
	int32_t open(const String &p_out, int32_t p_w, int32_t p_h, int32_t p_fps, int32_t p_mbps);
	// 只解码成 PCM（不编 AAC）；gain = 设置页的音乐音量（与 ffmpeg 那条链的 music_vol 对齐）
	int32_t set_audio(const String &p_song_path, double p_gain = 1.0);
	// 打击音：times=音乐秒、paths=每个事件的音频文件（".f32"=48k 立体声裸 float，
	// 其它交给 MediaExtractor/MediaCodec 解），gain=线性音量。调用它才会把音轨编成 AAC，
	// 所以必须在推第一帧之前调（muxer 的轨道要先挂上）。
	int32_t set_hits(const PackedFloat64Array &p_times, const PackedStringArray &p_paths,
			double p_gain);
	int32_t push_frame(const PackedByteArray &p_pixels, int32_t p_bpp);
	int32_t finish();
	void abort();
	String last_error() const { return _err; }
	int64_t output_size() const;      // 已写进 muxer 的字节数（相册输出时拿不到文件系统大小）
	Dictionary debug_stats() const;   // 诊断：帧数/填充帧/写出样本/分片/残留字节
	Dictionary _last_stats;           // finish() 会 abort() 释放 Impl，统计先抄一份

	static void _bind_methods();

	struct Impl;          // 平台实现（Android 才有内容）
	Impl *_impl = nullptr;
	String _err;
};

} // namespace godot