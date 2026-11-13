class_name DamageTrail
extends MeshInstance3D
## The line an aircraft leaves along its flight path, so its turns are easy to
## read. Its look follows the hull: a faint see-through line when healthy, then
## solid white, grey smoke, dark smoke and black smoke as damage mounts (the same
## five stages as the HUD's health dots). Drawn in world space; it stays and
## fades out by itself when the aircraft is shot down.

const LIFETIME: float = 4.0         ## seconds of flight path shown, about 500-700 m
const SAMPLE_EVERY: float = 0.05
const HEAD_FADE: float = 0.12       ## seconds: the line starts just behind the tail
const MIN_PIXEL_WIDTH: float = 0.0022   ## metres per metre of distance: about 2 px at 1080p
## The line fades out this close to the camera, so the stretch passing beside the
## chase camera never shows as a broad band across the screen.
const NEAR_FADE_FROM: float = 8.0
const NEAR_FADE_TO: float = 30.0

## Hull share -> colour, opacity, width in metres. Linear between the keys.
const LOOK: Array = [
	[0.0, Color(0.06, 0.055, 0.05), 0.86, 4.2],
	[0.1, Color(0.08, 0.075, 0.07), 0.84, 3.8],
	[0.3, Color(0.27, 0.26, 0.25), 0.74, 2.7],
	[0.5, Color(0.64, 0.64, 0.64), 0.62, 1.5],
	[0.7, Color(1.0, 1.0, 1.0), 0.56, 0.55],
	[0.9, Color(1.0, 1.0, 1.0), 0.24, 0.35],
	[1.0, Color(1.0, 1.0, 1.0), 0.24, 0.35],
]

var strength: float = 1.0           ## overall opacity; the player's own line is fainter
var points: PackedVector3Array = PackedVector3Array()
var ages: PackedFloat32Array = PackedFloat32Array()
var shares: PackedFloat32Array = PackedFloat32Array()
var immediate: ImmediateMesh = ImmediateMesh.new()
var sample_timer: float = 0.0


func _ready() -> void:
	top_level = true
	mesh = immediate
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = mat
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# The line spans hundreds of metres; never cull it by the mesh's own bounds.
	extra_cull_margin = 16384.0


## Colour (with opacity) and width of the line for a hull share 0..1.
static func look(hull_share: float) -> Array:
	var h: float = clampf(hull_share, 0.0, 1.0)
	for i in range(LOOK.size() - 1):
		var a: Array = LOOK[i]
		var b: Array = LOOK[i + 1]
		if h <= float(b[0]):
			var t: float = inverse_lerp(float(a[0]), float(b[0]), h)
			var colour: Color = (a[1] as Color).lerp(b[1], t)
			colour.a = lerpf(float(a[2]), float(b[2]), t)
			return [colour, lerpf(float(a[3]), float(b[3]), t)]
	var last: Array = LOOK[LOOK.size() - 1]
	var c: Color = last[1]
	c.a = float(last[2])
	return [c, float(last[3])]


func clear() -> void:
	points.clear()
	ages.clear()
	shares.clear()
	immediate.clear_surfaces()


## Called every rendered frame while the aircraft flies.
func push(tail: Vector3, hull_share: float, delta: float) -> void:
	_age(delta)
	sample_timer += delta
	if sample_timer >= SAMPLE_EVERY or points.is_empty():
		sample_timer = 0.0
		points.append(tail)
		ages.append(0.0)
		shares.append(hull_share)
	_rebuild(tail, hull_share, true)


## Called every rendered frame while the aircraft is gone: the line fades out.
func fade(delta: float) -> void:
	if points.is_empty():
		return
	_age(delta)
	_rebuild(Vector3.ZERO, 0.0, false)


func _age(delta: float) -> void:
	for i in range(ages.size()):
		ages[i] += delta
	var stale: int = 0
	while stale < ages.size() and ages[stale] > LIFETIME:
		stale += 1
	if stale > 0:
		points = points.slice(stale)
		ages = ages.slice(stale)
		shares = shares.slice(stale)


func _rebuild(head: Vector3, head_share: float, with_head: bool) -> void:
	immediate.clear_surfaces()
	var line: PackedVector3Array = points.duplicate()
	var line_ages: PackedFloat32Array = ages.duplicate()
	var line_shares: PackedFloat32Array = shares.duplicate()
	if with_head:
		line.append(head)
		line_ages.append(0.0)
		line_shares.append(head_share)
	var count: int = line.size()
	if count < 2:
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	var eye: Vector3 = camera.global_position
	immediate.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in range(count):
		var p: Vector3 = line[i]
		var age: float = line_ages[i]
		var share: float = line_shares[i]
		var dir: Vector3 = line[mini(i + 1, count - 1)] - line[maxi(i - 1, 0)]
		if dir.length_squared() < 0.0001:
			dir = Vector3.FORWARD
		var to_eye: Vector3 = eye - p
		var side: Vector3 = dir.cross(to_eye).normalized()
		var style: Array = look(share)
		var colour: Color = style[0]
		var life: float = age / LIFETIME
		# Smoke spreads as it ages; the clean line stays thin.
		var spread: float = 1.0 + life * 2.4 * clampf((0.6 - share) / 0.5, 0.0, 1.0)
		var width: float = maxf(float(style[1]) * spread, to_eye.length() * MIN_PIXEL_WIDTH)
		colour.a *= strength * smoothstep(0.0, HEAD_FADE, age) * (1.0 - life) * (1.0 - life * 0.4) \
			* smoothstep(NEAR_FADE_FROM, NEAR_FADE_TO, to_eye.length())
		immediate.surface_set_color(colour)
		immediate.surface_add_vertex(p - side * width * 0.5)
		immediate.surface_set_color(colour)
		immediate.surface_add_vertex(p + side * width * 0.5)
	immediate.surface_end()
