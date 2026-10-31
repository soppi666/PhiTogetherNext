class_name SkinDemoChart
extends RefCounted
## 皮肤演示带用的那张谱：**一条判定线 + 用户口径的 8 个事件**，60 BPM。
## 演示带不再自己画音符，而是把这张谱喂给游玩那个 `ChartPlayer`
## （用户第四轮："演示区域使用真实的播放，宽度也是真实的宽度"）——
## 只要还有一份"演示专用画法"，就会一直出现"和游玩不一样"。
##
## 时刻表（秒；60BPM ⇒ 1 拍 = 1 秒）：
##   2.0 tap → 2.5 drag → 3.0 flick → 3.5 hold(0.5s)
##   → 4.5 双 tap → 5.0 双 drag → 5.5 双 flick → 6.0 双 hold(0.5s) → 7.0 一轮
##   相邻两个音符之间空 0.5s；长条先占掉自己那 0.5s 再空 0.5s（尾与下一个之间也是 0.5s）。
##
## ⚠ "多押"那一遍**必须**是同一时刻两条：原生 `mm = n.multi && _multiHint`，
## 而 `n.multi` 的定义就是"同一时刻的音符数 ≥ 2"（chart_player.cpp:1681）。
## 一条音符永远不会取 `*_hl` 那张——所以想预览多押皮肤，就得真给两条。
## 带子现在是真实画布上开的窗口（宽=真实音符尺寸），两条并排也不再挤出界。

## type：1=Tap 2=Hold 3=Flick 4=Drag（RPE/prpr 那套编号，与 SkinPack.HIT_DEFAULTS 对得上）
const SEQ := [
	{"t": 2.0, "type": 1, "n": 1, "snd": "HitSong0"},
	{"t": 2.5, "type": 4, "n": 1, "snd": "HitSong1"},
	{"t": 3.0, "type": 3, "n": 1, "snd": "HitSong2"},
	{"t": 3.5, "type": 2, "n": 1, "snd": "HitSong0", "hold": 0.5},
	{"t": 4.5, "type": 1, "n": 2, "snd": "HitSong0"},
	{"t": 5.0, "type": 4, "n": 2, "snd": "HitSong1"},
	{"t": 5.5, "type": 3, "n": 2, "snd": "HitSong2"},
	{"t": 6.0, "type": 2, "n": 2, "snd": "HitSong0", "hold": 0.5},
]
const LOOP := 7.0           # 一轮：最后一个事件的尾(6.5) + 0.5s 空隙
const BPM := 60.0
## 线的 y：RPE 口径 `wy = 画布中心 − oy`（chart_player.cpp:1979），−180 ⇒ 画布 70% 高
## = 用户口径"下 30% 的位置为判定线"
const LINE_OY := -180.0
## 多押那两条**叠在同一个位置**（PAIR_X=0）。原生判 multi 只看"同一时刻的音符数 ≥ 2"
## （chart_player.cpp:1681），跟 x 无关 ⇒ 叠着放照样用 *_hl 那张，画面就是"一条音符套一层
## 高亮边"，正是用户要的"后四个双押叠在一起"；并排摆反而看着像两条普通音符。
const PAIR_X := 0.0
## 下落速度：音符屏幕距离 = (拍数差) × note.speed × (画布高×2/15)
## ⇒ speed=7.5 时"一拍正好飞过一个画布高"，就是 60BPM 那一档手感
const NOTE_SPEED := 7.5
const VISIBLE_TIME := 1.5   # 提前多少拍可见（>1 拍 ⇒ 进场那一小段在屏外，不突兀）


## 事件表 → 音效触发点（演示带自己放打击音：player 不出声，声音是舞台那层的活）
static func sounds() -> Array:
	var out: Array = []
	for e in SEQ:
		var d: Dictionary = e
		out.append([float(d["t"]), String(d["snd"]), int(d["n"])])
	return out


static func _step(t: float, v: Variant) -> Dictionary:
	return {"startTime": t, "endTime": t, "start": v, "end": v, "easingType": 1}


## ⚠ 字段名是 **type**，不是 typeID：RPE 解析读的是 `nd.get("type", 1)`
## （chart_player.cpp:518），写成 typeID 会被静默忽略 ⇒ 全变成默认的 Tap
## （用户："怎么都是tap的图像"）。编号按 RPE 口径：1=Tap 2=Hold 3=Flick 4=Drag。
## 长条长度用 **endTime** 表达（holdTime 是官谱 pgr 那条路的字段，RPE 这条路不读）。
static func _note(t: float, x: float, type: int, hold: float) -> Dictionary:
	return {
		"type": type, "startTime": t, "endTime": t + hold, "positionX": x,
		"speed": NOTE_SPEED, "x": 0.0, "y": 0.0,
		"alpha": 255, "size": 1.0, "visibleTime": VISIBLE_TIME, "appearanceTime": 0.5,
		"rotationType": 0.0, "zIndex": 1.0, "isCover": 0, "above": 1,
		"yOffset": 0.0, "zHeight": 0.0, "text": "", "numEmail": 0.0,
	}


static func build() -> Dictionary:
	var notes: Array = []
	for e in SEQ:
		var d: Dictionary = e
		var hold: float = float(d.get("hold", 0.0))
		var cnt: int = int(d["n"])
		if cnt <= 1:
			notes.append(_note(float(d["t"]), 0.0, int(d["type"]), hold))
		else:
			# 多押=同一时刻两条、叠在同一位置（原生判 multi 只看同刻音符数，与 x 无关）
			for k in cnt:
				notes.append(_note(float(d["t"]),
						PAIR_X * (float(k) - float(cnt - 1) * 0.5), int(d["type"]), hold))
	return {
		"RPEVersion": 150,
		"BPMList": [{"startBar": 0, "startBeat": 0, "startTime": 0.0, "bpm": BPM}],
		"META": {"offset": 0, "RPEVersion": 150, "name": "皮肤演示", "level": "",
				"background": "", "rescale": false, "source": "skin-demo",
				"charter": "", "composer": "", "song": ""},
		"judgeLineList": [{
			"Name": "demo", "Texture": "line.png", "father": -1, "zOrder": 0,
			"rotateWithFather": 0, "isCover": 0, "bpmfactor": 1.0, "anchor": [0.5, 0.5],
			"eventLayers": [{
				"alphaEvents": [_step(0.0, 255.0)],
				"speedEvents": [_step(0.0, 1.0)],
				"moveXEvents": [_step(0.0, 0.0)],
				# 线停在画布 70% 高：RPE 的 moveY 正值朝上，所以要 -180
				"moveYEvents": [_step(0.0, LINE_OY)],
				"rotateEvents": [],
			}],
			"notes": notes,
			"extended": {},
		}],
		"name": "skin-demo", "isMedieval": false,
	}
