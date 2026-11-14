class_name TerrainData
extends RefCounted
## CPU copy of an arena heightmap, shared by rendering, flight collision and AI.
## Heights are sampled exactly like the GPU does (bilinear between sample centres),
## so what the player sees is what the aircraft collides with.

## The arenas that can be flown. The first is the default.
const MAPS: Array[Dictionary] = [
	{"id": "alpine", "name": "Alpine Valley"},
	{"id": "plav", "name": "Plav & Gusinje"},
]
## Lake level of the Alpine valley. Cloud, haze and shower heights were tuned for
## it and move with the lake on other maps (see `altitude_offset`).
const REFERENCE_WATER_LEVEL: float = 432.0

var id: String = "alpine"
var title: String = "Alpine Valley"
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
var spawn_heading: float = 0.0           ## radians, 0 = north (-Z), positive = toward west
var altitude_offset: float = 0.0         ## this map's lake level relative to the Alpine valley's
var look: Dictionary = {}                ## per-map shader settings: snow line, colours
var showers: Array[Vector3] = []         ## snow shower sites (x, z, radius); empty = the defaults
var valley_path: PackedVector3Array = PackedVector3Array()
var path_marks: PackedFloat32Array = PackedFloat32Array()   ## distance along the path at each point
var path_length: float = 0.0


static func map_index(map_id: String) -> int:
	for i in range(MAPS.size()):
		if String(MAPS[i].id) == map_id:
			return i
	return 0


## Path of one of a map's generated files, e.g. asset_path("plav", "height.r32").
static func asset_path(map_id: String, file: String) -> String:
	return "res://assets/terrain/%s_%s" % [map_id, file]


static func load_default() -> TerrainData:
	return load_map(String(MAPS[0].id))


static func load_map(map_id: String) -> TerrainData:
	var data: TerrainData = TerrainData.new()
	data.id = String(MAPS[map_index(map_id)].id)
	data.title = String(MAPS[map_index(map_id)].name)
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(asset_path(data.id, "meta.json")))
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
	data.spawn_heading = deg_to_rad(float(meta.spawn.get("heading_deg", 0.0)))
	data.altitude_offset = data.water_level - REFERENCE_WATER_LEVEL
	data.look = meta.get("look", {})
	for site: Array in meta.get("showers", []):
		data.showers.append(Vector3(site[0], site[1], site[2]))
	for point: Array in meta.valley_path:
		if not data.valley_path.is_empty():
			var last: Vector3 = data.valley_path[data.valley_path.size() - 1]
			data.path_length += Vector2(point[0] - last.x, point[2] - last.z).length()
		data.valley_path.append(Vector3(point[0], point[1], point[2]))
		data.path_marks.append(data.path_length)
	DeviceDiag.mark("heights")
	data.heights = FileAccess.get_file_as_bytes(asset_path(data.id, "height.r32")).to_float32_array()
	assert(data.heights.size() == data.samples * data.samples, "Heightmap size mismatch")
	DeviceDiag.mark("mask load")
	var mask: Texture2D = load(asset_path(data.id, "mask.png"))
	DeviceDiag.mark("mask get_image")
	data.mask_image = mask.get_image()
	DeviceDiag.mark("mask done")
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


## Distance along the valley path of the path point nearest to `position`.
func path_progress(position: Vector3) -> float:
	var p: Vector2 = Vector2(position.x, position.z)
	var best_distance: float = INF
	var best: float = 0.0
	for i in range(valley_path.size() - 1):
		var a: Vector2 = Vector2(valley_path[i].x, valley_path[i].z)
		var along: Vector2 = Vector2(valley_path[i + 1].x, valley_path[i + 1].z) - a
		var u: float = clampf((p - a).dot(along) / maxf(along.length_squared(), 0.001), 0.0, 1.0)
		var d: float = p.distance_squared_to(a + along * u)
		if d < best_distance:
			best_distance = d
			best = lerpf(path_marks[i], path_marks[i + 1], u)
	return best


## Point on the valley path at a distance along it (clamped to its ends).
func path_point(distance: float) -> Vector3:
	var last: int = valley_path.size() - 1
	if distance <= 0.0:
		return valley_path[0]
	if distance >= path_length:
		return valley_path[last]
	var i: int = clampi(path_marks.bsearch(distance) - 1, 0, last - 1)
	return valley_path[i].lerp(valley_path[i + 1], inverse_lerp(path_marks[i], path_marks[i + 1], distance))


## Point on the valley centre line `lookahead` metres beyond the aircraft, toward
## the end of the path (heading_sign 1) or its start (-1). Used by the autopilot
## and the AI.
func valley_point_ahead(position: Vector3, lookahead: float, heading_sign: float) -> Vector3:
	return path_point(path_progress(position) + lookahead * heading_sign)
