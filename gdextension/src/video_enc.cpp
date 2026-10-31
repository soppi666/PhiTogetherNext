#include "video_enc.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstdio>
#include <cstring>
#include <string>

#ifdef __ANDROID__
#include <dlfcn.h>
#include <fcntl.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>
#include <media/NdkMediaMuxer.h>
#include <jni.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

using namespace godot;

// ── Android 实现：MediaCodec(H.264) + MediaCodec(AAC) + MediaMuxer(MP4) ─────
#ifdef __ANDROID__

#define COLOR_FLEXIBLE 0x7F420888
#define COLOR_SEMI 21   // COLOR_FormatYUV420SemiPlanar（NV12）
#define COLOR_PLANAR 19 // COLOR_FormatYUV420Planar（I420）

// ── MediaStore（相册）输出 ────────────────────────────────────────────────
// Android 10+ 分区存储：直接写 /storage/emulated/0/Pictures 会被拒，只有走
// ContentResolver.insert(MediaStore.Video) 才能落到相册（用户要 Pictures/PhiTogetherNext，
// 不插 adb 也能在相册/文件管理器里看到）。insert 之后拿到 ParcelFileDescriptor 的 fd，
// MediaMuxer 本来就吃 fd，所以编码管线完全不用改。
struct MsFileState {
	jobject uri = nullptr; // 全局引用（发布/丢弃时用）
	int fd = -1;
	bool pending = false;
	bool published = false;
};

static JavaVM *g_jvm = nullptr;

static char g_jvm_err[96] = "";

static bool jvm_ready() {
	if (g_jvm) {
		return true;
	}
	typedef jint (*getvms_t)(JavaVM **, jsize, jsize *);
	getvms_t f = (getvms_t)dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
	if (!f) {
		// 进程里没有全局导出的 JNI_GetCreatedJavaVMs 时，去运行时库里找
		const char *libs[] = { "libnativehelper.so", "libart.so", "libandroid_runtime.so" };
		for (int i = 0; i < 3 && !f; ++i) {
			void *h = dlopen(libs[i], RTLD_NOW);
			if (h) {
				f = (getvms_t)dlsym(h, "JNI_GetCreatedJavaVMs");
			}
		}
	}
	if (!f) {
		snprintf(g_jvm_err, sizeof(g_jvm_err), "找不到 JNI_GetCreatedJavaVMs");
		return false;
	}
	jsize n = 0;
	JavaVM *vm = nullptr;
	if (f(&vm, 1, &n) != JNI_OK || n < 1 || !vm) {
		snprintf(g_jvm_err, sizeof(g_jvm_err), "JNI_GetCreatedJavaVMs 失败 n=%d", (int)n);
		return false;
	}
	g_jvm = vm;
	return true;
}

static JNIEnv *ms_env(bool *attached) {
	*attached = false;
	if (!jvm_ready()) {
		return nullptr;
	}
	JNIEnv *env = nullptr;
	if (g_jvm->GetEnv((void **)&env, JNI_VERSION_1_6) == JNI_OK && env) {
		return env;
	}
	if (g_jvm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
		return nullptr;
	}
	*attached = true;
	return env;
}

static int g_sdk_int = -1;

static int android_sdk_int() {
	if (g_sdk_int >= 0) {
		return g_sdk_int;
	}
	bool att = false;
	JNIEnv *env = ms_env(&att);
	if (!env) {
		return -1;
	}
	jclass c = env->FindClass("android/os/Build$VERSION");
	if (c) {
		jfieldID f = env->GetStaticFieldID(c, "SDK_INT", "I");
		if (f) {
			g_sdk_int = (int)env->GetStaticIntField(c, f);
		}
		env->DeleteLocalRef(c);
	}
	if (env->ExceptionCheck()) {
		env->ExceptionClear();
	}
	if (att) {
		g_jvm->DetachCurrentThread();
	}
	return g_sdk_int;
}

// Application → ContentResolver（Application 是 Context 子类，直接用 getContentResolver）
static jobject ms_resolver(JNIEnv *env) {
	jclass c_at = env->FindClass("android/app/ActivityThread");
	if (!c_at) {
		return nullptr;
	}
	jmethodID m_cur = env->GetStaticMethodID(c_at, "currentApplication",
			"()Landroid/app/Application;");
	if (!m_cur) {
		return nullptr;
	}
	jobject app = env->CallStaticObjectMethod(c_at, m_cur);
	if (!app) {
		return nullptr;
	}
	jclass c_ctx = env->GetObjectClass(app);
	jmethodID m_res = env->GetMethodID(c_ctx, "getContentResolver",
			"()Landroid/content/ContentResolver;");
	if (!m_res) {
		return nullptr;
	}
	return env->CallObjectMethod(app, m_res);
}

static jobject ms_cv(JNIEnv *env) {
	jclass c_cv = env->FindClass("android/content/ContentValues");
	jmethodID ctor = env->GetMethodID(c_cv, "<init>", "()V");
	return env->NewObject(c_cv, ctor);
}

static void ms_put_str(JNIEnv *env, jobject cv, const char *k, const char *v) {
	jclass c_cv = env->GetObjectClass(cv);
	jmethodID put = env->GetMethodID(c_cv, "put", "(Ljava/lang/String;Ljava/lang/String;)V");
	jstring ks = env->NewStringUTF(k);
	jstring vs = env->NewStringUTF(v);
	env->CallVoidMethod(cv, put, ks, vs);
}

static void ms_put_int(JNIEnv *env, jobject cv, const char *k, int v) {
	jclass c_cv = env->GetObjectClass(cv);
	jmethodID put = env->GetMethodID(c_cv, "put", "(Ljava/lang/String;Ljava/lang/Integer;)V");
	jclass c_int = env->FindClass("java/lang/Integer");
	jmethodID val = env->GetStaticMethodID(c_int, "valueOf", "(I)Ljava/lang/Integer;");
	jstring ks = env->NewStringUTF(k);
	jobject iv = env->CallStaticObjectMethod(c_int, val, (jint)v);
	env->CallVoidMethod(cv, put, ks, iv);
}

// 取当前异常的文字（排查 insert 失败用）
static std::string jexc(JNIEnv *env, const char *where) {
	std::string out(where);
	if (!env->ExceptionCheck()) {
		return out;
	}
	jthrowable ex = env->ExceptionOccurred();
	env->ExceptionClear();
	out += ": ";
	if (ex) {
		jclass c = env->GetObjectClass(ex);
		jmethodID m = env->GetMethodID(c, "toString", "()Ljava/lang/String;");
		if (m) {
			jstring js = (jstring)env->CallObjectMethod(ex, m);
			if (js) {
				const char *cs = env->GetStringUTFChars(js, nullptr);
				if (cs) {
					out += cs;
					env->ReleaseStringUTFChars(js, cs);
				}
			}
		}
		env->DeleteLocalRef(ex);
	}
	if (env->ExceptionCheck()) {
		env->ExceptionClear();
	}
	return out;
}

// insert 一条 MediaStore.Video 记录并拿到可写 fd
static bool ms_create(const char *rel_dir, const char *name, MsFileState *st, std::string &err) {
	int sdk = android_sdk_int();
	if (sdk < 29) {
		err = std::string("API ") + std::to_string(sdk) + (g_jvm_err[0] ? g_jvm_err : "");
		return false;
	}
	bool att = false;
	JNIEnv *env = ms_env(&att);
	if (!env) {
		err = "JNI 环境拿不到";
		return false;
	}
	bool ok = false;
	if (env->PushLocalFrame(40) == 0) {
		do {
			jobject res = ms_resolver(env);
			if (!res) {
				err = "no resolver";
				break;
			}
			jobject cv = ms_cv(env);
			if (!cv) {
				err = "no ContentValues";
				break;
			}
			ms_put_str(env, cv, "_display_name", name);
			ms_put_str(env, cv, "mime_type", "video/mp4");
			ms_put_str(env, cv, "relative_path", rel_dir);
			ms_put_int(env, cv, "is_pending", 1);

			jclass c_ms = env->FindClass("android/provider/MediaStore$Video$Media");
			jfieldID f_uri = c_ms ? env->GetStaticFieldID(c_ms, "EXTERNAL_CONTENT_URI",
					"Landroid/net/Uri;") : nullptr;
			jobject base_uri = f_uri ? env->GetStaticObjectField(c_ms, f_uri) : nullptr;
			if (!base_uri) {
				err = "MediaStore.Video API";
				break;
			}
			jclass c_res = env->FindClass("android/content/ContentResolver");
			jmethodID m_ins = env->GetMethodID(c_res, "insert",
					"(Landroid/net/Uri;Landroid/content/ContentValues;)Landroid/net/Uri;");
			if (!m_ins) {
				err = "no insert";
				break;
			}
			jobject out_uri = env->CallObjectMethod(res, m_ins, base_uri, cv);
			if (env->ExceptionCheck()) {
				err = jexc(env, "insert");
				break;
			}
			if (!out_uri) {
				err = "insert 返回 null";
				break;
			}
			jmethodID m_open = env->GetMethodID(c_res, "openFileDescriptor",
					"(Landroid/net/Uri;Ljava/lang/String;)Landroid/os/ParcelFileDescriptor;");
			if (!m_open) {
				err = "no openFileDescriptor";
				break;
			}
			jstring rw = env->NewStringUTF("rw");
			jobject pfd = env->CallObjectMethod(res, m_open, out_uri, rw);
			if (!pfd) {
				err = "openFileDescriptor null";
				break;
			}
			jclass c_pfd = env->FindClass("android/os/ParcelFileDescriptor");
			jmethodID m_det = env->GetMethodID(c_pfd, "detachFd", "()I");
			if (!m_det) {
				err = "no detachFd";
				break;
			}
			jint fd = env->CallIntMethod(pfd, m_det);
			if (fd < 0) {
				err = "detachFd 失败";
				break;
			}
			st->uri = env->NewGlobalRef(out_uri);
			st->fd = (int)fd;
			st->pending = true;
			st->published = false;
			ok = true;
		} while (false);
		if (env->ExceptionCheck()) {
			env->ExceptionClear();
		}
		env->PopLocalFrame(nullptr);
	}
	if (att) {
		g_jvm->DetachCurrentThread();
	}
	return ok;
}

// 发布：IS_PENDING=0，相册/文件管理器立刻能看到
static void ms_publish(MsFileState *st) {
	if (!st->uri || st->published) {
		return;
	}
	bool att = false;
	JNIEnv *env = ms_env(&att);
	if (env && env->PushLocalFrame(16) == 0) {
		jobject res = ms_resolver(env);
		jobject cv = ms_cv(env);
		if (res && cv) {
			ms_put_int(env, cv, "is_pending", 0);
			jclass c_res = env->FindClass("android/content/ContentResolver");
			jmethodID m_upd = env->GetMethodID(c_res, "update",
					"(Landroid/net/Uri;Landroid/content/ContentValues;Ljava/lang/String;[Ljava/lang/String;)I");
			if (m_upd) {
				env->CallIntMethod(res, m_upd, st->uri, cv, nullptr, nullptr);
			}
		}
		if (env->ExceptionCheck()) {
			env->ExceptionClear();
		}
		env->PopLocalFrame(nullptr);
	}
	if (env) {
		env->DeleteGlobalRef(st->uri);
	}
	if (att) {
		g_jvm->DetachCurrentThread();
	}
	st->uri = nullptr;
	st->published = true;
}

// 失败/取消：把半截条目删掉，别在相册里留一个打不开的视频
static void ms_discard(MsFileState *st) {
	if (!st->uri) {
		return;
	}
	bool att = false;
	JNIEnv *env = ms_env(&att);
	if (env && env->PushLocalFrame(16) == 0) {
		jobject res = ms_resolver(env);
		if (res) {
			jclass c_res = env->FindClass("android/content/ContentResolver");
			jmethodID m_del = env->GetMethodID(c_res, "delete",
					"(Landroid/net/Uri;Ljava/lang/String;[Ljava/lang/String;)I");
			if (m_del) {
				env->CallIntMethod(res, m_del, st->uri, nullptr, nullptr);
			}
		}
		if (env->ExceptionCheck()) {
			env->ExceptionClear();
		}
		env->PopLocalFrame(nullptr);
	}
	if (env) {
		env->DeleteGlobalRef(st->uri);
	}
	if (att) {
		g_jvm->DetachCurrentThread();
	}
	st->uri = nullptr;
}

struct NativeVideoEncoder::Impl {
	AMediaCodec *venc = nullptr;
	AMediaFormat *vout = nullptr;
	AMediaCodec *aenc = nullptr;
	AMediaFormat *aout = nullptr;
	AMediaMuxer *mux = nullptr;
	int fd = -1;
	int vtrack = -1, atrack = -1;
	bool mux_started = false;
	int w = 0, h = 0, fps = 30, mbps = 20;  // mbps=兆比特/秒（GDScript 的 rec_mbps）
	int cf = COLOR_SEMI, stride = 0, slice = 0;
	int64_t frame_i = 0;
	size_t frame_bytes = 0;   // 每帧目标字节数（CBR 填充用）
	int64_t pad_frames = 0;   // 补过 filler 的帧数（诊断）
	int64_t dbg_n = 0, dbg_partial = 0, dbg_written = 0;
	int64_t dbg_wr_fail = 0;
	int64_t vbytes = 0, vframes = 0;   // 已写出的视频字节/帧数（CBR 预算）
	int64_t dbg_unaligned = 0;         // 分帧对不上、放弃填充的样本数
	int64_t dbg_first_size = 0, dbg_first_ln = 0;
	int dbg_wr_err = 0;
	std::vector<uint8_t> vpart;  // 分片访问单元的拼装缓冲
	int64_t vpart_pts = 0;
	bool vpart_open = false;
	std::vector<uint8_t> yuv;
	int sr = 48000, ch = 2;
	struct AS {
		std::vector<uint8_t> d;
		int64_t pts;
	};
	std::vector<AS> asamples;
	std::vector<int16_t> pcm; // 乐曲 PCM（已归一到 im->sr 双声道；set_hits 里混打击音再编 AAC）
	MsFileState ms;           // 相册输出（mediastore: 路径时才用）
	int64_t out_bytes = 0;    // 写进 muxer 的总字节（成片大小的近似值）
};

static void rgba_to_yuv(const uint8_t *p, int bpp, int w, int h, int stride, int slice, int cf,
		uint8_t *out, size_t cap) {
	const int cw = stride / 2;
	const int chh = slice / 2;
	memset(out, 16, (size_t)cap);
	uint8_t *Y = out;
	uint8_t *U = out + (size_t)stride * slice;
	uint8_t *V = (cf == COLOR_SEMI) ? U + 1 : U + (size_t)cw * chh;
	const int ustep = (cf == COLOR_SEMI) ? 2 : 1;
	const int vstep = (cf == COLOR_SEMI) ? 2 : 1;
	for (int y = 0; y < h; ++y) {
		const uint8_t *row = p + (size_t)y * w * bpp;
		uint8_t *yd = Y + (size_t)y * stride;
		for (int x = 0; x < w; ++x) {
			int r = row[x * bpp + 0], g = row[x * bpp + 1], b = row[x * bpp + 2];
			// BT.601 limited range（H.264 默认 tv range，和 ffmpeg 那条约一致）
			int yy = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
			yd[x] = (uint8_t)(yy < 16 ? 16 : (yy > 235 ? 235 : yy));
		}
		if ((y & 1) == 0 && (y / 2) < chh) {
			uint8_t *ud = U + (size_t)(y / 2) * cw * ustep;
			uint8_t *vd = V + (size_t)(y / 2) * cw * vstep;
			for (int x = 0; x < w; x += 2) {
				int r = 0, g = 0, b = 0;
				for (int k = 0; k < 2 && x + k < w; ++k) {
					const uint8_t *q = row + (size_t)(x + k) * bpp;
					r += q[0];
					g += q[1];
					b += q[2];
				}
				r /= 2;
				g /= 2;
				b /= 2;
				int uu = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
				int vv = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
				uu = uu < 0 ? 0 : (uu > 255 ? 255 : uu);
				vv = vv < 0 ? 0 : (vv > 255 ? 255 : vv);
				ud[(x / 2) * ustep] = (uint8_t)uu;
				vd[(x / 2) * vstep] = (uint8_t)vv;
			}
		}
	}
}

bool NativeVideoEncoder::available() const {
	AMediaCodec *c = AMediaCodec_createEncoderByType("video/avc");
	if (!c) {
		return false;
	}
	AMediaCodec_delete(c);
	return true;
}

int32_t NativeVideoEncoder::open(const String &p_out, int32_t p_w, int32_t p_h, int32_t p_fps,
		int32_t p_mbps) {
	abort();
	CharString cs = p_out.utf8();
	_impl = new Impl();
	Impl *im = _impl;
	im->w = p_w & ~1;
	im->h = p_h & ~1;
	im->fps = p_fps > 0 ? p_fps : 30;
	im->mbps = p_mbps > 0 ? p_mbps : 20;
	std::string out_path(cs.get_data() ? cs.get_data() : "");
	if (out_path.rfind("mediastore:", 0) == 0) {
		// mediastore:<相册相对目录>/<文件名> —— 走 ContentResolver.insert，
		// 文件直接落在 Pictures/PhiTogetherNext 里（不用 adb 也能看到）
		std::string rest = out_path.substr(11); // "mediastore:" 正好 11 个字符
		size_t slash = rest.find_last_of('/');
		if (slash == std::string::npos || slash + 1 >= rest.size()) {
			_err = "mediastore 路径缺文件名";
			return -1;
		}
		std::string dir = rest.substr(0, slash);
		std::string nm = rest.substr(slash + 1);
		std::string e;
		if (!ms_create(dir.c_str(), nm.c_str(), &im->ms, e)) {
			_err = String("相册写入失败：") + String(e.c_str());
			return -1;
		}
		im->fd = im->ms.fd;
	} else {
		im->fd = ::open(cs.get_data(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
	}
	if (im->fd < 0) {
		_err = "MP4 打不开";
		return -1;
	}
	im->mux = AMediaMuxer_new(im->fd, AMEDIAMUXER_OUTPUT_FORMAT_MPEG_4);
	if (!im->mux) {
		_err = "MediaMuxer 创建失败";
		return -2;
	}
	im->venc = AMediaCodec_createEncoderByType("video/avc");
	if (!im->venc) {
		_err = "没有 H.264 编码器";
		return -3;
	}
	AMediaFormat *f = AMediaFormat_new();
	AMediaFormat_setString(f, AMEDIAFORMAT_KEY_MIME, "video/avc");
	AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_WIDTH, im->w);
	AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_HEIGHT, im->h);
	// 单位：设置页给的是 Mbps。这里以前写成 kbps*1000，于是 46Mbps 被当成 46kbps，
	// 编码器只能按最低档跑（实测 2K60 三分钟 44MB）——用户两次报"码率不对"就是这条。
	AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_BIT_RATE, im->mbps * 1000000);
	AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_FRAME_RATE, im->fps);
	AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_I_FRAME_INTERVAL, 1);
	AMediaFormat_setInt32(f, AMEDIAFORMAT_KEY_COLOR_FORMAT, COLOR_FLEXIBLE);
	// 码率：默认 VBR 在简单画面上会掉到设定值的几分之一（用户实测 2K60 三分钟只有 50MB）。
	// CBR（bitrate-mode=2）让编码器按设定码率填；B 帧一律关掉，pts 才是单调的。
	AMediaFormat_setInt32(f, "bitrate-mode", 2);
	AMediaFormat_setInt32(f, "max-bframes", 0);
	media_status_t st = AMediaCodec_configure(im->venc, f, nullptr, nullptr,
			AMEDIACODEC_CONFIGURE_FLAG_ENCODE);
	AMediaFormat_delete(f);
	if (st != AMEDIA_OK) {
		_err = "H.264 configure 失败";
		return -4;
	}
	if (AMediaCodec_start(im->venc) != AMEDIA_OK) {
		_err = "H.264 start 失败";
		return -5;
	}
	// getInputFormat 是 API 28 才有的；我们 minSdk=24，所以按符号动态取。
	// 拿不到就按最常见布局兜底：NV12 + 16 对齐的 stride/slice
	im->cf = COLOR_SEMI;
	im->stride = (im->w + 15) & ~15;
	im->slice = (im->h + 15) & ~15;
	typedef AMediaFormat *(*gif_t)(AMediaCodec *);
	gif_t gif = (gif_t)dlsym(RTLD_DEFAULT, "AMediaCodec_getInputFormat");
	if (gif) {
		AMediaFormat *in = gif(im->venc);
		if (in) {
			AMediaFormat_getInt32(in, AMEDIAFORMAT_KEY_COLOR_FORMAT, &im->cf);
			AMediaFormat_getInt32(in, "stride", &im->stride);
			AMediaFormat_getInt32(in, "slice-height", &im->slice);
			AMediaFormat_delete(in);
		}
	}
	if (im->cf == COLOR_FLEXIBLE || im->cf == 0) {
		im->cf = COLOR_SEMI; // H.264 编码器基本都是 NV12
	}
	if (im->stride < im->w) {
		im->stride = im->w;
	}
	if (im->slice < im->h) {
		im->slice = im->h;
	}
	im->yuv.resize((size_t)im->stride * im->slice * 3 / 2 + 64);
	im->frame_bytes = (size_t)((double)im->mbps * 1000000.0 / 8.0 / (double)im->fps);
	return 0;
}

// ── 音频：解码 →（可选）混打击音 → AAC ─────────────────────────────────────
// 时间轴＝音乐秒：歌曲从 0 开始摆，打击音按事件时刻摆进去，视频也从音乐第 0 秒开录。
// 编码必须在推第一帧之前完成——MediaMuxer 的轨道只能在写第一帧之前 addTrack。

// 任何容器（ogg/mp3/wav/flac/m4a）→ int16 交错 PCM（按文件原生采样率/声道）
static bool decode_to_pcm(const char *path, std::vector<int16_t> &out, int &sr, int &ch) {
	out.clear();
	sr = 48000;
	ch = 2;
	int fd = ::open(path, O_RDONLY);
	if (fd < 0) {
		return false;
	}
	struct stat sbuf;
	if (fstat(fd, &sbuf) != 0) {
		::close(fd);
		return false;
	}
	AMediaExtractor *ex = AMediaExtractor_new();
	if (!ex || AMediaExtractor_setDataSourceFd(ex, fd, 0, sbuf.st_size) != AMEDIA_OK) {
		if (ex) {
			AMediaExtractor_delete(ex);
		}
		::close(fd);
		return false;
	}
	int at = -1;
	AMediaFormat *afmt = nullptr;
	for (size_t i = 0; i < AMediaExtractor_getTrackCount(ex); ++i) {
		AMediaFormat *f = AMediaExtractor_getTrackFormat(ex, i);
		const char *mime = nullptr;
		if (f && AMediaFormat_getString(f, AMEDIAFORMAT_KEY_MIME, &mime) && mime &&
				strncmp(mime, "audio/", 6) == 0) {
			at = (int)i;
			afmt = f;
			break;
		}
		if (f) {
			AMediaFormat_delete(f);
		}
	}
	if (at < 0) {
		AMediaExtractor_delete(ex);
		::close(fd);
		return false;
	}
	AMediaExtractor_selectTrack(ex, at);
	const char *amime = nullptr;
	AMediaFormat_getString(afmt, AMEDIAFORMAT_KEY_MIME, &amime);
	AMediaCodec *dec = AMediaCodec_createDecoderByType(amime);
	if (!dec || AMediaCodec_configure(dec, afmt, nullptr, nullptr, 0) != AMEDIA_OK ||
			AMediaCodec_start(dec) != AMEDIA_OK) {
		if (dec) {
			AMediaCodec_delete(dec);
		}
		AMediaFormat_delete(afmt);
		AMediaExtractor_delete(ex);
		::close(fd);
		return false;
	}
	AMediaFormat_delete(afmt);
	int src_sr = 48000, src_ch = 2;
	bool eos_in = false, eos_out = false;
	int guard = 0;
	while (!eos_out && guard++ < 4000000) {
		if (!eos_in) {
			ssize_t ii = AMediaCodec_dequeueInputBuffer(dec, 10000);
			if (ii >= 0) {
				size_t cap = 0;
				uint8_t *b = AMediaCodec_getInputBuffer(dec, ii, &cap);
				ssize_t rs = b ? AMediaExtractor_readSampleData(ex, b, cap) : -1;
				if (rs < 0) {
					AMediaCodec_queueInputBuffer(dec, ii, 0, 0, 0,
							AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
					eos_in = true;
				} else {
					int64_t pts = AMediaExtractor_getSampleTime(ex);
					AMediaCodec_queueInputBuffer(dec, ii, 0, (size_t)rs, pts, 0);
					AMediaExtractor_advance(ex);
				}
			}
		}
		for (;;) {
			AMediaCodecBufferInfo info;
			ssize_t oi = AMediaCodec_dequeueOutputBuffer(dec, &info, 0);
			if (oi == AMEDIACODEC_INFO_TRY_AGAIN_LATER) {
				break;
			}
			if (oi == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
				AMediaFormat *of = AMediaCodec_getOutputFormat(dec);
				if (of) {
					AMediaFormat_getInt32(of, AMEDIAFORMAT_KEY_SAMPLE_RATE, &src_sr);
					AMediaFormat_getInt32(of, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &src_ch);
					AMediaFormat_delete(of);
				}
				continue;
			}
			if (oi < 0) {
				break;
			}
			size_t sz = 0;
			uint8_t *b = AMediaCodec_getOutputBuffer(dec, oi, &sz);
			if (b && info.size > 0) {
				const int16_t *s = (const int16_t *)(b + info.offset);
				size_t cnt = (size_t)info.size / 2;
				out.insert(out.end(), s, s + cnt);
			}
			AMediaCodec_releaseOutputBuffer(dec, oi, false);
			if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) {
				eos_out = true;
			}
		}
	}
	AMediaCodec_stop(dec);
	AMediaCodec_delete(dec);
	AMediaExtractor_delete(ex);
	::close(fd);
	sr = src_sr > 0 ? src_sr : 48000;
	ch = src_ch > 0 ? src_ch : 2;
	return !out.empty();
}

// ≤2 声道 int16 交错 → 立体声（单声道复制，多声道取前两路）
static void pcm_to_stereo(const std::vector<int16_t> &in, int ch, std::vector<int16_t> &out) {
	out.clear();
	if (in.empty() || ch <= 0) {
		return;
	}
	if (ch == 2) {
		out = in;
		return;
	}
	if (ch == 1) {
		out.resize(in.size() * 2);
		for (size_t i = 0; i < in.size(); ++i) {
			out[i * 2] = in[i];
			out[i * 2 + 1] = in[i];
		}
		return;
	}
	size_t frames = in.size() / (size_t)ch;
	out.resize(frames * 2);
	for (size_t i = 0; i < frames; ++i) {
		out[i * 2] = in[i * (size_t)ch];
		out[i * 2 + 1] = in[i * (size_t)ch + 1];
	}
}

// 立体声 int16 线性重采样
static void pcm_resample_stereo(const std::vector<int16_t> &in, int sr_src, int sr_dst,
		std::vector<int16_t> &out) {
	out.clear();
	if (in.empty() || sr_src <= 0 || sr_dst <= 0) {
		return;
	}
	if (sr_src == sr_dst) {
		out = in;
		return;
	}
	size_t frames = in.size() / 2;
	size_t out_frames = (size_t)((double)frames * sr_dst / sr_src);
	out.resize(out_frames * 2);
	for (size_t i = 0; i < out_frames; ++i) {
		double pos = (double)i * sr_src / sr_dst;
		size_t i0 = (size_t)pos;
		size_t i1 = i0 + 1 < frames ? i0 + 1 : i0;
		double fr = pos - (double)i0;
		for (int c = 0; c < 2; ++c) {
			double a = in[i0 * 2 + c];
			double b = in[i1 * 2 + c];
			out[i * 2 + c] = (int16_t)(a + (b - a) * fr);
		}
	}
}

// 打击音文件：".f32" = 48k 立体声裸 float；其它交给系统解码器
static void load_sound(const std::string &path, int sr, std::vector<int16_t> &out) {
	out.clear();
	if (path.size() > 4 && path.compare(path.size() - 4, 4, ".f32") == 0) {
		int fd = ::open(path.c_str(), O_RDONLY);
		if (fd < 0) {
			return;
		}
		struct stat sb;
		if (fstat(fd, &sb) != 0 || sb.st_size < 8) {
			::close(fd);
			return;
		}
		size_t n = (size_t)sb.st_size / 4;
		std::vector<float> f(n);
		ssize_t got = ::read(fd, f.data(), n * 4);
		::close(fd);
		if (got <= 0) {
			return;
		}
		n = (size_t)got / 4;
		out.resize(n);
		for (size_t i = 0; i < n; ++i) {
			float v = f[i] * 32767.0f;
			out[i] = (int16_t)(v > 32767.0f ? 32767 : (v < -32768.0f ? -32768 : v));
		}
		if (sr != 48000) {
			std::vector<int16_t> r;
			pcm_resample_stereo(out, 48000, sr, r);
			out.swap(r);
		}
		return;
	}
	std::vector<int16_t> raw;
	int ssr = 48000, sch = 2;
	if (!decode_to_pcm(path.c_str(), raw, ssr, sch)) {
		return;
	}
	std::vector<int16_t> st;
	pcm_to_stereo(raw, sch, st);
	if (ssr != sr) {
		pcm_resample_stereo(st, ssr, sr, out);
	} else {
		out.swap(st);
	}
}

// 整条 PCM → AAC（样本与输出格式缓在 Impl 里，等 muxer 起来一次性写进去）
static int32_t encode_aac(NativeVideoEncoder::Impl *im, const std::vector<int16_t> &pcm, int sr,
		int ch) {
	im->asamples.clear();
	if (im->aout) {
		AMediaFormat_delete(im->aout);
		im->aout = nullptr;
	}
	if (pcm.empty() || sr <= 0 || ch <= 0) {
		return 0;
	}
	im->aenc = AMediaCodec_createEncoderByType("audio/mp4a-latm");
	if (!im->aenc) {
		return 0;
	}
	AMediaFormat *ef = AMediaFormat_new();
	AMediaFormat_setString(ef, AMEDIAFORMAT_KEY_MIME, "audio/mp4a-latm");
	AMediaFormat_setInt32(ef, AMEDIAFORMAT_KEY_SAMPLE_RATE, sr);
	AMediaFormat_setInt32(ef, AMEDIAFORMAT_KEY_CHANNEL_COUNT, ch);
	AMediaFormat_setInt32(ef, AMEDIAFORMAT_KEY_BIT_RATE, 192000);
	AMediaFormat_setInt32(ef, AMEDIAFORMAT_KEY_AAC_PROFILE, 2); // AACObjectLC
	AMediaFormat_setInt32(ef, AMEDIAFORMAT_KEY_MAX_INPUT_SIZE, 16384);
	if (AMediaCodec_configure(im->aenc, ef, nullptr, nullptr, AMEDIACODEC_CONFIGURE_FLAG_ENCODE) !=
					AMEDIA_OK ||
			AMediaCodec_start(im->aenc) != AMEDIA_OK) {
		AMediaFormat_delete(ef);
		AMediaCodec_delete(im->aenc);
		im->aenc = nullptr;
		return 0;
	}
	AMediaFormat_delete(ef);
	const size_t frames = pcm.size() / (size_t)ch;
	const size_t chunk = 4096;
	// 先把缓冲喂满，然后持续排空输出；输入队列满了就先收输出再喂，
	// 绝不阻塞等输入（管道满时阻塞会让整首歌退化成 2 秒/块，把渲染卡死）
	bool in_eos = false, out_eos = false;
	size_t off = 0;
	int idle = 0;
	while (!out_eos) {
		bool did = false;
		for (;;) {
			AMediaCodecBufferInfo info;
			ssize_t oi = AMediaCodec_dequeueOutputBuffer(im->aenc, &info, 0);
			if (oi == AMEDIACODEC_INFO_TRY_AGAIN_LATER) {
				break;
			}
			if (oi == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
				AMediaFormat *of = AMediaCodec_getOutputFormat(im->aenc);
				if (of) {
					if (im->aout) {
						AMediaFormat_delete(im->aout);
					}
					im->aout = of;
				}
				did = true;
				continue;
			}
			if (oi < 0) {
				break;
			}
			size_t sz = 0;
			uint8_t *b = AMediaCodec_getOutputBuffer(im->aenc, oi, &sz);
			// CODEC_CONFIG（AudioSpecificConfig）不是音频帧：混进样本表里会变成一个
			// 解不动的包（ffmpeg 报 "Invalid data found when processing input"）
			if (b && info.size > 0 && !(info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG)) {
				NativeVideoEncoder::Impl::AS s;
				s.d.assign(b + info.offset, b + info.offset + info.size);
				s.pts = info.presentationTimeUs;
				im->asamples.push_back(std::move(s));
			}
			did = true;
			if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) {
				out_eos = true;
			}
			AMediaCodec_releaseOutputBuffer(im->aenc, oi, false);
		}
		if (out_eos) {
			break;
		}
		if (!in_eos) {
			ssize_t ii = AMediaCodec_dequeueInputBuffer(im->aenc, 0);
			if (ii >= 0) {
				size_t cap = 0;
				uint8_t *b = AMediaCodec_getInputBuffer(im->aenc, ii, &cap);
				size_t n = (off < frames) ? (frames - off < chunk ? frames - off : chunk) : 0;
				size_t bytes = n * (size_t)ch * 2;
				bool last = off + n >= frames;
				if (!b || bytes > cap) {
					AMediaCodec_queueInputBuffer(im->aenc, ii, 0, 0, 0,
							AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
					in_eos = true;
				} else {
					if (bytes > 0) {
						memcpy(b, pcm.data() + off * (size_t)ch, bytes);
					}
					int64_t pts = (int64_t)((double)off * 1000000.0 / sr);
					AMediaCodec_queueInputBuffer(im->aenc, ii, 0, bytes, pts,
							last ? AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM : 0);
					off += n;
					if (last) {
						in_eos = true;
					}
				}
				did = true;
			}
		}
		if (!did) {
			if (++idle > 6000) { // ≈3s 纹丝不动：放弃音轨，别把录制挂死
				break;
			}
			::usleep(500);
		} else {
			idle = 0;
		}
	}
	AMediaCodec_stop(im->aenc);
	AMediaCodec_delete(im->aenc);
	im->aenc = nullptr;
	if (!out_eos) {
		im->asamples.clear();
		if (im->aout) {
			AMediaFormat_delete(im->aout);
			im->aout = nullptr;
		}
		return -1;
	}
	return 0;
}

// 只解码乐曲：AAC 要等打击音都摆好再编（set_hits）
int32_t NativeVideoEncoder::set_audio(const String &p_song_path, double p_gain) {
	if (!_impl || !_impl->mux) {
		_err = "编码器未打开";
		return -1;
	}
	Impl *im = _impl;
	im->pcm.clear();
	if (p_song_path.is_empty()) {
		return 0;
	}
	CharString cs = p_song_path.utf8();
	std::vector<int16_t> raw;
	int sr = 48000, ch = 2;
	if (!decode_to_pcm(cs.get_data(), raw, sr, ch)) {
		return 0; // 没音轨也能出片
	}
	std::vector<int16_t> st;
	pcm_to_stereo(raw, ch, st);
	im->sr = (sr == 44100 || sr == 48000) ? sr : 48000;
	im->ch = 2;
	if (im->sr != sr) {
		pcm_resample_stereo(st, sr, im->sr, im->pcm);
	} else {
		im->pcm.swap(st);
	}
	// 音乐音量（设置页 music_vol）：ffmpeg 那条链用 volume 滤镜，这里同一个口径
	double g = p_gain < 0.0 ? 0.0 : (p_gain > 1.0 ? 1.0 : p_gain);
	if (g < 0.999) {
		for (auto &v : im->pcm) {
			int x = (int)((double)v * g);
			v = (int16_t)(x > 32767 ? 32767 : (x < -32768 ? -32768 : x));
		}
	}
	return 0;
}

// 打击音摆进乐曲 PCM → 立刻编 AAC（muxer 起来时轨道与样本都齐了）
int32_t NativeVideoEncoder::set_hits(const PackedFloat64Array &p_times,
		const PackedStringArray &p_paths, double p_gain) {
	if (!_impl) {
		_err = "编码器未打开";
		return -1;
	}
	Impl *im = _impl;
	const int64_t n = p_times.size();
	const double gain = p_gain < 0.0 ? 0.0 : (p_gain > 1.0 ? 1.0 : p_gain);
	// 每个不同文件只解码一次（一张谱通常就 3~4 种打击音）
	std::vector<std::string> keys;
	std::vector<std::vector<int16_t>> cache;
	std::vector<int64_t> slot(n, -1);
	size_t frames = im->pcm.size() / 2;
	for (int64_t i = 0; i < n; ++i) {
		if (i >= p_paths.size()) {
			break;
		}
		std::string key = std::string(p_paths[i].utf8().get_data());
		if (key.empty()) {
			continue;
		}
		int64_t idx = -1;
		for (size_t k = 0; k < keys.size(); ++k) {
			if (keys[k] == key) {
				idx = (int64_t)k;
				break;
			}
		}
		if (idx < 0) {
			std::vector<int16_t> s;
			load_sound(key, im->sr, s);
			keys.push_back(key);
			cache.push_back(std::move(s));
			idx = (int64_t)cache.size() - 1;
			if (cache.back().empty()) {
				continue; // 解不开就当没有，别把整条音轨拖垮
			}
		}
		slot[i] = idx;
		double t = p_times[i];
		if (t < 0.0) {
			continue;
		}
		size_t start = (size_t)(t * im->sr);
		size_t end = start + cache[idx].size() / 2;
		if (end > frames) {
			frames = end;
		}
	}
	if (frames == 0) {
		return 0;
	}
	std::vector<int16_t> mix(frames * 2, 0);
	for (size_t i = 0; i < im->pcm.size() && i < mix.size(); ++i) {
		mix[i] = im->pcm[i];
	}
	size_t mixed = 0;
	for (int64_t i = 0; i < n; ++i) {
		if (slot[i] < 0) {
			continue;
		}
		const std::vector<int16_t> &s = cache[slot[i]];
		double t = p_times[i];
		if (t < 0.0) {
			continue;
		}
		size_t off = (size_t)(t * im->sr) * 2;
		size_t m = s.size();
		if (off + m > mix.size()) {
			m = mix.size() > off ? mix.size() - off : 0;
		}
		for (size_t k = 0; k < m; ++k) {
			int v = (int)mix[off + k] + (int)((double)s[k] * gain);
			mix[off + k] = (int16_t)(v > 32767 ? 32767 : (v < -32768 ? -32768 : v));
		}
		mixed++;
	}
	int32_t rc = encode_aac(im, mix, im->sr, im->ch);
	if (rc != 0) {
		_err = "AAC 编码没收到 EOS（已成片为无音轨）";
	}
	return 0;
}

static void drain_video(NativeVideoEncoder::Impl *im, bool eos);

int32_t NativeVideoEncoder::push_frame(const PackedByteArray &p_pixels, int32_t p_bpp) {
	if (!_impl || !_impl->venc) {
		_err = "编码器未打开";
		return -1;
	}
	Impl *im = _impl;
	const int bpp = (p_bpp == 4) ? 4 : 3;
	const uint8_t *src = p_pixels.ptr();
	size_t need = (size_t)im->w * im->h * bpp;
	if (!src || p_pixels.size() < (int64_t)need) {
		_err = "帧字节数不对";
		return -2;
	}
	ssize_t ii = AMediaCodec_dequeueInputBuffer(im->venc, 2000000);
	if (ii < 0) {
		_err = "dequeueInputBuffer 超时";
		return -3;
	}
	size_t cap = 0;
	uint8_t *b = AMediaCodec_getInputBuffer(im->venc, ii, &cap);
	const size_t need_yuv = (size_t)im->stride * im->slice * 3 / 2;
	if (!b || cap < need_yuv) {
		AMediaCodec_queueInputBuffer(im->venc, ii, 0, 0, 0, 0);
		_err = "输入缓冲太小";
		return -4;
	}
	rgba_to_yuv(src, bpp, im->w, im->h, im->stride, im->slice, im->cf, b, cap);
	const size_t used = (size_t)im->stride * im->slice * 3 / 2;
	int64_t pts = im->frame_i * 1000000LL / im->fps;
	AMediaCodec_queueInputBuffer(im->venc, ii, 0, used, pts, 0);
	im->frame_i++;
	drain_video(im, false);
	return 0;
}

// 写一个完整访问单元：不足目标码率的部分用 filler NAL 补齐（AVCC 格式，
// nal_unit_type=12，解码器直接忽略）。x264 的 nal-hrd=cbr 也是这个做法。
static void write_video_sample(NativeVideoEncoder::Impl *im, const uint8_t *data, size_t size,
		int64_t pts, int32_t flags) {
	AMediaCodecBufferInfo si;
	memset(&si, 0, sizeof(si));
	si.size = (int32_t)size;
	si.presentationTimeUs = pts;
	// 关键帧标志必须原样带过去：muxer 靠它写 stss（同步样本表）。
	// 丢掉之后整条视频轨没有同步样本，成片只剩一条空视频轨（实测就是这么翻车的）。
	si.flags = flags & 1; // BUFFER_FLAG_KEY_FRAME（NDK 头里没给这个名字，值就是 1）
	const bool eos = (flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) != 0;
	if (eos) {
		si.flags |= AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM;
	}
	// 按**累计预算**补：关键帧往往远超每帧目标，补完一帧就超额，下几帧就别再补，
	// 这样整片平均码率才真正等于设定值（逐帧各自补满会系统性偏高 10% 以上）
	size_t write_sz = size;
	// 补 filler：**MediaCodec 的 H.264 输出是 Annex-B（起始码 00 00 00 01）**，
	// MediaMuxer 收到后自己转 AVCC 写进 MP4。这里必须跟着起始码写——
	// 以前按 AVCC 的 4 字节长度前缀补，muxer 转码时把这几个字节当成新 NAL 的
	// 数据流长度，于是零星几帧被切歪（实测 6817 帧里 10 帧解出 type=0 垃圾 NAL）。
	if (!eos && im->frame_bytes > 0) {
		int64_t want = (int64_t)((double)(im->vframes + 1) * (double)im->frame_bytes);
		int64_t deficit = want - im->vbytes - (int64_t)size;
		if (deficit > 8) {
			size_t pad = (size_t)deficit;
			std::vector<uint8_t> tmp(size + pad);
			memcpy(tmp.data(), data, size);
			uint8_t *fp = tmp.data() + size;
			fp[0] = 0;
			fp[1] = 0;
			fp[2] = 0;
			fp[3] = 1;
			fp[4] = 0x0C;                 // nal_unit_type = 12（filler data）
			memset(fp + 5, 0xFF, pad - 5); // 剩余全部填充
			si.size = (int32_t)tmp.size();
			write_sz = tmp.size();
			media_status_t st = AMediaMuxer_writeSampleData(im->mux, im->vtrack, tmp.data(), &si);
			if (st != AMEDIA_OK) {
				im->dbg_wr_fail++;
				im->dbg_wr_err = (int)st;
			}
			im->pad_frames++;
			im->vbytes += (int64_t)write_sz;
			im->out_bytes += (int64_t)write_sz;
			im->vframes++;
			return;
		}
	}
	media_status_t st = AMediaMuxer_writeSampleData(im->mux, im->vtrack, data, &si);
	if (st != AMEDIA_OK) {
		im->dbg_wr_fail++;
		im->dbg_wr_err = (int)st;
	}
	im->vbytes += (int64_t)write_sz;
	im->out_bytes += (int64_t)write_sz;
	im->vframes++;
}

static void drain_video(NativeVideoEncoder::Impl *im, bool eos) {
	for (;;) {
		AMediaCodecBufferInfo info;
		ssize_t oi = AMediaCodec_dequeueOutputBuffer(im->venc, &info, eos ? 2000000 : 0);
		if (oi == AMEDIACODEC_INFO_TRY_AGAIN_LATER) {
			break;
		}
		if (oi == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
			if (!im->mux_started) {
				AMediaFormat *of = AMediaCodec_getOutputFormat(im->venc);
				if (of) {
					im->vout = of;
					im->vtrack = AMediaMuxer_addTrack(im->mux, im->vout);
					if (im->aout) {
						im->atrack = AMediaMuxer_addTrack(im->mux, im->aout);
					}
					im->mux_started = AMediaMuxer_start(im->mux) == AMEDIA_OK;
					if (im->mux_started && im->atrack >= 0) {
						for (auto &s : im->asamples) {
							AMediaCodecBufferInfo ai;
							memset(&ai, 0, sizeof(ai));
							ai.size = (int32_t)s.d.size();
							ai.presentationTimeUs = s.pts;
							AMediaMuxer_writeSampleData(im->mux, im->atrack, s.d.data(), &ai);
							im->out_bytes += (int64_t)s.d.size();
						}
						im->asamples.clear();
					}
				}
			}
			continue;
		}
		if (oi < 0) {
			break;
		}
		size_t sz = 0;
		uint8_t *b = AMediaCodec_getOutputBuffer(im->venc, oi, &sz);
		if (im->dbg_n < 8) {
			UtilityFunctions::print("QA-REC 样本 ", (int64_t)im->dbg_n, " size=", (int64_t)info.size,
					" flags=", (int64_t)info.flags, " offset=", (int64_t)info.offset,
					" mux=", im->mux_started);
			im->dbg_n++;
		}
		if (b && im->mux_started && im->vtrack >= 0) {
			const bool partial = (info.flags & AMEDIACODEC_BUFFER_FLAG_PARTIAL_FRAME) != 0;
			im->dbg_partial += partial ? 1 : 0;
			im->dbg_written++;
			// 分片样本：一个访问单元被编码器切成几段（46Mbps 的关键帧能有 1MB，
			// 超出编码器输出缓冲）。MediaMuxer 的"一个 sample = 一个访问单元"是硬约束，
			// 分段各写一次会让后续字节错位（实测 6817 帧里 8 帧解成垃圾 NAL）。
			// 这里攒齐再写一次。
			// 时间戳一变就说明上一帧结束了：不管 PARTIAL 标志怎么给，都要把它写出去
			// （以前只看标志，碰上编码器给所有样本都带 PARTIAL 的情况会永远攒着不写，
			//  成片只剩一条空视频轨）。
			if (im->vpart_open && im->vpart_pts != info.presentationTimeUs) {
				write_video_sample(im, im->vpart.data(), im->vpart.size(), im->vpart_pts, 0);
				im->vpart.clear();
				im->vpart_open = false;
			}
			if (partial || im->vpart_open) {
				if (!im->vpart_open) {
					im->vpart_open = true;
					im->vpart_pts = info.presentationTimeUs;
				}
				im->vpart.insert(im->vpart.end(), b + info.offset, b + info.offset + info.size);
				if (!partial) { // 这一段是收尾段
					write_video_sample(im, im->vpart.data(), im->vpart.size(), im->vpart_pts,
							info.flags);
					im->vpart.clear();
					im->vpart_open = false;
				}
			} else {
				write_video_sample(im, b + info.offset, (size_t)info.size,
						info.presentationTimeUs, info.flags);
			}
		}
		AMediaCodec_releaseOutputBuffer(im->venc, oi, false);
		if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) {
			break;
		}
	}
}

int64_t NativeVideoEncoder::output_size() const {
	if (!_impl) {
		return int64_t(_last_stats.get("out_bytes", 0));
	}
	return _impl->out_bytes;
}

Dictionary NativeVideoEncoder::debug_stats() const {
	Dictionary d;
	if (!_impl) {
		return _last_stats;
	}
	Impl *im = _impl;
	d["frames"] = (int64_t)im->frame_i;
	d["pad_frames"] = (int64_t)im->pad_frames;
	d["frame_bytes"] = (int64_t)im->frame_bytes;
	d["written"] = im->dbg_written;
	d["partial"] = im->dbg_partial;
	d["vpart"] = (int64_t)im->vpart.size();
	d["wr_fail"] = (int64_t)im->dbg_wr_fail;
	d["wr_err"] = im->dbg_wr_err;
	d["unaligned"] = (int64_t)im->dbg_unaligned;
	d["first_size"] = im->dbg_first_size;
	d["first_ln"] = im->dbg_first_ln;
	d["vtrack"] = im->vtrack;
	d["atrack"] = im->atrack;
	d["out_bytes"] = im->out_bytes;
	return d;
}

int32_t NativeVideoEncoder::finish() {
	if (!_impl) {
		return 0;
	}
	Impl *im = _impl;
	if (im->venc) {
		ssize_t ii = AMediaCodec_dequeueInputBuffer(im->venc, 2000000);
		if (ii >= 0) {
			AMediaCodec_queueInputBuffer(im->venc, ii, 0, 0,
					im->frame_i * 1000000LL / im->fps, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
		}
		drain_video(im, true);
		AMediaCodec_stop(im->venc);
	}
	if (im->mux && im->mux_started) {
		AMediaMuxer_stop(im->mux);
	}
	_last_stats = debug_stats();
	int32_t rc = im->mux_started ? 0 : -1;
	if (rc != 0) {
		_err = "一帧都没编出来";
	}
	// 先把 fd 关掉（muxer 已经把数据写进去了），再决定发布还是丢弃相册条目
	if (im->fd >= 0) {
		::close(im->fd);
		im->fd = -1;
	}
	if (rc == 0) {
		ms_publish(&im->ms);
	} else {
		ms_discard(&im->ms);
	}
	abort();
	return rc;
}

void NativeVideoEncoder::abort() {
	if (!_impl) {
		return;
	}
	Impl *im = _impl;
	if (im->venc) {
		AMediaCodec_delete(im->venc);
	}
	if (im->aenc) {
		AMediaCodec_delete(im->aenc);
	}
	if (im->vout) {
		AMediaFormat_delete(im->vout);
	}
	if (im->aout) {
		AMediaFormat_delete(im->aout);
	}
	if (im->mux) {
		AMediaMuxer_delete(im->mux);
	}
	if (im->fd >= 0) {
		::close(im->fd);
		im->fd = -1;
	}
	if (im->ms.uri && !im->ms.published) {
		ms_discard(&im->ms);
	}
	delete im;
	_impl = nullptr;
}

#else // ── 非 Android：没有进程内编码器（桌面继续用系统 ffmpeg） ────────────────

struct NativeVideoEncoder::Impl {};

bool NativeVideoEncoder::available() const { return false; }
int32_t NativeVideoEncoder::open(const String &, int32_t, int32_t, int32_t, int32_t) {
	_err = "本平台没有进程内编码器";
	return -1;
}
int32_t NativeVideoEncoder::set_audio(const String &, double) { return 0; }
int32_t NativeVideoEncoder::set_hits(const PackedFloat64Array &, const PackedStringArray &, double) {
	return 0;
}
int32_t NativeVideoEncoder::push_frame(const PackedByteArray &, int32_t) { return -1; }
int64_t NativeVideoEncoder::output_size() const { return 0; }
Dictionary NativeVideoEncoder::debug_stats() const { return Dictionary(); }
int32_t NativeVideoEncoder::finish() { return -1; }
void NativeVideoEncoder::abort() {}

#endif

void NativeVideoEncoder::_bind_methods() {
	ClassDB::bind_method(D_METHOD("available"), &NativeVideoEncoder::available);
	ClassDB::bind_method(D_METHOD("open", "path", "width", "height", "fps", "kbps"),
			&NativeVideoEncoder::open);
	ClassDB::bind_method(D_METHOD("set_audio", "song_path", "gain"), &NativeVideoEncoder::set_audio);
	ClassDB::bind_method(D_METHOD("set_hits", "times", "paths", "gain"),
			&NativeVideoEncoder::set_hits);
	ClassDB::bind_method(D_METHOD("push_frame", "pixels", "bpp"), &NativeVideoEncoder::push_frame);
	ClassDB::bind_method(D_METHOD("finish"), &NativeVideoEncoder::finish);
	ClassDB::bind_method(D_METHOD("abort"), &NativeVideoEncoder::abort);
	ClassDB::bind_method(D_METHOD("debug_stats"), &NativeVideoEncoder::debug_stats);
	ClassDB::bind_method(D_METHOD("output_size"), &NativeVideoEncoder::output_size);
	ClassDB::bind_method(D_METHOD("last_error"), &NativeVideoEncoder::last_error);
}