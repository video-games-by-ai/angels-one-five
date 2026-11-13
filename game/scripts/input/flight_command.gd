class_name FlightCommand
extends RefCounted
## One tick of pilot intent. Produced by any input device (mouse, gamepad, touch,
## autopilot, network) and consumed by FlightModel, so control schemes can be
## swapped without touching the flight code.

var aim_direction: Vector3 = Vector3.FORWARD  ## world-space direction to fly toward
var throttle_axis: float = 0.0                ## -1..1, adjusts throttle
var roll_axis: float = 0.0                    ## -1..1, manual roll override (right positive)
var yaw_axis: float = 0.0                     ## -1..1, rudder (right positive)
var boost: bool = false
var brake: bool = false                        ## held: engine to idle, flaps down
var fire: bool = false
var rocket: bool = false


func copy_from(other: FlightCommand) -> void:
	aim_direction = other.aim_direction
	throttle_axis = other.throttle_axis
	roll_axis = other.roll_axis
	yaw_axis = other.yaw_axis
	boost = other.boost
	brake = other.brake
	fire = other.fire
	rocket = other.rocket
