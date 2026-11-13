class_name GameSettings
extends RefCounted
## Player preferences, persisted to user://settings.cfg.

enum Quality { LOW, MEDIUM, HIGH }

const PATH: String = "user://settings.cfg"
const QUALITY_NAMES: PackedStringArray = ["Low", "Medium", "High"]
## Audio buses under Master; every sound in the game is routed to one of them.
const BUS_ENGINE: StringName = &"Engine"    ## engines and airflow, own and others'
const BUS_EFFECTS: StringName = &"Effects"  ## guns, strikes, explosions
const OUTPUT_CEILING_DB: float = -1.0       ## nothing leaves the game louder than this

var mouse_sensitivity: float = 1.0
var invert_y: bool = false
var level_assist: bool = true
var camera_shake: float = 0.6
var master_volume: float = 0.8
var engine_volume: float = 1.0
var effects_volume: float = 1.0
var quality: Quality = Quality.HIGH
var fullscreen: bool = false
var aircraft: int = 1   ## last aircraft flown (Airframes.Id)
var snow_showers: bool = true   ## test weather: local snow showers on a clear day
var map: String = "alpine"      ## last map flown (TerrainData.MAPS id)
var player_name: String = "Pilot"   ## shown to other players online
var host_address: String = ""       ## address or DNS name written into invites when hosting
var net_port: int = 24555           ## UDP port when hosting
var auto_port: bool = false         ## ask the router to open the port (UPnP); off unless chosen
var score_limit: int = 5            ## kills that win an online match


static func load_or_default(path: String = PATH) -> GameSettings:
	var s: GameSettings = GameSettings.new()
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(path) == OK:
		s.mouse_sensitivity = float(cfg.get_value("controls", "mouse_sensitivity", s.mouse_sensitivity))
		s.invert_y = bool(cfg.get_value("controls", "invert_y", s.invert_y))
		s.level_assist = bool(cfg.get_value("controls", "level_assist", s.level_assist))
		s.camera_shake = float(cfg.get_value("camera", "shake", s.camera_shake))
		s.master_volume = clampf(float(cfg.get_value("audio", "master_volume", s.master_volume)), 0.0, 1.0)
		s.engine_volume = clampf(float(cfg.get_value("audio", "engine_volume", s.engine_volume)), 0.0, 1.0)
		s.effects_volume = clampf(float(cfg.get_value("audio", "effects_volume", s.effects_volume)), 0.0, 1.0)
		s.quality = clampi(int(cfg.get_value("graphics", "quality", s.quality)), 0, 2) as Quality
		s.fullscreen = bool(cfg.get_value("graphics", "fullscreen", s.fullscreen))
		s.snow_showers = bool(cfg.get_value("game", "snow_showers", s.snow_showers))
		s.aircraft = clampi(int(cfg.get_value("game", "aircraft", s.aircraft)), 0, 2)
		s.map = String(cfg.get_value("game", "map", s.map))
		s.player_name = NetProtocol.clean_text(String(cfg.get_value("online", "name", s.player_name)), NetProtocol.NAME_MAX)
		s.host_address = String(cfg.get_value("online", "host_address", s.host_address)).substr(0, 253)
		s.net_port = clampi(int(cfg.get_value("online", "port", s.net_port)), 1024, 65535)
		s.auto_port = bool(cfg.get_value("online", "auto_port", s.auto_port))
		s.score_limit = clampi(int(cfg.get_value("online", "score_limit", s.score_limit)), 1, 50)
		if s.player_name == "":
			s.player_name = "Pilot"
	return s


func save(path: String = PATH) -> void:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value("controls", "mouse_sensitivity", mouse_sensitivity)
	cfg.set_value("controls", "invert_y", invert_y)
	cfg.set_value("controls", "level_assist", level_assist)
	cfg.set_value("camera", "shake", camera_shake)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("audio", "engine_volume", engine_volume)
	cfg.set_value("audio", "effects_volume", effects_volume)
	cfg.set_value("graphics", "quality", quality)
	cfg.set_value("graphics", "fullscreen", fullscreen)
	cfg.set_value("game", "aircraft", aircraft)
	cfg.set_value("game", "snow_showers", snow_showers)
	cfg.set_value("game", "map", map)
	cfg.set_value("online", "name", player_name)
	cfg.set_value("online", "host_address", host_address)
	cfg.set_value("online", "port", net_port)
	cfg.set_value("online", "auto_port", auto_port)
	cfg.set_value("online", "score_limit", score_limit)
	cfg.save(path)


## Set the bus volumes, creating the Engine and Effects buses on first use.
func apply_audio() -> void:
	_guard_output()
	_set_bus(&"Master", master_volume)
	_set_bus(BUS_ENGINE, engine_volume)
	_set_bus(BUS_EFFECTS, effects_volume)


## A limiter on the output. Without one, a burst of gunfire over a full-throttle
## engine overshoots full scale and is clipped, which sounds like a torn
## speaker; with it the peak is turned down for an instant instead.
static func _guard_output() -> void:
	var master: int = AudioServer.get_bus_index(&"Master")
	for i in range(AudioServer.get_bus_effect_count(master)):
		if AudioServer.get_bus_effect(master, i) is AudioEffectHardLimiter:
			return
	var limiter: AudioEffectHardLimiter = AudioEffectHardLimiter.new()
	limiter.ceiling_db = OUTPUT_CEILING_DB
	AudioServer.add_bus_effect(master, limiter)


static func _set_bus(bus_name: StringName, linear: float) -> void:
	var index: int = AudioServer.get_bus_index(bus_name)
	if index < 0:
		index = AudioServer.bus_count
		AudioServer.add_bus(index)
		AudioServer.set_bus_name(index, bus_name)
		AudioServer.set_bus_send(index, &"Master")
	AudioServer.set_bus_mute(index, linear <= 0.001)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(linear, 0.0001)))


## Rendering budget for each preset. Measured on the documented test machine.
func profile() -> Dictionary:
	match quality:
		Quality.LOW:
			return {"lod_scale": 0.7, "tree_range": 1700.0, "tree_shadows": false, "shadow_distance": 900.0,
				"shadow_splits": 2, "ssr": false, "ssao": false, "msaa": Viewport.MSAA_DISABLED, "fxaa": true,
				"render_scale": 0.8, "clouds": 0.6, "glow": true, "volumetric": false}
		Quality.MEDIUM:
			return {"lod_scale": 0.9, "tree_range": 2600.0, "tree_shadows": false, "shadow_distance": 1400.0,
				"shadow_splits": 4, "ssr": true, "ssao": false, "msaa": Viewport.MSAA_2X, "fxaa": false,
				"render_scale": 1.0, "clouds": 0.85, "glow": true, "volumetric": false}
		_:
			return {"lod_scale": 1.0, "tree_range": 3600.0, "tree_shadows": true, "shadow_distance": 1800.0,
				"shadow_splits": 4, "ssr": true, "ssao": true, "msaa": Viewport.MSAA_4X, "fxaa": false,
				"render_scale": 1.0, "clouds": 1.0, "glow": true, "volumetric": false}
