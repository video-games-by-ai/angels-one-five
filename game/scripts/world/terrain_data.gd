class_name TerrainData
extends RefCounted
## CPU copy of the arena heightmap, shared by rendering, flight collision and AI.
## Heights are sampled exactly like the GPU does (bilinear between sample centres),
## so what the player sees is what the aircraft collides with.

const HEIGHT_PATH: String = "res://assets/terrain/alpine_height.r32"
const META_PATH: String = "res://assets/terrain/alpine_meta.json"
const MASK_PATH: String = "res://assets/terrain/alpine_mask.png"

var size: float = 24000.0
var samples: int = 2048
var spacing: float = 1.0
var water_level: float = 0.0
var height_min: float = 0.0
var height_max: float = 0.0
var heights: PackedFloat32Array
var mask_image: Image
var sun_direction: Vector3 = Vector3.UP
var spawn_position: Vector3 = Vector3.ZERO
var valley_path: PackedVector3Array = PackedVector3Array()


static func load_default() -> TerrainData:
	var data: TerrainData = TerrainData.new()
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(META_PATH))
	data.size = float(meta.size)
	data.samples = int(meta.samples)
	data.spacing = data.size / float(data.samples - 1)
	data.water_level = float(meta.water_level)
	data.height_min = float(meta.height_min)
	data.height_max = float(meta.height_max)
	var sun: Array = meta.sun_direction
	data.sun_direction = Vector3(sun[0], sun[1], sun[2]).normalized()
	var spawn: Array = meta.spawn.position
	data.spawn_position = Vector3(spawn[0], spawn[1], spawn[2])
	for point: Array in meta.valley_path:
		data.valley_path.append(Vector3(point[0], point[1], point[2]))
	data.heights = FileAccess.get_file_as_bytes(HEIGHT_PATH).to_float32_array()
	assert(data.heights.size() == data.samples * data.samples, "Heightmap size mismatch")
	var mask: Texture2D = load(MASK_PATH)
	data.mask_image = mask.get_image()
	if data.mask_image.is_compressed():
		data.mask_image.decompress()
	return data


func height_at(x: float, z: float) -> float:
	var fx: float = clampf((x + size * 0.5) / spacing, 0.0, samples - 1.0001)
	var fz: float = clampf((z + size * 0.5) / spacing, 0.0, samples - 1.0001)
	var ix: int = int(fx)
	var iz: int = int(fz)
	var tx: float = fx - ix
	var tz: float = fz - iz
	var i: int = iz * samples + ix
	var top: float = lerpf(heights[i], heights[i + 1], tx)
	var bottom: float = lerpf(heights[i + samples], heights[i + samples + 1], tx)
	return lerpf(top, bottom, tz)


## Height of whatever is solid at this point: terrain or the lake surface.
func surface_at(x: float, z: float) -> float:
	return maxf(height_at(x, z), water_level)


## Forest density 0..1 from the terrain mask (blue channel).
func forest_at(x: float, z: float) -> float:
	if mask_image == null:
		return 0.0
	var px: int = clampi(int((x + size * 0.5) / spacing + 0.5), 0, samples - 1)
	var pz: int = clampi(int((z + size * 0.5) / spacing + 0.5), 0, samples - 1)
	return mask_image.get_pixel(px, pz).b


func normal_at(x: float, z: float) -> Vector3:
	var e: float = spacing
	var dx: float = height_at(x + e, z) - height_at(x - e, z)
	var dz: float = height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


func max_height_in(rect_min: Vector2, rect_max: Vector2, step: float) -> Vector2:
	var low: float = INF
	var high: float = -INF
	var z: float = rect_min.y
	while z <= rect_max.y:
		var x: float = rect_min.x
		while x <= rect_max.x:
			var h: float = height_at(x, z)
			low = minf(low, h)
			high = maxf(high, h)
			x += step
		z += step
	return Vector2(low, high)


func height_image() -> Image:
	return Image.create_from_data(samples, samples, false, Image.FORMAT_RF, heights.to_byte_array())


## Closest point on the valley centre line, used by the autopilot and the AI.
func valley_point_ahead(position: Vector3, lookahead: float, heading_sign: float) -> Vector3:
	var target_z: float = position.z - lookahead * heading_sign
	var best: Vector3 = valley_path[0]
	for i in range(valley_path.size() - 1):
		var a: Vector3 = valley_path[i]
		var b: Vector3 = valley_path[i + 1]
		if (target_z - a.z) * (target_z - b.z) <= 0.0:
			var t: float = inverse_lerp(a.z, b.z, target_z)
			return a.lerp(b, t)
	if absf(valley_path[valley_path.size() - 1].z - target_z) < absf(best.z - target_z):
		best = valley_path[valley_path.size() - 1]
	return best
