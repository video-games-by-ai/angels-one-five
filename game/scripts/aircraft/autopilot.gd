class_name Autopilot
extends RefCounted
## Flies down the valley at low level. Used for the attract demo, screenshots and
## the repeatable performance benchmark; the same logic will seed the AI pilots.

var terrain: TerrainData
var heading_sign: float = 1.0
var clearance: float = 140.0
var command: FlightCommand = FlightCommand.new()
var time: float = 0.0


func sample(model: FlightModel) -> FlightCommand:
	time += 1.0 / Engine.physics_ticks_per_second
	if model.position.z < -7300.0:
		heading_sign = -1.0
	elif model.position.z > 7300.0:
		heading_sign = 1.0
	var target: Vector3 = terrain.valley_point_ahead(model.position, 1300.0, heading_sign)
	target.x += sin(time * 0.35) * 260.0
	var ground: float = terrain.surface_at(target.x, target.z)
	for k in range(1, 6):
		var probe: Vector3 = model.position + model.forward() * 250.0 * k
		ground = maxf(ground, terrain.surface_at(probe.x, probe.z))
	target.y = ground + clearance
	command.aim_direction = (target - model.position).normalized()
	command.throttle_axis = 1.0
	command.boost = fmod(time, 22.0) > 15.0
	command.roll_axis = 0.0
	command.yaw_axis = 0.0
	return command
