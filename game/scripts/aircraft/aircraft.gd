class_name Aircraft
extends Node3D
## Visual aircraft: imported Blender model, painted or bare-metal skin, moving
## control surfaces, propeller blur, exhaust smoke, boost flames, wingtip vapour
## trails, muzzle flashes, smoke from hot guns, a flight-path trail and
## battle-damage smoke and fire that darken with the hull, and (for other
## aircraft) its own engine and gun sounds in the world. Other aircraft are drawn
## a little larger the further away they are, so they stay readable at range.

const TEAM_COLORS: Array[Color] = [Color("f2b33d"), Color("4db4f0"), Color("ff7a3d")]
## Full travel of each control surface. Larger than the aircraft really used,
## so the movement reads from the chase camera.
const AILERON_TRAVEL: float = deg_to_rad(20.0)
const ELEVATOR_TRAVEL: float = deg_to_rad(28.0)
const RUDDER_TRAVEL: float = deg_to_rad(30.0)
const FLAP_RATE: float = 0.7          ## share of full flap travel per second
const COMBAT_FLAPS: float = 0.6       ## how far down the flaps go in a turn, share of full travel
const COMBAT_FROM: float = 0.1        ## share of the hardest pull at which they start to drop
const COMBAT_FULL: float = 0.5        ## share of the hardest pull at which they are at COMBAT_FLAPS
## The wings bend like a spring: about two swings a second, settling within a
## couple of overshoots once the load changes.
const FLEX_FREQUENCY: float = 2.2
const FLEX_DAMPING: float = 0.3
## Load at which the tips rise the aircraft's full `flex`: the hardest pull the
## game's aircraft make (they turn far tighter than the real ones could).
const FLEX_FULL_LOAD: float = 18.0
const FLEX_LEAST: float = -0.25       ## pushing below 1 g bends them down, this share at most
const BUFFET: float = 0.06            ## stall buffet, metres at the tips
const SPOT_FROM: float = 700.0      ## metres: beyond this a distant aircraft is drawn larger
const SPOT_SHARE: float = 0.6       ## how much of the shrinking with distance is made up for
const SPOT_MAX: float = 2.5         ## never drawn larger than this
const FLASH_TIME: float = 0.05

## Where the player listens from, for the pitch of aircraft flying past.
static var listener_position: Vector3 = Vector3.ZERO
static var listener_velocity: Vector3 = Vector3.ZERO
static var flame_mesh: ArrayMesh

var model_root: Node3D
var propeller: Node3D
var prop_disc: MeshInstance3D
var prop_material: ShaderMaterial
var surfaces: Dictionary = {}
var flaps: Array[Node3D] = []
var flap_angle: float = 0.0
var flap_slide: float = 0.0                ## metres the flaps move back when fully down
var flap_rest: Array[Vector3] = []
var flap_amount: float = 0.0               ## 0 = up, 1 = fully down
var flex_meshes: Array[MeshInstance3D] = []
var flex_shapes: PackedInt32Array = PackedInt32Array()
var flex_tip: float = 0.0                  ## metres the tips rise in the hardest pull
var flex_bend: float = 0.0                 ## metres the tips are bent up right now
var flex_speed: float = 0.0
var flex_shown: float = 0.0                ## bend last given to the meshes
var felt_load: float = 1.0                 ## g felt along the aircraft's up axis, measured from its motion
var last_velocity: Vector3 = Vector3.ZERO
var load_time: float = 0.0
var load_measured: bool = false
var buffet_phase: float = 0.0
var skin_material: ShaderMaterial
var muzzles: Array[Node3D] = []
var exhausts: Array[GPUParticles3D] = []
var flames: Array[GPUParticles3D] = []
var trails: Array[TipTrail] = []
var tips: Array[Node3D] = []
var flashes: Array[Node3D] = []
var flash_light: OmniLight3D
var gun_smoke: Array[GPUParticles3D] = []
var enlarge: bool = false                  ## draw larger at range (aircraft other than the player's)
var damage_smoke: GPUParticles3D
var damage_fire: GPUParticles3D
var smoke_material: StandardMaterial3D
var fire_process: ParticleProcessMaterial
var fire_glow: MeshInstance3D
var damage_trail: DamageTrail
var trail_anchor: Vector3 = Vector3.ZERO   ## where the trail leaves the airframe, in its own space
var fire_level: float = 0.0                ## 0 = no fire, 1 = fully ablaze
var engine_voices: Array[AudioStreamPlayer3D] = []   ## low-revs loop, high-revs loop
var gun_voice: AudioStreamPlayer3D
var voice_rpm: float = 0.85
var voice_doppler: float = 1.0
var prop_angle: float = 0.0
var disc_spin: float = 0.0
var flash_time: float = 0.0
var gun_pitch: float = 1.0


## `effects` adds particles, trails and flashes (off for the hangar display);
## `voiced` gives the aircraft its own engine and gun sounds in the world, for
## aircraft other than the player's.
func build(spec: Dictionary, team: int, effects: bool = true, voiced: bool = false) -> void:
	var scene: PackedScene = load(String(spec.model))
	model_root = scene.instantiate()
	add_child(model_root)
	skin_material = ShaderMaterial.new()
	skin_material.shader = load("res://shaders/aircraft_skin.gdshader")
	var paint: Dictionary = spec.paint
	for key: String in paint:
		skin_material.set_shader_parameter(key, paint[key])
	var frame_material: ShaderMaterial = ShaderMaterial.new()
	frame_material.shader = skin_material.shader
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
		# Keeps the paint pattern continuous across parts that have their own origin.
		mesh_instance.set_instance_shader_parameter("part_offset", _offset_in_model(mesh_instance))
		var shape: int = mesh_instance.find_blend_shape_by_name(&"Flex")
		if shape >= 0:
			mesh_instance.set_blend_shape_value(shape, 0.0)
			flex_meshes.append(mesh_instance)
			flex_shapes.append(shape)
	propeller = model_root.find_child("Propeller", true, false)
	for part in ["Aileron_L", "Aileron_R", "Elevator_L", "Elevator_R", "Rudder"]:
		var n: Node3D = model_root.find_child(part, true, false)
		if n != null:
			surfaces[part] = n
	for n in model_root.find_children("Flap_*", "Node3D", true, false):
		flaps.append(n)
		flap_rest.append((n as Node3D).position)
	flap_angle = deg_to_rad(float(spec.flap_angle))
	flap_slide = float(spec.flap_slide)
	flex_tip = float(spec.flex)
	# Shown again for a new life: start clean rather than read the jump as a load.
	visibility_changed.connect(func() -> void:
		if visible:
			reset_pose())
	for tag in ["L", "R"]:
		var muzzle: Node3D = model_root.find_child("Muzzle_" + tag, true, false)
		if muzzle != null:
			muzzles.append(muzzle)
			if effects:
				flashes.append(_muzzle_flash(muzzle))
				gun_smoke.append(_gun_smoke(muzzle))
		var port: Node3D = model_root.find_child("ExhaustPort_" + tag, true, false)
		if port != null and effects:
			exhausts.append(_exhaust_smoke(port))
			flames.append(_boost_flame(port))
		var tip: Node3D = model_root.find_child("WingTip_" + tag, true, false)
		if tip != null and effects:
			tips.append(tip)
			var trail: TipTrail = TipTrail.new()
			add_child(trail)
			trails.append(trail)
	if effects and not flashes.is_empty():
		# The guns light up the wings and nose for an instant.
		flash_light = OmniLight3D.new()
		flash_light.light_color = Color(1.0, 0.72, 0.4)
		flash_light.light_energy = 3.0
		flash_light.omni_range = 9.0
		flash_light.shadow_enabled = false
		flash_light.position = Vector3(0.0, 0.9, (spec.muzzles[0] as Vector3).z - 1.0)
		flash_light.visible = false
		add_child(flash_light)
	if effects:
		_build_prop_disc(float(spec.prop_radius))
		_build_damage_effects(float(spec.smoke_z))
		_build_trail(float(spec.tail_z))
	if voiced:
		gun_pitch = float(spec.gun_pitch)
		enlarge = true
		for high: bool in [false, true]:
			var voice: AudioStreamPlayer3D = _voice(Sfx.engine_loop(spec, high), -60.0, 55.0, 1, GameSettings.BUS_ENGINE)
			voice.attenuation_filter_cutoff_hz = 4000.0   # distance takes the edge off first
			voice.play()
			engine_voices.append(voice)
		gun_voice = _voice(Sfx.gun_stream(spec), 2.0, 70.0, 6, GameSettings.BUS_EFFECTS)


func _offset_in_model(node: Node3D) -> Vector3:
	var t: Transform3D = Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != model_root:
		t = (n as Node3D).transform * t
		n = n.get_parent()
	return t.origin


func _voice(stream: AudioStream, volume_db: float, unit_size: float, polyphony: int, bus: StringName) -> AudioStreamPlayer3D:
	var player: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
	player.bus = bus
	player.stream = stream
	player.volume_db = volume_db
	player.unit_size = unit_size
	player.max_distance = 3200.0
	player.max_polyphony = polyphony
	player.attenuation_filter_cutoff_hz = 9000.0
	add_child(player)
	return player


func _build_prop_disc(radius: float) -> void:
	if propeller == null:
		return
	prop_material = ShaderMaterial.new()
	prop_material.shader = load("res://shaders/prop_disc.gdshader")
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(radius * 2.0 + 0.05, radius * 2.0 + 0.05)
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
		if prop_material != null:
			prop_material.set_shader_parameter("spin", disc_spin)
	var c: Vector3 = model.controls
	if surfaces.has("Aileron_R"):
		(surfaces["Aileron_R"] as Node3D).rotation.x = -c.z * AILERON_TRAVEL
	if surfaces.has("Aileron_L"):
		(surfaces["Aileron_L"] as Node3D).rotation.x = c.z * AILERON_TRAVEL
	for part in ["Elevator_L", "Elevator_R"]:
		if surfaces.has(part):
			(surfaces[part] as Node3D).rotation.x = -c.x * ELEVATOR_TRAVEL
	if surfaces.has("Rudder"):
		(surfaces["Rudder"] as Node3D).rotation.y = c.y * RUDDER_TRAVEL
	_measure_load(model, delta)
	flap_amount = move_toward(flap_amount, flap_target(model.speed, felt_load, model.spec), FLAP_RATE * delta)
	_pose_flaps()
	_flex_wings(model.near_stall(), delta)
	for flame in flames:
		flame.emitting = model.boosting
	for smoke in exhausts:
		smoke.amount_ratio = 0.55 + model.throttle * 0.45
	var vapour: float = TipTrail.vapour_strength(model.g_load, model.speed, float(model.spec.top_speed), float(model.spec.boost_speed))
	for i in range(trails.size()):
		# The ribbon leaves the bent tip, not where the straight wing would end.
		var tip: Transform3D = tips[i].get_global_transform_interpolated()
		trails[i].push(tip.origin + tip.basis.y * flex_bend, vapour, delta)
	if damage_trail != null:
		damage_trail.push(get_global_transform_interpolated() * trail_anchor, model.hull_ratio(), delta)
	_update_fire_glow()
	flash_time = maxf(flash_time - delta, 0.0)
	for flash in flashes:
		flash.visible = flash_time > 0.0
	if flash_light != null:
		flash_light.visible = flash_time > 0.0
	# Hot guns smoke, most just after they stop.
	for smoke in gun_smoke:
		smoke.emitting = model.gun_heat > 0.45
		smoke.amount_ratio = clampf((model.gun_heat - 0.45) / 0.55, 0.15, 1.0)
	if enlarge:
		var camera: Camera3D = get_viewport().get_camera_3d()
		if camera != null:
			var apparent: float = camera.global_position.distance_to(global_position) / ChaseCamera.magnification(camera.fov)
			model_root.scale = Vector3.ONE * spot_scale(apparent)
	if not engine_voices.is_empty():
		# Two loops crossfaded by RPM, as for the player's own engine, shifted in
		# pitch by how fast the aircraft closes on or leaves the listener.
		voice_rpm = lerpf(voice_rpm, Sfx.engine_rpm(model), 1.0 - exp(-delta * 3.0))
		voice_doppler = lerpf(voice_doppler, Sfx.doppler(model.position, model.velocity(), listener_position, listener_velocity), 1.0 - exp(-delta * 8.0))
		var layers: PackedFloat32Array = Sfx.engine_layers(voice_rpm)
		for i in range(2):
			engine_voices[i].pitch_scale = layers[i * 2] * voice_doppler
			engine_voices[i].volume_db = 5.5 + linear_to_db(maxf(layers[i * 2 + 1], 0.001))


## How far the flaps should be down, 0..1, for an aircraft of `spec` flying at
## `speed` and pulling `load` g. Slow flight brings them fully down (all the way
## at 1.2 times the stall speed, none above twice it). A turn drops them part way
## as combat flaps, by how hard the aircraft is pulling compared with the hardest
## pull it can make at that speed, so a firm turn shows them on every aircraft:
## none in a gentle turn, COMBAT_FLAPS from COMBAT_FULL of the hardest pull. They
## go no further than that below 80% of the aircraft's top speed, less and less
## above it, and stay up at its boost speed.
static func flap_target(speed: float, load: float, spec: Dictionary) -> float:
	var stall: float = float(spec.stall)
	var slow: float = clampf((stall * 2.0 - speed) / (stall * 0.8), 0.0, 1.0)
	var hardest: float = float(spec.pitch_rate) * maxf(speed, stall) / FlightModel.GRAVITY
	var pull: float = clampf(((load - 1.0) / hardest - COMBAT_FROM) / (COMBAT_FULL - COMBAT_FROM), 0.0, 1.0)
	var boost: float = float(spec.boost_speed)
	var fast: float = clampf((boost - speed) / (boost - float(spec.top_speed) * 0.8), 0.0, 1.0)
	return maxf(slow, COMBAT_FLAPS * pull * fast)


## How far the tips should rise, in metres, under `load` g for wings that rise
## `flex` at FLEX_FULL_LOAD. Straight at 1 g, the shape they were built in.
static func flex_target(load: float, flex: float) -> float:
	return flex * clampf((load - 1.0) / (FLEX_FULL_LOAD - 1.0), FLEX_LEAST, 1.0)


## The g the wings carry, measured from how the aircraft's motion changes, so it
## works the same for aircraft copied from the network (they carry no g). Level
## flight reads 1, a level 60° banked turn 2, a push over less than 1.
func _measure_load(model: FlightModel, delta: float) -> void:
	var v: Vector3 = model.velocity()
	load_time += delta
	if not load_measured:
		last_velocity = v
		load_measured = true
		load_time = 0.0
		return
	if v == last_velocity:
		return   # no new physics step since the last frame
	var accel: Vector3 = (v - last_velocity) / maxf(load_time, 0.001)
	var up: Vector3 = model.orientation * Vector3.UP
	var load: float = clampf((accel + Vector3.UP * FlightModel.GRAVITY).dot(up) / FlightModel.GRAVITY, -5.0, 25.0)
	# Smoothed over the time since the last measurement, not the frame: several
	# frames are drawn per physics step on a fast display.
	felt_load = lerpf(felt_load, load, 1.0 - exp(-load_time * 8.0))
	last_velocity = v
	load_time = 0.0


## Bend the wings toward the load on a damped spring, with a shudder near the stall.
func _flex_wings(buffeting: bool, delta: float) -> void:
	if flex_meshes.is_empty():
		return
	var target: float = flex_target(felt_load, flex_tip)
	var w: float = TAU * FLEX_FREQUENCY
	var steps: int = ceili(delta / (1.0 / 120.0))
	var h: float = delta / maxf(steps, 1)
	for i in range(steps):
		flex_speed += (w * w * (target - flex_bend) - 2.0 * FLEX_DAMPING * w * flex_speed) * h
		flex_bend += flex_speed * h
	var shown: float = flex_bend
	if buffeting:
		buffet_phase += delta
		shown += BUFFET * (sin(buffet_phase * 41.0) * 0.6 + sin(buffet_phase * 67.0 + 1.3) * 0.4)
	if absf(shown - flex_shown) < 0.001:
		return   # settled: leave the meshes alone
	flex_shown = shown
	for i in range(flex_meshes.size()):
		flex_meshes[i].set_blend_shape_value(flex_shapes[i], shown)


## Swing the flaps down by `flap_amount`, sliding them back as they go so the slot
## ahead of them opens and reads from above.
func _pose_flaps() -> void:
	for i in range(flaps.size()):
		flaps[i].rotation.x = flap_amount * flap_angle
		flaps[i].position = flap_rest[i] + Vector3(0.0, -0.2, 1.0) * flap_slide * flap_amount


## Put the flaps up, the wings straight and the load back to 1 g (a new life).
func reset_pose() -> void:
	flap_amount = 0.0
	flex_bend = 0.0
	flex_speed = 0.0
	flex_shown = 0.0
	felt_load = 1.0
	load_measured = false
	_pose_flaps()
	for i in range(flex_meshes.size()):
		flex_meshes[i].set_blend_shape_value(flex_shapes[i], 0.0)


## How much larger than life an aircraft `apparent_distance` metres away is drawn
## (the distance as it looks: real distance divided by the zoom). Up close it is
## true to size; beyond SPOT_FROM it grows so that it shrinks on screen only
## 40% as fast as it should, up to SPOT_MAX. Hits are judged on the true size.
static func spot_scale(apparent_distance: float) -> float:
	return clampf(lerpf(1.0, apparent_distance / SPOT_FROM, SPOT_SHARE), 1.0, SPOT_MAX)


## Slow turntable idle for the hangar display.
func idle(delta: float) -> void:
	prop_angle = wrapf(prop_angle + delta * 1.6, 0.0, TAU)
	if propeller != null:
		propeller.rotation.z = -prop_angle


## Called for each step in which the guns fired.
func show_gunfire() -> void:
	flash_time = FLASH_TIME
	for flash in flashes:
		# A different tongue of flame every shot.
		flash.scale = Vector3(randf_range(0.75, 1.2), randf_range(0.75, 1.2), randf_range(0.7, 1.45))
		flash.rotation.z = randf() * TAU
	if gun_voice != null:
		gun_voice.pitch_scale = gun_pitch
		gun_voice.play()


func set_hit_flash(amount: float) -> void:
	skin_material.set_shader_parameter("hit_flash", amount)


## Smoke from the engine below 60% hull, light grey turning black as the hull
## is shot away, and fire below 40% (1 = intact). Matches DamageTrail's stages.
func set_damage(hull_ratio: float) -> void:
	if damage_smoke == null:
		return
	damage_smoke.emitting = hull_ratio < 0.6
	damage_smoke.amount_ratio = clampf((0.6 - hull_ratio) / 0.45, 0.2, 1.0)
	var shade: float = clampf(remap(hull_ratio, 0.6, 0.1, 0.9, 0.1), 0.1, 0.9)
	smoke_material.albedo_color = Color(shade, shade, shade)
	fire_level = clampf(remap(hull_ratio, 0.4, 0.1, 0.25, 1.0), 0.0, 1.0) if hull_ratio < 0.4 else 0.0
	damage_fire.emitting = fire_level > 0.0
	damage_fire.amount_ratio = clampf(fire_level, 0.3, 1.0)
	fire_process.scale_min = lerpf(0.22, 0.42, fire_level)
	fire_process.scale_max = fire_process.scale_min * 1.5
	skin_material.set_shader_parameter("scorch", clampf((0.6 - hull_ratio) * 0.9, 0.0, 0.45))


## A soft glow over the fire that keeps a few pixels on screen at any range, so a
## burning aircraft is seen from far away.
func _update_fire_glow() -> void:
	if fire_glow == null:
		return
	fire_glow.visible = fire_level > 0.0
	if not fire_glow.visible:
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	var distance: float = camera.global_position.distance_to(fire_glow.global_position) if camera != null else 0.0
	var flicker: float = 0.85 + 0.15 * sin(Time.get_ticks_msec() * 0.031) * sin(Time.get_ticks_msec() * 0.017)
	fire_glow.scale = Vector3.ONE * lerpf(0.5, 1.0, fire_level) * maxf(1.0, distance * 0.005) * flicker


## While the aircraft is gone its trail keeps fading out where it was flown.
func _process(delta: float) -> void:
	if damage_trail != null and not visible:
		damage_trail.fade(delta)


func clear_trail() -> void:
	if damage_trail != null:
		damage_trail.clear()


func set_voice_enabled(on: bool) -> void:
	for voice in engine_voices:
		voice.stream_paused = not on


func reset_effects() -> void:
	for trail in trails:
		trail.clear()
	clear_trail()
	fire_level = 0.0
	if fire_glow != null:
		fire_glow.visible = false
	for smoke in exhausts:
		smoke.restart()
	if damage_smoke != null:
		damage_smoke.restart()
		damage_smoke.emitting = false
		damage_fire.emitting = false
	flash_time = 0.0
	for flash in flashes:
		flash.visible = false
	if flash_light != null:
		flash_light.visible = false
	for smoke in gun_smoke:
		smoke.restart()
		smoke.emitting = false
	voice_doppler = 1.0


## A tongue of flame along the barrel line with a soft glow at its root.
func _muzzle_flash(muzzle: Node3D) -> Node3D:
	var flash: Node3D = Node3D.new()
	flash.visible = false
	muzzle.add_child(flash)
	var tongue: MeshInstance3D = MeshInstance3D.new()
	tongue.mesh = _flame_mesh()
	tongue.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.add_child(tongue)
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.62, 0.62)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.albedo_texture = _soft_dot()
	mat.albedo_color = Color(3.0, 1.7, 0.6)
	quad.material = mat
	var glow: MeshInstance3D = MeshInstance3D.new()
	glow.mesh = quad
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glow.position = Vector3(0.0, 0.0, -0.3)
	flash.add_child(glow)
	return flash


## Two crossed quads 1.7 m long, root at the origin and tip toward -Z (the way
## the guns point), shared by every muzzle.
static func _flame_mesh() -> ArrayMesh:
	if flame_mesh != null:
		return flame_mesh
	var half: float = 0.32
	var length: float = 1.7
	var vertices: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()
	for axis: Vector3 in [Vector3.RIGHT, Vector3.UP]:
		var base: int = vertices.size()
		vertices.append_array([-axis * half, axis * half, axis * half + Vector3.FORWARD * length, -axis * half + Vector3.FORWARD * length])
		uvs.append_array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	flame_mesh = ArrayMesh.new()
	flame_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = load("res://shaders/muzzle_flame.gdshader")
	flame_mesh.surface_set_material(0, material)
	return flame_mesh


## Thin grey smoke curling off a hot gun, left behind in the airflow.
func _gun_smoke(muzzle: Node3D) -> GPUParticles3D:
	var p: GPUParticles3D = _trail_particles(20, 0.4, Color(0.8, 0.8, 0.8, 0.3), Color(0.9, 0.9, 0.9, 0.0), 0.16, 4.0, false)
	(p.process_material as ParticleProcessMaterial).gravity = Vector3(0, 0.5, 0)
	muzzle.add_child(p)
	return p


func _build_damage_effects(smoke_z: float) -> void:
	# Light puffs; set_damage darkens them through the material colour.
	damage_smoke = _trail_particles(70, 2.6, Color(0.86, 0.85, 0.84, 0.66), Color(0.92, 0.92, 0.92, 0.0), 0.9, 6.5, false)
	damage_smoke.position = Vector3(0.0, 0.1, smoke_z)
	add_child(damage_smoke)
	smoke_material = (damage_smoke.draw_pass_1 as QuadMesh).material
	damage_fire = _trail_particles(48, 0.32, Color(1.0, 0.76, 0.36, 0.95), Color(0.9, 0.22, 0.04, 0.0), 0.32, 2.6, true)
	damage_fire.position = Vector3(0.0, 0.1, smoke_z)
	add_child(damage_fire)
	fire_process = damage_fire.process_material
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(2.6, 2.6)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.albedo_texture = _soft_dot()
	mat.albedo_color = Color(2.4, 1.2, 0.35)
	quad.material = mat
	fire_glow = MeshInstance3D.new()
	fire_glow.mesh = quad
	fire_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fire_glow.position = Vector3(0.0, 0.2, smoke_z + 0.8)
	fire_glow.visible = false
	add_child(fire_glow)


## The flight-path line. It lives beside the aircraft rather than inside it, so
## it stays visible and fades out after the aircraft is hidden.
func _build_trail(tail_z: float) -> void:
	trail_anchor = Vector3(0.0, 0.15, tail_z + 1.8)
	damage_trail = DamageTrail.new()
	if is_inside_tree() and get_parent() != null:
		get_parent().add_child(damage_trail)
		tree_exiting.connect(damage_trail.queue_free)
	else:
		add_child(damage_trail)


## World-space particles left behind along the flight path.
func _trail_particles(amount: int, life: float, start: Color, end: Color, size_from: float, grow: float, additive: bool) -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.local_coords = false
	p.emitting = false
	p.visibility_aabb = AABB(Vector3(-400, -400, -400), Vector3(800, 800, 800))
	var process: ParticleProcessMaterial = ParticleProcessMaterial.new()
	process.direction = Vector3(0, 0.2, 1)
	process.spread = 25.0
	process.initial_velocity_min = 1.0
	process.initial_velocity_max = 4.0
	process.gravity = Vector3(0, 1.2, 0)
	process.scale_min = size_from
	process.scale_max = size_from * 1.5
	var scale_curve: Curve = Curve.new()
	scale_curve.max_value = grow
	scale_curve.add_point(Vector2(0, 1.0))
	scale_curve.add_point(Vector2(1, grow))
	var scale_tex: CurveTexture = CurveTexture.new()
	scale_tex.curve = scale_curve
	process.scale_curve = scale_tex
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
	mat.albedo_texture = _soft_dot()
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.7, 1.1, 0.6)
	else:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	quad.material = mat
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


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
