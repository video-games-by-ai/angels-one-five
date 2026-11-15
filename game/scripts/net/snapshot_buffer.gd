class_name SnapshotBuffer
extends RefCounted
## Smooths another player's aircraft from the motion reports that arrive about
## 30 times a second. It is drawn DELAY seconds behind the newest report, blended
## between the two reports either side of that moment (position along a curve
## that matches both velocities, orientation by slerp). If reports stop it carries
## on along the last velocity for MAX_EXTRAPOLATE seconds, then holds.

const DELAY: float = 0.1
const MAX_EXTRAPOLATE: float = 0.25
const KEEP: int = 24
const TICK: float = 1.0 / 60.0
const REPORT_TICKS: int = 2          ## a report is sent every this many physics ticks: 30 a second
const MEASURE_SECONDS: float = 3.0   ## the link figures below are averages over this long

var snaps: Array[Dictionary] = []
var play_time: float = -1.0

## Measured for the stats readout, refreshed every MEASURE_SECONDS of drawing.
## `behind` is the part of the delay this game adds: how far the moment drawn
## lies before the newest report, plus how long ago that report came in. The
## age of what is on screen is the report's journey here plus this.
var behind: float = -1.0             ## seconds; -1 until measured
var lost: float = 0.0                ## share of reports that never came, or came too late to use
var guessed: float = 0.0             ## share of the time drawn past the newest report (a guess)

var _clock: float = 0.0              ## this game's time, counted by sample()
var _arrived: float = 0.0            ## _clock when the newest report came in
var _last_tick: int = -1
var _got: int = 0
var _missed: int = 0
var _behind_sum: float = 0.0
var _guess_time: float = 0.0
var _span: float = 0.0


## Forget the reports (a respawn, or the sender restarted its clock). The
## figures already measured stay until the next ones are ready.
func reset() -> void:
	snaps.clear()
	play_time = -1.0
	_last_tick = -1


## Add a report; its `tick` is the sender's own physics tick.
func push(state: Dictionary) -> void:
	var s: Dictionary = state.duplicate()
	s.time = int(s.tick) * TICK
	if not snaps.is_empty():
		var last: float = snaps[snaps.size() - 1].time
		if s.time <= last:
			if s.time < last - 5.0:
				reset()   # the sender restarted its clock
			else:
				return     # late or duplicate
	snaps.append(s)
	if snaps.size() > KEEP:
		snaps.pop_front()
	var tick: int = int(s.tick)
	if _last_tick >= 0 and tick - _last_tick <= 60:   # a longer gap is a pause, not loss
		_missed += maxi((tick - _last_tick) / REPORT_TICKS - 1, 0)
	_last_tick = tick
	_got += 1
	_arrived = _clock


func newest() -> Dictionary:
	return snaps[snaps.size() - 1] if not snaps.is_empty() else {}


## Advance by `dt` and return the motion to show now, or {} with no reports yet.
func sample(dt: float) -> Dictionary:
	if snaps.is_empty():
		return {}
	var latest: float = snaps[snaps.size() - 1].time
	var target: float = latest - DELAY
	if play_time < 0.0:
		play_time = target
	else:
		play_time += dt
		# Drift gently toward the target delay; jump if far off (a stall or a burst).
		var error: float = target - play_time
		if absf(error) > 0.5:
			play_time = target
		else:
			play_time += error * 0.05
	var t: float = play_time
	_measure(dt, latest, t)
	if t <= snaps[0].time:
		return snaps[0]
	for i in range(snaps.size() - 1):
		var a: Dictionary = snaps[i]
		var b: Dictionary = snaps[i + 1]
		if t <= b.time:
			return _blend(a, b, t)
	# Past the newest report: extrapolate a little, then hold.
	var last: Dictionary = snaps[snaps.size() - 1]
	var ahead: float = minf(t - float(last.time), MAX_EXTRAPOLATE)
	var out: Dictionary = last.duplicate()
	out.position = (last.position as Vector3) + (last.direction as Vector3) * float(last.speed) * ahead
	return out


## Keep the link figures: called once per sample with the moment being drawn.
func _measure(dt: float, latest: float, t: float) -> void:
	var shown: float = clampf(t, float(snaps[0].time), latest + MAX_EXTRAPOLATE)
	_behind_sum += (latest - shown + _clock - _arrived) * dt
	if t > latest:
		_guess_time += dt
	_span += dt
	_clock += dt
	if _span < MEASURE_SECONDS:
		return
	behind = _behind_sum / _span
	guessed = _guess_time / _span
	lost = float(_missed) / float(_missed + _got) if _got > 0 else 1.0
	_behind_sum = 0.0
	_guess_time = 0.0
	_span = 0.0
	_got = 0
	_missed = 0


static func _blend(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var span: float = maxf(float(b.time) - float(a.time), 0.0001)
	var u: float = clampf((t - float(a.time)) / span, 0.0, 1.0)
	var p0: Vector3 = a.position
	var p1: Vector3 = b.position
	var v0: Vector3 = (a.direction as Vector3) * float(a.speed) * span
	var v1: Vector3 = (b.direction as Vector3) * float(b.speed) * span
	var u2: float = u * u
	var u3: float = u2 * u
	var out: Dictionary = b.duplicate()
	out.position = p0 * (2.0 * u3 - 3.0 * u2 + 1.0) + v0 * (u3 - 2.0 * u2 + u) + p1 * (-2.0 * u3 + 3.0 * u2) + v1 * (u3 - u2)
	out.orientation = (a.orientation as Quaternion).slerp(b.orientation, u)
	out.direction = (a.direction as Vector3).slerp(b.direction, u).normalized()
	out.speed = lerpf(float(a.speed), float(b.speed), u)
	out.throttle = lerpf(float(a.throttle), float(b.throttle), u)
	out.controls = (a.controls as Vector3).lerp(b.controls, u)
	out.flags = int(a.flags) | int(b.flags) if u < 0.5 else int(b.flags)
	return out


## Write a sampled motion into a flight model that is not simulated locally.
static func apply(state: Dictionary, model: FlightModel) -> void:
	model.position = state.position
	model.orientation = state.orientation
	model.travel_direction = state.direction
	model.speed = state.speed
	model.throttle = state.throttle
	model.controls = state.controls
	model.boosting = (int(state.flags) & NetProtocol.FLAG_BOOSTING) != 0
	model.braking = (int(state.flags) & NetProtocol.FLAG_BRAKING) != 0


## A model's motion as a report, for sending.
static func capture(model: FlightModel, life: int, tick: int) -> Dictionary:
	var flags: int = (NetProtocol.FLAG_BOOSTING if model.boosting else 0) | (NetProtocol.FLAG_FIRING if model.firing else 0) \
		| (NetProtocol.FLAG_BRAKING if model.braking else 0)
	return {"life": life, "tick": tick, "position": model.position, "orientation": model.orientation.normalized(),
		"direction": model.travel_direction.normalized(), "speed": model.speed, "throttle": model.throttle,
		"controls": model.controls, "flags": flags}
