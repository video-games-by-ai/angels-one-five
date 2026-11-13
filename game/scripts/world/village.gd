class_name Village
extends Node3D
## Houses of a map's towns and villages, from the generated placement file
## (x, y, z, scale, yaw, kind per house). Three simple gabled buildings, one
## MultiMesh each. Maps without a placement file simply have no houses.

const RECORD: int = 6
## Footprint and wall height (x, y, z), roof height, wall and roof colours.
const KINDS: Array[Dictionary] = [
	{"size": Vector3(9.0, 5.2, 7.0), "roof": 2.8, "wall": Color(0.86, 0.83, 0.76), "tiles": Color(0.50, 0.23, 0.16)},
	{"size": Vector3(8.0, 4.4, 6.5), "roof": 3.4, "wall": Color(0.70, 0.66, 0.58), "tiles": Color(0.29, 0.26, 0.25)},
	{"size": Vector3(13.0, 4.0, 7.0), "roof": 3.0, "wall": Color(0.44, 0.33, 0.24), "tiles": Color(0.42, 0.27, 0.20)},
]

var count: int = 0


func build(terrain: TerrainData) -> void:
	var path: String = TerrainData.asset_path(terrain.id, "houses.bin")
	if not FileAccess.file_exists(path):
		return
	var data: PackedFloat32Array = FileAccess.get_file_as_bytes(path).to_float32_array()
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 0.9
	var half: float = terrain.size * 0.5
	for kind in range(KINDS.size()):
		var transforms: Array[Transform3D] = []
		for i in range(0, data.size(), RECORD):
			if int(data[i + 5]) != kind:
				continue
			var basis: Basis = Basis(Vector3.UP, data[i + 4]).scaled(Vector3.ONE * data[i + 3])
			transforms.append(Transform3D(basis, Vector3(data[i], data[i + 1], data[i + 2])))
		if transforms.is_empty():
			continue
		var spec: Dictionary = KINDS[kind]
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _house_mesh(spec.size, float(spec.roof), spec.wall, spec.tiles)
		mm.instance_count = transforms.size()
		for k in range(transforms.size()):
			mm.set_instance_transform(k, transforms[k])
		var inst: MultiMeshInstance3D = MultiMeshInstance3D.new()
		inst.multimesh = mm
		inst.material_override = material
		inst.custom_aabb = AABB(Vector3(-half, terrain.height_min, -half), Vector3(terrain.size, terrain.height_max - terrain.height_min, terrain.size))
		inst.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(inst)
		count += transforms.size()


## A gabled house: four walls reaching below ground (for sloping sites), two
## gable ends and a roof with a small overhang. The ridge runs along X.
static func _house_mesh(size: Vector3, roof: float, wall: Color, tiles: Color) -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hx: float = size.x * 0.5
	var hz: float = size.z * 0.5
	var top: float = size.y
	var centre: Vector3 = Vector3(0.0, top * 0.5, 0.0)
	var corners: Array[Vector3] = [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]
	for i in range(4):
		var a: Vector3 = corners[i]
		var b: Vector3 = corners[(i + 1) % 4]
		_quad(st, Vector3(a.x, -2.5, a.z), Vector3(b.x, -2.5, b.z), Vector3(b.x, top, b.z), Vector3(a.x, top, a.z), centre, wall)
	for side: float in [-1.0, 1.0]:
		_tri(st, Vector3(hx * side, top, -hz), Vector3(hx * side, top, hz), Vector3(hx * side, top + roof, 0.0), centre, wall)
		# One roof slope per side of the ridge.
		var eave: float = 0.6
		var drop: float = roof * eave / hz
		_quad(st, Vector3(-hx - eave, top - drop, (hz + eave) * side), Vector3(hx + eave, top - drop, (hz + eave) * side),
			Vector3(hx + eave, top + roof, 0.0), Vector3(-hx - eave, top + roof, 0.0), centre, tiles)
	return st.commit()


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, centre: Vector3, colour: Color) -> void:
	_tri(st, a, b, c, centre, colour)
	_tri(st, a, c, d, centre, colour)


## One flat-shaded triangle facing away from `centre` (Godot's front faces wind clockwise).
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, centre: Vector3, colour: Color) -> void:
	var normal: Vector3 = (b - a).cross(c - a).normalized()
	if normal.dot((a + b + c) / 3.0 - centre) > 0.0:
		var swap: Vector3 = b
		b = c
		c = swap
	else:
		normal = -normal
	for v: Vector3 in [a, b, c]:
		st.set_normal(normal)
		st.set_color(colour)
		st.add_vertex(v)
