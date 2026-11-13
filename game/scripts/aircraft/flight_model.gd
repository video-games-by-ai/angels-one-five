class_name FlightModel
extends RefCounted
## Arcade flight for one aircraft. Pure state + fixed-step update so the same code
## can run on the server (authority) and on clients (prediction).
##
## The pilot points the aim direction; the aircraft banks into the turn and pulls
## toward it, rolls wings-level when the aim is close to the nose, and trades
## speed for altitude so energy matters a little without stalling beginners.

const GRAVITY: float = 9.81
const TREE_HEIGHT: float = 17.0

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
var alive: bool = true


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
	var target_rate: Vector3 = Vector3(pitch_cmd * float(spec.pitch_rate), yaw_cmd * float(spec.yaw_rate), roll_cmd * float(spec.roll_rate)) * authority
	angular_rate = angular_rate.lerp(target_rate, 1.0 - exp(-dt * float(spec.response)))
	controls = controls.lerp(Vector3(pitch_cmd, yaw_cmd, roll_cmd), 1.0 - exp(-dt * 10.0))

	orientation = orientation * Quaternion(Vector3.RIGHT, angular_rate.x * dt)
	orientation = orientation * Quaternion(Vector3.UP, -angular_rate.y * dt)
	orientation = orientation * Quaternion(Vector3.BACK, -angular_rate.z * dt)
	orientation = orientation.normalized()
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
	g_load = 1.0 + absf(angular_rate.x) * speed / GRAVITY
	var induced: float = maxf(g_load - 1.5, 0.0) * 0.55
	var accel: float = thrust * power - drag * speed * speed - GRAVITY * fwd.y * 0.75 - induced
	speed = clampf(speed + accel * dt, stall * 0.75, float(spec.boost_speed) * 1.25)

	# The flight path lags the nose slightly so hard turns feel weighty.
	travel_direction = travel_direction.slerp(fwd, 1.0 - exp(-dt * 7.0)).normalized()
	var velocity: Vector3 = travel_direction * speed
	if speed < stall:
		velocity.y -= (stall - speed) * 0.6  # mushy sink instead of a spin
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
