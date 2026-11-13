class_name AiPilot
extends RefCounted
## Opponent pilot. Patrols the valley until its target comes close, then attacks
## in passes: it pursues with lead, fires short bursts when the guns bear, runs
## out and regains speed after closing in, breaks away when hit, and never flies
## itself into the mountains. Produces the same FlightCommand a human does, so it
## obeys the same flight model.

const ALERT_RANGE: float = 2400.0
const GUN_RANGE: float = 600.0
const SAFE_HEIGHT: float = 80.0
const ARENA_RADIUS: float = 8200.0
const BREAK_RANGE: float = 170.0       ## closer than this: stop pressing, run out
const CEILING: float = 1700.0          ## preferred maximum height above the ground

var terrain: TerrainData
var patrol: Autopilot = Autopilot.new()
var command: FlightCommand = FlightCommand.new()
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var alerted: bool = false
var evade_time: float = 0.0
var evade_aim: Vector3 = Vector3.FORWARD
var extend_time: float = 0.0    ## running out after a pass
var extend_aim: Vector3 = Vector3.FORWARD
var burst_time: float = 0.0     ## >= 0 while a burst may run, < 0 while resting
var break_side: float = 1.0
var phase: float = 0.0
var time: float = 0.0
var aim_error: float = deg_to_rad(1.4)


func setup(arena: TerrainData, seed_value: int) -> void:
	terrain = arena
	patrol.terrain = arena
	patrol.clearance = 260.0
	rng.seed = seed_value
	phase = rng.randf() * TAU
	break_side = 1.0 if rng.randf() > 0.5 else -1.0
	reset()


func reset() -> void:
	alerted = false
	evade_time = 0.0
	extend_time = 0.0
	burst_time = 0.0


## Being shot at: alert, and break hard away from the attacker for a moment.
func on_hit(me: FlightModel, from: Vector3) -> void:
	alerted = true
	if evade_time > 0.0:
		return
	evade_time = rng.randf_range(1.6, 2.6)
	var away: Vector3 = (me.position - from).normalized()
	var side: Vector3 = away.cross(Vector3.UP).normalized() * (1.0 if rng.randf() > 0.5 else -1.0)
	evade_aim = (side + away * 0.3 + Vector3.UP * rng.randf_range(-0.35, 0.3)).normalized()


func sample(me: FlightModel, target: FlightModel, dt: float) -> FlightCommand:
	time += dt
	command.copy_from(patrol.sample(me))
	command.boost = false
	command.fire = false
	if target != null and target.alive:
		var to: Vector3 = target.position - me.position
		var dist: float = to.length()
		if dist < ALERT_RANGE:
			alerted = true
		elif dist > ALERT_RANGE * 2.2:
			alerted = false
		if alerted:
			_pursue(me, target, to, dist, dt)
	else:
		alerted = false
	if extend_time > 0.0:
		extend_time -= dt
		command.aim_direction = extend_aim
		command.boost = true
		command.fire = false
	if evade_time > 0.0:
		evade_time -= dt
		command.aim_direction = evade_aim
		command.boost = true
		command.fire = false
	var flat: Vector2 = Vector2(me.position.x, me.position.z)
	if flat.length() > ARENA_RADIUS:
		command.aim_direction = Vector3(-me.position.x, 0.0, -me.position.z).normalized()
		command.fire = false
	command.aim_direction = _keep_clear(me, command.aim_direction)
	return command


func _pursue(me: FlightModel, target: FlightModel, to: Vector3, dist: float, dt: float) -> void:
	# Point where the rounds and the target would meet.
	var flight_time: float = dist / BulletField.SPEED
	var lead: Vector3 = (to + (target.velocity() - me.velocity()) * flight_time).normalized()
	var nose: Vector3 = me.forward()
	var off: float = nose.angle_to(lead)
	var wobble: Vector3 = Vector3(sin(time * 1.7 + phase), sin(time * 2.3 + phase * 2.0), sin(time * 1.3 + phase * 3.0)) * aim_error
	command.aim_direction = (lead + wobble).normalized()
	command.throttle_axis = 1.0
	command.boost = dist > 900.0 and off < 0.6
	if dist < BREAK_RANGE and extend_time <= 0.0:
		# Too close to shoot: end the pass. Run out level to one side, regain
		# speed, then come round for another attack.
		var flat_nose: Vector3 = Vector3(nose.x, 0.0, nose.z).normalized()
		var side: Vector3 = flat_nose.cross(Vector3.UP) * break_side
		extend_aim = (flat_nose + side * 0.55 + Vector3.DOWN * 0.1).normalized()
		extend_time = rng.randf_range(2.6, 4.2)
		break_side = -break_side
		burst_time = 0.0
		return
	if burst_time < 0.0:
		burst_time = minf(burst_time + dt, 0.0)
	elif off < deg_to_rad(2.6) and dist < GUN_RANGE:
		command.fire = true
		burst_time += dt
		if burst_time > 0.9:
			burst_time = -rng.randf_range(0.7, 1.3)
	else:
		burst_time = 0.0


## Never aim below a safe height, and pull up if the present flight path would
## meet the ground in the next few seconds.
func _keep_clear(me: FlightModel, aim: Vector3) -> Vector3:
	var look: Vector3 = me.position + aim * 550.0
	var floor_y: float = terrain.surface_at(look.x, look.z) + SAFE_HEIGHT
	if look.y < floor_y:
		look.y = floor_y
		aim = (look - me.position).normalized()
	# Do not let a turning fight spiral up to the top of the sky.
	if me.position.y > terrain.surface_at(me.position.x, me.position.z) + CEILING and aim.y > -0.12:
		aim = Vector3(aim.x, -0.12, aim.z).normalized()
	var v: Vector3 = me.velocity()
	for k in range(1, 8):
		var p: Vector3 = me.position + v * (0.5 * k)
		if p.y < terrain.surface_at(p.x, p.z) + SAFE_HEIGHT * 0.8:
			var home: Vector3 = terrain.valley_point_ahead(me.position, 900.0, patrol.heading_sign)
			var inward: Vector3 = Vector3(home.x - me.position.x, 0.0, home.z - me.position.z).normalized()
			var ahead: Vector3 = Vector3(v.x, 0.0, v.z).normalized()
			return (ahead * 0.55 + inward * 0.45 + Vector3.UP * 0.8).normalized()
	return aim
