class_name AudioComplexity
extends RefCounted
## 从**音频本身**找"最复杂的 N 秒"，给选曲试听当起播点 + 循环段
## （用户 2026-10-29："预览为什么不试试最密集的12秒片段呢" → "那就音乐最复杂的12秒"）。
## 故意不解析谱面：社区谱在没下谱面前也要能算，而且"复杂"本来就是音乐侧的量。
##
## 四种容器各有各的代理量，都按 0.5 秒一格铺成一条曲线，再用 N 秒滑窗取最大：
##   wav / flac → 真 PCM 的平均绝对值（能量）。flac 走 ChartPlayer.decode_flac（自带 dr_flac）。
##                大文件按步长抽样（155s 的 24bit wav 也只二十万次内层循环，十几毫秒）。
##   ogg        → 每个 Ogg 页的字节数摊到时间上。Vorbis 是 VBR，复杂段分到的码率就高，
##                所以"字节密度"就是编码器等感知的复杂度；页头 granulepos 给时间，
##                采样率不解析 id 头，用 末 granule ÷ 已知时长 反标定（Godot 已告诉我们时长）。
##   mp3        → 每帧字节数。VBR（LAME 那类）实测单格峰/均 1.9~2.0，信号很强；
##                **CBR 时曲线是平的，没有信息量** → 返回 t=-1，让调用方退回别的取点法。
##                ⚠ 帧头必须"下一帧也对上"才认账：ID3v2 里的封面字节经常伪装成 0xFFE_，
##                误认一次就把整块标签算成 t≈0 的巨大权重，症状是"每首都选第 0 秒"。

## 一格多少秒：12 秒窗口 = 24 格，够细也够快
const BIN := 0.5
## 判"曲线是平的"（恒定码率）：单格最大值/均值低于这个倍数就没信号
const FLAT_RATIO := 1.08
## PCM 抽样上限：整条曲线最多走这么多次内层循环（44MB 的 24bit wav 实测 20 万次要 0.7 秒，
## GDScript 的调用/分支开销在这儿是主成本，所以压到 4 万次≈每 4ms 取一帧，足够分辨 12 秒窗）
const PCM_LOOPS := 40000

## 返回 {"t": 起播秒(-1=没算出来), "why": 人话, "peak": 选中窗的均值, "mean": 全曲均值, "bmax": 单格峰}
static func best_start(buf: PackedByteArray, kind: String, len: float, win: float) -> Dictionary:
	if buf.size() < 64 or len <= win + 0.5:
		return {"t": -1.0, "why": "曲子太短或没数据", "peak": 0.0, "mean": 0.0, "bmax": 0.0}
	var curve := PackedFloat64Array()
	match kind:
		"ogg":
			curve = _ogg_curve(buf, len)
		"mp3":
			curve = _mp3_curve(buf, len)
		"wav":
			curve = _wav_curve(buf, len)
		"flac":
			var dec: Dictionary = ChartPlayer.decode_flac(buf)
			var chc: int = 2 if bool(dec.get("stereo", false)) else 1
			curve = _pcm_curve(dec.get("pcm", PackedByteArray()), len, chc, 2)
		_:
			return {"t": -1.0, "why": "未知容器 " + kind, "peak": 0.0, "mean": 0.0, "bmax": 0.0}
	if curve.size() < 4:
		return {"t": -1.0, "why": "曲线太短", "peak": 0.0, "mean": 0.0, "bmax": 0.0}
	var total := 0.0
	var mx := 0.0
	for v in curve:
		total += v
		mx = maxf(mx, v)
	var mean := total / float(curve.size())
	if mean <= 0.0 or mx / mean < FLAT_RATIO:
		return {"t": -1.0, "why": "曲线是平的(恒定码率)", "peak": 0.0, "mean": mean, "bmax": mx}
	# N 秒滑窗（按格数）取分数最大的起点；要比当前最好高 2% 才换（并列取靠前：
	# 前奏之后的第一波高潮比曲子末尾更耐听）
	var nb := maxi(int(win / BIN), 1)
	var best_i := -1
	var best_sum := 0.0
	var run := 0.0
	for i in curve.size():
		run += curve[i]
		if i >= nb:
			run -= curve[i - nb]
		if i >= nb - 1 and run > best_sum * 1.02:
			best_sum = run
			best_i = i - nb + 1
	if best_i < 0:
		return {"t": -1.0, "why": "没有一个完整窗口", "peak": 0.0, "mean": mean, "bmax": mx}
	var t := minf(float(best_i) * BIN, maxf(len - win, 0.0))
	return {"t": t, "why": "复杂度滑窗", "peak": best_sum / float(nb), "mean": mean, "bmax": mx}

## ── Ogg 页表 → 字节/秒 ─────────────────────────────────────────────────────
static func _ogg_curve(buf: PackedByteArray, len: float) -> PackedFloat64Array:
	var n := maxi(int(ceil(len / BIN)), 1)
	var w := PackedFloat64Array()
	w.resize(n)
	var pos := 0
	var granules: PackedFloat64Array = PackedFloat64Array()
	var sizes: PackedFloat64Array = PackedFloat64Array()
	var size := buf.size()
	var guard := 0
	var run_g := 0.0  # 续页的 granulepos 是 -1，沿用上一个有效值（那几页的字节本来就属于那一刻）
	while pos + 27 <= size and guard < 200000:
		guard += 1
		if buf[pos] != 0x4F or buf[pos + 1] != 0x67 or buf[pos + 2] != 0x67 or buf[pos + 3] != 0x53:
			pos += 1  # 丢同步就一格一格找（代价极小，比整条曲线作废划算）
			continue
		var seg := int(buf[pos + 26])
		var body := 0
		for s in seg:
			body += int(buf[pos + 27 + s])
		var total := 27 + seg + body
		if total < 27 or pos + total > size:
			break
		var g := _le(buf, pos + 6, 8)
		if g > run_g:
			run_g = g
		# 只算 granule>0 的页：头几页（identification / vorbis comment / setup）granulepos 是 0 或 -1，
		# 而曲绘内嵌进 vorbis comment 时那几页能有几 MB —— 不排掉的话第 0 格凭空高二十倍，
		# 症状就是"每首都选第 0 秒"（实测 Pixel Journey 单格峰/均 22.2）
		if g > 0.0:
			granules.append(float(g))
			sizes.append(float(total))
		pos += total
	if granules.is_empty() or run_g <= 0.0:
		return w
	# 不解析 vorbis id 头：末 granule 就是全曲采样数，除以已知时长即得采样率
	var rate := run_g / maxf(len, 0.001)
	for i in granules.size():
		var b := clampi(int(granules[i] / rate / BIN), 0, n - 1)
		w[b] += sizes[i]
	return w

## ── MPEG 帧头 → 字节/秒 ────────────────────────────────────────────────────
## ⚠ 这是 **Layer III** 的码率表，不是 Layer I/II 的：MPEG1-L3 索引 14 = 320kbps（不是 448）。
## 拿错表会让帧长算成 1463B 而真实是 1044B ⇒ 每一帧都"下一帧没对齐"，整条曲线作废
## （实测 Avantgarde：错表 覆盖率 0%、失配 6093 次；对表 覆盖率 100%、时长 157.9s 与解码一致）。
const BR_V1 := [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
const BR_V2 := [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
const SR := [[11025, 12000, 8000], [0, 0, 0], [22050, 24000, 16000], [44100, 48000, 32000]]

## 读一帧头 → [帧长, 每帧样本数, 采样率]；不是帧头返回空数组（留给边界/测试用，
## 热循环里是内联解析的——GDScript 函数调用开销在 3 万帧上能差出 100ms）
static func _mp3_hdr(buf: PackedByteArray, pos: int) -> Array:
	if pos + 4 > buf.size() or buf[pos] != 0xFF or (buf[pos + 1] & 0xE0) != 0xE0:
		return []
	var ver := (int(buf[pos + 1]) >> 3) & 3
	var layer := (int(buf[pos + 1]) >> 1) & 3
	var b2 := int(buf[pos + 2])
	return _hdr_of(ver, layer, b2, pos, buf.size())

static func _hdr_of(ver: int, layer: int, b2: int, pos: int, size: int) -> Array:
	var bri := (b2 >> 4) & 15
	var sri := (b2 >> 2) & 3
	var pad := (b2 >> 1) & 1
	if ver == 1 or layer != 1 or sri == 3 or bri == 0 or bri == 15:
		return []
	var kbps: int = (BR_V1 if ver == 3 else BR_V2)[bri]
	var hz: int = SR[ver][sri]
	var spf: int = 1152 if ver == 3 else 576
	if kbps <= 0 or hz <= 0:
		return []
	var flen := int(float(spf) / 8.0 * float(kbps * 1000) / float(hz)) + pad
	if flen < 24 or pos + flen > size:
		return []
	return [flen, spf, hz]

static func _mp3_curve(buf: PackedByteArray, len: float) -> PackedFloat64Array:
	var n := maxi(int(ceil(len / BIN)), 1)
	var w := PackedFloat64Array()
	w.resize(n)
	var size := buf.size()
	var pos := 0
	# 跳过 ID3v2 标签（长度是 synchsafe：每字节只用 7 位）
	if size > 10 and buf[0] == 0x49 and buf[1] == 0x44 and buf[2] == 0x33:
		var tag := ((int(buf[6]) & 0x7F) << 21) | ((int(buf[7]) & 0x7F) << 14) \
				| ((int(buf[8]) & 0x7F) << 7) | (int(buf[9]) & 0x7F)
		pos = mini(10 + tag, size)
	var t := 0.0
	var guard := 0
	# 光看"下一帧也对齐"不够狠：JPEG 里的 0xFFE0~0xFFEF 本来就是合法 marker，
	# 封面块能被连成一串假帧，于是第 0 格凭空高几百倍（实测月华舞 单格峰/均=488、选 0.0s）。
	# 所以要**连续 3 帧参数自洽**（同版本、同采样率）才开始计入，末尾再验一遍字节覆盖率。
	var run_ok := 0
	var last_key := -1
	var walked := 0
	while pos + 4 <= size and guard < 3000000:
		guard += 1
		if buf[pos] != 0xFF or (buf[pos + 1] & 0xE0) != 0xE0:
			run_ok = 0
			pos += 1
			continue
		var b1 := int(buf[pos + 1])
		var b2 := int(buf[pos + 2])
		var h := _hdr_of((b1 >> 3) & 3, (b1 >> 1) & 3, b2, pos, size)
		if h.is_empty():
			run_ok = 0
			pos += 1
			continue
		var np := pos + int(h[0])
		if np + 2 > size or buf[np] != 0xFF or (buf[np + 1] & 0xE0) != 0xE0:
			run_ok = 0
			pos += 1
			continue
		var key := (((b1 >> 3) & 3) << 8) | ((b2 >> 2) & 3)
		if key != last_key:
			run_ok = 0
			last_key = key
		run_ok += 1
		if run_ok >= 3:
			walked += int(h[0])  # 只数"认账的"字节：把标签里的伪装帧也算进来会让覆盖率失去意义
			w[clampi(int(t / BIN), 0, n - 1)] += float(h[0])
		t += float(int(h[1])) / float(int(h[2]))
		pos = np
	# 覆盖率太低 = 根本没走进音频区（标签/伪装帧/异常文件），这条曲线不能用
	if float(walked) < float(size) * 0.4:
		w.fill(0.0)
	return w

## ── WAV（RIFF）→ 能量曲线：8/16/24bit、float32 都能读 ──────────────────────
static func _wav_curve(buf: PackedByteArray, len: float) -> PackedFloat64Array:
	var n := maxi(int(ceil(len / BIN)), 1)
	var w := PackedFloat64Array()
	w.resize(n)
	if buf.size() < 44 or _le(buf, 0, 4) != 0x46464952:  # "RIFF"
		return w
	var pos := 12
	var ch := 0
	var rate := 0
	var bits := 0
	var tag := 1
	var sub := 0
	var data_at := -1
	var data_len := 0
	while pos + 8 <= buf.size():
		var id := _le(buf, pos, 4)
		var cs := int(_le(buf, pos + 4, 4))
		if id == 0x20746D66:  # "fmt "
			tag = int(_le(buf, pos + 8, 2))
			ch = int(_le(buf, pos + 10, 2))
			rate = int(_le(buf, pos + 12, 4))
			bits = int(_le(buf, pos + 22, 2))
			if cs > 16:
				sub = int(_le(buf, pos + 26, 2))  # EXTENSIBLE 的真格式在这儿
		elif id == 0x61746164:  # "data"
			data_at = pos + 8
			data_len = mini(cs, buf.size() - data_at)
			break
		pos += 8 + cs + (cs & 1)
	if data_at < 0 or ch < 1 or ch > 2 or rate <= 0:
		return w
	var real := sub if (tag == 0xFFFE and sub != 0) else tag
	var bpf := maxi(bits / 8, 1) * ch
	var frames := data_len / bpf
	var step := maxi(int(float(frames) / float(PCM_LOOPS)), 1)
	var per := maxi(int(float(frames) / float(n) / float(step)), 1)
	var i := 0
	var bin := 0
	var acc := 0.0
	var cnt := 0
	while i < frames and bin < n:
		var o := data_at + i * bpf
		var v := 0.0
		if real == 3 and bits == 32:
			v = absf(buf.decode_float(o)) * 32767.0
		elif bits == 8:
			v = float(int(buf[o]) - 128) * 256.0
		elif bits == 16:
			# 内联符号扩展：热循环里调 _sle 的话，4 万次调用就要多花几十毫秒
			v = float((int(buf[o]) | (int(buf[o + 1]) << 8)) << 48 >> 48)
		elif bits == 24:
			v = float((int(buf[o + 1]) | (int(buf[o + 2]) << 8)) << 48 >> 48)  # 高 16 位就够算能量
		elif bits == 32:
			v = float((_le(buf, o + 1, 3) << 40) >> 40) / 256.0
		acc += absf(v)
		cnt += 1
		if cnt >= per:
			w[bin] = acc / float(cnt)
			bin += 1
			acc = 0.0
			cnt = 0
		i += step
	return w

## ── 裸 int16 交织 PCM（dr_flac 解出来就是这个）→ 能量曲线 ──────────────────
static func _pcm_curve(pcm: PackedByteArray, len: float, ch: int, bps: int) -> PackedFloat64Array:
	var w := PackedFloat64Array()
	if pcm.size() < 4 or len <= 0.0 or ch < 1:
		return w
	var n := maxi(int(ceil(len / BIN)), 1)
	w.resize(n)
	var bpf := ch * bps
	var frames := pcm.size() / bpf
	var step := maxi(int(float(frames) / float(PCM_LOOPS)), 1)
	var per := maxi(int(float(frames) / float(n) / float(step)), 1)
	var i := 0
	var bin := 0
	var acc := 0.0
	var cnt := 0
	while i < frames and bin < n:
		var o := i * bpf
		for c in ch:
			var so := o + c * bps
			acc += absf(float((int(pcm[so]) | (int(pcm[so + 1]) << 8)) << 48 >> 48))
		cnt += 1
		if cnt >= per:
			w[bin] = acc / float(cnt)
			bin += 1
			acc = 0.0
			cnt = 0
		i += step
	return w

## 小端整数（≤8 字节），移位读，不依赖 decode_*。
## GDScript 的 int 是 64 位有符号，所以 0xFF…FF 读出来就是 -1，符号天然正确。
static func _le(b: PackedByteArray, p: int, n: int) -> int:
	var v := 0
	for i in n:
		if p + i >= b.size():
			break
		v |= int(b[p + i]) << (8 * i)
	return v
