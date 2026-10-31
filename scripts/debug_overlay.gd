class_name DebugOverlay
extends Control
## F12 调试层：在游玩画面上给**每条判定线**和**每个屏内音符**标出序号。
## 规则（用户指定）：透明的线也照样标（要查的就是"这条线去哪了"，字色按线 alpha 走）；
## 假音符（fake=1，不参与判定、过点即隐）的序号用蓝色，与真音符的白字一眼分开。
##
## 数据来源是原生的 debug_overlay_lines()/debug_overlay_notes() —— 这两个只读上一帧
## set_now 已经算好的线/音符位姿，**不会重跑整帧更新**（debug_note_worlds(t) 会调
## set_now，判定/触点/特效都在那条路径里，拿来每帧画编号等于自己给自己造双帧）。
##
## 画在 _draw 里而不是建 Label 池：一屏几百条 draw_string 远比几百个节点便宜，
## 而且不干扰任何 HUD/特效的层级与命中。
## 坐标是舞台内部系（= 逻辑×_k 的设备像素），与原生 set_scale 同系，所以直接画。

var _cp: ChartPlayer
var _f: Font

## QA 用：本帧线总数 / 真正贴上编号的线数 / 屏内音符数
var stats := [0, 0, 0]

const NOTE_COL := Color(1, 1, 1, 0.95)
const FAKE_COL := Color(0.25, 0.55, 1.0, 0.98)  # 假音符（fake=1）序号用蓝色，一眼分得开
const LINE_COL := Color(0.35, 0.9, 1.0, 0.95)
const OUT_COL := Color(0, 0, 0, 0.85)

func setup(cp: ChartPlayer) -> void:
	_cp = cp

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_f = UiTokens.install_font()

func _process(_delta: float) -> void:
	if visible and _cp != null:
		queue_redraw()

func _draw() -> void:
	if _cp == null or not visible:
		return
	# 线号按画布取百分比；音符号按**音符自身宽度**取（用户：序号太小，做成音符宽度的 20%）
	var lfs := maxi(int(size.x * 26.0 / 1350.0), 13)
	var ls := _cp.debug_overlay_lines()
	var ns := _cp.debug_overlay_notes()
	stats = [ls.size(), 0, ns.size()]
	for L in ls:
		var idx := int(L[0])
		var x := float(L[1])
		var y := float(L[2])
		var rot := float(L[3])
		# 透明的线**也要标**（用户明确要求）：调试时问的正是"这条线去哪了"，
		# 藏起编号就查不到；alpha 已经打在每个点的字色里，全透明的会淡到不挡视线
		var la := float(L[5])
		var t := str(idx)
		var tw := _f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs).x
		# 序号钉在**判定线的锚点**上，并且**跟着线一起转**（用户指定）。
		# 上一版放在"线段落在画布内的最左点"，为的是别出屏，但那样读不出这条线的朝向，
		# 而锚点才是这条线的身份点——锚点在屏外，编号就跟着出去（那儿本来也没有线可看）。
		if x >= 0.0 and x <= size.x and y >= 0.0 and y <= size.y:
			stats[1] += 1
		draw_set_transform(Vector2(x, y), rot, Vector2.ONE)
		# draw_string 的 pos 是左上角 → 横竖都往回挪半个字，让数字中心压在锚点上
		_ink(Vector2(-tw * 0.5, -lfs * 0.36), t, lfs,
				Color(LINE_COL.r, LINE_COL.g, LINE_COL.b, LINE_COL.a * maxf(la, 0.35)))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for N in ns:
		var li := int(N[0])
		var ni := int(N[1])
		var t := "%d#%d" % [li, ni]
		# N[7]=原生算好的该音符绘制宽度（贴图宽×noteScaleRatio×sizeCtrl×size），换皮肤自动跟
		var nfs := maxi(int(float(N[7]) * 0.2), 6)
		var tw := _f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, nfs).x
		# 假音符（fake=1）标蓝色：它们不参与判定、过点即隐，混在白字里根本看不出来
		var col := FAKE_COL if int(N[6]) != 0 else NOTE_COL
		# 用户要"音符上面显示序号"：整串水平居中，底边落在音符中心略上方
		_ink(Vector2(float(N[2]) - tw * 0.5, float(N[3]) - nfs * 0.95), t, nfs, col)

## 4.7 的 draw_string 已经没有 outline/shadow 参数了（只剩 modulate 这一层色），
## 而底图是整屏曲绘，不带描边根本读不出来 → 自己描：四个方向先画一遍黑，再画正色。
## 只在 F12 打开时才跑，一屏几百条 = 上千次 draw_string，调试开销可以接受（正式路径零成本）。
func _ink(pos: Vector2, t: String, fs: int, col: Color) -> void:
	var o := Vector2(maxi(int(fs * 0.09), 1), maxi(int(fs * 0.09), 1))
	for d in [Vector2(-o.x, 0), Vector2(o.x, 0), Vector2(0, -o.y), Vector2(0, o.y)]:
		draw_string(_f, pos + d, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, OUT_COL)
	draw_string(_f, pos, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
