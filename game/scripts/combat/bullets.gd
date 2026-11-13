class_name BulletField
extends Node3D
## Every round in flight. Simulation is plain arrays advanced on the fixed step
## (so it also runs headless and on a server); rendering is one MultiMesh of
## glowing tracer streaks extrapolated to the rendered frame.

const SPEED: float = 880.0          ## muzzle velocity, m/s
const LIFETIME: float = 1.5         ## seconds, about 1.3 km of range
const DROP: float = 5.0             ## m/s², gentle so beginners need not aim high
const TRACER_LENGTH: float = 30.0
const MAX_BULLETS: int = 640
const FLATTEN: float = 0.42         ## hit volume is this much thinner vertically

var positions: PackedVector3Array = PackedVector3Array()
var velocities: PackedVector3Array = PackedVector3Array()
var ages: PackedFloat32Array = PackedFloat32Array()
var damages: PackedFloat32Array = PackedFloat32Array()
var shooters: PackedInt32Array = PackedInt32Array()
var teams: PackedInt32Array = PackedInt32Array()
var cosmetic: PackedByteArray = PackedByteArray()   ## 1 = drawn only: another machine decides its hits
var multimesh: MultiMesh
var holder: MultiMeshInstance3D


func _ready() -> void:
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _tracer_mesh()
	multimesh.instance_count = MAX_BULLETS
	multimesh.visible_instance_count = 0
	holder = MultiMeshInstance3D.new()
	holder.multimesh = multimesh
	holder.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.custom_aabb = AABB(Vector3(-20000, -2000, -20000), Vector3(40000, 12000, 40000))
	holder.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(holder)


func count() -> int:
	return positions.size()


func clear() -> void:
	positions.clear()
	velocities.clear()
	ages.clear()
	damages.clear()
	shooters.clear()
	teams.clear()
	cosmetic.clear()


## Launch one round. `carrier_velocity` is the shooting aircraft's velocity.
func fire(shooter: int, team: int, origin: Vector3, direction: Vector3, carrier_velocity: Vector3, damage: float, only_drawn: bool = false) -> void:
	if positions.size() >= MAX_BULLETS:
		return
	positions.append(origin)
	velocities.append(direction * SPEED + carrier_velocity)
	ages.append(0.0)
	damages.append(damage)
	shooters.append(shooter)
	teams.append(team)
	cosmetic.append(1 if only_drawn else 0)


## Advance all rounds one fixed step. Returns impacts: aircraft hits carry
## {target, shooter, point, zone, damage}, ground strikes carry {ground, point}.
## Damage is not applied here; the caller decides what a hit does.
func step(dt: float, terrain: TerrainData, targets: Array[Combatant]) -> Array[Dictionary]:
	var impacts: Array[Dictionary] = []
	var i: int = 0
	while i < positions.size():
		var p0: Vector3 = positions[i]
		var v: Vector3 = velocities[i]
		v.y -= DROP * dt
		var p1: Vector3 = p0 + v * dt
		ages[i] += dt
		var spent: bool = ages[i] > LIFETIME
		for target in targets:
			if cosmetic[i] == 1:
				break
			if target.team == teams[i] or not target.model.alive or target.left:
				continue
			# Flattened sphere around the aircraft, tested in its own space.
			var inverse: Basis = target.model.basis().inverse()
			var a: Vector3 = inverse * (p0 - target.model.position)
			var b: Vector3 = inverse * (p1 - target.model.position)
			var a_s: Vector3 = Vector3(a.x, a.y / FLATTEN, a.z)
			var d_s: Vector3 = Vector3(b.x, b.y / FLATTEN, b.z) - a_s
			var u: float = clampf(-a_s.dot(d_s) / maxf(d_s.length_squared(), 0.0001), 0.0, 1.0)
			if (a_s + d_s * u).length_squared() < target.hit_radius * target.hit_radius:
				var local: Vector3 = a.lerp(b, u)
				impacts.append({"target": target, "shooter": shooters[i], "point": p0.lerp(p1, u),
					"zone": Airframes.zone_at(target.model.spec, local), "damage": damages[i]})
				spent = true
				break
		if not spent and p1.y < terrain.surface_at(p1.x, p1.z):
			impacts.append({"ground": true, "point": p1})
			spent = true
		if spent:
			_remove(i)
		else:
			positions[i] = p1
			velocities[i] = v
			i += 1
	return impacts


func _remove(i: int) -> void:
	var last: int = positions.size() - 1
	positions[i] = positions[last]
	velocities[i] = velocities[last]
	ages[i] = ages[last]
	damages[i] = damages[last]
	shooters[i] = shooters[last]
	teams[i] = teams[last]
	cosmetic[i] = cosmetic[last]
	positions.resize(last)
	velocities.resize(last)
	ages.resize(last)
	damages.resize(last)
	shooters.resize(last)
	teams.resize(last)
	cosmetic.resize(last)


func _process(_delta: float) -> void:
	var n: int = positions.size()
	multimesh.visible_instance_count = n
	var lead: float = Engine.get_physics_interpolation_fraction() / Engine.physics_ticks_per_second
	for i in range(n):
		var v: Vector3 = velocities[i]
		var direction: Vector3 = v.normalized()
		var up: Vector3 = Vector3.UP if absf(direction.y) < 0.98 else Vector3.RIGHT
		var frame: Basis = Basis.looking_at(direction, up)
		frame.z *= clampf((ages[i] + lead) * SPEED, 2.0, TRACER_LENGTH)
		multimesh.set_instance_transform(i, Transform3D(frame, positions[i] + v * lead))


## Two crossed quads one metre long, head at the origin and tail toward +Z.
static func _tracer_mesh() -> ArrayMesh:
	var half: float = 0.2
	var vertices: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()
	for axis: Vector3 in [Vector3.RIGHT, Vector3.UP]:
		var base: int = vertices.size()
		vertices.append_array([-axis * half, axis * half, axis * half + Vector3.BACK, -axis * half + Vector3.BACK])
		uvs.append_array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = load("res://shaders/tracer.gdshader")
	mesh.surface_set_material(0, material)
	return mesh
