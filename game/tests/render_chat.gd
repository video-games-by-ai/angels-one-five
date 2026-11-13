extends SceneTree
## Renders the online chat box over real game screenshots to PNG files, for
## checking its look. Drawn in an off-screen viewport that takes no input.
## Run: godot --path game --disable-vsync --script res://tests/render_chat.gd -- --out=DIR

var out_dir: String = "user://"
var stage: SubViewport
var backdrop: TextureRect
var chat: ChatBox
var host: NetSession
var frame: int = 0
var shots: Array[Dictionary] = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.trim_prefix("--out=")
	stage = SubViewport.new()
	stage.size = Vector2i(1600, 900)   # the screenshots' size: the chat draws at 900/1080 scale
	stage.gui_disable_input = true
	stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(stage)
	backdrop = TextureRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.stretch_mode = TextureRect.STRETCH_SCALE
	stage.add_child(backdrop)
	host = NetSession.new()   # a real session (peer 1 is "you"); lines are placed in its log
	host.host(24692, "Falco", Airframes.Id.MUSTANG, "alpine")
	chat = ChatBox.new()
	chat.session = host
	chat.can_type = true
	stage.add_child(chat)
	shots = [
		{"file": "chat-lines.png", "backdrop": "online-match.png", "open": false, "lines": [
			[2, "Mara", "good shot, that was my rudder", 8.6], [1, "Falco", "sorry :)", 3.0], [2, "Mara", "rematch after this one?", 1.0]]},
		{"file": "chat-typing.png", "backdrop": "online-match.png", "open": true, "typed": "sure, same valley", "lines": [
			[2, "Mara", "good shot, that was my rudder", 30.0], [1, "Falco", "sorry :)", 25.0], [2, "Mara", "rematch after this one?", 12.0]]},
		{"file": "chat-five.png", "backdrop": "plav-peaks.png", "open": false, "lines": [
			[1, "Falco", "break left, he is on your tail", 8.7], [3, "Ivo", "I see him", 6.0], [2, "Mara", "too late :)", 4.0],
			[3, "Ivo", "smoking badly and heading for the lake, cover me while I try to land on the ice", 2.0]]},
	]


func _shot_setup(shot: Dictionary) -> void:
	var path: String = ProjectSettings.globalize_path("res://").path_join("../docs/screenshots").path_join(String(shot.backdrop))
	backdrop.texture = ImageTexture.create_from_image(Image.load_from_file(path))
	host.chat_log.clear()
	var now: int = Time.get_ticks_msec()
	for line: Array in shot.lines:
		host.chat_log.append({"peer": line[0], "name": line[1], "text": line[2], "at": now - int(float(line[3]) * 1000.0)})
	chat.close_input()
	if bool(shot.open):
		chat.open_input()
		chat.edit.text = String(shot.typed)
		chat.edit.caret_column = chat.edit.text.length()


func _process(_delta: float) -> bool:
	frame += 1
	var index: int = (frame - 1) / 20
	if index >= shots.size():
		host.close()
		return true
	if (frame - 1) % 20 == 0:
		_shot_setup(shots[index])
	elif (frame - 1) % 20 == 19:
		var path: String = out_dir.path_join(String(shots[index].file))
		stage.get_texture().get_image().save_png(path)
		print("saved ", path)
	return false
