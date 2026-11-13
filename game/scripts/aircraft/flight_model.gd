class_name FlightModel
extends RefCounted
## Arcade flight for one aircraft. Pure state + fixed-step update so the same code
## can run on the server (authority) and on clients (prediction).
##
## The pilot points the aim direction; the aircraft banks into the turn and pulls
## toward it, rolls wings-level when the aim is close to the nose, and trades
## speed for altitude: gravity takes its full share in a climb and gives it back
## in a dive, and the steeper the climb the less the labouring engine can add,
## so no aircraft hangs on its propeller. Out of flying speed the nose falls
## until the speed is back (a gentle stall, never a spin).

const GRAVITY: float = 9.81
## Share of its thrust the engine loses hauling the aircraft straight up. The
## loss grows with the square of the slope, so a shallow climb costs almost
## nothing extra, and what is left pointing straight up is far less than the
## aircraft's weight, even on boost.
const CLIMB_THRUST_LOSS: float = 0.8
## The stall, in multiples of the aircraft's stall speed: below STALL_BELOW the
## nose falls, and it stays the pilot's to lose until the speed is back above
## STALL_RECOVERED. Under STALL_PULL_FROM the wings pull less and less.
const STALL_BELOW: float = 0.95
const STALL_RECOVERED: float = 1.3
const STALL_WARNING: float = 1.15     ## the HUD warns from here down
const STALL_PULL_FROM: float = 1.45
const STALL_PULL_LEAST: float = 0.1   ## share of the pitch rate left to pull with when stalled
const STALL_NOSE_DROP: float = 1.3    ## rad/s the nose falls when stalled
const STALL_NOSE_REST: float = -0.5   ## the fall stops with the nose this far down (sine of the pitch)
const MIN_SPEED: float = 0.6          ## the slowest the aircraft can go, times its stall speed
const TREE_HEIGHT: float = 17.0
const MAX_HIT_MARKS: int = 48   ## bullet holes kept for the damage panels; the oldest go first
const GUN_COOL_TIME: float = 10.0   ## seconds for red-hot guns to cool completely
const GUN_SLOW_FROM: float = 0.5    ## heat at which the rate of fire starts to drop
const GUN_SLOWEST: float = 0.3      ## share of the rate of fire left just before they stop
const GUN_RESUME: float = 0.6       ## overheated guns fire again once they have cooled to this
const GUN_HOT_SCATTER: float = 1.5  ## hot barrels scatter this much more (added share at full heat)

var frame_id: int = Airframes.Id.MUSTANG
var spec: Dictionary = Airframes.spec(Airframes.Id.MUSTANG)
var position: Vector3 = Vector3.ZERO
var orientation: Quaternion = Quaternion.IDENTITY
var travel_direction: Vector3 = Vector3.FORWARD
var speed: float = 130.0
var throttle: float = 0.8
var boost_energy: float = 1.0
var boosting: bool = false
var angular_rate: Vector3 = Vector3.ZERO  ## pitch (nose up +), yaw (right +), roll (right +)
var controls: Vector3 = Vector3.ZERO      ## smoothed surface deflection -1..1, same axes
var g_load: float = 1.0
var stalled: bool = false                 ## out of flying speed: the nose is falling until the speed is back
var alive: bool = true
var hull: float = 100.0
var zone_health: PackedFloat32Array = PackedFloat32Array([1.0, 1.0, 1.0, 1.0, 1.0])  ## Airframes.Zone order
var gun_cooldown: float = 0.0
var gun_heat: float = 0.0            ## 0 = cold, 1 = too hot to fire
var gun_overheated: bool = false     ## stopped until they cool to GUN_RESUME
var firing: bool = false
var hit_marks: PackedVector2Array = PackedVector2Array()  ## where rounds struck, planform x, z in metres, oldest first


func setup(id: int, spawn: Vector3, heading: float) -> void:
	frame_id = id
	spec = Airframes.spec(id)
	position = spawn
	orientation = Quaternion(Vector3.UP, heading)
	travel_direction = forward()
	speed = float(spec.top_speed) * 0.82
	throttle = 0.8
	boost_energy = 1.0
	angular_rate = Vector3.ZERO
	controls = Vector3.ZERO
	alive = true
	hull = float(spec.hull)
	zone_health = PackedFloat32Array([1.0, 1.0, 1.0, 1.0, 1.0])
	hit_marks.clear()
	gun_cooldown = 0.0
	gun_heat = 0.0
	gun_overheated = false
	firing = false
	g_load = 1.0
	stalled = false
	boosting = false


func basis() -> Basis:
	return Basis(orientation)


func forward() -> Vector3:
	return -basis().z


func transform() -> Transform3D:
	return Transform3D(basis(), position)


## Advance one fixed step. Returns true if the aircraft hit the ground this step.
func step(cmd: FlightCommand, dt: float, terrain: TerrainData) -> bool:
	if not alive:
		return false
	var b: Basis = basis()
	var fwd: Vector3 = -b.z
	var local: Vector3 = b.inverse() * cmd.aim_direction.normalized()
	var angle_off: float = acos(clampf(-local.z, -1.0, 1.0))

	# Pitch and yaw toward the aim point.
	var pitch_cmd: float = clampf(atan2(local.y, -local.z) * 3.2, -1.0, 1.0)
	var yaw_cmd: float = clampf(atan2(local.x, -local.z) * 2.0, -1.0, 1.0)
	# Bank so the aim point sits "above" the canopy, then pulling turns toward it.
	var bank_error: float = atan2(local.x, local.y)
	if local.y < 0.0 and angle_off < deg_to_rad(28.0):
		bank_error = atan2(local.x, -local.y) * 0.7  # small dips: push, do not roll inverted
	var aggressive_roll: float = clampf(bank_error * 2.4, -1.0, 1.0)
	var level_roll: float = clampf(b.x.y * 3.0, -1.0, 1.0)
	var aggressive: float = clampf(angle_off / deg_to_rad(9.0), 0.0, 1.0)
	var roll_cmd: float = lerpf(level_roll, aggressive_roll, aggressive)
	if absf(cmd.roll_axis) > 0.05:
		roll_cmd = cmd.roll_axis
	if absf(cmd.yaw_axis) > 0.05:
		yaw_cmd = cmd.yaw_axis
	# Do not pull hard while the wings are still rolling toward the target.
	pitch_cmd *= lerpf(1.0, clampf(cos(bank_error), 0.15, 1.0), aggressive)

	var stall: float = float(spec.stall)
	var authority: float = clampf((speed - stall * 0.6) / (stall * 1.2), 0.3, 1.0)
	# Near the stall the wings have little left to pull the nose up with, and a
	# stalled aircraft has to build speed before it can climb again.
	if speed < stall * STALL_BELOW:
		stalled = true
	elif speed > stall * STALL_RECOVERED:
		stalled = false
	if pitch_cmd > 0.0:
		pitch_cmd *= STALL_PULL_LEAST if stalled else clampf((speed - stall) / (stall * (STALL_PULL_FROM - 1.0)), STALL_PULL_LEAST, 1.0)
	# Battle damage: a shot-up tail pitches and yaws sluggishly, holed wings roll slowly.
	var tail_factor: float = lerpf(0.55, 1.0, zone_health[Airframes.Zone.TAIL])
	var wing_factor: float = lerpf(0.5, 1.0, minf(zone_health[Airframes.Zone.WING_L], zone_health[Airframes.Zone.WING_R]))
	var target_rate: Vector3 = Vector3(pitch_cmd * float(spec.pitch_rate) * tail_factor, yaw_cmd * float(spec.yaw_rate) * tail_factor,
		roll_cmd * float(spec.roll_rate) * wing_factor) * authority
	angular_rate = angular_rate.lerp(target_rate, 1.0 - exp(-dt * float(spec.response)))
	controls = controls.lerp(Vector3(pitch_cmd, yaw_cmd, roll_cmd), 1.0 - exp(-dt * 10.0))

	orientation = orientation * Quaternion(Vector3.RIGHT, angular_rate.x * dt)
	orientation = orientation * Quaternion(Vector3.UP, -angular_rate.y * dt)
	orientation = orientation * Quaternion(Vector3.BACK, -angular_rate.z * dt)
	orientation = orientation.normalized()
	b = basis()
	fwd = -b.z
	# Stalled: the nose falls toward the ground whatever the pilot asks.
	var drop: float = STALL_NOSE_DROP * clampf((fwd.y - STALL_NOSE_REST) / 0.5, 0.0, 1.0) * dt if stalled else 0.0
	if drop > 0.0:
		var axis: Vector3 = fwd.cross(Vector3.DOWN)
		if axis.length_squared() < 0.0004:
			axis = b.x   # pointing straight up: tip forward over the nose
		orientation = (Quaternion(axis.normalized(), drop) * orientation).normalized()
		b = basis()
		fwd = -b.z

	# Throttle and boost (water injection: a limited, regenerating reserve).
	throttle = clampf(throttle + cmd.throttle_axis * dt * 0.6, 0.25, 1.0)
	boosting = cmd.boost and boost_energy > (0.0 if boosting else 0.08)
	boost_energy = clampf(boost_energy + (-1.0 / 7.0 if boosting else 1.0 / 18.0) * dt, 0.0, 1.0)

	var top: float = float(spec.top_speed)
	var thrust: float = float(spec.thrust)
	var drag: float = thrust / (top * top)
	var power: float = throttle
	if boosting:
		power = pow(float(spec.boost_speed) / top, 2.0)
	power *= damage_power(zone_health[Airframes.Zone.ENGINE], hull_ratio())
	g_load = 1.0 + absf(angular_rate.x) * speed / GRAVITY
	var induced: float = maxf(g_load - 1.5, 0.0) * 0.55
	var accel: float = thrust * power * climb_thrust(fwd.y) - drag * speed * speed - GRAVITY * fwd.y - induced
	speed = clampf(speed + accel * dt, stall * MIN_SPEED, float(spec.boost_speed) * 1.25)

	# The flight path lags the nose slightly so hard turns feel weighty.
	travel_direction = travel_direction.slerp(fwd, 1.0 - exp(-dt * 7.0)).normalized()
	var velocity: Vector3 = travel_direction * speed
	if speed < stall:
		velocity.y -= (stall - speed) * 0.9  # mushy sink instead of a spin
	position += velocity * dt

	# Ground, lake and treetops.
	var ground: float = terrain.surface_at(position.x, position.z)
	var clearance: float = position.y - ground
	if clearance < 1.2 or (clearance < TREE_HEIGHT and terrain.forest_at(position.x, position.z) > 0.45):
		alive = false
		return true
	# Invisible ceiling well above the peaks.
	if position.y > 4300.0:
		position.y = 4300.0
	return false


func velocity() -> Vector3:
	return travel_direction * speed


## Share of its thrust the engine delivers with the nose pointing `rise` up (the
## sine of the pitch: 1 straight up). All of it level or diving.
static func climb_thrust(rise: float) -> float:
	return 1.0 - CLIMB_THRUST_LOSS * rise * rise if rise > 0.0 else 1.0


## Too slow to fly properly: at or near the stall (for the HUD warning; it goes
## by the speed alone, so it also works for aircraft copied from the network).
func near_stall() -> bool:
	return speed < float(spec.stall) * STALL_WARNING


## How hard the engine is being worked, -1..1. Above 0 it labours: hauling the
## aircraft uphill, hanging near the stall, or dragged down by a hard pull. Below
## 0 it is unloaded: in a dive the airflow drives the propeller and the revs run
## away. 0 is steady level flight. The sounds follow it (see Sfx.engine_rpm).
func engine_load() -> float:
	var rise: float = forward().y
	if rise < 0.0:
		return maxf(rise, -1.0)
	var slow: float = clampf((0.75 - speed / float(spec.top_speed)) / 0.4, 0.0, 1.0)
	var pull: float = clampf((g_load - 2.0) / 5.0, 0.0, 1.0)
	return clampf(rise * 0.9 + slow * 0.45 + pull * 0.35, 0.0, 1.0) * lerpf(0.5, 1.0, throttle)


func hull_ratio() -> float:
	return clampf(hull / float(spec.hull), 0.0, 1.0)


## Share of engine power left after battle damage. A shot-up engine zone and a
## badly holed (burning) airframe both cost power; the worse of the two applies,
## never both, so a wreck keeps about 72% of its top speed (sqrt of 0.52).
static func damage_power(engine_health: float, hull_share: float) -> float:
	var engine: float = lerpf(0.5, 1.0, engine_health)
	var burning: float = lerpf(0.52, 1.0, clampf((hull_share - 0.2) / 0.2, 0.0, 1.0))
	return minf(engine, burning)


## Share of the full rate of fire the guns manage at `heat`: all of it while
## cool, falling steadily to GUN_SLOWEST as they approach the limit.
static func gun_rate_factor(heat: float) -> float:
	return lerpf(1.0, GUN_SLOWEST, clampf((heat - GUN_SLOW_FROM) / (1.0 - GUN_SLOW_FROM), 0.0, 1.0))


## How far rounds scatter at `heat`, as a multiple of the cold spread.
static func gun_scatter_factor(heat: float) -> float:
	return 1.0 + GUN_HOT_SCATTER * clampf(heat, 0.0, 1.0)


## Number of rounds leaving the guns this step. The trigger must be held; the
## first round of a burst goes at once and the rest follow at the fire rate.
##
## Firing heats the guns: unbroken fire takes them from cold to the limit in the
## aircraft's `gun_heat_time`. For the first half of that they fire at the full
## rate; then the rate drops, round by round, to under a third, and at the limit
## they stop. They cool only while silent (fully in GUN_COOL_TIME) and, once
## overheated, stay stopped until they are back down to GUN_RESUME. Short bursts
## with pauses can go on indefinitely.
func rounds_this_step(trigger: bool, dt: float) -> int:
	gun_cooldown = maxf(gun_cooldown - dt, -dt)
	if gun_overheated and gun_heat <= GUN_RESUME:
		gun_overheated = false
	firing = trigger and alive and not gun_overheated
	if not firing:
		gun_cooldown = maxf(gun_cooldown, 0.0)
		gun_heat = maxf(gun_heat - dt / GUN_COOL_TIME, 0.0)
		return 0
	var rounds: int = 0
	var full_rate: float = float(spec.fire_rate)
	while gun_cooldown <= 0.0 and not gun_overheated:
		var share: float = gun_rate_factor(gun_heat)
		gun_cooldown += 1.0 / (full_rate * share)
		# Each round adds more heat as the rate drops, so heat climbs at a steady pace.
		gun_heat += 1.0 / (full_rate * float(spec.gun_heat_time) * share)
		rounds += 1
		if gun_heat >= 1.0:
			gun_heat = 1.0
			gun_overheated = true
	return rounds


## World position of a gun muzzle (alternating sides) and the direction its
## rounds leave in, converging on a point ahead of the nose.
func muzzle(index: int, convergence: float = 380.0) -> Array[Vector3]:
	var muzzles: Array = spec.muzzles
	var b: Basis = basis()
	var origin: Vector3 = position + b * (muzzles[index % muzzles.size()] as Vector3)
	var target: Vector3 = position - b.z * convergence
	return [origin, (target - origin).normalized()]


## Take a hit in one zone. Returns true if this destroyed the aircraft.
func apply_damage(amount: float, zone: int) -> bool:
	if not alive:
		return false
	zone_health[zone] = maxf(zone_health[zone] - amount / (float(spec.hull) * Airframes.ZONE_CAPACITY), 0.0)
	hull -= amount
	if hull <= 0.0:
		hull = 0.0
		alive = false
		return true
	return false


## Remember a bullet hole in `zone` at planform position `spot` (x, z), drawn on
## the damage panels. Spots outside the zone's outline are pulled onto it.
func mark_hit(zone: int, spot: Vector2) -> void:
	hit_marks.append(AirframeOutline.place_hit(frame_id, zone, spot))
	if hit_marks.size() > MAX_HIT_MARKS:
		hit_marks.remove_at(0)


## Seconds until ground impact on the current path, or INF.
func time_to_impact(terrain: TerrainData, horizon: float = 4.0) -> float:
	var v: Vector3 = velocity()
	var t: float = 0.25
	while t <= horizon:
		var p: Vector3 = position + v * t
		if p.y < terrain.surface_at(p.x, p.z) + 3.0:
			return t
		t += 0.25
	return INF
