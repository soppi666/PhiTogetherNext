extends SceneTree
func _initialize() -> void:
	for m in ClassDB.class_get_method_list("RenderingDevice"):
		var n := String(m.name)
		if n.contains("adapter") or n.contains("extension") or n.contains("device_"):
			print("VVFN ", n)
	var rd := RenderingServer.get_rendering_device()
	print("VV rd=", rd)
	if rd == null:
		quit(); return
	var exts: PackedStringArray = rd.get_device_extensions()
	var hits: Array = []
	for e in exts:
		var s := String(e)
		if s.contains("video") or s.contains("external_memory") or s.contains("maint"):
			hits.append(s)
	print("VV n_ext=", exts.size(), " video-ish=", hits)
	quit()
