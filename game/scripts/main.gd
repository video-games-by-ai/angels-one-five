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

const RESPAWN_DELAY: float = 3.0
const ENEMY_RESPAWN_DELAY: float = 6.0
const AI_DAMAGE_SCALE: float = 0.5    ## opponents' rounds are softened so beginners last
const PLAYER_COLOR: int = 0
const ENEMY_COLOR: int = 2

enum Mode { HANGAR, FLYING }

## Map of this run. It survives the scene reload that switching maps performs.
static var session_map: String = ""

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


func _ready() -> void:
	PlayerInput.register_actions()
	settings = GameSettings.load_or_default()
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
		elif arg.begins_with("--quit-at="):
			quit_at = float(arg.trim_prefix("--quit-at="))

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
	if not args.has("--no-trees"):
		forest.build(terrain, terrain_renderer.mask_texture, profile)
	village = Village.new()
	add_child(village)
	village.build(terrain)
	clouds = CloudField.new()
	add_child(clouds)
	if not args.has("--no-clouds"):
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
	hangar.quit_requested.connect(func() -> void: get_tree().quit())
	ui_layer = layer
	_apply_settings()
	if aircraft_id >= 0 or use_autopilot or ai_player:
		_start_flight(aircraft_id if aircraft_id >= 0 else settings.aircraft, false)
	else:
		_enter_hangar()


## Show the aircraft selection over a slow view of the valley.
func _enter_hangar() -> void:
	mode = Mode.HANGAR
	get_tree().paused = false
	if pause_menu != null:
		pause_menu.visible = false
	for c in combatants:
		if c.aircraft != null:
			c.aircraft.visible = false
			c.aircraft.set_voice_enabled(false)
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
func _build_visual(c: Combatant) -> void:
	if c.aircraft != null:
		c.aircraft.queue_free()
	c.aircraft = Aircraft.new()
	add_child(c.aircraft)
	c.aircraft.build(Airframes.spec(c.frame_id), PLAYER_COLOR if c.is_player else ENEMY_COLOR, true, not c.is_player)


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
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(settings.master_volume, 0.0001)))
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
	enemy.aircraft.set_voice_enabled(true)
	enemy.ai.reset()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and mode == Mode.FLYING:
		if get_tree().paused:
			_resume()
		else:
			get_tree().paused = true
			_ensure_pause_menu()
			pause_menu.visible = true
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
	pause_menu.hangar_requested.connect(_enter_hangar)


func _resume() -> void:
	if pause_menu != null:
		pause_menu.visible = false
	get_tree().paused = false
	if _player_flies():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## True when a human is at the controls of a sortie in progress.
func _player_flies() -> bool:
	return mode == Mode.FLYING and autopilot == null and not ai_player


func _physics_process(delta: float) -> void:
	if mode != Mode.FLYING:
		return
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
	if mode == Mode.FLYING:
		var shown: Transform3D = aircraft.get_global_transform_interpolated()
		input.camera_up = camera.up_vector
		camera.follow(delta, input.aim_direction, shown, model)
		for c in combatants:
			if c.aircraft.visible:
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
	if OS.get_cmdline_user_args().has("--log") and int(elapsed) != int(elapsed - delta):
		var foes: String = ""
		for enemy in opponents:
			foes += " | %s hull=%d d=%d" % [String(enemy.model.spec.short), int(enemy.model.hull), int(enemy.model.position.distance_to(model.position))]
		print("t=%d fps=%d pos=%s speed=%d alive=%s hull=%d kills=%d lost=%d bullets=%d draws=%d prims=%d%s" % [int(elapsed), Engine.get_frames_per_second(),
			str(model.position.round()), int(model.speed), model.alive, int(model.hull), player.kills, player.losses, bullets.count(),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME), foes])
	var ready_for_shot: bool = not OS.get_cmdline_user_args().has("--screenshot-when-firing") or (model.firing and bullets.count() > 8)
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
