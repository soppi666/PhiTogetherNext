class_name GameFlags
extends RefCounted
## 会话级全局开关（不落盘、不写配置文件）：进程重启即复位。
##
## block_area = 官方谱 blockArea（噪域）总开关。彩蛋门控：
## 主菜单四个未实现按钮（多人游戏/回放/活动/设置）全部被 GlitchFx「按灭」
## （1 秒内连点 5 次上锁）后由 game.gd 置真。见 [[主菜单彩蛋]] 接线处。
## 为什么是彩蛋：项目主支持 RPE，RPE 未实现的机制默认不启用；
## 官方谱解析只是顺手功能，噪域按用户裁定藏在门控后面。

static var block_area := false
