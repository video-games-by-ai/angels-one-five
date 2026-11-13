class_name EngineAudio
extends Node
## The player's own sounds: the engine of the chosen aircraft (each type has its
## own voice), airflow, the guns, rounds passing close, and bullet strikes given
## and taken. The engine is two loops, low revs and high revs, crossfaded as the
## RPM rises (see Sfx.engine_layers); the wind rises with airspeed. The revs
## follow the flying, not only the throttle (see Sfx.engine_rpm), and a labouring
## engine gets louder and shudders.

## Engine level at part throttle. With full throttle, boost, a labouring engine
## and the top of its shudder all at once, the loudest loop still peaks just
## under full scale (the loops are written at -14 dB with peaks near -2 dB).
const ENGINE_DB: float = -7.0
const WIND_QUIET_DB: float = -36.0
const WIND_LOUD_DB: float = -15.0    ## kept under the engine: airflow is a bed, not a hiss
const LABOUR_DB: float = 1.5         ## a fully loaded engine is this much louder
const SHUDDER_DB: float = 1.6        ## depth of its shudder
const SHUDDER_RATE: float = 7.5      ## shudders per second, slowing a little as it bogs down

var engine_low: AudioStreamPlayer
var engine_high: AudioStreamPlayer
var wind: AudioStreamPlayer
var guns: AudioStreamPlayer
var jam: AudioStreamPlayer
var whizz_player: AudioStreamPlayer
var hit: AudioStreamPlayer
var hurt: AudioStreamPlayer
var gun_pitch: float = 1.0
var hit_cooldown: float = 0.0
var whizz_cooldown: float = 0.0
var rpm: float = 0.8
var labour: float = 0.0        ## smoothed engine load, 0..1
var shudder_phase: float = 0.0
var level_db: float = -60.0
var was_overheated: bool = false
var active: bool = false


func _ready() -> void:
	engine_low = _player(null, -60.0, 1, GameSettings.BUS_ENGINE)
	engine_high = _player(null, -60.0, 1, GameSettings.BUS_ENGINE)
	wind = _player(Sfx.looped("res://assets/audio/wind_loop.wav"), -60.0, 1, GameSettings.BUS_ENGINE)
	wind.play()
	guns = _player(null, -6.0, 8, GameSettings.BUS_EFFECTS)
	jam = _player(load("res://assets/audio/gun_jam.wav"), -5.0, 2, GameSettings.BUS_EFFECTS)
	whizz_player = _player(load("res://assets/audio/whizz.wav"), -11.0, 4, GameSettings.BUS_EFFECTS)
	hit = _player(load("res://assets/audio/hit.wav"), -9.0, 4, GameSettings.BUS_EFFECTS)
	hurt = _player(load("res://assets/audio/hurt.wav"), -4.0, 4, GameSettings.BUS_EFFECTS)


func _player(stream: AudioStream, volume_db: float, polyphony: int, bus: StringName) -> AudioStreamPlayer:
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.bus = bus
	player.stream = stream
	player.volume_db = volume_db
	player.max_polyphony = polyphony
	add_child(player)
	return player


## Switch to the sounds of one aircraft type.
func use_aircraft(spec: Dictionary) -> void:
	engine_low.stream = Sfx.engine_loop(spec, false)
	engine_high.stream = Sfx.engine_loop(spec, true)
	engine_low.play()
	engine_high.play()
	guns.stream = Sfx.gun_stream(spec)
	gun_pitch = float(spec.gun_pitch)
	was_overheated = false
	active = true


func silence() -> void:
	active = false
	level_db = -60.0
	engine_low.volume_db = -60.0
	engine_high.volume_db = -60.0
	wind.volume_db = -60.0


## One round fired. Hot guns sound a little duller and slower.
func shot(heat: float = 0.0) -> void:
	guns.pitch_scale = gun_pitch * lerpf(1.0, 0.92, clampf((heat - 0.5) * 2.0, 0.0, 1.0))
	guns.play()


## A hostile round passing close to the cockpit.
func whizz() -> void:
	if whizz_cooldown <= 0.0:
		whizz_cooldown = 0.09
		whizz_player.pitch_scale = randf_range(0.8, 1.2)
		whizz_player.play()


## A round of ours striking an opponent.
func hit_confirm() -> void:
	if hit_cooldown <= 0.0:
		hit_cooldown = 0.05
		hit.pitch_scale = randf_range(0.9, 1.15)
		hit.play()


## A round striking our own aircraft.
func struck() -> void:
	hurt.pitch_scale = randf_range(0.85, 1.1)
	hurt.play()


func update(model: FlightModel, delta: float) -> void:
	hit_cooldown = maxf(hit_cooldown - delta, 0.0)
	whizz_cooldown = maxf(whizz_cooldown - delta, 0.0)
	if not active:
		return
	if model.gun_overheated and not was_overheated:
		jam.play()   # the guns stop with a clunk
	was_overheated = model.gun_overheated
	# The engine takes a moment to follow the throttle, quicker up than down.
	var wanted: float = Sfx.engine_rpm(model)
	rpm = lerpf(rpm, wanted, 1.0 - exp(-delta * (3.2 if wanted > rpm else 2.2)))
	var layers: PackedFloat32Array = Sfx.engine_layers(rpm)
	# Working hard uphill the engine is louder and shudders: two beats that
	# drift against each other, so it never settles into a steady wobble.
	labour = lerpf(labour, clampf(model.engine_load(), 0.0, 1.0), 1.0 - exp(-delta * 2.5))
	shudder_phase = fmod(shudder_phase + delta * SHUDDER_RATE * lerpf(1.0, 0.8, labour), 1000.0)
	var shudder: float = (0.65 * sin(shudder_phase * TAU) + 0.35 * sin(shudder_phase * TAU * 1.62 + 1.0)) * SHUDDER_DB * labour * labour
	var wanted_db: float = ENGINE_DB + model.engine_throttle() * 3.5 + (2.5 if model.boosting else 0.0) + labour * LABOUR_DB if model.alive else -60.0
	level_db = lerpf(level_db, wanted_db, 1.0 - exp(-delta * 5.0))
	engine_low.pitch_scale = layers[0]
	engine_low.volume_db = level_db + shudder + linear_to_db(maxf(layers[1], 0.001))
	engine_high.pitch_scale = layers[2]
	engine_high.volume_db = level_db + shudder + linear_to_db(maxf(layers[3], 0.001))
	var speed_ratio: float = clampf(model.speed / float(model.spec.top_speed), 0.0, 1.4)
	var wind_db: float = lerpf(WIND_QUIET_DB, WIND_LOUD_DB, clampf((speed_ratio - 0.3) / 1.0, 0.0, 1.0)) + clampf(model.g_load - 3.0, 0.0, 4.0)
	wind.volume_db = lerpf(wind.volume_db, wind_db if model.alive else -60.0, 1.0 - exp(-delta * 4.0))
	wind.pitch_scale = 0.8 + speed_ratio * 0.3
