class_name BakePump
extends Node
## 重活丢工作线程、结果回主线程按帧应用的小调度器。
##
## 为什么不是"每帧同步做一件"：实测一张 8MB RPE 谱的 JSON.parse 要 100–295ms，
## 一帧一件反而把整页打成 3–10fps（比原来一次性冻结还难看）；而全压进点击那一帧
## 就是用户看到的"卡一下然后瞬间到位"。唯一两头都占的做法：解析/解码在后台线程跑，
## 主线程每帧只收割结果（回填字段 + 重绘，亚毫秒级）。
##
## 两条队列：
## - flush(jobs)：主线程小件（封面烘焙这类 ≤2ms 的活），一帧一件；
## - push_threaded(job, apply)：job 在工作线程跑（只碰纯数据：FileAccess/JSON/Image），
##   返回值交回主线程由 apply 消费。job/apply 一律用 bind 具名方法——
##   不用闭包（本项目踩过：闭包按引用捕获局部，多次调用全读到最后一批值）。

const MAX_CONCURRENT := 1   # 后台同时只跑一件重活：本机实测并发 3 时主线程被抢核，
							# 整个窗口 avg 从 8.1ms 抬到 10.1ms（120fps→99fps），不值
const APPLY_PER_FRAME := 1  # 每帧回主线程应用几件（应用含一次卡片重绘+可能的 1.2ms 烘焙）
const MAX_QUEUED := 64      # 主线程小件队列上限：连点翻页时丢最旧的

## 队列排空时的一次性回调（用于"攒着的脏数据最后落一次盘"这类收尾）
var on_idle := Callable()

class Task:
	extends RefCounted
	var job := Callable()
	var apply := Callable()
	var mutex := Mutex.new()
	var result: Variant = null
	var has_result := false
	func run() -> void:
		var r: Variant = job.call()
		mutex.lock()
		result = r
		has_result = true
		mutex.unlock()
	func take() -> Variant:
		mutex.lock()
		var r: Variant = result
		mutex.unlock()
		return r

var _main_jobs: Array[Callable] = []
var _threaded: Array = []    # [[job, apply], ...] 待提交
var _live: Dictionary = {}   # task_id -> Task
var _inbox: Array = []       # [[apply, result], ...] 待主线程应用

## 追加主线程小件（不清空别人的活）
func flush(jobs: Array) -> void:
	for j in jobs:
		_main_jobs.append(j as Callable)
	while _main_jobs.size() > MAX_QUEUED:
		_main_jobs.pop_front()
	set_process(true)

## 主线程小件插到队首：详情大卡/放大层这种"下一帧就要露出来"的，不能排在 30 张卡后面
func push_front(job: Callable) -> void:
	_main_jobs.push_front(job)
	set_process(true)

## 重活：job 在工作线程执行，其返回值在主线程交给 apply(result)
func push_threaded(job: Callable, apply: Callable) -> void:
	_threaded.append([job, apply])
	set_process(true)

func _process(_dt: float) -> void:
	_harvest()
	_spawn()
	_apply_inbox()
	if not _main_jobs.is_empty():
		var job: Callable = _main_jobs.pop_front()
		if job.is_valid():
			job.call()
	if _main_jobs.is_empty() and _threaded.is_empty() and _live.is_empty() and _inbox.is_empty():
		set_process(false)
		if on_idle.is_valid():
			var cb := on_idle
			on_idle = Callable()
			cb.call()

func _spawn() -> void:
	while not _threaded.is_empty() and _live.size() < MAX_CONCURRENT:
		var pair: Array = _threaded.pop_front()
		var t := Task.new()
		t.job = pair[0]
		t.apply = pair[1]
		var tid := WorkerThreadPool.add_task(t.run, false, "bake_pump")
		_live[tid] = t

func _harvest() -> void:
	var ids := _live.keys()
	for v in ids:
		var tid := int(v)
		if not WorkerThreadPool.is_task_completed(tid):
			continue
		WorkerThreadPool.wait_for_task_completion(tid)
		var t: Task = _live[tid]
		_live.erase(tid)
		if t.apply.is_valid():
			_inbox.append([t.apply, t.take()])

func _apply_inbox() -> void:
	var n := mini(APPLY_PER_FRAME, _inbox.size())
	for i in n:
		var item: Array = _inbox.pop_front()
		var cb: Callable = item[0]
		if cb.is_valid():
			cb.call(item[1])
