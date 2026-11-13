class_name Sfx
extends RefCounted
## Small audio helpers shared by the player's cockpit sounds and world sounds.

## Each engine has two loops: one made at low revs and one made half as fast
## again. A loop plays at its natural speed when the RPM equals its `_AT` value.
const ENGINE_LOW_AT: float = 0.75
const ENGINE_HIGH_AT: float = 1.125
const GUN_TAKES: int = 3
const SOUND_SPEED: float = 340.0


## A WAV resource set to loop over its whole length.
static func looped(path: String) -> AudioStreamWAV:
	var stream: AudioStreamWAV = load(path)
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = int(stream.get_length() * stream.mix_rate)
	return stream


## One of an aircraft's two engine loops (`spec.engine_sound` is their shared name).
static func engine_loop(spec: Dictionary, high: bool) -> AudioStreamWAV:
	return looped("%s_%s.wav" % [String(spec.engine_sound), "high" if high else "low"])


## Engine speed as the sounds understand it. The throttle sets the base (about
## 0.78 throttled back, 1.0 at full throttle, 1.16 on boost) and the flying moves
## it: the revs follow the airspeed, sag by up to ENGINE_LOAD_SAG when the engine
## labours in a climb or a hard pull, and run up by ENGINE_DIVE_RISE when a dive
## unloads the propeller (see FlightModel.engine_load). At full throttle that is
## about 0.8 hanging at the top of a steep climb and 1.2 in a vertical dive. A
## damaged engine runs slow.
const ENGINE_LOAD_SAG: float = 0.13
const ENGINE_DIVE_RISE: float = 0.10
const ENGINE_SPEED_SHARE: float = 0.18   ## revs gained per unit of airspeed (as a share of top speed)
static func engine_rpm(model: FlightModel) -> float:
	var speed_ratio: float = clampf(model.speed / float(model.spec.top_speed), 0.0, 1.4)
	var rpm: float = 0.70 + model.engine_throttle() * 0.30 + (0.16 if model.boosting else 0.0) + (speed_ratio - 0.8) * ENGINE_SPEED_SHARE
	var load: float = model.engine_load()
	rpm -= load * (ENGINE_LOAD_SAG if load > 0.0 else ENGINE_DIVE_RISE)
	return clampf(rpm * lerpf(0.86, 1.0, model.zone_health[Airframes.Zone.ENGINE]), 0.6, 1.4)


## How to play the two loops at `rpm`: [low pitch, low level, high pitch, high
## level], levels 0..1. The low loop carries idle and cruise and hands over to the
## high loop as the revs rise, so the exhaust beat quickens while the body of the
## sound stays put. The levels always add up to the same power.
static func engine_layers(rpm: float) -> PackedFloat32Array:
	var blend: float = smoothstep(0.78, 1.12, rpm)
	return PackedFloat32Array([rpm / ENGINE_LOW_AT, cos(blend * PI * 0.5), rpm / ENGINE_HIGH_AT, sin(blend * PI * 0.5)])


## Pitch change heard from a source moving at `source_velocity` past a listener.
static func doppler(source: Vector3, source_velocity: Vector3, listener: Vector3, listener_velocity: Vector3) -> float:
	var away: Vector3 = source - listener
	var distance: float = away.length()
	if distance < 1.0:
		return 1.0
	var parting: float = (source_velocity - listener_velocity).dot(away / distance)   # m/s, + = moving apart
	return clampf(SOUND_SPEED / (SOUND_SPEED + parting), 0.72, 1.4)


## An aircraft's gun: several takes of the same shot, picked at random with a
## little pitch and level change, so a burst does not sound like one sample.
static func gun_stream(spec: Dictionary) -> AudioStreamRandomizer:
	var stream: AudioStreamRandomizer = AudioStreamRandomizer.new()
	for take in range(1, GUN_TAKES + 1):
		stream.add_stream(-1, load("%s_%d.wav" % [String(spec.gun_sound), take]))
	stream.random_pitch = 1.05
	stream.random_volume_offset_db = 1.2
	return stream
