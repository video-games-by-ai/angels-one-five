extends Node3D
## Bootstrap for the practice dogfight: builds the valley, shows the aircraft
## selection, then runs the sortie: the player and the AI opponents, their guns,
## damage and respawns, plus camera, HUD, audio and the pause menu.
##
## Command-line options (after `--`):
##   --quality=0|1|2          Low / Medium / High graphics
##   --aircraft=0|1|2         fly the Spitfire / Mustang / Thunderbolt at once (skips the selection screen)
##   --map=alpine|plav        which map to fly (default: the one flown last)
##   --opponents=N            number of AI opponents (default 2; 0 with --benchmark)
##   --weather=0|1            snow showers off / on (test feature; F4 toggles in flight)
##   --ai-player              an AI flies and fights for the player (demo / tests)
##   --autopilot              fly the valley automatically (demo / benchmark)
##   --clearance=METRES       autopilot height above ground (default 140)
##   --benchmark=SECONDS      autopilot + frame-time measurement, then quit
##   --benchmark-out=PATH     write benchmark results as JSON
##   --screenshot=PATH --screenshot-at=SECONDS   save one frame
##   --screenshot-when-firing  after that time, wait for the player's guns before saving
##   --view=X,Y,Z,YAW,PITCH   fixed camera for map screenshots (metres, degrees; yaw 0 = north, 90 = west)
##   --quit-at=SECONDS
##   --log                    print position / FPS once per second
##   --no-trees --no-clouds --no-hud   diagnostics: skip a subsystem
##   --opponent-hull=A,B,...  diagnostics: opponents start with these hull shares (0..1), by index
##
## Online play (see docs/multiplayer-design.md):
##   --host                   host a match at once (with --aircraft, --port, --address, --name)
##   --join=INVITE            join a match at once
##   --server                 dedicated server: no local pilot; run with --headless and --address
##   --address=HOST           public address or DNS name written into the invite
##   --port=N                 UDP port to host on (default 24555)
##   --name=NAME              pilot name shown to the others
##   --score-limit=N          kills that win (host)
##   --autostart=N            host: start the match once N players are in (server default 2)
##   --invite-out=PATH        host: write the invite to this file whenever it changes
##   --quit-after-matches=N   quit once N matches have ended (tests)

const RESPAWN_DELAY: float = 3.0
const ENEMY_RESPAWN_DELAY: float = 6.0
const AI_DAMAGE_SCALE: float = 0.5    ## opponents' rounds are softened so beginners last
const PLAYER_COLOR: int = 0
const ENEMY_COLOR: int = 2
const OWN_TRAIL_STRENGTH: float = 0.6  ## the player's own flight-path line is fainter

enum Mode { HANGAR, FLYING, LOBBY }

## Map of this run. It survives the scene reload that switching maps performs.
static var session_map: String = ""
## A message for the hangar after a reload, e.g. why an online match ended.
static var pending_notice: String = ""

var settings: GameSettings
var terrain: TerrainData
var atmosphere: Atmosphere
var terrain_renderer: TerrainRenderer
var forest: Forest
var village: Village
var clouds: CloudField
var weather: Weather
var water: MeshInstance3D
var camera: ChaseCamera
var input: PlayerInput
var autopilot: Autopilot
var player: Combatant
var opponents: Array[Combatant] = []
var combatants: Array[Combatant] = []
var bullets: BulletField
var model: FlightModel            ## the player's flight model
var aircraft: Aircraft            ## the player's visual aircraft
var audio: EngineAudio
var hud: Hud
var hangar: Hangar
var pause_menu: PauseMenu
var ui_layer: CanvasLayer
var effects: Effects
var mode: Mode = Mode.HANGAR
var aircraft_id: int = -1
var opponent_count: int = 2
var ai_player: bool = false
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var elapsed: float = 0.0
var screenshot_path: String = ""
var screenshot_at: float = -1.0
var quit_at: float = -1.0
var benchmark_seconds: float = 0.0
var benchmark_out: String = ""
var frame_times: PackedFloat32Array = PackedFloat32Array()
var fixed_view: PackedFloat64Array = PackedFloat64Array()
var opponent_hull: PackedFloat64Array = PackedFloat64Array()
# Online play
var net: NetSession
var referee: MatchReferee         ## host only
var lobby: Lobby
var online: bool = false          ## a networked match is being flown
var world_dirty: bool = false     ## offline combatants were replaced; leaving reloads the scene
var server_mode: bool = false
var cli_host: bool = false
var cli_join: String = ""
var cli_address: String = ""
var cli_name: String = ""
var net_port: int = NetSession.DEFAULT_PORT
var score_limit: int = 5
var autostart: int = 0
var autostart_wait: float = 0.0
var invite_out: String = ""
var invite_written: String = ""
var matches_to_quit: int = 0
var matches_ended: int = 0
var net_tick: int = 0
var latest_states: Dictionary = {}    ## host: combatant id -> newest accepted motion report
var claims: Dictionary = {}           ## hits our rounds made this tick, by target and zone
var kicked: Dictionary = {}
var end_timer: float = -1.0
var result_text: String = ""


func _ready() -> void:
	PlayerInput.register_actions()
	settings = GameSettings.load_or_default()
	settings.apply_audio()   # buses exist before any sound is created
	var use_autopilot: bool = false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quality="):
			settings.quality = clampi(int(arg.trim_prefix("--quality=")), 0, 2) as GameSettings.Quality
		elif arg.begins_with("--aircraft="):
			aircraft_id = clampi(int(arg.trim_prefix("--aircraft=")), 0, 2)
		elif arg.begins_with("--opponents="):
			opponent_count = clampi(int(arg.trim_prefix("--opponents=")), 0, 6)
		elif arg.begins_with("--map=") and session_map == "":
			session_map = arg.trim_prefix("--map=")
		elif arg.begins_with("--weather="):
			settings.snow_showers = int(arg.trim_prefix("--weather=")) != 0
		elif arg == "--ai-player":
			ai_player = true
		elif arg == "--autopilot":
			use_autopilot = true
		elif arg.begins_with("--benchmark="):
			benchmark_seconds = float(arg.trim_prefix("--benchmark="))
			use_autopilot = true
			opponent_count = 0
		elif arg.begins_with("--benchmark-out="):
			benchmark_out = arg.trim_prefix("--benchmark-out=")
		elif arg.begins_with("--screenshot="):
			screenshot_path = arg.trim_prefix("--screenshot=")
		elif arg.begins_with("--screenshot-at="):
			screenshot_at = float(arg.trim_prefix("--screenshot-at="))
		elif arg.begins_with("--view="):
			fixed_view = arg.trim_prefix("--view=").split_floats(",")
		elif arg.begins_with("--opponent-hull="):
			opponent_hull = arg.trim_prefix("--opponent-hull=").split_floats(",")
		elif arg.begins_with("--quit-at="):
			quit_at = float(arg.trim_prefix("--quit-at="))
		elif arg == "--host":
			cli_host = true
		elif arg == "--server":
			server_mode = true
		elif arg.begins_with("--join="):
			cli_join = arg.trim_prefix("--join=")
		elif arg.begins_with("--address="):
			cli_address = Lobby._clean_address(arg.trim_prefix("--address="))
		elif arg.begins_with("--port="):
			net_port = clampi(int(arg.trim_prefix("--port=")), 1024, 65535)
		elif arg.begins_with("--name="):
			cli_name = NetProtocol.clean_text(arg.trim_prefix("--name="), NetProtocol.NAME_MAX)
		elif arg.begins_with("--score-limit="):
			score_limit = clampi(int(arg.trim_prefix("--score-limit=")), 1, 50)
		elif arg.begins_with("--autostart="):
			autostart = clampi(int(arg.trim_prefix("--autostart=")), 2, NetProtocol.MAX_PLAYERS)
		elif arg.begins_with("--invite-out="):
			invite_out = arg.trim_prefix("--invite-out=")
		elif arg.begins_with("--quit-after-matches="):
			matches_to_quit = maxi(int(arg.trim_prefix("--quit-after-matches=")), 1)
	if not args_have_value("--port="):
		net_port = settings.net_port
	if not args_have_value("--score-limit="):
		score_limit = settings.score_limit
	if server_mode and autostart == 0:
		autostart = 2
	if cli_name != "":
		settings.player_name = cli_name

	var t0: int = Time.get_ticks_msec()
	if session_map == "":
		session_map = settings.map
	terrain = TerrainData.load_map(session_map)
	Weather.use_map(terrain)
	var profile: Dictionary = settings.profile()
	atmosphere = Atmosphere.new()
	add_child(atmosphere)
	atmosphere.build(terrain.sun_direction, terrain.altitude_offset)
	terrain_renderer = TerrainRenderer.new()
	add_child(terrain_renderer)
	terrain_renderer.build(terrain, float(profile.lod_scale))
	_build_water()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	forest = Forest.new()
	add_child(forest)
	if not args.has("--no-trees") and not server_mode:
		forest.build(terrain, terrain_renderer.mask_texture, profile)
	village = Village.new()
	add_child(village)
	village.build(terrain)
	clouds = CloudField.new()
	add_child(clouds)
	if not args.has("--no-clouds") and not server_mode:
		clouds.build(terrain, float(profile.clouds))
	weather = Weather.new()
	add_child(weather)
	weather.build(terrain, clouds, settings.snow_showers)
	weather.register(terrain_renderer.material)
	weather.register(forest.needle_material)
	weather.register(clouds.material)
	effects = Effects.new()
	add_child(effects)
	bullets = BulletField.new()
	add_child(bullets)
	print("World built in %d ms" % (Time.get_ticks_msec() - t0))

	rng.seed = 1944
	player = Combatant.new()
	model = player.model
	combatants.append(player)
	if ai_player:
		player.ai = AiPilot.new()
		player.ai.setup(terrain, 7)
	for i in range(opponent_count):
		var enemy: Combatant = Combatant.new()
		enemy.setup(i + 1, 1, (i * 2) % Airframes.COUNT, false)
		enemy.ai = AiPilot.new()
		enemy.ai.setup(terrain, 100 + i)
		opponents.append(enemy)
		combatants.append(enemy)
	camera = ChaseCamera.new()
	camera.settings = settings
	add_child(camera)
	camera.make_current()
	input = PlayerInput.new()
	input.settings = settings
	add_child(input)
	if use_autopilot:
		autopilot = Autopilot.new()
		autopilot.terrain = terrain
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--clearance="):
				autopilot.clearance = float(arg.trim_prefix("--clearance="))
	audio = EngineAudio.new()
	add_child(audio)

	var layer: CanvasLayer = CanvasLayer.new()
	add_child(layer)
	var flare: LensFlare = LensFlare.new()
	flare.camera = camera
	flare.terrain = terrain
	flare.sun_direction = terrain.sun_direction
	flare.weather = weather
	layer.add_child(flare)
	hud = Hud.new()
	hud.camera = camera
	hud.terrain = terrain
	hud.input = input
	if use_autopilot:
		hud.mode_label = "FREE FLIGHT · AUTOPILOT" if opponent_count == 0 else "PRACTICE DOGFIGHT · AUTOPILOT"
	elif opponent_count == 0:
		hud.mode_label = "FREE FLIGHT"
	hud.visible = false
	layer.add_child(hud)
	if args.has("--no-hud"):
		hud.process_mode = Node.PROCESS_MODE_DISABLED
	hangar = Hangar.new()
	layer.add_child(hangar)
	hangar.build(settings.aircraft, terrain.title)
	hangar.chosen.connect(_start_flight)
	hangar.map_requested.connect(_next_map)
	hangar.settings_requested.connect(_open_settings_from_hangar)
	hangar.quit_requested.connect(func() -> void: get_tree().quit())
	hangar.host_requested.connect(func(id: int) -> void: _host_match(id))
	hangar.join_requested.connect(_join_screen)
	lobby = Lobby.new()
	layer.add_child(lobby)
	lobby.build(settings)
	lobby.start_requested.connect(_net_start_match)
	lobby.join_requested.connect(_join)
	lobby.leave_requested.connect(_leave_online)
	ui_layer = layer
	_apply_settings()
	if pending_notice != "":
		hangar.notice(pending_notice)
		pending_notice = ""
	if NetSession.current != null and NetSession.current.role != NetSession.Role.NONE:
		# Back after reloading for the host's map: carry on in the lobby.
		net = NetSession.current
		_connect_session()
		_enter_lobby()
	elif server_mode:
		_host_match(settings.aircraft, true, false)
	elif cli_host:
		_host_match(aircraft_id if aircraft_id >= 0 else settings.aircraft, false, false)
	elif cli_join != "":
		var error: Array = []
		var invite: Invite = Invite.decode(cli_join, error)
		if invite == null:
			print("JOIN: ", error[0] if not error.is_empty() else "bad invite")
			_enter_hangar()
		else:
			if aircraft_id >= 0:
				settings.aircraft = aircraft_id
			_join_screen(-1)
			_join(invite)
	elif aircraft_id >= 0 or use_autopilot or ai_player:
		_start_flight(aircraft_id if aircraft_id >= 0 else settings.aircraft, false)
	else:
		_enter_hangar()


## Show the aircraft selection over a slow view of the valley.
func _enter_hangar() -> void:
	mode = Mode.HANGAR
	get_tree().paused = false
	if pause_menu != null:
		pause_menu.visible = false
	hangar.set_process_unhandled_input(true)
	for c in combatants:
		if c.aircraft != null:
			c.aircraft.visible = false
			c.aircraft.set_voice_enabled(false)
			c.aircraft.clear_trail()
	bullets.clear()
	audio.silence()
	hud.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hangar.open()


## Switch to the next map: remember it and rebuild the world.
func _next_map() -> void:
	var next: int = (TerrainData.map_index(terrain.id) + 1) % TerrainData.MAPS.size()
	session_map = String(TerrainData.MAPS[next].id)
	settings.map = session_map
	settings.save()
	get_tree().reload_current_scene()


## Begin a sortie in the chosen aircraft.
func _start_flight(id: int, remember: bool = true) -> void:
	aircraft_id = clampi(id, 0, Airframes.COUNT - 1)
	if remember and settings.aircraft != aircraft_id:
		settings.aircraft = aircraft_id
		settings.save()
	hangar.close()
	mode = Mode.FLYING
	player.setup(0, 0, aircraft_id, true)
	player.kills = 0
	player.losses = 0
	_build_visual(player)
	aircraft = player.aircraft
	audio.use_aircraft(Airframes.spec(aircraft_id))
	bullets.clear()
	_spawn()
	for enemy in opponents:
		enemy.kills = 0
		enemy.losses = 0
		_spawn_enemy(enemy)
	hud.attach(player, opponents)
	hud.visible = not OS.get_cmdline_user_args().has("--no-hud")
	if autopilot == null and not ai_player:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## (Re)create a combatant's visual aircraft for its current type.
func args_have_value(prefix: String) -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return true
	return false


func _build_visual(c: Combatant) -> void:
	if c.aircraft != null:
		c.aircraft.queue_free()
	c.aircraft = Aircraft.new()
	add_child(c.aircraft)
	c.aircraft.build(Airframes.spec(c.frame_id), PLAYER_COLOR if c.is_player else ENEMY_COLOR, true, not c.is_player)
	if c.is_player:
		c.aircraft.damage_trail.strength = OWN_TRAIL_STRENGTH


func _build_water() -> void:
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(terrain.size, terrain.size)
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = load("res://shaders/water.gdshader")
	material.set_shader_parameter("heightmap", terrain_renderer.height_texture)
	material.set_shader_parameter("world_size", terrain.size)
	material.set_shader_parameter("samples", float(terrain.samples))
	material.set_shader_parameter("water_level", terrain.water_level)
	material.set_shader_parameter("wave_a", TerrainRenderer._noise_texture(21, 0.02, true))
	material.set_shader_parameter("wave_b", TerrainRenderer._noise_texture(22, 0.045, true))
	material.set_shader_parameter("foam_noise", TerrainRenderer._noise_texture(23, 0.05, false))
	for key: String in ["shallow", "deep"]:
		if terrain.look.has("water_" + key):
			var c: Array = terrain.look["water_" + key]
			material.set_shader_parameter(key, Color(c[0], c[1], c[2]))
	water = MeshInstance3D.new()
	water.mesh = plane
	water.material_override = material
	water.position.y = terrain.water_level
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)


func _apply_settings() -> void:
	var profile: Dictionary = settings.profile()
	atmosphere.apply_quality(profile)
	forest.apply_quality(profile)
	if weather.enabled != settings.snow_showers:
		weather.set_enabled(settings.snow_showers)
	var viewport: Viewport = get_viewport()
	viewport.msaa_3d = profile.msaa
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if profile.fxaa else Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if float(profile.render_scale) < 1.0 else Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = float(profile.render_scale)
	settings.apply_audio()
	var mode: DisplayServer.WindowMode = DisplayServer.WINDOW_MODE_FULLSCREEN if settings.fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != mode and benchmark_seconds <= 0.0:
		DisplayServer.window_set_mode(mode)


func _spawn() -> void:
	player.spawn(terrain.spawn_position, terrain.spawn_heading)
	if player.ai != null:
		player.ai.reset()
	input.reset(model.forward())
	camera.snap(model.forward(), model.position)
	hud.crash_time = 0.0


## Bring an opponent in a few kilometres away along the valley, heading for the
## player. Each time it returns as the next aircraft type, so all three are met.
func _spawn_enemy(enemy: Combatant) -> void:
	if enemy.losses > 0 or enemy.aircraft == null:
		if enemy.losses > 0:
			enemy.setup(enemy.id, enemy.team, (enemy.frame_id + 1) % Airframes.COUNT, false)
		_build_visual(enemy)
	var best: Vector3 = terrain.valley_path[0]
	var best_score: float = INF
	for point in terrain.valley_path:
		var score: float = absf(point.distance_to(model.position) - 3600.0) + rng.randf() * 900.0
		for other in opponents:
			if other != enemy and other.model.alive and other.model.position.distance_to(point) < 900.0:
				score += 2000.0
		if score < best_score:
			best_score = score
			best = point
	var at: Vector3 = Vector3(best.x, terrain.surface_at(best.x, best.z) + rng.randf_range(300.0, 520.0), best.z)
	var to_player: Vector3 = model.position - at
	enemy.spawn(at, atan2(-to_player.x, -to_player.z))
	var index: int = opponents.find(enemy)
	if index < opponent_hull.size():
		enemy.model.hull = float(enemy.model.spec.hull) * clampf(opponent_hull[index], 0.01, 1.0)
	enemy.aircraft.set_voice_enabled(true)
	enemy.ai.reset()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and mode == Mode.HANGAR:
		if pause_menu != null and pause_menu.visible:
			_resume()
		else:
			_open_settings_from_hangar()
	elif event.is_action_pressed("pause") and mode == Mode.FLYING and online:
		# Online the world keeps going: the menu opens over it and the controls let go.
		_ensure_pause_menu()
		if pause_menu.visible:
			_resume()
		else:
			pause_menu.open(false)
			pause_menu.hangar.text = "End match" if net != null and net.is_host() else "Leave match"
			input.enabled = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("pause") and mode == Mode.FLYING:
		if get_tree().paused:
			_resume()
		else:
			get_tree().paused = true
			_ensure_pause_menu()
			pause_menu.open(false)
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("toggle_fps"):
		hud.show_fps = not hud.show_fps
	elif event.is_action_pressed("toggle_weather"):
		settings.snow_showers = not settings.snow_showers
		settings.save()
		_apply_settings()
		if pause_menu != null:   # rebuilt on next use so its checkbox matches
			pause_menu.queue_free()
			pause_menu = null
		hud.announce("SNOW SHOWERS ON" if settings.snow_showers else "SNOW SHOWERS OFF")
	elif event.is_action_pressed("fullscreen"):
		settings.fullscreen = not settings.fullscreen
		settings.save()
		_apply_settings()
	elif event is InputEventMouseButton and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not get_tree().paused and _player_flies():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## The pause menu is created on first use. Its quality dropdown owns a hidden
## popup window, and a hidden popup present while the main window is first shown
## makes Godot 4.5 log harmless "disconnect a nonexistent connection" errors.
func _ensure_pause_menu() -> void:
	if pause_menu != null:
		return
	pause_menu = PauseMenu.new()
	ui_layer.add_child(pause_menu)
	pause_menu.build(settings)
	pause_menu.resumed.connect(_resume)
	pause_menu.quit_requested.connect(func() -> void: get_tree().quit())
	pause_menu.settings_changed.connect(_apply_settings)
	pause_menu.hangar_requested.connect(_on_pause_leave)


## The settings panel over the aircraft selection; the hangar ignores keys
## until it is closed so Enter on a slider does not start a sortie.
func _open_settings_from_hangar() -> void:
	_ensure_pause_menu()
	pause_menu.open(true)
	hangar.set_process_unhandled_input(false)


func _resume() -> void:
	if pause_menu != null:
		pause_menu.visible = false
	input.enabled = true
	if mode == Mode.HANGAR:
		hangar.set_process_unhandled_input(true)
		return
	get_tree().paused = false
	if _player_flies():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## True when a human is at the controls of a sortie in progress.
func _player_flies() -> bool:
	return mode == Mode.FLYING and autopilot == null and not ai_player and player != null and not (pause_menu != null and pause_menu.visible)


func _physics_process(delta: float) -> void:
	if mode != Mode.FLYING:
		return
	if online:
		_physics_online(delta)
		return
	if world_dirty:
		return   # online aircraft linger until the scene reloads
	for c in combatants:
		if not c.model.alive:
			c.respawn_timer -= delta
			if c.respawn_timer <= 0.0:
				if c.is_player:
					_spawn()
				else:
					_spawn_enemy(c)
			continue
		var cmd: FlightCommand = _command_for(c, delta)
		var crashed: bool = c.model.step(cmd, delta, terrain)
		c.aircraft.transform = c.model.transform()
		if crashed:
			_destroyed(c, null)
			continue
		if c.shoot(cmd.fire, delta, bullets, 1.0 if c.is_player else AI_DAMAGE_SCALE) > 0:
			c.aircraft.show_gunfire()
			if c.is_player:
				audio.shot()
				camera.extra_shake = maxf(camera.extra_shake, 0.35)
	for impact in bullets.step(delta, terrain, combatants):
		_on_impact(impact)


func _command_for(c: Combatant, delta: float) -> FlightCommand:
	if c.ai != null:
		var cmd: FlightCommand = c.ai.sample(c.model, _target_for(c), delta)
		if c.is_player:
			input.aim_direction = cmd.aim_direction
		return cmd
	if autopilot != null:
		var cmd: FlightCommand = autopilot.sample(model)
		input.aim_direction = cmd.aim_direction
		return cmd
	return input.sample(delta, model.position, model.forward())


## Opponents hunt the player; an AI-flown player hunts the nearest opponent.
func _target_for(c: Combatant) -> FlightModel:
	if not c.is_player:
		return model
	var nearest: FlightModel = null
	for enemy in opponents:
		if enemy.model.alive and (nearest == null or enemy.model.position.distance_squared_to(model.position) < nearest.position.distance_squared_to(model.position)):
			nearest = enemy.model
	return nearest


func _on_impact(impact: Dictionary) -> void:
	var point: Vector3 = impact.point
	if impact.has("ground"):
		effects.puff(point)
		return
	var target: Combatant = impact.target
	var shooter: Combatant = combatants[int(impact.shooter)]
	var destroyed: bool = target.model.apply_damage(float(impact.damage), int(impact.zone))
	effects.sparks(point)
	target.hit_flash = 1.0
	if target.ai != null:
		target.ai.on_hit(target.model, shooter.model.position)
	if shooter.is_player:
		audio.hit_confirm()
		hud.hit_marker = 0.16
		hud.target_hit(target)
	if target.is_player:
		audio.struck()
		hud.damage_flash = 1.0
		camera.extra_shake = maxf(camera.extra_shake, 1.1)
	if destroyed:
		_destroyed(target, shooter)


## An aircraft is gone: shot down by `by`, or flown into the ground (null).
func _destroyed(c: Combatant, by: Combatant) -> void:
	c.losses += 1
	c.respawn_timer = RESPAWN_DELAY if c.is_player else ENEMY_RESPAWN_DELAY
	effects.explosion(c.model.position, 1.4)
	c.aircraft.visible = false
	c.aircraft.set_voice_enabled(false)
	if by != null:
		by.kills += 1
	if c.is_player:
		camera.extra_shake = 2.5
		hud.lost_reason = "SHOT DOWN" if by != null else "AIRCRAFT LOST"
	elif by != null and by.is_player:
		hud.announce("ENEMY %s DESTROYED" % String(c.model.spec.short))
	else:
		hud.announce("ENEMY %s CRASHED" % String(c.model.spec.short))


func _process(delta: float) -> void:
	elapsed += delta
	_online_tick(delta)
	if mode == Mode.FLYING and player != null:
		var shown: Transform3D = aircraft.get_global_transform_interpolated()
		input.camera_up = camera.up_vector
		camera.follow(delta, input.aim_direction, shown, model)
		for c in combatants:
			if c.aircraft != null and c.aircraft.visible:
				c.aircraft.animate(c.model, delta)
				c.aircraft.set_damage(c.model.hull_ratio())
				c.hit_flash = maxf(c.hit_flash - delta * 7.0, 0.0)
				c.aircraft.set_hit_flash(c.hit_flash)
		audio.update(model, delta)
		if not model.alive:
			hud.crash_time += delta
	else:
		# Selection screen backdrop: a slow pan across the valley.
		var yaw: float = terrain.spawn_heading + sin(elapsed * 0.07) * 0.55
		var look: Vector3 = Vector3(-sin(yaw), -0.07, -cos(yaw)).normalized()
		camera.global_transform = Transform3D(Basis.looking_at(look, Vector3.UP), terrain.spawn_position + Vector3(0.0, 30.0, 0.0))
		camera.fov = ChaseCamera.BASE_FOV
	if fixed_view.size() == 5:
		camera.global_transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(fixed_view[4]), deg_to_rad(fixed_view[3]), 0.0)),
			Vector3(fixed_view[0], fixed_view[1], fixed_view[2]))
	clouds.update(camera.global_position)
	weather.update(delta, camera.global_position)
	forest.update(camera.global_position)
	_benchmark_tick(delta)
	if OS.get_cmdline_user_args().has("--log") and int(elapsed) != int(elapsed - delta) and online:
		_log_online()
	elif OS.get_cmdline_user_args().has("--log") and int(elapsed) != int(elapsed - delta) and model != null and mode == Mode.FLYING:
		var foes: String = ""
		for enemy in opponents:
			foes += " | %s hull=%d d=%d" % [String(enemy.model.spec.short), int(enemy.model.hull), int(enemy.model.position.distance_to(model.position))]
		print("t=%d fps=%d pos=%s speed=%d alive=%s hull=%d kills=%d lost=%d bullets=%d draws=%d prims=%d%s" % [int(elapsed), Engine.get_frames_per_second(),
			str(model.position.round()), int(model.speed), model.alive, int(model.hull), player.kills, player.losses, bullets.count(),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME), foes])
	var ready_for_shot: bool = not OS.get_cmdline_user_args().has("--screenshot-when-firing") or (model != null and model.firing and bullets.count() > 8)
	if screenshot_at >= 0.0 and elapsed >= screenshot_at and ready_for_shot:
		screenshot_at = -1.0
		var image: Image = get_viewport().get_texture().get_image()
		image.save_png(screenshot_path)
		print("Screenshot saved: ", screenshot_path)
	if quit_at > 0.0 and elapsed >= quit_at:
		get_tree().quit()


func _benchmark_tick(delta: float) -> void:
	if benchmark_seconds <= 0.0:
		return
	if elapsed > 5.0:
		frame_times.append(delta * 1000.0)
	if elapsed < benchmark_seconds + 5.0:
		return
	var sorted: PackedFloat32Array = frame_times.duplicate()
	sorted.sort()
	var total: float = 0.0
	for ms in sorted:
		total += ms
	var avg_ms: float = total / maxf(sorted.size(), 1)
	var p99: float = sorted[int(sorted.size() * 0.99)]
	var worst: float = sorted[sorted.size() - 1]
	var size: Vector2i = get_viewport().get_visible_rect().size
	var result: Dictionary = {
		"quality": GameSettings.QUALITY_NAMES[settings.quality], "resolution": "%dx%d" % [size.x, size.y],
		"frames": sorted.size(), "seconds": benchmark_seconds, "avg_fps": snappedf(1000.0 / avg_ms, 0.1),
		"avg_ms": snappedf(avg_ms, 0.01), "p99_ms": snappedf(p99, 0.01), "one_percent_low_fps": snappedf(1000.0 / p99, 0.1),
		"worst_ms": snappedf(worst, 0.01), "vsync": DisplayServer.window_get_vsync_mode(),
		"gpu": RenderingServer.get_video_adapter_name(), "driver": RenderingServer.get_video_adapter_api_version(),
		"cpu": OS.get_processor_name(), "godot": Engine.get_version_info().string,
	}
	print("BENCHMARK ", JSON.stringify(result))
	if benchmark_out != "":
		var f: FileAccess = FileAccess.open(benchmark_out, FileAccess.WRITE)
		f.store_string(JSON.stringify(result, "  "))
	benchmark_seconds = 0.0
	get_tree().quit()


# --- Online play ---------------------------------------------------------------
# Each game flies its own aircraft and reports its motion; the host's
# MatchReferee checks the reports and alone decides damage, kills, respawns and
# the winner. See docs/multiplayer-design.md.

## Hangar "Host match", --host, or --server (no local pilot).
func _host_match(frame: int, dedicated: bool = false, remember: bool = true) -> void:
	if net != null:
		return
	if remember and frame != settings.aircraft:
		settings.aircraft = frame
		settings.save()
	net = NetSession.create(get_tree())
	var err: Error = net.host(net_port, settings.player_name, frame, terrain.id, dedicated)
	if err != OK:
		var reason: String = net.status
		net.close("")
		net = null
		print("HOST: ", reason)
		if server_mode:
			get_tree().quit(1)
			return
		_enter_hangar()
		hangar.notice(reason)
		return
	net.set_address(cli_address if cli_address != "" else settings.host_address)
	if settings.auto_port and not server_mode and not cli_host:
		net.set_auto_port(true)
	_connect_session()
	_enter_lobby()
	print("HOST: listening on UDP %d%s" % [net_port, " (dedicated server)" if dedicated else ""])


## Hangar "Join match": the paste-an-invite screen.
func _join_screen(frame: int) -> void:
	if frame >= 0 and frame != settings.aircraft:
		settings.aircraft = frame
		settings.save()
	mode = Mode.LOBBY
	hangar.close()
	hangar.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	lobby.open(null, false)


func _join(invite: Invite) -> void:
	if net != null:
		return
	net = NetSession.create(get_tree())
	if net.join(invite, settings.player_name, settings.aircraft) != OK:
		var reason: String = net.status
		net.close("")
		net = null
		lobby.open(null, false)
		lobby.status_label.text = reason
		return
	_connect_session()
	lobby.open(net, false)


func _connect_session() -> void:
	net.message.connect(_on_net_message)
	net.welcomed.connect(_on_welcomed)
	net.player_left.connect(_on_player_left)
	net.ended.connect(_on_session_ended)
	net.changed.connect(_on_session_changed)
	net.drain.call_deferred()
	_on_session_changed()


func _disconnect_session() -> void:
	for pair: Array in [[net.message, _on_net_message], [net.welcomed, _on_welcomed], [net.player_left, _on_player_left],
			[net.ended, _on_session_ended], [net.changed, _on_session_changed]]:
		var sig: Signal = pair[0]
		if sig.is_connected(pair[1]):
			sig.disconnect(pair[1])


func _enter_lobby() -> void:
	mode = Mode.LOBBY
	online = false
	get_tree().paused = false
	if pause_menu != null:
		pause_menu.visible = false
	input.enabled = true
	hangar.close()
	hangar.set_process_unhandled_input(false)
	for c in combatants:
		if c.aircraft != null:
			c.aircraft.visible = false
			c.aircraft.set_voice_enabled(false)
			c.aircraft.clear_trail()
	bullets.clear()
	audio.silence()
	hud.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	lobby.open(net, net != null and net.is_host(), result_text)


## Lobby "Stop hosting" / "Leave" / "Back".
func _leave_online() -> void:
	if net != null:
		net.close("")
	else:
		lobby.close()
		_enter_hangar()


## Pause menu middle button: offline it changes aircraft; online the host ends
## the match for everyone and a joiner leaves.
func _on_pause_leave() -> void:
	if not online or net == null:
		_enter_hangar()
	elif net.is_host():
		_end_online_match("The host ended the match.")
	else:
		net.close("You left the match.")


func _on_session_ended(reason: String) -> void:
	net = null
	online = false
	if world_dirty:
		mode = Mode.LOBBY   # the offline loop must never run the online aircraft
	referee = null
	if server_mode or (matches_to_quit > 0 and matches_ended + (1 if end_timer > 0.0 else 0) >= matches_to_quit):
		print("NET: session ended, quitting. ", reason)
		get_tree().quit()
		return
	if world_dirty:
		pending_notice = reason
		get_tree().paused = false
		get_tree().reload_current_scene.call_deferred()
		return
	lobby.close()
	_enter_hangar()
	hangar.notice(reason)
	if reason != "":
		print("NET: ", reason)


func _on_welcomed(map_id: String, _in_match: bool) -> void:
	if String(TerrainData.MAPS[TerrainData.map_index(map_id)].id) != map_id:
		net.close("The host is flying a map this copy of the game does not have.")
		return
	if map_id != terrain.id:
		# Load the host's map; the session waits under the scene root meanwhile.
		_disconnect_session()
		session_map = map_id
		get_tree().reload_current_scene.call_deferred()
		return
	lobby.refresh()


func _on_session_changed() -> void:
	if net == null:
		return
	if net.is_host():
		var text: String = net.invite_text()
		if text != invite_written:
			invite_written = text
			if invite_out != "" and text != "":
				var f: FileAccess = FileAccess.open(invite_out, FileAccess.WRITE)
				if f != null:
					f.store_string(text)
			if server_mode:
				print("INVITE ", text if text != "" else "(none yet: start the server with --address=YOUR_PUBLIC_ADDRESS)")


## Lobby "Start match", or --autostart. Host only.
func _net_start_match() -> void:
	if net == null or not net.is_host() or net.in_match or net.players.size() < 2:
		return
	var planner: MatchReferee = MatchReferee.new()
	planner.terrain = terrain
	var spots: Array[Dictionary] = planner.start_positions(net.players.size())
	var entries: Array[Dictionary] = []
	for i in range(net.players.size()):
		var p: Dictionary = net.players[i]
		entries.append({"id": i, "peer": int(p.peer), "team": i, "frame": int(p.frame), "name": String(p.name),
			"position": spots[i].position, "heading": spots[i].heading})
	var msg: Dictionary = {"type": NetProtocol.Msg.MATCH_START, "score_limit": score_limit, "entries": entries}
	net.set_in_match(true)
	net.broadcast(msg)
	_apply_match_start(msg)


func _apply_match_start(msg: Dictionary) -> void:
	var me: int = net.my_id()
	var mine: bool = false
	for e: Dictionary in msg.entries:
		mine = mine or int(e.peer) == me
	if not mine and not net.is_host():
		lobby.refresh()   # joined while a match runs: wait for the next one
		return
	world_dirty = true
	for c in combatants:
		if c.aircraft != null:
			c.aircraft.queue_free()
	combatants.clear()
	opponents.clear()
	player = null
	model = null
	aircraft = null
	bullets.clear()
	for e: Dictionary in msg.entries:
		var local: bool = int(e.peer) == me
		var c: Combatant = Combatant.new()
		c.setup(int(e.id), int(e.team), int(e.frame), local)
		c.peer_id = int(e.peer)
		c.pilot_name = String(e.name)
		c.remote = not local
		if c.remote:
			c.buffer = SnapshotBuffer.new()
		combatants.append(c)
		if not server_mode:
			_build_visual(c)
		c.spawn(e.position, float(e.heading))
		if c.aircraft != null:
			c.aircraft.set_voice_enabled(c.remote)
		if local:
			player = c
			model = c.model
			aircraft = c.aircraft
		else:
			opponents.append(c)
	score_limit = int(msg.score_limit)
	latest_states.clear()
	claims.clear()
	kicked.clear()
	net_tick = 0
	end_timer = -1.0
	result_text = ""
	if net.is_host():
		referee = MatchReferee.new()
		referee.setup(terrain, combatants, score_limit, rng.randi())
		for c in combatants:
			referee.placed(c, c.model.position)
	online = true
	mode = Mode.FLYING
	lobby.close()
	hangar.close()
	if player == null:
		print("SERVER: match started with %d players" % combatants.size())
		return
	if ai_player:
		player.ai = AiPilot.new()
		player.ai.setup(terrain, 7 + me)
	audio.use_aircraft(Airframes.spec(player.frame_id))
	input.reset(model.forward())
	camera.snap(model.forward(), model.position)
	hud.attach(player, opponents)
	hud.mode_label = "ONLINE MATCH · FIRST TO %d KILLS" % score_limit
	hud.visible = not OS.get_cmdline_user_args().has("--no-hud")
	if _player_flies():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	print("NET: match started, %d players, first to %d" % [combatants.size(), score_limit])


func _physics_online(delta: float) -> void:
	net_tick += 1
	for c in combatants:
		if c.left or not c.model.alive:
			continue
		if c.remote:
			var snap: Dictionary = c.buffer.sample(delta)
			if snap.is_empty():
				continue
			SnapshotBuffer.apply(snap, c.model)
			if c.aircraft != null:
				c.aircraft.transform = c.model.transform()
			# Their guns are drawn here; their game decides what the rounds hit.
			var firing: bool = (int(snap.flags) & NetProtocol.FLAG_FIRING) != 0
			if c.shoot(firing, delta, bullets, 1.0, true) > 0 and c.aircraft != null:
				c.aircraft.show_gunfire()
			continue
		var cmd: FlightCommand = _command_for(c, delta)
		var crashed: bool = c.model.step(cmd, delta, terrain)
		c.aircraft.transform = c.model.transform()
		if crashed:
			_local_crash(c)
			continue
		if c.shoot(cmd.fire, delta, bullets) > 0:
			c.aircraft.show_gunfire()
			audio.shot()
			camera.extra_shake = maxf(camera.extra_shake, 0.35)
	for impact in bullets.step(delta, terrain, combatants):
		if impact.has("ground"):
			effects.puff(impact.point)
		else:
			_local_hit(impact)
	if player != null and net_tick % 2 == 0:
		var state: Dictionary = SnapshotBuffer.capture(player.model, player.life, net_tick)
		if net.is_host():
			if referee.accept_state(player, state):
				latest_states[player.id] = state
		elif player.model.alive:
			net.send(1, {"type": NetProtocol.Msg.STATE, "state": state})
	_flush_claims()
	if net != null and net.is_host() and referee != null:
		_dispatch(referee.tick(delta))
		if net_tick % 2 == 0:
			_send_world()
		for c in combatants:
			if c.remote and not c.left and not kicked.has(c.peer_id) and referee.strikes_exceeded(c):
				kicked[c.peer_id] = true
				net.kick(c.peer_id, "Removed: your game sent impossible flight or hit reports.")


## One of our rounds hit someone: show it now, report it to the host.
func _local_hit(impact: Dictionary) -> void:
	var target: Combatant = impact.target
	if player == null or int(impact.shooter) != player.id:
		return
	effects.sparks(impact.point)
	target.hit_flash = 1.0
	audio.hit_confirm()
	hud.hit_marker = 0.16
	hud.target_hit(target)
	var key: int = target.id * 8 + int(impact.zone)
	if claims.has(key):
		claims[key].rounds = mini(int(claims[key].rounds) + 1, NetProtocol.MAX_ROUNDS_PER_CLAIM)
	else:
		claims[key] = {"target": target.id, "life": target.life, "zone": int(impact.zone), "rounds": 1}


func _flush_claims() -> void:
	if claims.is_empty():
		return
	var list: Array[Dictionary] = []
	for key: int in claims:
		if list.size() < NetProtocol.MAX_CLAIMS:
			list.append(claims[key])
	claims.clear()
	if net.is_host():
		_dispatch(referee.claim_hits(player, list))
	else:
		net.send(1, {"type": NetProtocol.Msg.HIT_CLAIM, "claims": list})


## Our own aircraft flew into the ground. Shown at once; the host makes it count.
func _local_crash(c: Combatant) -> void:
	effects.explosion(c.model.position, 1.4)
	c.aircraft.visible = false
	c.aircraft.set_voice_enabled(false)
	camera.extra_shake = 2.5
	hud.lost_reason = "AIRCRAFT LOST"
	if net.is_host():
		_dispatch(referee.crashed(c, c.life))
	else:
		net.send(1, {"type": NetProtocol.Msg.CRASHED, "life": c.life})


## Host: send every joiner where everyone else is.
func _send_world() -> void:
	for r in combatants:
		if not r.remote or r.left:
			continue
		var states: Array[Dictionary] = []
		for c in combatants:
			if c == r or c.left or not c.model.alive or not latest_states.has(c.id):
				continue
			var s: Dictionary = latest_states[c.id].duplicate()
			s.id = c.id
			states.append(s)
		if not states.is_empty():
			net.send(r.peer_id, {"type": NetProtocol.Msg.WORLD, "states": states})


## Host: apply the referee's decisions here and tell everyone.
func _dispatch(events: Array[Dictionary]) -> void:
	for e in events:
		_apply_event(e)
		if net != null:
			net.broadcast(e)


func _combatant_of(peer: int) -> Combatant:
	for c in combatants:
		if c.peer_id == peer:
			return c
	return null


func _combatant_at(id: int) -> Combatant:
	return combatants[id] if id >= 0 and id < combatants.size() else null


func _on_net_message(peer: int, msg: Dictionary) -> void:
	var type: int = int(msg.type)
	if net.is_host():
		var c: Combatant = _combatant_of(peer)
		if c == null or not online or referee == null:
			return
		match type:
			NetProtocol.Msg.STATE:
				if referee.accept_state(c, msg.state):
					latest_states[c.id] = msg.state
					c.buffer.push(msg.state)
			NetProtocol.Msg.HIT_CLAIM:
				_dispatch(referee.claim_hits(c, msg.claims))
			NetProtocol.Msg.CRASHED:
				_dispatch(referee.crashed(c, int(msg.life)))
		return
	# Keep the lobby's "match in progress" line right, also for those waiting it out.
	if type == NetProtocol.Msg.MATCH_START:
		net.set_in_match(true)
	elif type == NetProtocol.Msg.MATCH_END or type == NetProtocol.Msg.LOBBY:
		net.set_in_match(false)
	match type:
		NetProtocol.Msg.MATCH_START:
			_apply_match_start(msg)
		NetProtocol.Msg.LOBBY:
			if online or mode == Mode.FLYING:
				result_text = "The host ended the match."
				_enter_lobby()
		NetProtocol.Msg.WORLD:
			if not online:
				return
			for s: Dictionary in msg.states:
				var c: Combatant = _combatant_at(int(s.id))
				if c != null and c.remote and not c.left and c.model.alive and (int(s.life) & 255) == (c.life & 255):
					c.buffer.push(s)
		_:
			if online:
				_apply_event(msg)


## A decision from the referee, the same on the host and on every joiner.
func _apply_event(e: Dictionary) -> void:
	match int(e.type):
		NetProtocol.Msg.DAMAGE:
			var t: Combatant = _combatant_at(int(e.target))
			var by: Combatant = _combatant_at(int(e.shooter))
			if t == null or t.left:
				return
			t.model.hull = float(e.hull)
			t.model.zone_health = (e.zones as PackedFloat32Array).duplicate()
			if by != player:   # our own hits were shown when they landed
				effects.sparks(t.model.position)
				t.hit_flash = 1.0
			if t == player:
				audio.struck()
				hud.damage_flash = 1.0
				camera.extra_shake = maxf(camera.extra_shake, 1.1)
				if t.ai != null and by != null:
					t.ai.on_hit(t.model, by.model.position)
		NetProtocol.Msg.DESTROYED:
			var t: Combatant = _combatant_at(int(e.target))
			if t == null:
				return
			var by: Combatant = _combatant_at(int(e.by)) if int(e.by) != NetProtocol.NO_ONE else null
			t.model.alive = false
			t.model.hull = 0.0
			t.losses = int(e.losses)
			if by != null:
				by.kills = int(e.kills)
			if t.aircraft != null and t.aircraft.visible:
				effects.explosion(t.model.position, 1.4)
				t.aircraft.visible = false
				t.aircraft.set_voice_enabled(false)
			if player == null:
				return
			if t == player:
				camera.extra_shake = 2.5
				hud.lost_reason = "SHOT DOWN BY %s" % by.pilot_name.to_upper() if by != null else "AIRCRAFT LOST"
			elif by == player:
				hud.announce("%s DESTROYED" % t.pilot_name.to_upper())
			elif by != null:
				hud.announce("%s SHOT DOWN %s" % [by.pilot_name.to_upper(), t.pilot_name.to_upper()])
			else:
				hud.announce("%s CRASHED" % t.pilot_name.to_upper())
		NetProtocol.Msg.SPAWN:
			var c: Combatant = _combatant_at(int(e.id))
			if c == null or c.left:
				return
			c.life = int(e.life)
			c.spawn(e.position, float(e.heading))
			if c.buffer != null:
				c.buffer.reset()
			latest_states.erase(c.id)
			if referee != null:
				referee.placed(c, e.position)
			if c.aircraft != null:
				c.aircraft.set_voice_enabled(c.remote)
			if c == player:
				input.reset(model.forward())
				camera.snap(model.forward(), model.position)
				hud.crash_time = 0.0
				if c.ai != null:
					c.ai.reset()
		NetProtocol.Msg.MATCH_END:
			var winner: Combatant = _combatant_at(int(e.winner)) if int(e.winner) != NetProtocol.NO_ONE else null
			for s: Dictionary in e.scores:
				var c: Combatant = _combatant_at(int(s.id))
				if c != null:
					c.kills = int(s.kills)
					c.losses = int(s.losses)
			var line: String = ""
			for c in combatants:
				line += "%s%s %d" % ["" if line == "" else "  ·  ", c.pilot_name, c.kills]
			if winner == null:
				result_text = "Match over.  " + line
			elif winner == player:
				result_text = "You won!  " + line
			else:
				result_text = "%s won.  %s" % [winner.pilot_name, line]
			if player != null:
				hud.announce("VICTORY" if winner == player else ("%s WINS" % winner.pilot_name.to_upper() if winner != null else "MATCH OVER"))
			print("NET: match over. ", result_text)
			end_timer = 4.0
			if net != null and net.is_host():
				net.set_in_match(false)
		NetProtocol.Msg.LEFT:
			var c: Combatant = _combatant_at(int(e.id))
			if c == null:
				return
			c.left = true
			c.model.alive = false
			if c.aircraft != null:
				c.aircraft.visible = false
				c.aircraft.set_voice_enabled(false)
			if player != null:
				hud.announce("%s LEFT THE MATCH" % c.pilot_name.to_upper())


func _on_player_left(peer: int) -> void:
	if not online or referee == null:
		return
	var c: Combatant = _combatant_of(peer)
	if c != null and not c.left:
		_dispatch(referee.remove(c))


## Host: stop the match and bring everyone back to the lobby.
func _end_online_match(reason: String) -> void:
	if referee != null:
		referee.running = false
	net.set_in_match(false)
	net.broadcast({"type": NetProtocol.Msg.LOBBY})
	result_text = reason
	_enter_lobby()


## Per-frame online housekeeping: the results pause after a match and autostart.
func _online_tick(delta: float) -> void:
	if end_timer > 0.0:
		end_timer -= delta
		if end_timer <= 0.0:
			end_timer = -1.0
			matches_ended += 1
			if matches_to_quit > 0 and matches_ended >= matches_to_quit:
				print("NET: quitting after %d match(es)" % matches_ended)
				if net != null:
					net.close("")
				get_tree().quit()
				return
			if mode == Mode.FLYING:
				_enter_lobby()
	if autostart > 0 and net != null and net.is_host() and mode == Mode.LOBBY and not net.in_match and net.players.size() >= autostart:
		autostart_wait += delta
		if autostart_wait > (2.0 if matches_ended == 0 else 6.0):
			autostart_wait = 0.0
			_net_start_match()
	else:
		autostart_wait = 0.0


func _log_online() -> void:
	var others: String = ""
	for c in combatants:
		if c != player:
			var d: int = int(c.model.position.distance_to(model.position)) if model != null else 0
			others += " | %s %s hull=%d alive=%s k=%d l=%d d=%d" % [c.pilot_name, String(c.model.spec.short), int(c.model.hull), c.model.alive, c.kills, c.losses, d]
	var me: String = "server"
	if player != null:
		me = "%s pos=%s speed=%d hull=%d alive=%s k=%d l=%d" % [player.pilot_name, str(model.position.round()), int(model.speed), int(model.hull), model.alive, player.kills, player.losses]
	print("NET t=%d fps=%d %s%s" % [int(elapsed), Engine.get_frames_per_second(), me, others])
