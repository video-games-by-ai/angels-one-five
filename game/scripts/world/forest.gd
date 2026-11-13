class_name Forest
extends Node3D
## Conifer forests from the generated placement file, batched into MultiMesh
## chunks that switch off beyond the quality preset's draw distance. Far away the
## terrain shader paints the same forests, so the cut-off reads as haze.

const MODEL_PATH: String = "res://assets/models/trees.glb"
const CHUNK: float = 1200.0
const RECORD: int = 6

var chunks: Array[MultiMeshInstance3D] = []
var needle_material: ShaderMaterial


func build(terrain: TerrainData, mask: Texture2D, profile: Dictionary) -> void:
	var scene: Node = (load(MODEL_PATH) as PackedScene).instantiate()
	var meshes: Array[Mesh] = []
	for name in ["Spruce", "Fir"]:
		var mi: MeshInstance3D = scene.find_child(name, true, false)
		meshes.append(mi.mesh)
	scene.free()
	needle_material = ShaderMaterial.new()
	needle_material.shader = load("res://shaders/tree.gdshader")
	if terrain.look.has("snow_line"):
		needle_material.set_shader_parameter("snow_line", float(terrain.look.snow_line))
	var trunk: StandardMaterial3D = StandardMaterial3D.new()
	trunk.albedo_color = Color(0.22, 0.16, 0.11)
	trunk.roughness = 1.0

	var data: PackedFloat32Array = FileAccess.get_file_as_bytes(TerrainData.asset_path(terrain.id, "trees.bin")).to_float32_array()
	var buckets: Dictionary = {}
	var half: float = terrain.size * 0.5
	for i in range(0, data.size(), RECORD):
		var key: Vector3i = Vector3i(int((data[i] + half) / CHUNK), int((data[i + 2] + half) / CHUNK), int(data[i + 5]))
		if not buckets.has(key):
			buckets[key] = []
		(buckets[key] as Array).append(i)
	for key: Vector3i in buckets:
		var indices: Array = buckets[key]
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = meshes[key.z]
		mm.instance_count = indices.size()
		var centre: Vector3 = Vector3((key.x + 0.5) * CHUNK - half, 0.0, (key.y + 0.5) * CHUNK - half)
		var low: float = INF
		var high: float = -INF
		var buffer: PackedFloat32Array = PackedFloat32Array()
		buffer.resize(indices.size() * 16)
		var k: int = 0
		for i: int in indices:
			var s: float = data[i + 3]
			var yaw: float = data[i + 4]
			var c: float = cos(yaw) * s
			var sn: float = sin(yaw) * s
			var pos: Vector3 = Vector3(data[i], data[i + 1], data[i + 2]) - centre
			low = minf(low, pos.y)
			high = maxf(high, pos.y)
			buffer[k] = c; buffer[k + 1] = 0.0; buffer[k + 2] = sn; buffer[k + 3] = pos.x
			buffer[k + 4] = 0.0; buffer[k + 5] = s; buffer[k + 6] = 0.0; buffer[k + 7] = pos.y
			buffer[k + 8] = -sn; buffer[k + 9] = 0.0; buffer[k + 10] = c; buffer[k + 11] = pos.z
			var tint: float = fposmod(data[i] * 0.013 + data[i + 2] * 0.007, 1.0)
			var sun: float = terrain.mask_image.get_pixel(
				clampi(int((data[i] + half) / terrain.spacing + 0.5), 0, terrain.samples - 1),
				clampi(int((data[i + 2] + half) / terrain.spacing + 0.5), 0, terrain.samples - 1)).r
			buffer[k + 12] = tint
			buffer[k + 13] = fposmod(yaw * 3.1, 1.0)
			buffer[k + 14] = Weather.ground_snow(data[i], data[i + 2])   # fresh snow under the showers
			buffer[k + 15] = sun
			k += 16
		mm.buffer = buffer
		var inst: MultiMeshInstance3D = MultiMeshInstance3D.new()
		inst.multimesh = mm
		inst.position = centre
		inst.custom_aabb = AABB(Vector3(-CHUNK * 0.5 - 10, low - 5, -CHUNK * 0.5 - 10), Vector3(CHUNK + 20, high - low + 40, CHUNK + 20))
		inst.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(inst)
		chunks.append(inst)
	# Per-surface materials live on the shared meshes.
	for mesh in meshes:
		for s in range(mesh.get_surface_count()):
			var name: String = mesh.surface_get_material(s).resource_name if mesh.surface_get_material(s) else ""
			mesh.surface_set_material(s, trunk if name == "Trunk" else needle_material)
	apply_quality(profile)


func apply_quality(profile: Dictionary) -> void:
	var reach: float = float(profile.tree_range)
	var shadows: bool = bool(profile.tree_shadows)
	for inst in chunks:
		inst.visibility_range_end = reach
		inst.visibility_range_end_margin = 200.0
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func update(_eye: Vector3) -> void:
	pass
