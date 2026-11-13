class_name CloudField
extends Node3D
## Cumulus clouds built from lit, soft billboard puffs. Each cloud is one
## MultiMesh so Godot sorts clouds against each other; puffs inside nearby
## clouds are re-sorted back-to-front as the camera moves. Flying into a cloud
## raises `inside_amount`, which drives a white-out overlay.

const PUFF_STRIDE: int = 16  # 12 transform floats + 4 custom floats

var material: ShaderMaterial
var clouds: Array[Dictionary] = []
var inside_amount: float = 0.0
var sort_cursor: int = 0


func build(terrain: TerrainData, density: float) -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	material = ShaderMaterial.new()
	material.shader = load("res://shaders/cloud.gdshader")
	material.set_shader_parameter("puff_noise", _puff_texture())
	material.set_shader_parameter("sun_direction", terrain.sun_direction)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 4407
	var count: int = int(46 * density)
	var placed: int = 0
	var attempts: int = 0
	while placed < count and attempts < 2000:
		attempts += 1
		var centre: Vector3 = Vector3(rng.randf_range(-9800, 9800), 0.0, rng.randf_range(-9800, 9800))
		var too_close: bool = false
		for c in clouds:
			if Vector2(c.centre.x, c.centre.z).distance_to(Vector2(centre.x, centre.z)) < 1500.0:
				too_close = true
				break
		if too_close:
			continue
		var low: bool = rng.randf() < 0.3
		centre.y = rng.randf_range(1250.0, 1600.0) if low else rng.randf_range(1900.0, 2600.0)
		var radius: float = rng.randf_range(420.0, 820.0) * (0.7 if low else 1.0)
		_add_cloud(centre, radius, rng)
		placed += 1


func _add_cloud(centre: Vector3, radius: float, rng: RandomNumberGenerator) -> void:
	var puffs: Array[Vector4] = []  # xyz offset, w size
	var n: int = int(clampf(radius / 22.0, 16, 38))
	var height: float = radius * rng.randf_range(0.55, 0.9)
	for i in range(n):
		# Flat base, rounded domes: points in a squashed hemisphere, bigger near the core.
		var a: float = rng.randf() * TAU
		var r: float = sqrt(rng.randf()) * radius * 0.85
		var x: float = cos(a) * r
		var z: float = sin(a) * r * rng.randf_range(0.6, 1.0)
		var core: float = 1.0 - r / radius
		var y: float = rng.randf_range(0.0, 1.0) * height * (0.35 + 0.65 * core)
		var size: float = rng.randf_range(0.65, 1.0) * (radius * 0.30 + core * radius * 0.25)
		puffs.append(Vector4(x, y + size * 0.25, z, size))
	# A few wide base puffs give the flat, shaded underside.
	for i in range(4):
		var a: float = rng.randf() * TAU
		puffs.append(Vector4(cos(a) * radius * 0.4, radius * 0.06, sin(a) * radius * 0.4, radius * 0.45))
	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mm.mesh = quad
	mm.instance_count = puffs.size()
	var inst: MultiMeshInstance3D = MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.material_override = material
	inst.position = centre
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.custom_aabb = AABB(Vector3(-radius * 1.6, -radius * 0.6, -radius * 1.6), Vector3(radius * 3.2, height + radius * 1.4, radius * 3.2))
	add_child(inst)
	var cloud: Dictionary = {"centre": centre, "radius": radius, "height": height, "puffs": puffs, "node": inst, "mm": mm}
	clouds.append(cloud)
	_write(cloud, Vector3(0, 100000, 0))


## Write puffs back-to-front as seen from `eye` into the MultiMesh buffer.
func _write(cloud: Dictionary, eye: Vector3) -> void:
	var puffs: Array[Vector4] = cloud.puffs
	var centre: Vector3 = cloud.centre
	var radius: float = cloud.radius
	var order: Array = range(puffs.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		var pa: Vector4 = puffs[a]
		var pb: Vector4 = puffs[b]
		return (centre + Vector3(pa.x, pa.y, pa.z)).distance_squared_to(eye) > (centre + Vector3(pb.x, pb.y, pb.z)).distance_squared_to(eye))
	var buffer: PackedFloat32Array = PackedFloat32Array()
	buffer.resize(puffs.size() * PUFF_STRIDE)
	var k: int = 0
	for idx: int in order:
		var p: Vector4 = puffs[idx]
		var s: float = p.w
		# Basis rows (scale on the diagonal) then origin, Godot's MultiMesh layout.
		buffer[k] = s; buffer[k + 1] = 0.0; buffer[k + 2] = 0.0; buffer[k + 3] = p.x
		buffer[k + 4] = 0.0; buffer[k + 5] = s; buffer[k + 6] = 0.0; buffer[k + 7] = p.y
		buffer[k + 8] = 0.0; buffer[k + 9] = 0.0; buffer[k + 10] = s; buffer[k + 11] = p.z
		var rel: Vector3 = Vector3(p.x / radius, p.y / maxf(cloud.height, 1.0) * 2.0 - 1.0, p.z / radius)
		buffer[k + 12] = rel.x
		buffer[k + 13] = rel.y
		buffer[k + 14] = rel.z
		buffer[k + 15] = float(idx % 7) / 7.0
		k += PUFF_STRIDE
	(cloud.mm as MultiMesh).buffer = buffer


func update(eye: Vector3) -> void:
	if clouds.is_empty():
		return
	# Re-sort a few clouds per frame, nearest ones every frame.
	var inside: float = 0.0
	for c in clouds:
		var centre: Vector3 = c.centre
		var radius: float = c.radius
		var local: Vector3 = eye - centre
		var d: float = Vector3(local.x / radius, (local.y - c.height * 0.45) / (c.height * 0.6 + 1.0), local.z / radius).length()
		inside = maxf(inside, clampf((1.0 - d) / 0.35, 0.0, 1.0))
		if Vector2(local.x, local.z).length() < radius * 2.5 and absf(local.y) < radius * 1.5:
			_write(c, eye)
	for i in range(3):
		sort_cursor = (sort_cursor + 1) % clouds.size()
		_write(clouds[sort_cursor], eye)
	inside_amount = inside


static func _puff_texture() -> NoiseTexture2D:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = 77
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.frequency = 0.012
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	var texture: NoiseTexture2D = NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	texture.invert = true
	texture.generate_mipmaps = true
	texture.noise = noise
	return texture
