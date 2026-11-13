extends SceneTree
## Renders each aircraft with its flaps up and wings straight, then with the flaps
## down, the wings bent in the hardest pull and the controls deflected, to PNG
## files, for checking the moving parts. Off-screen, takes no input.
## Run: godot --path game --disable-vsync --script res://tests/render_wings.gd -- --out=DIR

const VIEWS: Array[Dictionary] = [
	{"name": "rear", "eye": Vector3(5.5, 3.2, 15.0)},    # chase-camera angle
	{"name": "below", "eye": Vector3(-7.5, -3.0, 9.0)},  # low rear quarter: the flaps' undersides
]
const SETTLE_TIME: float = 0.25

var out_dir: String = "user://"
var stage: SubViewport
var camera: Camera3D
var display: Aircraft
var shots: Array[Dictionary] = []
var index: int = 0
var settled: float = -1.0   ## seconds since the current shot was set up; below 0: not set up yet


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.trim_prefix("--out=")
	stage = SubViewport.new()
	stage.size = Vector2i(1200, 800)
	stage.gui_disable_input = true
	stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	stage.own_world_3d = true
	root.add_child(stage)
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.70, 0.80)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.68)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world: WorldEnvironment = WorldEnvironment.new()
	world.environment = env
	stage.add_child(world)
	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(30.0), 0.0)
	sun.light_energy = 1.3
	stage.add_child(sun)
	camera = Camera3D.new()
	camera.fov = 40.0
	stage.add_child(camera)
	for id in [Airframes.Id.SPITFIRE, Airframes.Id.MUSTANG, Airframes.Id.THUNDERBOLT]:
		for loaded: bool in [false, true]:
			for view: Dictionary in VIEWS:
				shots.append({"id": id, "loaded": loaded, "view": view})


func _shot_setup(shot: Dictionary) -> void:
	if display == null or display.get_meta("id", -1) != int(shot.id):
		if display != null:
			display.free()
		display = Aircraft.new()
		display.set_meta("id", int(shot.id))
		stage.add_child(display)
		display.build(Airframes.spec(int(shot.id)), 0, false)
	display.reset_pose()
	var loaded: bool = bool(shot.loaded)
	var bend: float = display.flex_tip if loaded else 0.0
	display.flap_amount = 1.0 if loaded else 0.0
	display._pose_flaps()
	for i in range(display.flex_meshes.size()):
		display.flex_meshes[i].set_blend_shape_value(display.flex_shapes[i], bend)
	# Pulling up and rolling right, with a touch of right rudder.
	var roll: float = 1.0 if loaded else 0.0
	var pitch: float = 1.0 if loaded else 0.0
	(display.surfaces["Aileron_R"] as Node3D).rotation.x = -roll * Aircraft.AILERON_TRAVEL
	(display.surfaces["Aileron_L"] as Node3D).rotation.x = roll * Aircraft.AILERON_TRAVEL
	for part in ["Elevator_L", "Elevator_R"]:
		(display.surfaces[part] as Node3D).rotation.x = -pitch * Aircraft.ELEVATOR_TRAVEL
	(display.surfaces["Rudder"] as Node3D).rotation.y = 0.5 * roll * Aircraft.RUDDER_TRAVEL
	var view: Dictionary = shot.view
	camera.position = view.eye
	camera.look_at(Vector3(0.0, 0.0, 0.6))


func _process(delta: float) -> bool:
	if index >= shots.size():
		return true
	var shot: Dictionary = shots[index]
	if settled < 0.0:
		_shot_setup(shot)
		settled = 0.0
		return false
	# Moved parts and the camera ease into place over a physics step (physics
	# interpolation), so let a few steps pass before saving the picture.
	settled += delta
	if settled < SETTLE_TIME:
		return false
	var file: String = "wings-%s-%s-%s.png" % [String(Airframes.spec(int(shot.id)).short).to_lower(),
		"loaded" if bool(shot.loaded) else "clean", String((shot.view as Dictionary).name)]
	stage.get_texture().get_image().save_png(out_dir.path_join(file))
	print("saved ", file)
	index += 1
	settled = -1.0
	return false
