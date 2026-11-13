class_name EngineAudio
extends Node
## The player's own sounds: the engine of the chosen aircraft (each type has its
## own voice), airflow, the guns, and bullet strikes given and taken. Engine
## pitch follows RPM, the wind rises with airspeed, boost adds a harder edge.

var engine: AudioStreamPlayer
var wind: AudioStreamPlayer
var guns: AudioStreamPlayer
var hit: AudioStreamPlayer
var hurt: AudioStreamPlayer
var gun_pitch: float = 1.0
var hit_cooldown: float = 0.0
var active: bool = false


func _ready() -> void:
	engine = _player(null, -60.0, 1, GameSettings.BUS_ENGINE)
	wind = _player(Sfx.looped("res://assets/audio/wind_loop.wav"), -60.0, 1, GameSettings.BUS_ENGINE)
	wind.play()
	guns = _player(null, -7.0, 8, GameSettings.BUS_EFFECTS)
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
	engine.stream = Sfx.looped(String(spec.engine_sound))
	engine.play()
	guns.stream = load(String(spec.gun_sound))
	gun_pitch = float(spec.gun_pitch)
	active = true


func silence() -> void:
	active = false
	engine.volume_db = -60.0
	wind.volume_db = -60.0


func shot() -> void:
	guns.pitch_scale = gun_pitch * randf_range(0.96, 1.04)
	guns.play()


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
	if not active:
		return
	var speed_ratio: float = clampf(model.speed / float(model.spec.top_speed), 0.0, 1.4)
	var health: float = model.zone_health[Airframes.Zone.ENGINE]
	var rpm: float = 0.72 + model.throttle * 0.28 + (0.14 if model.boosting else 0.0) + (speed_ratio - 0.8) * 0.08
	rpm *= lerpf(0.88, 1.0, health)   # a damaged engine labours
	engine.pitch_scale = lerpf(engine.pitch_scale, clampf(rpm, 0.5, 1.5), 1.0 - exp(-delta * 4.0))
	var engine_db: float = -9.0 + model.throttle * 4.0 + (2.5 if model.boosting else 0.0)
	engine.volume_db = lerpf(engine.volume_db, engine_db if model.alive else -60.0, 1.0 - exp(-delta * 5.0))
	var wind_db: float = lerpf(-34.0, -10.0, clampf((speed_ratio - 0.3) / 1.0, 0.0, 1.0)) + clampf(model.g_load - 3.0, 0.0, 4.0)
	wind.volume_db = lerpf(wind.volume_db, wind_db if model.alive else -60.0, 1.0 - exp(-delta * 4.0))
	wind.pitch_scale = 0.8 + speed_ratio * 0.35
