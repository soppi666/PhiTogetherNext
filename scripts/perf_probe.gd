class_name PerfProbe
extends RefCounted
## 真机帧率/线程落核的只读探针：全部走 /proc，不碰渲染路径，采样一次约几十 µs。
##
## 为什么要它：手机上的两个猜测（"vsync 把上屏压在 60"、"渲染全挤在一个核上"）用肉眼
## 和帧率计数器分不开——Engine.get_frames_per_second() 数的是**主循环**跑了多少圈，
## 不等于**上屏**了多少帧；而"挤在哪个核"必须看每个线程实际落在哪个 CPU 上。
## 所以这里量三样：
##   ① 上屏节拍 = RenderingServer.frame_post_draw 每秒次数（由调用方数）；
##   ② 每个线程的 CPU 时间增量（utime+stime，clk_tck=100 → 直接换算成占一核的百分比）；
##   ③ 每个线程最后一次被调度的核（stat 第 39 字段 processor）。
##
## /proc/<pid>/task/<tid>/stat 的 comm 带括号且可能含空格，必须按"第一个 '(' 到最后一个
## ')'"取名字，剩下的字段再按空格切；切出来第 0 个是 state=第 3 字段，所以
## utime=第 14 字段=rest[11]、stime=rest[12]、processor=第 39 字段=rest[36]。

const CLK_TCK := 100.0  # Linux/Android 固定 100Hz jiffies


## prev = 上一次采样 {tid: ticks}；返回 {"rows": [{name, core, pct}...按 pct 倒序], "ticks": 新快照}
static func sample(prev: Dictionary) -> Dictionary:
	var rows: Array = []
	var now := {}
	var ta := DirAccess.open("/proc/self/task")
	if ta == null:
		return {"rows": rows, "ticks": now}
	var t0 := Time.get_ticks_msec()
	for d in ta.get_directories():
		var tid := int(d)
		var txt := _read_line("/proc/self/task/%s/stat" % d)
		if txt == "":
			continue
		var a := txt.find("(")
		var b := txt.rfind(")")
		if a < 0 or b <= a:
			continue
		var nm := txt.substr(a + 1, b - a - 1)
		var rest := txt.substr(b + 1).strip_edges(true, false).split(" ")
		if rest.size() < 37:
			continue
		var ticks: int = int(rest[11]) + int(rest[12])
		now[tid] = ticks
		var pct := 0.0
		if prev.has(tid):
			pct = float(ticks - int(prev[tid])) / CLK_TCK * 1000.0
		rows.append({"name": nm, "core": int(rest[36]), "pct": pct})
	rows.sort_custom(_by_pct)
	print("QA-PERF 采样耗时=", Time.get_ticks_msec() - t0, "ms 线程=", rows.size())
	return {"rows": rows, "ticks": now}


static func _by_pct(x: Dictionary, y: Dictionary) -> bool:
	return float(x["pct"]) > float(y["pct"])


static func _read_line(p: String) -> String:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_line()
	f.close()
	return s


## 一行读数：主线程/渲染线程等前几名，"名@核n x.x%"
static func fmt_rows(rows: Array, top: int) -> String:
	var parts: Array = []
	for i in mini(top, rows.size()):
		var r: Dictionary = rows[i]
		parts.append("%s@核%d %.1f%%" % [r["name"], int(r["core"]), float(r["pct"])])
	return " ".join(parts)
