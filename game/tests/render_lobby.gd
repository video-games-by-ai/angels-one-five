extends SceneTree
## Renders the online lobby screens to PNG files, for checking their layout. The
## screens are drawn in an off-screen viewport that takes no input.
## Run: godot --path game --disable-vsync --script res://tests/render_lobby.gd -- --out=DIR

var out_dir: String = "user://"
var frames: int = 0
var stage: SubViewport
var shots: Array = []
var host: NetSession
var guest: NetSession


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.trim_prefix("--out=")
	stage = SubViewport.new()
	stage.size = Vector2i(1920, 1080)
	stage.gui_disable_input = true
	stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(stage)
	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = Color(0.36, 0.42, 0.50)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.add_child(backdrop)
	var settings: GameSettings = GameSettings.new()
	settings.player_name = "Alija"
	# A real hosting session on loopback with one joiner, so the lobby shows live data.
	host = NetSession.new()
	host.host(24690, "Alija", Airframes.Id.MUSTANG, "plav")
	host.set_address("203.0.113.5")
	guest = NetSession.new()
	guest.join(Invite.decode(_loopback_invite()), "Ana", Airframes.Id.SPITFIRE)
	var hosting: Lobby = Lobby.new()
	stage.add_child(hosting)
	hosting.build(settings)
	var joining: Lobby = Lobby.new()
	stage.add_child(joining)
	joining.build(settings)
	shots = [[joining, func() -> void: joining.open(null, false), "lobby-join.png"],
		[hosting, func() -> void: hosting.open(host, true), "lobby-host.png"],
		[joining, func() -> void: joining.open(guest, false), "lobby-joined.png"]]


func _loopback_invite() -> String:
	var address: String = host.address
	host.address = "127.0.0.1"
	var text: String = host.invite_text()
	host.address = address
	return text


func _process(_delta: float) -> bool:
	for s in [host, guest]:
		s._physics_process(0.016)
	if host.players.size() < 2 and frames < 2000:
		OS.delay_msec(5)
		frames += 1
		return false   # let the joiner arrive first, so the lobby shows two players
	frames = maxi(frames, 2000) + 1
	var index: int = (frames - 2001) / 40
	if (frames - 2001) % 40 == 0 and index < shots.size():
		for shot: Array in shots:
			(shot[0] as Lobby).visible = false
		(shots[index][1] as Callable).call()
	if (frames - 2001) % 40 == 39 and index < shots.size():
		var path: String = out_dir.path_join(String(shots[index][2]))
		stage.get_texture().get_image().save_png(path)
		print("saved ", path)
	if index >= shots.size():
		guest.close()
		host.close()
		return true
	return false
