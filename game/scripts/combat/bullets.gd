class_name BulletField
extends Node3D
## Every round in flight. Simulation is plain arrays advanced on the fixed step
## (so it also runs headless and on a server); rendering is one MultiMesh,
## extrapolated to the rendered frame: a glowing streak with a sparkling head
## and a thin wisp of smoke behind each round. The viewer's own rounds glow
## gold, a team-mate's pale, everyone else's red, so it is clear whose fire is
## whose.

const SPEED: float = 880.0          ## muzzle velocity, m/s
const LIFETIME: float = 1.5         ## seconds, about 1.3 km of range
const DROP: float = 5.0             ## m/s², gentle so beginners need not aim high
const TRACER_LENGTH: float = 52.0
const SMOKE_LENGTH: float = 120.0   ## metres of smoke wisp behind a round
const BURN_OUT: float = 0.3         ## seconds over which a round dims at the end of its flight
const MAX_BULLETS: int = 640
const FLATTEN: float = 0.42         ## hit volume is this much thinner vertically
const NEAR_MISS: float = 26.0       ## metres: a hostile round this close to the listener is heard passing
const TINT_OWN: Color = Color(1.0, 0.68, 0.26)
const TINT_FRIEND: Color = Color(0.95, 0.9, 0.62)
const TINT_HOSTILE: Color = Color(1.0, 0.27, 0.15)

var positions: PackedVector3Array = PackedVector3Array()
var velocities: PackedVector3Array = PackedVector3Array()
var ages: PackedFloat32Array = PackedFloat32Array()
var damages: PackedFloat32Array = PackedFloat32Array()
var shooters: PackedInt32Array = PackedInt32Array()
var teams: PackedInt32Array = PackedInt32Array()
var cosmetic: PackedByteArray = PackedByteArray()   ## 1 = drawn only: another machine decides its hits
var tints: PackedColorArray = PackedColorArray()
var seeds: PackedFloat32Array = PackedFloat32Array()
var viewer_id: int = 0              ## whose eyes and ears: this shooter's rounds are "own"
var viewer_team: int = 0
var listening: bool = false         ## count near misses around `ear`
var ear: Vector3 = Vector3.ZERO     ## where the viewer's aircraft is
var near_misses: int = 0            ## hostile rounds that passed close to `ear` in the last step
var multimesh: MultiMesh
var holder: MultiMeshInstance3D


func _ready() -> void:
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
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
	tints.clear()
	seeds.clear()
	near_misses = 0


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
	tints.append(TINT_OWN if shooter == viewer_id else (TINT_FRIEND if team == viewer_team else TINT_HOSTILE))
	seeds.append(randf())


## Advance all rounds one fixed step. Returns impacts: aircraft hits carry
## {target, shooter, point, local, zone, damage} (`local` is the strike point in
## the target's own space), ground strikes carry {ground, point}.
## Damage is not applied here; the caller decides what a hit does.
func step(dt: float, terrain: TerrainData, targets: Array[Combatant]) -> Array[Dictionary]:
	var impacts: Array[Dictionary] = []
	near_misses = 0
	var i: int = 0
	while i < positions.size():
		var p0: Vector3 = positions[i]
		var v: Vector3 = velocities[i]
		v.y -= DROP * dt
		var p1: Vector3 = p0 + v * dt
		ages[i] += dt
		if listening and shooters[i] != viewer_id and passes_close(p0, p1, ear, NEAR_MISS):
			near_misses += 1
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
				impacts.append({"target": target, "shooter": shooters[i], "point": p0.lerp(p1, u), "local": local,
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


## True if a round travelling from `p0` to `p1` makes its closest pass to `point`
## during that stretch (so each round counts once) and within `within` metres.
static func passes_close(p0: Vector3, p1: Vector3, point: Vector3, within: float) -> bool:
	var d: Vector3 = p1 - p0
	var u: float = (point - p0).dot(d) / maxf(d.length_squared(), 0.0001)
	return u > 0.0 and u <= 1.0 and (p0 + d * u).distance_squared_to(point) < within * within


func _remove(i: int) -> void:
	var last: int = positions.size() - 1
	positions[i] = positions[last]
	velocities[i] = velocities[last]
	ages[i] = ages[last]
	damages[i] = damages[last]
	shooters[i] = shooters[last]
	teams[i] = teams[last]
	cosmetic[i] = cosmetic[last]
	tints[i] = tints[last]
	seeds[i] = seeds[last]
	positions.resize(last)
	velocities.resize(last)
	ages.resize(last)
	damages.resize(last)
	shooters.resize(last)
	teams.resize(last)
	cosmetic.resize(last)
	tints.resize(last)
	seeds.resize(last)


func _process(_delta: float) -> void:
	var n: int = positions.size()
	multimesh.visible_instance_count = n
	var lead: float = Engine.get_physics_interpolation_fraction() / Engine.physics_ticks_per_second
	for i in range(n):
		var v: Vector3 = velocities[i]
		var direction: Vector3 = v.normalized()
		var up: Vector3 = Vector3.UP if absf(direction.y) < 0.98 else Vector3.RIGHT
		var flown: float = (ages[i] + lead) * SPEED
		multimesh.set_instance_transform(i, Transform3D(Basis.looking_at(direction, up), positions[i] + v * lead))
		multimesh.set_instance_color(i, tints[i])
		# Streak length, smoke length, a random number, brightness (dimming as the round burns out).
		multimesh.set_instance_custom_data(i, Color(clampf(flown, 2.0, TRACER_LENGTH), clampf(flown - 6.0, 0.0, SMOKE_LENGTH),
			seeds[i], clampf((LIFETIME - ages[i] - lead) / BURN_OUT, 0.0, 1.0)))


## One round's drawing: a smoke ribbon, a glow ribbon and a point for the head.
## Ribbons run from the head at the origin toward the tail at +Z, one unit long
## and two wide; the shaders stretch them and turn them to the camera.
static func _tracer_mesh() -> ArrayMesh:
	var mesh: ArrayMesh = ArrayMesh.new()
	var ribbon: PackedVector3Array = PackedVector3Array([Vector3(-1, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(-1, 0, 1)])
	var point: PackedVector3Array = PackedVector3Array([Vector3(-1, -1, 0), Vector3(1, -1, 0), Vector3(1, 1, 0), Vector3(-1, 1, 0)])
	var quad_uv: PackedVector2Array = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	var quad_index: PackedInt32Array = PackedInt32Array([0, 1, 2, 0, 2, 3])
	# Surface 0: smoke, drawn first so the glow lies over it.
	var smoke: Array = []
	smoke.resize(Mesh.ARRAY_MAX)
	smoke[Mesh.ARRAY_VERTEX] = ribbon
	smoke[Mesh.ARRAY_TEX_UV] = quad_uv
	smoke[Mesh.ARRAY_INDEX] = quad_index
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, smoke)
	var smoke_material: ShaderMaterial = ShaderMaterial.new()
	smoke_material.shader = load("res://shaders/tracer_smoke.gdshader")
	mesh.surface_set_material(0, smoke_material)
	# Surface 1: the glow. UV2.x tells the shader which part a vertex belongs to.
	var vertices: PackedVector3Array = ribbon.duplicate()
	vertices.append_array(point)
	var uvs: PackedVector2Array = quad_uv.duplicate()
	uvs.append_array(quad_uv)
	var kinds: PackedVector2Array = PackedVector2Array()
	for k in range(8):
		kinds.append(Vector2(0.0 if k < 4 else 1.0, 0.0))
	var glow: Array = []
	glow.resize(Mesh.ARRAY_MAX)
	glow[Mesh.ARRAY_VERTEX] = vertices
	glow[Mesh.ARRAY_TEX_UV] = uvs
	glow[Mesh.ARRAY_TEX_UV2] = kinds
	glow[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, glow)
	var glow_material: ShaderMaterial = ShaderMaterial.new()
	glow_material.shader = load("res://shaders/tracer.gdshader")
	glow_material.render_priority = 1
	mesh.surface_set_material(1, glow_material)
	return mesh
