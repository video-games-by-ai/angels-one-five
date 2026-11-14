class_name TiltSteering
extends RefCounted
## Flying by leaning the phone, read from its gravity sensor.
##
## Leaning it sideways, like a steering wheel, turns: the further it leans, the
## faster the heading swings, and held level it flies straight. Tipping its top
## edge toward the pilot climbs and tipping it away dives, by an amount: the
## attitude the phone had when it was last centred is level flight, and holding
## it tipped holds that climb. So nothing drifts while the phone is held still.
##
## Gravity arrives in screen axes: x to the right, y up the screen, z out of
## the glass toward the pilot (Godot turns the sensor with the display).

const LEAN_DEAD: float = deg_to_rad(2.5)    ## leaning less than this flies straight
const LEAN_FULL: float = deg_to_rad(22.0)   ## the fastest turn
const LEAN_CURVE: float = 1.5               ## above 1: small leans steer finely
const CLIMB_GAIN: float = 2.5               ## degrees of climb for each degree the phone is tipped
const CLIMB_MAX: float = deg_to_rad(60.0)   ## steepest climb or dive asked for
const CLIMB_DEAD: float = deg_to_rad(3.0)   ## of climb: a little play around level flight
const SMOOTHING: float = 0.08               ## seconds; takes the tremor out of the hands

var down: Vector3 = Vector3.ZERO   ## smoothed direction of gravity; zero until the sensor has spoken
var lean: float = 0.0              ## radians the phone is turned like a wheel, right side down
var tip: float = 0.0               ## radians the phone is tipped back: 0 upright, a quarter turn lying face up
var level: float = 0.0             ## the tip that is level flight
var climb: float = 0.0             ## radians of climb asked for, before the limits
var gain_used: float = 1.0
var centred: bool = false


## x: how far the phone is turned like a steering wheel, right side down.
## y: how far it is tipped back. Both in radians, from the direction of gravity.
##
## A phone held up in front of the pilot is steered by turning it in the plane
## of its screen, and that must not read as tipping: there the two are taken
## apart exactly. A phone lying nearly flat cannot sense that turn at all (it is
## about the vertical); it is steered by lowering one side, read from x alone.
## `upright` blends from the one reading to the other between the two holds.
static func attitude(gravity: Vector3) -> Vector2:
	var d: Vector3 = gravity.normalized()
	var across: float = Vector2(d.x, d.y).length()   # 1 held upright, 0 lying flat
	var upright: float = smoothstep(0.3, 0.6, across)
	var wheel: float = atan2(d.x, absf(d.y))
	var side: float = asin(clampf(d.x, -1.0, 1.0))
	var along: float = -d.y * pow(across / maxf(absf(d.y), 0.000001), upright)
	return Vector2(lerpf(side, wheel, upright), atan2(-d.z, along))


## Take the attitude the phone has at its next reading as level flight.
func centre() -> void:
	centred = false
	down = Vector3.ZERO   # and not as it was held before a pause: the next reading stands unsmoothed


## One reading of the gravity sensor. `gain` scales how much climb a tip gives
## (the sensitivity setting, and less while zoomed).
func feed(gravity: Vector3, delta: float, gain: float = 1.0) -> void:
	if gravity.length_squared() < 0.01:
		return   # no sensor
	var unit: Vector3 = gravity.normalized()
	down = unit if down == Vector3.ZERO else down.lerp(unit, 1.0 - exp(-delta / SMOOTHING)).normalized()
	var now: Vector2 = attitude(down)
	lean = now.x
	if Vector2(down.y, down.z).length() < 0.3:
		return   # held on its side: which way it is tipped cannot be told
	if not centred:
		centred = true
		level = now.y
	elif not is_equal_approx(gain, gain_used):
		# The gain changed (zooming in or out): keep the climb, move the level.
		level = tip - wrapf(tip - level, -PI, PI) * gain_used / gain
	gain_used = gain
	tip = now.y
	# Tipping the top toward the pilot stands the phone up: less tip, more climb.
	climb = -wrapf(tip - level, -PI, PI) * CLIMB_GAIN * gain


## Turn asked for, -1 (hard left) to 1 (hard right).
func turn() -> float:
	var share: float = clampf((absf(lean) - LEAN_DEAD) / (LEAN_FULL - LEAN_DEAD), 0.0, 1.0)
	return signf(lean) * pow(share, LEAN_CURVE)


## Climb angle asked for, in radians; negative dives.
func elevation() -> float:
	return signf(climb) * clampf(absf(climb) - CLIMB_DEAD, 0.0, CLIMB_MAX)
