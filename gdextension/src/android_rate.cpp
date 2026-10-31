#include "android_rate.h"

#include <godot_cpp/core/class_db.hpp>

#if defined(__ANDROID__)

#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <jni.h>

#endif

namespace godot {

#if defined(__ANDROID__)

// ── 诊断文本 ────────────────────────────────────────────────────────────────
// 这条链全是在反射 Godot 的 Java 层，任何一步静默失败都会变成"投了票但屏还是 60"，
// 从外部完全分不出是哪一环。所以每一步都往同一段文本里写，vote() 把它整个返回给
// GDScript 打 logcat。
// ⚠ 运行期字符串一律 ASCII：中文字面量经 String(const char*) 上 logcat 会变乱码
//   （真机实测 "投票已提交" → "æç¥¨å·²æº"），诊断读不了就等于没有诊断。
static char g_trace[1400];
static int g_tlen = 0;

static void treset() {
	g_trace[0] = 0;
	g_tlen = 0;
}

static void tput(const char *p_fmt, ...) {
	if (g_tlen >= (int)sizeof(g_trace) - 1) {
		return;
	}
	int room = (int)sizeof(g_trace) - 1 - g_tlen;
	va_list ap;
	va_start(ap, p_fmt);
	int w = vsnprintf(g_trace + g_tlen, room, p_fmt, ap);
	va_end(ap);
	if (w > 0) {
		g_tlen += (w < room) ? w : room;
	}
}

static JavaVM *g_vm = nullptr;

static bool s_vm() {
	if (g_vm) {
		return true;
	}
	typedef jint (*getvms_t)(JavaVM **, jsize, jsize *);
	getvms_t f = (getvms_t)dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
	if (!f) {
		const char *libs[] = { "libnativehelper.so", "libart.so", "libandroid_runtime.so" };
		for (int i = 0; i < 3 && !f; ++i) {
			void *h = dlopen(libs[i], RTLD_NOW);
			if (h) {
				f = (getvms_t)dlsym(h, "JNI_GetCreatedJavaVMs");
			}
		}
	}
	if (!f) {
		tput("JNI_GetCreatedJavaVMs not found\n");
		return false;
	}
	jsize n = 0;
	if (f(&g_vm, 1, &n) != JNI_OK || n < 1 || !g_vm) {
		tput("JNI_GetCreatedJavaVMs failed (n=%d)\n", (int)n);
		g_vm = nullptr;
		return false;
	}
	return true;
}

static JNIEnv *s_env(bool *p_attached) {
	*p_attached = false;
	if (!s_vm()) {
		return nullptr;
	}
	JNIEnv *env = nullptr;
	if (g_vm->GetEnv((void **)&env, JNI_VERSION_1_6) == JNI_OK && env) {
		return env;
	}
	if (g_vm->AttachCurrentThread(&env, nullptr) == JNI_OK && env) {
		*p_attached = true;
		return env;
	}
	tput("AttachCurrentThread failed\n");
	return nullptr;
}

static bool jcheck(JNIEnv *p_env, const char *p_where) {
	if (p_env->ExceptionCheck()) {
		p_env->ExceptionClear();
		tput("%s: java exception\n", p_where);
		return true;
	}
	return false;
}

// Godot 的类在 app 自己的 ClassLoader 里；原生线程 FindClass 用的是系统 ClassLoader，
// 直接找会 NoClassDefFoundError。所以从 currentApplication() 拿到 app 的 loader 再 loadClass。
static jclass s_loadclass(JNIEnv *p_env, const char *p_dotted, const char *p_slashed) {
	jobject loader = nullptr;
	jclass at = p_env->FindClass("android/app/ActivityThread");
	if (at) {
		jmethodID cur = p_env->GetStaticMethodID(at, "currentApplication", "()Landroid/app/Application;");
		jobject app = cur ? p_env->CallStaticObjectMethod(at, cur) : nullptr;
		if (app && !jcheck(p_env, "currentApplication")) {
			jmethodID gcl = p_env->GetMethodID(p_env->FindClass("android/content/ContextWrapper"),
					"getClassLoader", "()Ljava/lang/ClassLoader;");
			loader = gcl ? p_env->CallObjectMethod(app, gcl) : nullptr;
			if (jcheck(p_env, "getClassLoader")) {
				loader = nullptr;
			}
		}
	}
	jclass out = nullptr;
	if (loader) {
		jmethodID ld = p_env->GetMethodID(p_env->FindClass("java/lang/ClassLoader"),
				"loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
		if (ld) {
			out = (jclass)p_env->CallObjectMethod(loader, ld, p_env->NewStringUTF(p_dotted));
			if (jcheck(p_env, p_dotted)) {
				out = nullptr;
			}
		}
	}
	if (!out) {
		out = (jclass)p_env->FindClass(p_slashed);   // 兜底：某些构建下系统 loader 也看得见
		jcheck(p_env, p_slashed);
	}
	return out;
}

static jmethodID s_mid(JNIEnv *p_env, jclass p_cls, const char *p_name, const char *p_sig,
		const char *p_where) {
	if (!p_cls) {
		return nullptr;
	}
	jmethodID m = p_env->GetMethodID(p_cls, p_name, p_sig);
	if (!m) {
		jcheck(p_env, p_name);
		tput("%s has no %s%s\n", p_where, p_name, p_sig);
	}
	return m;
}

// Godot 单例（Kotlin object → 静态字段 INSTANCE）
static jobject s_godot(JNIEnv *p_env) {
	jclass gv = s_loadclass(p_env, "org.godotengine.godot.Godot", "org/godotengine/godot/Godot");
	if (!gv) {
		tput("class org.godotengine.godot.Godot not found\n");
		return nullptr;
	}
	jfieldID f = p_env->GetStaticFieldID(gv, "INSTANCE", "Lorg/godotengine/godot/Godot;");
	if (!f) {
		jcheck(p_env, "INSTANCE");
		tput("Godot.INSTANCE unreachable\n");
		return nullptr;
	}
	jobject inst = p_env->GetStaticObjectField(gv, f);
	if (!inst) {
		tput("Godot.INSTANCE=null (no token yet)\n");
	}
	return inst;
}

// Godot.INSTANCE.getRenderView() → SurfaceView（VkSurfaceView 是它的子类）→ Surface
static jobject s_surface(JNIEnv *p_env) {
	jobject godot = s_godot(p_env);
	if (!godot) {
		return nullptr;
	}
	jclass gv = p_env->GetObjectClass(godot);
	jmethodID m_grv = s_mid(p_env, gv, "getRenderView", "()Lorg/godotengine/godot/GodotRenderView;", "Godot");
	jobject view = m_grv ? p_env->CallObjectMethod(godot, m_grv) : nullptr;
	if (m_grv && jcheck(p_env, "getRenderView")) {
		return nullptr;
	}
	if (!view) {
		tput("getRenderView()=null (surface not created yet)\n");
		return nullptr;
	}
	jclass sv = p_env->FindClass("android/view/SurfaceView");
	if (!sv || !p_env->IsInstanceOf(view, sv)) {
		// 不是 SurfaceView 就把真实类名打出来，下一轮照这个名字改链
		jclass vc = p_env->GetObjectClass(view);
		jmethodID gn = p_env->GetMethodID(p_env->FindClass("java/lang/Class"), "getName", "()Ljava/lang/String;");
		jstring jn = gn ? (jstring)p_env->CallObjectMethod(vc, gn) : nullptr;
		const char *cn = jn ? p_env->GetStringUTFChars(jn, nullptr) : nullptr;
		tput("renderView is not a SurfaceView; real class=%s\n", cn ? cn : "?");
		if (jn && cn) {
			p_env->ReleaseStringUTFChars(jn, cn);
		}
		return nullptr;
	}
	jmethodID m_hold = s_mid(p_env, sv, "getHolder", "()Landroid/view/SurfaceHolder;", "SurfaceView");
	jobject holder = m_hold ? p_env->CallObjectMethod(view, m_hold) : nullptr;
	if (m_hold && jcheck(p_env, "getHolder")) {
		return nullptr;
	}
	if (!holder) {
		tput("getHolder()=null\n");
		return nullptr;
	}
	jclass sh = p_env->FindClass("android/view/SurfaceHolder");
	jmethodID m_surf = s_mid(p_env, sh, "getSurface", "()Landroid/view/Surface;", "SurfaceHolder");
	jobject surf = m_surf ? p_env->CallObjectMethod(holder, m_surf) : nullptr;
	if (m_surf && jcheck(p_env, "getSurface")) {
		return nullptr;
	}
	if (!surf) {
		tput("getSurface()=null\n");
	}
	return surf;
}

static jobject s_activity(JNIEnv *p_env) {
	jobject godot = s_godot(p_env);
	if (!godot) {
		return nullptr;
	}
	jclass gv = p_env->GetObjectClass(godot);
	jmethodID m = s_mid(p_env, gv, "getActivity", "()Landroid/app/Activity;", "Godot");
	jobject a = m ? p_env->CallObjectMethod(godot, m) : nullptr;
	if (m && jcheck(p_env, "getActivity")) {
		return nullptr;
	}
	if (!a) {
		tput("getActivity()=null\n");
	}
	return a;
}

// libandroid 里的两个投票入口：setFrameRateWithChangeStrategy(API31+) 优先，
// 因为它能显式允许"非无缝切档"（ALWAYS），正好是我们想要的"宁可闪一下也要抬到 120"。
static int s_do_vote(JNIEnv *p_env, double p_hz) {
	void *h = dlopen("libandroid.so", RTLD_NOW);
	if (!h) {
		tput("dlopen(libandroid.so) failed\n");
		return -1;
	}
	typedef int32_t (*setfrs_t)(ANativeWindow *, float, int8_t, int8_t);
	typedef int32_t (*setfr_t)(ANativeWindow *, float, int8_t);
	setfrs_t fs = (setfrs_t)dlsym(h, "ANativeWindow_setFrameRateWithChangeStrategy");
	setfr_t f = (setfr_t)dlsym(h, "ANativeWindow_setFrameRate");
	jobject surf = s_surface(p_env);
	if (!surf) {
		return -2;
	}
	ANativeWindow *w = ANativeWindow_fromSurface(p_env, surf);
	if (!w) {
		tput("ANativeWindow_fromSurface=null\n");
		return -3;
	}
	int rc = -1;
	if (fs) {
		// compat=DEFAULT(0)：游戏内容；strategy=ALWAYS(1)：允许非无缝切档
		rc = fs(w, (float)p_hz, 0, 1);
		tput("setFrameRateWithChangeStrategy(%.1f,DEFAULT,ALWAYS)=%d\n", p_hz, rc);
	} else if (f) {
		rc = f(w, (float)p_hz, 0);
		tput("setFrameRate(%.1f,DEFAULT)=%d (no WithChangeStrategy)\n", p_hz, rc);
	} else {
		tput("libandroid has no setFrameRate symbol\n");
	}
	tput("  window=%dx%d\n", ANativeWindow_getWidth(w), ANativeWindow_getHeight(w));
	ANativeWindow_release(w);
	return rc;
}

#endif // __ANDROID__

String AndroidRate::vote(double p_hz) {
#if defined(__ANDROID__)
	treset();
	bool att = false;
	JNIEnv *env = s_env(&att);
	if (!env) {
		return String(g_trace);
	}
	int rc = s_do_vote(env, p_hz);
	tput("=> %s\n", rc == 0 ? "VOTE SUBMITTED" : "VOTE NOT SUBMITTED (see above)");
	if (att) {
		g_vm->DetachCurrentThread();
	}
	_trace = String(g_trace);
	return _trace;
#else
	return "AndroidRate: not android, no-op";
#endif
}

// 备用路线：本轮实测从原生线程调 Window.setAttributes 会抛 CalledFromWrongThreadException，
// 要挂到 UI 线程才有意义；ANativeWindow 那条已经能把屏档抬起来，所以先不修这条。
String AndroidRate::prefer_mode(int p_mode_id) {
#if defined(__ANDROID__)
	treset();
	bool att = false;
	JNIEnv *env = s_env(&att);
	if (!env) {
		return String(g_trace);
	}
	jobject act = s_activity(env);
	if (act) {
		jclass act_c = env->FindClass("android/app/Activity");
		jmethodID m_win = s_mid(env, act_c, "getWindow", "()Landroid/view/Window;", "Activity");
		jobject win = m_win ? env->CallObjectMethod(act, m_win) : nullptr;
		if (m_win && jcheck(env, "getWindow")) {
			win = nullptr;
		}
		if (win) {
			jclass win_c = env->FindClass("android/view/Window");
			jmethodID m_get = s_mid(env, win_c, "getAttributes",
					"()Landroid/view/WindowManager$LayoutParams;", "Window");
			jobject lp = m_get ? env->CallObjectMethod(win, m_get) : nullptr;
			if (m_get && jcheck(env, "getAttributes")) {
				lp = nullptr;
			}
			if (lp) {
				jclass lp_c = env->GetObjectClass(lp);
				jfieldID f = env->GetFieldID(lp_c, "preferredDisplayModeId", "I");
				if (!f) {
					jcheck(env, "preferredDisplayModeId");
					tput("LayoutParams.preferredDisplayModeId missing (needs API33)\n");
				} else {
					int old = env->GetIntField(lp, f);
					env->SetIntField(lp, f, (jint)p_mode_id);
					jmethodID m_set = s_mid(env, win_c, "setAttributes",
							"(Landroid/view/WindowManager$LayoutParams;)V", "Window");
					if (m_set) {
						env->CallVoidMethod(win, m_set, lp);
						bool exc = jcheck(env, "setAttributes");
						tput("preferredDisplayModeId %d->%d %s\n", old, p_mode_id,
								exc ? "BUT java exception" : "submitted");
					}
				}
			}
		}
	}
	if (att) {
		g_vm->DetachCurrentThread();
	}
	_trace = String(g_trace);
	return _trace;
#else
	return "AndroidRate: not android, no-op";
#endif
}

String AndroidRate::probe() {
#if defined(__ANDROID__)
	treset();
	bool att = false;
	JNIEnv *env = s_env(&att);
	if (!env) {
		return String(g_trace);
	}
	jobject surf = s_surface(env);
	tput("surface=%s ", surf ? "YES" : "NO");
	jobject act = s_activity(env);
	tput("activity=%s\n", act ? "YES" : "NO");
	if (att) {
		g_vm->DetachCurrentThread();
	}
	_trace = String(g_trace);
	return _trace;
#else
	return "AndroidRate: not android, no-op";
#endif
}

void AndroidRate::_bind_methods() {
	ClassDB::bind_method(D_METHOD("vote", "hz"), &AndroidRate::vote);
	ClassDB::bind_method(D_METHOD("prefer_mode", "mode_id"), &AndroidRate::prefer_mode);
	ClassDB::bind_method(D_METHOD("probe"), &AndroidRate::probe);
}

} // namespace godot
