class_name Weather
extends Node3D
## Test weather: a clear day with a few local snow showers. Each shower is a soft
## column of falling snow under its own cloud. Seen from outside it is a sunlit
## veil; inside, visibility drops, flakes streak past and the ground below is
## dusted white. Shaders share the shower list through `register()`.

## x, z, radius of each shower in metres. The first sits in the valley ahead of
## the start so it is the first thing a new flight meets. A map may bring its own.
const DEFAULT_SITES: Array[Vector3] = [
	Vector3(600.0, 1300.0, 1400.0),
	Vector3(-3600.0, -2600.0, 1900.0),
	Vector3(3800.0, -5200.0, 1700.0),
	Vector3(-2200.0, 6800.0, 1600.0),
]
const DEFAULT_TOP: float = 2050.0
const EXTINCTION: float = 0.0028   ## 1/m in the core: terrain fades out around 1 km
const WIND: Vector3 = Vector3(-2.2, -2.4, -8.6)   ## flake velocity: wind plus fall, m/s
const FLAKES: int = 9000
const BOX: float = 70.0

static var sites: Array[Vector3] = DEFAULT_SITES
static var top: float = DEFAULT_TOP

var enabled: bool = true
var sun_direction: Vector3 = Vector3.UP
var materials: Array[ShaderMaterial] = []
var noise: NoiseTexture2D
var veil: MeshInstance3D
var veil_material: ShaderMaterial
var flakes: MeshInstance3D
var flake_material: ShaderMaterial
var caps: Array[Node3D] = []
var drift: Vector3 = Vector3.ZERO
var last_eye: Vector3 = Vector3.ZERO
var eye_velocity: Vector3 = Vector3.ZERO
var has_eye: bool = false
var snowfall: float = 0.0     ## 0..1 how hard it snows at the camera


## Take the shower sites and cloud base for a map. Call before anything that
## uses them is built (the forest bakes ground_snow into its trees).
static func use_map(terrain: TerrainData) -> void:
	sites = DEFAULT_SITES if terrain.showers.is_empty() else terrain.showers
	top = DEFAULT_TOP + terrain.altitude_offset


func build(terrain: TerrainData, clouds: CloudField, start_enabled: bool) -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	enabled = start_enabled
	sun_direction = terrain.sun_direction
	noise = TerrainRenderer._noise_texture(53, 0.008, false)

	veil_material = ShaderMaterial.new()
	veil_material.shader = load("res://shaders/squall_veil.gdshader")
	veil_material.set_shader_parameter("sun_direction", sun_direction)
	veil_material.render_priority = -100
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	veil = MeshInstance3D.new()
	veil.mesh = quad
	veil.material_override = veil_material
	veil.custom_aabb = AABB(Vector3.ONE * -100000.0, Vector3.ONE * 200000.0)
	veil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(veil)
	register(veil_material)

	flake_material = ShaderMaterial.new()
	flake_material.shader = load("res://shaders/snowfall.gdshader")
	flake_material.set_shader_parameter("box", Vector3.ONE * BOX)
	flake_material.set_shader_parameter("fall_velocity", WIND)
	flake_material.set_shader_parameter("sun_direction", sun_direction)
	flake_material.render_priority = 20
	flakes = MeshInstance3D.new()
	flakes.mesh = _flake_mesh()
	flakes.material_override = flake_material
	flakes.custom_aabb = veil.custom_aabb
	flakes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flakes.visible = false
	add_child(flakes)

	# Each shower falls from its own broad cloud.
	if clouds != null and clouds.material != null:
		for i in range(sites.size()):
			var site: Vector3 = sites[i]
			caps.append(clouds.add_cloud(Vector3(site.x, top - 120.0, site.y), site.z * 0.8, 9100 + i))
	set_enabled(enabled)


## Give a material the shower list (terrain, trees, clouds: anything that
## includes squall.gdshaderinc).
func register(material: ShaderMaterial) -> void:
	if material == null:
		return
	materials.append(material)
	_push(material)


func set_enabled(on: bool) -> void:
	enabled = on
	veil.visible = on
	for cap in caps:
		cap.visible = on
	if not on:
		flakes.visible = false
		snowfall = 0.0
	for material in materials:
		_push(material)


func _push(material: ShaderMaterial) -> void:
	var list: PackedVector4Array = PackedVector4Array()
	for site in sites:
		list.append(Vector4(site.x, site.y, site.z, 1.0 if enabled else 0.0))
	var wind: Vector2 = Vector2(WIND.x, WIND.z).normalized()
	material.set_shader_parameter("squalls", list)
	material.set_shader_parameter("squall_noise", noise)
	material.set_shader_parameter("squall_top", top)
	material.set_shader_parameter("squall_extinction", EXTINCTION)
	material.set_shader_parameter("fresh_snow_scale", 1.0 if enabled else 0.0)
	material.set_shader_parameter("squall_wind", wind)


## Smooth shower density 0..1 at a point (the shader's columns without the wisps).
func density_at(p: Vector3) -> float:
	if not enabled:
		return 0.0
	var d: float = 0.0
	for site in sites:
		var f: float = maxf(1.0 - Vector2(p.x - site.x, p.z - site.y).length_squared() / (site.z * site.z), 0.0)
		d += f * f
	return d * (1.0 - smoothstep(top - 400.0, top, p.y))


## Fresh snow on the ground 0..1 (the shader's squall_ground without the ragged
## edge); the forest bakes this into each tree.
static func ground_snow(x: float, z: float) -> float:
	var wind: Vector2 = Vector2(WIND.x, WIND.z).normalized()
	var g: float = 0.0
	for site in sites:
		var o: Vector2 = Vector2(x - site.x, z - site.y) / site.z
		if o.length_squared() > 9.0:
			continue
		var along: float = o.dot(wind)
		var across: Vector2 = o - wind * along
		along *= 0.62 if along < 0.0 else 1.0
		g = maxf(g, 1.0 - smoothstep(0.25, 1.2, (across + wind * along).length()))
	return g


## How much of the sun's disc gets through the showers to a viewer at `p`.
func sun_visibility(p: Vector3) -> float:
	if not enabled:
		return 1.0
	var depth: float = 0.0
	for i in range(16):
		depth += density_at(p + sun_direction * (150.0 + i * 300.0)) * 300.0
	return exp(-depth * EXTINCTION)


func update(delta: float, eye: Vector3) -> void:
	if delta > 0.0:
		var velocity: Vector3 = (eye - last_eye) / delta if has_eye else Vector3.ZERO
		# A camera cut (respawn, hangar) is not motion.
		if velocity.length() > 400.0:
			velocity = Vector3.ZERO
		eye_velocity = eye_velocity.lerp(velocity, 1.0 - exp(-delta * 12.0))
		drift = (drift + WIND * delta).posmod(BOX)
	last_eye = eye
	has_eye = true
	if not enabled:
		return
	snowfall = clampf(density_at(eye) * 1.6, 0.0, 1.0)
	flakes.visible = snowfall > 0.01
	if flakes.visible:
		flake_material.set_shader_parameter("amount", snowfall)
		flake_material.set_shader_parameter("drift", drift)
		flake_material.set_shader_parameter("eye_velocity", eye_velocity)


## One mesh holding every flake: four corners share a seed position, the shader
## places and stretches them.
static func _flake_mesh() -> ArrayMesh:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 1947
	var verts: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var uv2s: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()
	for i in range(FLAKES):
		var seed_pos: Vector3 = Vector3(rng.randf(), rng.randf(), rng.randf())
		var extra: Vector2 = Vector2(rng.randf_range(0.02, 1.0), rng.randf())
		for corner: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
			verts.append(seed_pos)
			uvs.append(corner)
			uv2s.append(extra)
		var b: int = i * 4
		indices.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
