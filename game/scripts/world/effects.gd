class_name Effects
extends Node3D
## One-shot effects: aircraft explosions (fireball, smoke column, sparks, flash
## and a boom heard across the valley), bullet strikes on metal (a flash, a
## spray of sparks, chips and a puff of smoke), and dust or water thrown up
## where rounds hit the ground or the lake. Strike effects are drawn larger the
## further away they are, so hits and misses can be read at gun range.

const FAR_GROWTH: float = 0.004     ## strike effects grow by this share per metre of distance
const FAR_MAX: float = 3.0          ## up to this many times life size

var dot_texture: GradientTexture2D
var water_level: float = -INF       ## rounds landing at this height splash instead of raising dust
var boom: AudioStream
var spark_cooldown: float = 0.0
var puff_cooldown: float = 0.0


func _ready() -> void:
	dot_texture = Aircraft._soft_dot()
	boom = load("res://assets/audio/explosion.wav")


func _process(delta: float) -> void:
	spark_cooldown = maxf(spark_cooldown - delta, 0.0)
	puff_cooldown = maxf(puff_cooldown - delta, 0.0)


## A round striking an aircraft: a white flash, sparks flying off as streaks,
## dark chips of metal and a small puff of smoke.
func sparks(at: Vector3) -> void:
	if spark_cooldown > 0.0:
		return
	spark_cooldown = 0.045
	var far: float = _far_scale(at)
	var root: Node3D = _root(at, 1.3)
	_flash(root, 1.25 * far, 0.1, Color(2.8, 2.0, 1.0))
	root.add_child(_streaks(_burst(14, 0.34, Color(1.0, 0.92, 0.66, 1.0), Color(1.0, 0.42, 0.08, 0.0), 0.5 * far, 0.18 * far, true, 34.0, Vector3(0, -9.0, 0)), 0.3, 2.2))
	root.add_child(_burst(5, 1.1, Color(0.1, 0.1, 0.1, 0.95), Color(0.14, 0.13, 0.12, 0.0), 0.16 * far, 0.1 * far, false, 15.0, Vector3(0, -16.0, 0)))
	root.add_child(_burst(4, 0.7, Color(0.25, 0.24, 0.23, 0.5), Color(0.4, 0.4, 0.4, 0.0), 1.2 * far, 3.8 * far, false, 5.0))


## A round striking the ground (a jet of dust and a slower cloud) or the lake
## (a white column of spray that falls back).
func puff(at: Vector3) -> void:
	if puff_cooldown > 0.0:
		return
	puff_cooldown = 0.07
	var far: float = _far_scale(at)
	if at.y <= water_level + 0.8:
		var splash: Node3D = _root(Vector3(at.x, water_level + 0.2, at.z), 1.9)
		splash.add_child(_burst(12, 0.95, Color(0.96, 0.98, 1.0, 0.85), Color(0.9, 0.95, 1.0, 0.0), 0.7 * far, 1.6 * far, false, 17.0, Vector3(0, -24.0, 0), 16.0))
		splash.add_child(_burst(8, 1.5, Color(0.92, 0.96, 1.0, 0.5), Color(0.9, 0.95, 1.0, 0.0), 1.2 * far, 4.2 * far, false, 4.0, Vector3(0, 0.4, 0), 85.0))
		return
	var root: Node3D = _root(at + Vector3(0, 0.5, 0), 2.2)
	_flash(root, 0.9 * far, 0.07, Color(2.2, 1.6, 0.9))
	root.add_child(_burst(8, 0.8, Color(0.6, 0.54, 0.45, 0.7), Color(0.7, 0.66, 0.6, 0.0), 0.8 * far, 2.6 * far, false, 15.0, Vector3(0, -8.0, 0), 22.0))
	root.add_child(_burst(7, 1.8, Color(0.72, 0.66, 0.56, 0.5), Color(0.8, 0.76, 0.7, 0.0), 1.6 * far, 6.0 * far, false, 5.0, Vector3(0, 1.6, 0), 70.0))


## How much larger than life to draw a strike `at`, for the current camera.
func _far_scale(at: Vector3) -> float:
	var camera: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return 1.0
	return far_scale(camera.global_position.distance_to(at) / ChaseCamera.magnification(camera.fov))


static func far_scale(apparent_distance: float) -> float:
	return clampf(1.0 + (apparent_distance - 150.0) * FAR_GROWTH, 1.0, FAR_MAX)


## A glow that swells and is gone within `seconds`.
func _flash(root: Node3D, size: float, seconds: float, colour: Color) -> void:
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2.ONE * size
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.no_depth_test = true
	mat.albedo_texture = dot_texture
	mat.albedo_color = colour
	quad.material = mat
	var flash: MeshInstance3D = MeshInstance3D.new()
	flash.mesh = quad
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.scale = Vector3.ONE * 0.5
	root.add_child(flash)
	var tween: Tween = flash.create_tween()
	tween.set_parallel(true)
	tween.tween_property(flash, "scale", Vector3.ONE * 1.5, seconds)
	tween.tween_property(mat, "albedo_color", Color(colour.r, colour.g, colour.b, 0.0), seconds)
	tween.chain().tween_callback(flash.queue_free)


## Turn a burst's round dots into streaks drawn along each particle's motion.
func _streaks(p: GPUParticles3D, thickness: float, length: float) -> GPUParticles3D:
	p.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	var quad: QuadMesh = p.draw_pass_1
	quad.size = Vector2(thickness, length)
	(quad.material as StandardMaterial3D).billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	(quad.material as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
	return p


func _root(at: Vector3, lifetime: float) -> Node3D:
	var root: Node3D = Node3D.new()
	root.top_level = true
	add_child(root)
	root.global_position = at
	root.reset_physics_interpolation()
	get_tree().create_timer(lifetime).timeout.connect(root.queue_free)
	return root


func explosion(at: Vector3, scale_factor: float = 1.0) -> void:
	var root: Node3D = Node3D.new()
	root.top_level = true
	add_child(root)
	root.global_position = at
	root.add_child(_burst(26, 0.7, Color(1.0, 0.75, 0.35, 1.0), Color(0.9, 0.2, 0.05, 0.0), 4.5 * scale_factor, 9.0 * scale_factor, true, 14.0))
	root.add_child(_burst(22, 4.5, Color(0.16, 0.14, 0.13, 0.75), Color(0.35, 0.34, 0.33, 0.0), 6.0 * scale_factor, 18.0 * scale_factor, false, 5.0, Vector3(0, 3.0, 0)))
	root.add_child(_streaks(_burst(48, 1.2, Color(1.0, 0.85, 0.5, 1.0), Color(1.0, 0.4, 0.1, 0.0), 0.5, 0.25, true, 42.0, Vector3(0, -12.0, 0)), 0.3, 2.6))
	_flash(root, 26.0 * scale_factor, 0.22, Color(3.4, 2.4, 1.3))
	var flash: OmniLight3D = OmniLight3D.new()
	flash.light_color = Color(1.0, 0.7, 0.4)
	flash.light_energy = 14.0
	flash.omni_range = 140.0 * scale_factor
	root.add_child(flash)
	var tween: Tween = create_tween()
	tween.tween_property(flash, "light_energy", 0.0, 0.5)
	var sound: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
	sound.stream = boom
	sound.bus = GameSettings.BUS_EFFECTS
	sound.unit_size = 160.0
	sound.max_distance = 6000.0
	sound.volume_db = 6.0
	sound.pitch_scale = randf_range(0.9, 1.1)
	root.add_child(sound)
	sound.play()
	get_tree().create_timer(7.0).timeout.connect(root.queue_free)


## One puff of particles thrown out at once. `spread` is the half-angle of the
## cone around straight up, in degrees (180 = every direction).
func _burst(amount: int, life: float, start: Color, end: Color, size_from: float, size_to: float, additive: bool, speed: float,
		gravity: Vector3 = Vector3.ZERO, spread: float = 180.0) -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 0.92
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-100, -100, -100), Vector3(200, 200, 200))
	var process: ParticleProcessMaterial = ParticleProcessMaterial.new()
	process.direction = Vector3.UP
	process.spread = spread
	process.initial_velocity_min = speed * 0.4
	process.initial_velocity_max = speed
	process.gravity = gravity
	process.damping_min = 2.0
	process.damping_max = 4.0
	process.scale_min = size_from
	process.scale_max = size_from * 1.4
	var curve: Curve = Curve.new()
	curve.add_point(Vector2(0, 0.6))
	curve.add_point(Vector2(1, size_to / maxf(size_from, 0.01)))
	curve.max_value = maxf(size_to / maxf(size_from, 0.01), 1.0)
	var curve_tex: CurveTexture = CurveTexture.new()
	curve_tex.curve = curve
	process.scale_curve = curve_tex
	var ramp: Gradient = Gradient.new()
	ramp.set_color(0, start)
	ramp.set_color(1, end)
	var ramp_tex: GradientTexture1D = GradientTexture1D.new()
	ramp_tex.gradient = ramp
	process.color_ramp = ramp_tex
	p.process_material = process
	var quad: QuadMesh = QuadMesh.new()
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = dot_texture
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(3.0, 2.2, 1.4)
	quad.material = mat
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.emitting = true
	return p
