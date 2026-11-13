class_name TerrainRenderer
extends Node3D
## Draws the heightmap as a grid of tiles. Each tile has four detail levels that
## share one flat grid mesh per level; the vertex shader lifts vertices to the
## heightmap, and skirts hide cracks where neighbouring tiles use different levels.

const TILE_COUNT: int = 32
const LOD_QUADS: Array[int] = [96, 48, 24, 12]

var material: ShaderMaterial
var height_texture: ImageTexture
var mask_texture: Texture2D


func build(data: TerrainData, lod_scale: float) -> void:
	height_texture = ImageTexture.create_from_image(data.height_image())
	mask_texture = load(TerrainData.asset_path(data.id, "mask.png"))
	material = ShaderMaterial.new()
	material.shader = load("res://shaders/terrain.gdshader")
	material.set_shader_parameter("heightmap", height_texture)
	material.set_shader_parameter("masks", mask_texture)
	material.set_shader_parameter("noise_large", _noise_texture(7, 0.012, false))
	material.set_shader_parameter("noise_detail", _noise_texture(11, 0.03, true))
	material.set_shader_parameter("world_size", data.size)
	material.set_shader_parameter("samples", float(data.samples))
	material.set_shader_parameter("water_level", data.water_level)
	# Optional second mask: gravel beds, brooks, settlements and reed beds.
	var extra: String = TerrainData.asset_path(data.id, "mask2.png")
	if ResourceLoader.exists(extra):
		material.set_shader_parameter("masks2", load(extra))
		material.set_shader_parameter("extra_layers", 1.0)
	apply_look(material, data.look)

	var tile_size: float = data.size / TILE_COUNT
	var meshes: Array[ArrayMesh] = []
	for quads in LOD_QUADS:
		meshes.append(_grid_mesh(quads, tile_size))
	var ranges: Array[float] = [0.0, 1900.0 * lod_scale, 4300.0 * lod_scale, 9500.0 * lod_scale, 0.0]
	for tz in range(TILE_COUNT):
		for tx in range(TILE_COUNT):
			var centre: Vector3 = Vector3((tx + 0.5) * tile_size - data.size * 0.5, 0.0, (tz + 0.5) * tile_size - data.size * 0.5)
			var half: float = tile_size * 0.5
			var span: Vector2 = data.max_height_in(Vector2(centre.x - half, centre.z - half), Vector2(centre.x + half, centre.z + half), tile_size / 8.0)
			var aabb: AABB = AABB(Vector3(-half, span.x - 80.0, -half), Vector3(tile_size, span.y - span.x + 120.0, tile_size))
			for lod in range(LOD_QUADS.size()):
				var tile: MeshInstance3D = MeshInstance3D.new()
				tile.mesh = meshes[lod]
				tile.material_override = material
				tile.position = centre
				tile.custom_aabb = aabb
				tile.visibility_range_begin = ranges[lod]
				tile.visibility_range_end = ranges[lod + 1]
				tile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if lod < 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				tile.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
				add_child(tile)


## Hand a map's look (snow line, colours, ...) to a shader. Keys are uniform names;
## three-number arrays are colours.
static func apply_look(target: ShaderMaterial, look: Dictionary) -> void:
	for key: String in look:
		if key.begins_with("water_"):
			continue   # the lake's colours, set on the water material
		var value: Variant = look[key]
		if value is Array:
			value = Color(value[0], value[1], value[2])
		target.set_shader_parameter(key, value)


static func _noise_texture(seed_value: int, frequency: float, normal_map: bool) -> NoiseTexture2D:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	noise.fractal_octaves = 5
	var texture: NoiseTexture2D = NoiseTexture2D.new()
	texture.width = 512
	texture.height = 512
	texture.seamless = true
	texture.generate_mipmaps = true
	texture.noise = noise
	if normal_map:
		texture.as_normal_map = true
		texture.bump_strength = 6.0
	return texture


## Flat grid of quads*quads cells with a skirt hanging below every edge.
static func _grid_mesh(quads: int, tile_size: float) -> ArrayMesh:
	var verts: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	var normals: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()
	var row: int = quads + 1
	var step: float = tile_size / quads
	var half: float = tile_size * 0.5
	for z in range(row):
		for x in range(row):
			verts.append(Vector3(x * step - half, 0.0, z * step - half))
			colors.append(Color(0, 0, 0))
			normals.append(Vector3.UP)
	for z in range(quads):
		for x in range(quads):
			var i: int = z * row + x
			indices.append_array([i, i + 1, i + row, i + 1, i + row + 1, i + row])
	# Border loop, then a matching skirt loop pushed down in the shader.
	var border: PackedInt32Array = PackedInt32Array()
	for x in range(quads):
		border.append(x)
	for z in range(quads):
		border.append(z * row + quads)
	for x in range(quads, 0, -1):
		border.append(quads * row + x)
	for z in range(quads, 0, -1):
		border.append(z * row)
	var skirt_start: int = verts.size()
	for i in border:
		verts.append(verts[i])
		colors.append(Color(1, 0, 0))
		normals.append(Vector3.UP)
	for k in range(border.size()):
		var a: int = border[k]
		var b: int = border[(k + 1) % border.size()]
		var sa: int = skirt_start + k
		var sb: int = skirt_start + (k + 1) % border.size()
		indices.append_array([a, b, sa, b, sb, sa, a, sa, b, b, sa, sb])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
