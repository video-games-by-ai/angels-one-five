class_name Effects
extends Node3D
## One-shot effects: aircraft explosions (fireball, smoke column, sparks, flash
## and a boom heard across the valley), bullet strikes on metal and dust kicked
## up where rounds hit the ground.

var dot_texture: GradientTexture2D
var boom: AudioStream
var spark_cooldown: float = 0.0
var puff_cooldown: float = 0.0


func _ready() -> void:
	dot_texture = Aircraft._soft_dot()
	boom = load("res://assets/audio/explosion.wav")


func _process(delta: float) -> void:
	spark_cooldown = maxf(spark_cooldown - delta, 0.0)
	puff_cooldown = maxf(puff_cooldown - delta, 0.0)


## Bright sparks where a round strikes an aircraft.
func sparks(at: Vector3) -> void:
	if spark_cooldown > 0.0:
		return
	spark_cooldown = 0.045
	var root: Node3D = _root(at, 0.9)
	root.add_child(_burst(10, 0.35, Color(1.0, 0.9, 0.6, 1.0), Color(1.0, 0.45, 0.1, 0.0), 0.5, 0.15, true, 26.0, Vector3(0, -9.0, 0)))
	root.add_child(_burst(4, 0.6, Color(0.25, 0.24, 0.23, 0.5), Color(0.4, 0.4, 0.4, 0.0), 1.2, 3.5, false, 5.0))


## Dust or spray where a round strikes the ground or the lake.
func puff(at: Vector3) -> void:
	if puff_cooldown > 0.0:
		return
	puff_cooldown = 0.07
	var root: Node3D = _root(at + Vector3(0, 0.5, 0), 1.6)
	root.add_child(_burst(6, 1.1, Color(0.72, 0.66, 0.56, 0.55), Color(0.8, 0.76, 0.7, 0.0), 1.6, 5.0, false, 7.0, Vector3(0, 2.0, 0)))


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
	root.add_child(_burst(48, 1.2, Color(1.0, 0.85, 0.5, 1.0), Color(1.0, 0.4, 0.1, 0.0), 0.35, 0.2, true, 38.0, Vector3(0, -12.0, 0)))
	var flash: OmniLight3D = OmniLight3D.new()
	flash.light_color = Color(1.0, 0.7, 0.4)
	flash.light_energy = 14.0
	flash.omni_range = 140.0 * scale_factor
	root.add_child(flash)
	var tween: Tween = create_tween()
	tween.tween_property(flash, "light_energy", 0.0, 0.5)
	var sound: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
	sound.stream = boom
	sound.unit_size = 160.0
	sound.max_distance = 6000.0
	sound.volume_db = 6.0
	sound.pitch_scale = randf_range(0.9, 1.1)
	root.add_child(sound)
	sound.play()
	get_tree().create_timer(7.0).timeout.connect(root.queue_free)


func _burst(amount: int, life: float, start: Color, end: Color, size_from: float, size_to: float, additive: bool, speed: float, gravity: Vector3 = Vector3.ZERO) -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 0.92
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-100, -100, -100), Vector3(200, 200, 200))
	var process: ParticleProcessMaterial = ParticleProcessMaterial.new()
	process.direction = Vector3.UP
	process.spread = 180.0
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
