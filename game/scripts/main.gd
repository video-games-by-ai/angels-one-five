extends Node3D
## Bootstrap for the free-flight practice scene: builds the valley, spawns the
## player's aircraft and wires input, camera, HUD, audio and the pause menu.
##
## Command-line options (after `--`):
##   --quality=0|1|2          Low / Medium / High graphics
##   --aircraft=0|1|2         Spitfire / Mustang / Thunderbolt balance
##   --autopilot              fly the valley automatically (demo / benchmark)
##   --clearance=METRES       autopilot height above ground (default 140)
##   --benchmark=SECONDS      autopilot + frame-time measurement, then quit
##   --benchmark-out=PATH     write benchmark results as JSON
##   --screenshot=PATH --screenshot-at=SECONDS   save one frame
##   --quit-at=SECONDS
##   --log                    print position / FPS once per second
##   --no-trees --no-clouds --no-hud   diagnostics: skip a subsystem

const RESPAWN_DELAY: float = 3.0

var settings: GameSettings
var terrain: TerrainData
var atmosphere: Atmosphere
var terrain_renderer: TerrainRenderer
var forest: Forest
var clouds: CloudField
var water: MeshInstance3D
var camera: ChaseCamera
var input: PlayerInput
var autopilot: Autopilot
var model: FlightModel
var aircraft: Aircraft
var audio: EngineAudio
var hud: Hud
var pause_menu: PauseMenu
var ui_layer: CanvasLayer
var effects: Effects
var aircraft_id: int = Airframes.Id.MUSTANG
var respawn_timer: float = 0.0
var elapsed: float = 0.0
var screenshot_path: String = ""
var screenshot_at: float = -1.0
var quit_at: float = -1.0
var benchmark_seconds: float = 0.0
var benchmark_out: String = ""
var frame_times: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	PlayerInput.register_actions()
	settings = GameSettings.load_or_default()
	var use_autopilot: bool = false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quality="):
			settings.quality = clampi(int(arg.trim_prefix("--quality=")), 0, 2) as GameSettings.Quality
		elif arg.begins_with("--aircraft="):
			aircraft_id = clampi(int(arg.trim_prefix("--aircraft=")), 0, 2)
		elif arg == "--autopilot":
			use_autopilot = true
		elif arg.begins_with("--benchmark="):
			benchmark_seconds = float(arg.trim_prefix("--benchmark="))
			use_autopilot = true
		elif arg.begins_with("--benchmark-out="):
			benchmark_out = arg.trim_prefix("--benchmark-out=")
		elif arg.begins_with("--screenshot="):
			screenshot_path = arg.trim_prefix("--screenshot=")
		elif arg.begins_with("--screenshot-at="):
			screenshot_at = float(arg.trim_prefix("--screenshot-at="))
		elif arg.begins_with("--quit-at="):
			quit_at = float(arg.trim_prefix("--quit-at="))

	var t0: int = Time.get_ticks_msec()
	terrain = TerrainData.load_default()
	var profile: Dictionary = settings.profile()
	atmosphere = Atmosphere.new()
	add_child(atmosphere)
	atmosphere.build(terrain.sun_direction)
	terrain_renderer = TerrainRenderer.new()
	add_child(terrain_renderer)
	terrain_renderer.build(terrain, float(profile.lod_scale))
	_build_water()
	var args: PackedStringArray = OS.get_cmdline_user_args()
	forest = Forest.new()
	add_child(forest)
	if not args.has("--no-trees"):
		forest.build(terrain, terrain_renderer.mask_texture, profile)
	clouds = CloudField.new()
	add_child(clouds)
	if not args.has("--no-clouds"):
		clouds.build(terrain, float(profile.clouds))
	effects = Effects.new()
	add_child(effects)
	print("World built in %d ms" % (Time.get_ticks_msec() - t0))

	model = FlightModel.new()
	aircraft = Aircraft.new()
	add_child(aircraft)
	aircraft.build(Airframes.spec(aircraft_id), 0)
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
	layer.add_child(flare)
	hud = Hud.new()
	hud.model = model
	hud.camera = camera
	hud.terrain = terrain
	hud.input = input
	hud.aircraft_name = String(Airframes.spec(aircraft_id).name)
	hud.mode_label = "FREE FLIGHT · AUTOPILOT" if use_autopilot else "FREE FLIGHT"
	layer.add_child(hud)
	if args.has("--no-hud"):
		hud.process_mode = Node.PROCESS_MODE_DISABLED
		hud.visible = false
	ui_layer = layer
	_apply_settings()
	_spawn()
	if not use_autopilot:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


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
	var spawn: Vector3 = terrain.spawn_position
	model.setup(aircraft_id, spawn, 0.0)
	aircraft.transform = model.transform()
	aircraft.reset_physics_interpolation()
	aircraft.reset_effects()
	aircraft.visible = true
	input.reset(model.forward())
	camera.snap(model.forward(), model.position)
	hud.crash_time = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if get_tree().paused:
			_resume()
		else:
			get_tree().paused = true
			_ensure_pause_menu()
			pause_menu.visible = true
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("toggle_fps"):
		hud.show_fps = not hud.show_fps
	elif event.is_action_pressed("fullscreen"):
		settings.fullscreen = not settings.fullscreen
		settings.save()
		_apply_settings()
	elif event is InputEventMouseButton and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not get_tree().paused and autopilot == null:
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


func _resume() -> void:
	if pause_menu != null:
		pause_menu.visible = false
	get_tree().paused = false
	if autopilot == null:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if not model.alive:
		respawn_timer -= delta
		if respawn_timer <= 0.0:
			_spawn()
		return
	var cmd: FlightCommand
	if autopilot != null:
		cmd = autopilot.sample(model)
		input.aim_direction = cmd.aim_direction
	else:
		cmd = input.sample(delta, model.position, model.forward())
	var crashed: bool = model.step(cmd, delta, terrain)
	aircraft.transform = model.transform()
	if crashed:
		respawn_timer = RESPAWN_DELAY
		effects.explosion(model.position, 1.4)
		camera.extra_shake = 2.5
		aircraft.visible = false


func _process(delta: float) -> void:
	elapsed += delta
	var shown: Transform3D = aircraft.get_global_transform_interpolated()
	input.camera_up = camera.up_vector
	camera.follow(delta, input.aim_direction, shown, model)
	if aircraft.visible:
		aircraft.animate(model, delta)
	audio.update(model, delta)
	clouds.update(camera.global_position)
	forest.update(camera.global_position)
	if not model.alive:
		hud.crash_time += delta
	_benchmark_tick(delta)
	if OS.get_cmdline_user_args().has("--log") and int(elapsed) != int(elapsed - delta):
		print("t=%d fps=%d pos=%s speed=%d alive=%s draws=%d prims=%d" % [int(elapsed), Engine.get_frames_per_second(), str(model.position.round()), int(model.speed), model.alive,
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)])
	if screenshot_at >= 0.0 and elapsed >= screenshot_at:
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
