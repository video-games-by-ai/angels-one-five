class_name EngineAudio
extends Node
## Engine drone and airflow for the local player. Pitch follows RPM, the wind
## rises with airspeed, boost adds a harder edge.

var engine: AudioStreamPlayer
var wind: AudioStreamPlayer


func _ready() -> void:
	engine = _looping_player("res://assets/audio/engine_loop.wav", -6.0)
	wind = _looping_player("res://assets/audio/wind_loop.wav", -30.0)


func _looping_player(path: String, volume_db: float) -> AudioStreamPlayer:
	var stream: AudioStreamWAV = load(path)
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = stream.get_length() * stream.mix_rate
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	add_child(player)
	player.play()
	return player


func update(model: FlightModel, delta: float) -> void:
	var speed_ratio: float = clampf(model.speed / float(model.spec.top_speed), 0.0, 1.4)
	var rpm: float = 0.72 + model.throttle * 0.28 + (0.14 if model.boosting else 0.0) + (speed_ratio - 0.8) * 0.08
	engine.pitch_scale = lerpf(engine.pitch_scale, clampf(rpm, 0.5, 1.5), 1.0 - exp(-delta * 4.0))
	var engine_db: float = -9.0 + model.throttle * 4.0 + (2.5 if model.boosting else 0.0)
	engine.volume_db = lerpf(engine.volume_db, engine_db if model.alive else -60.0, 1.0 - exp(-delta * 5.0))
	var wind_db: float = lerpf(-34.0, -10.0, clampf((speed_ratio - 0.3) / 1.0, 0.0, 1.0)) + clampf(model.g_load - 3.0, 0.0, 4.0)
	wind.volume_db = lerpf(wind.volume_db, wind_db if model.alive else -60.0, 1.0 - exp(-delta * 4.0))
	wind.pitch_scale = 0.8 + speed_ratio * 0.35
