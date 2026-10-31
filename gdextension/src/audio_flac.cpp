// FLAC 运行时解码。
//
// 为什么必须自己带：Godot 只在**编辑器导入 res:// 资源**时解 FLAC，运行时类里一个 flac
// 方法都没有（extension_api-4.7 查过）；而谱包落在 user://，且现实里大量"song.mp3"
// 其实是 FLAC（用户那份 RTX 20000 就是 fLaC 头）。以前这条被 AudioStreamMP3 硬接下来，
// 流对象永远非空 ⇒ 全程静音却看不出失败。
//
// 解码器 = third_party/dr_flac.h（v0.13.4，public domain / MIT-0，取自 mackron/dr_libs）。
// 只开内存解码：DR_FLAC_NO_STDIO / DR_FLAC_NO_WAV 把文件与 WAV 封装那两块砍掉。
#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_STDIO
#define DR_FLAC_NO_WAV
#include "dr_flac.h"

#include "chart_player.h"

#include <cstring>
#include <vector>

using namespace godot;

// FLAC 规范允许的块最大 32768 帧，一次读一块 → 峰值缓冲 = 32768 × 声道 × 2 字节。
Dictionary ChartPlayer::decode_flac(PackedByteArray bytes) {
	Dictionary out;
	if (bytes.size() < 4) return out;
	drflac *d = drflac_open_memory(bytes.ptr(), (size_t)bytes.size(), nullptr);
	if (d == nullptr) return out;

	const drflac_uint32 ch = d->channels;
	const drflac_uint32 rate = d->sampleRate;
	drflac_uint32 cap = d->maxBlockSizeInPCMFrames;
	if (cap == 0 || cap > 32768) cap = 4096;

	std::vector<drflac_int16> buf((size_t)cap * (ch > 0 ? ch : 1));
	PackedByteArray pcm;
	size_t total = 0;
	for (;;) {
		drflac_uint64 got = drflac_read_pcm_frames_s16(d, cap, buf.data());
		if (got == 0) break;
		size_t add = (size_t)got * (size_t)ch * sizeof(drflac_int16);
		pcm.resize((int)(total + add));
		std::memcpy(pcm.ptrw() + total, buf.data(), add);
		total += add;
	}
	drflac_close(d);

	if (total == 0) return out;
	out["pcm"] = pcm;
	out["rate"] = (int)rate;
	out["channels"] = (int)ch;
	out["frames"] = (int)(total / (ch > 0 ? ch : 1) / sizeof(drflac_int16));
	return out;
}
