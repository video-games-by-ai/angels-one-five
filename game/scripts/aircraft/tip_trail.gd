class_name TipTrail
extends MeshInstance3D
## Wingtip vapour ribbon drawn in world space from recent tip positions.

const LIFETIME: float = 1.3
const MAX_POINTS: int = 70
const WIDTH: float = 0.2

var points: Array[Vector3] = []
var ages: PackedFloat32Array = PackedFloat32Array()
var strengths: PackedFloat32Array = PackedFloat32Array()
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
	mat.no_depth_test = false
	material_override = mat
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


## Ribbon strength for the current flight state. Hard pulls give the full
## ribbon; speed adds a thinner one that starts at 90% of the airframe's own
## top speed and peaks at its boost speed, so each class shows it when it is
## fast for that class.
static func vapour_strength(g_load: float, speed: float, top_speed: float, boost_speed: float) -> float:
	var pull: float = clampf((g_load - 2.6) / 3.0, 0.0, 1.0)
	var fast: float = clampf(inverse_lerp(top_speed * 0.9, boost_speed, speed), 0.0, 1.0) * 0.8
	return pull + fast


func clear() -> void:
	points.clear()
	ages.clear()
	strengths.clear()
	immediate.clear_surfaces()


func push(world_point: Vector3, strength: float, delta: float) -> void:
	for i in range(ages.size()):
		ages[i] += delta
	while ages.size() > 0 and ages[0] > LIFETIME:
		points.pop_front()
		ages.remove_at(0)
		strengths.remove_at(0)
	sample_timer += delta
	if sample_timer >= 0.02:
		sample_timer = 0.0
		points.append(world_point)
		ages.append(0.0)
		strengths.append(strength)
		if points.size() > MAX_POINTS:
			points.pop_front()
			ages.remove_at(0)
			strengths.remove_at(0)
	_rebuild(world_point, strength)


func _rebuild(head: Vector3, head_strength: float) -> void:
	immediate.clear_surfaces()
	if points.size() < 2:
		return
	var any: bool = head_strength > 0.01
	for s in strengths:
		if s > 0.01:
			any = true
			break
	if not any:
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	var eye: Vector3 = camera.global_position
	immediate.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var count: int = points.size()
	for i in range(count + 1):
		var p: Vector3 = head if i == count else points[i]
		var prev: Vector3 = points[maxi(i - 1, 0)] if i > 0 else points[0]
		var dir: Vector3 = (p - prev)
		if dir.length_squared() < 0.0001:
			dir = Vector3.FORWARD
		var side: Vector3 = dir.cross(eye - p).normalized() * WIDTH
		var age: float = 0.0 if i == count else ages[i]
		var strength: float = head_strength if i == count else strengths[i]
		var alpha: float = strength * (1.0 - age / LIFETIME) * 0.3
		var color: Color = Color(1, 1, 1, clampf(alpha, 0.0, 1.0))
		immediate.surface_set_color(color)
		immediate.surface_add_vertex(p - side)
		immediate.surface_set_color(color)
		immediate.surface_add_vertex(p + side)
	immediate.surface_end()
