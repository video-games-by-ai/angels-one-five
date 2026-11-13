class_name Aircraft
extends Node3D
## Visual aircraft: imported Blender model, metal skin, moving control surfaces,
## propeller blur, exhaust smoke, boost flames and wingtip vapour trails.

const TEAM_COLORS: Array[Color] = [Color("f2b33d"), Color("4db4f0"), Color("ff7a3d")]
const SURFACE_DEFLECTION: float = deg_to_rad(20.0)

var model_root: Node3D
var propeller: Node3D
var prop_disc: MeshInstance3D
var prop_material: ShaderMaterial
var surfaces: Dictionary = {}
var skin_material: ShaderMaterial
var muzzles: Array[Node3D] = []
var exhausts: Array[GPUParticles3D] = []
var flames: Array[GPUParticles3D] = []
var trails: Array[TipTrail] = []
var tips: Array[Node3D] = []
var prop_angle: float = 0.0
var disc_spin: float = 0.0


func build(spec: Dictionary, team: int) -> void:
	var scene: PackedScene = load(String(spec.model))
	model_root = scene.instantiate()
	add_child(model_root)
	skin_material = ShaderMaterial.new()
	skin_material.shader = load("res://shaders/aircraft_skin.gdshader")
	var frame_material: ShaderMaterial = skin_material.duplicate()
	frame_material.set_shader_parameter("base_color", Color(0.45, 0.47, 0.49))
	frame_material.set_shader_parameter("seam_strength", 0.0)
	var accent: StandardMaterial3D = StandardMaterial3D.new()
	accent.albedo_color = TEAM_COLORS[clampi(team, 0, TEAM_COLORS.size() - 1)]
	accent.roughness = 0.42
	accent.metallic = 0.1
	var glass: StandardMaterial3D = StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.albedo_color = Color(0.55, 0.66, 0.72, 0.22)
	glass.roughness = 0.03
	glass.metallic_specular = 0.9
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	var replacements: Dictionary = {"Skin": skin_material, "Frame": frame_material, "Accent": accent, "Glass": glass}
	for node in model_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = node
		for i in range(mesh_instance.mesh.get_surface_count()):
			var mat: Material = mesh_instance.mesh.surface_get_material(i)
			if mat != null and replacements.has(mat.resource_name):
				mesh_instance.set_surface_override_material(i, replacements[mat.resource_name])
			elif mat is StandardMaterial3D and mat.resource_name.begins_with("Insignia"):
				var insignia: StandardMaterial3D = mat.duplicate()
				insignia.metallic = 0.0
				insignia.roughness = 0.6
				mesh_instance.set_surface_override_material(i, insignia)
		if mesh_instance.name.begins_with("Roundel"):
			mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	propeller = model_root.find_child("Propeller", true, false)
	for part in ["Aileron_L", "Aileron_R", "Elevator_L", "Elevator_R", "Rudder"]:
		var n: Node3D = model_root.find_child(part, true, false)
		if n != null:
			surfaces[part] = n
	for tag in ["L", "R"]:
		var muzzle: Node3D = model_root.find_child("Muzzle_" + tag, true, false)
		if muzzle != null:
			muzzles.append(muzzle)
		var port: Node3D = model_root.find_child("ExhaustPort_" + tag, true, false)
		if port != null:
			exhausts.append(_exhaust_smoke(port))
			flames.append(_boost_flame(port))
		var tip: Node3D = model_root.find_child("WingTip_" + tag, true, false)
		if tip != null:
			tips.append(tip)
			var trail: TipTrail = TipTrail.new()
			add_child(trail)
			trails.append(trail)
	_build_prop_disc()


func _build_prop_disc() -> void:
	if propeller == null:
		return
	prop_material = ShaderMaterial.new()
	prop_material.shader = load("res://shaders/prop_disc.gdshader")
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(3.45, 3.45)
	prop_disc = MeshInstance3D.new()
	prop_disc.mesh = quad
	prop_disc.material_override = prop_material
	prop_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	propeller.add_child(prop_disc)


## Per-frame visual update from the simulated state.
func animate(model: FlightModel, delta: float) -> void:
	var rpm_ratio: float = clampf(0.55 + model.throttle * 0.4 + (0.15 if model.boosting else 0.0), 0.0, 1.2)
	# Blades turn at a visible "camera strobe" rate; the disc carries the blur.
	prop_angle = wrapf(prop_angle + delta * TAU * (1.1 + rpm_ratio * 0.9), 0.0, TAU)
	disc_spin += delta * 40.0 * rpm_ratio
	if propeller != null:
		propeller.rotation.z = -prop_angle
		prop_material.set_shader_parameter("spin", disc_spin)
	var c: Vector3 = model.controls
	if surfaces.has("Aileron_R"):
		(surfaces["Aileron_R"] as Node3D).rotation.x = -c.z * SURFACE_DEFLECTION
	if surfaces.has("Aileron_L"):
		(surfaces["Aileron_L"] as Node3D).rotation.x = c.z * SURFACE_DEFLECTION
	for part in ["Elevator_L", "Elevator_R"]:
		if surfaces.has(part):
			(surfaces[part] as Node3D).rotation.x = -c.x * SURFACE_DEFLECTION
	if surfaces.has("Rudder"):
		(surfaces["Rudder"] as Node3D).rotation.y = c.y * SURFACE_DEFLECTION
	for flame in flames:
		flame.emitting = model.boosting
	for smoke in exhausts:
		smoke.amount_ratio = 0.55 + model.throttle * 0.45
	var vapour: float = clampf((model.g_load - 2.6) / 3.0, 0.0, 1.0) + clampf((model.speed - 175.0) / 30.0, 0.0, 0.5)
	for i in range(trails.size()):
		trails[i].push(tips[i].get_global_transform_interpolated().origin, vapour, delta)


func set_hit_flash(amount: float) -> void:
	skin_material.set_shader_parameter("hit_flash", amount)


func reset_effects() -> void:
	for trail in trails:
		trail.clear()
	for smoke in exhausts:
		smoke.restart()


static func _soft_dot() -> GradientTexture2D:
	var gradient: Gradient = Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	var texture: GradientTexture2D = GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(0.5, 0.0)
	texture.width = 64
	texture.height = 64
	return texture


func _exhaust_smoke(port: Node3D) -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.amount = 40
	p.lifetime = 1.1
	p.local_coords = false
	p.fixed_fps = 0
	p.visibility_aabb = AABB(Vector3(-60, -60, -60), Vector3(120, 120, 120))
	var process: ParticleProcessMaterial = ParticleProcessMaterial.new()
	process.direction = Vector3(1.0 if port.position.x > 0 else -1.0, 0.0, 0.6)
	process.spread = 12.0
	process.initial_velocity_min = 3.0
	process.initial_velocity_max = 6.0
	process.gravity = Vector3(0, 0.6, 0)
	process.damping_min = 1.0
	process.damping_max = 2.0
	process.scale_min = 0.35
	process.scale_max = 0.55
	var scale_curve: Curve = Curve.new()
	scale_curve.add_point(Vector2(0, 0.4))
	scale_curve.add_point(Vector2(1, 2.6))
	var scale_tex: CurveTexture = CurveTexture.new()
	scale_tex.curve = scale_curve
	process.scale_curve = scale_tex
	var ramp: Gradient = Gradient.new()
	ramp.set_color(0, Color(0.32, 0.31, 0.30, 0.38))
	ramp.set_color(1, Color(0.55, 0.55, 0.56, 0.0))
	var ramp_tex: GradientTexture1D = GradientTexture1D.new()
	ramp_tex.gradient = ramp
	process.color_ramp = ramp_tex
	p.process_material = process
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _soft_dot()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	quad.material = mat
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	port.add_child(p)
	return p


func _boost_flame(port: Node3D) -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.amount = 24
	p.lifetime = 0.09
	p.local_coords = true
	p.emitting = false
	var process: ParticleProcessMaterial = ParticleProcessMaterial.new()
	process.direction = Vector3(1.0 if port.position.x > 0 else -1.0, 0.0, 0.9)
	process.spread = 8.0
	process.initial_velocity_min = 9.0
	process.initial_velocity_max = 14.0
	process.gravity = Vector3.ZERO
	process.scale_min = 0.18
	process.scale_max = 0.3
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(0.02, 0.02, 0.55)
	var ramp: Gradient = Gradient.new()
	ramp.set_color(0, Color(1.0, 0.85, 0.45, 1.0))
	ramp.set_color(1, Color(1.0, 0.35, 0.08, 0.0))
	var ramp_tex: GradientTexture1D = GradientTexture1D.new()
	ramp_tex.gradient = ramp
	process.color_ramp = ramp_tex
	p.process_material = process
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _soft_dot()
	mat.albedo_color = Color(2.5, 1.6, 0.8)
	quad.material = mat
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	port.add_child(p)
	return p
