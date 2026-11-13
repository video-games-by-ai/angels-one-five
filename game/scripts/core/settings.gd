class_name GameSettings
extends RefCounted
## Player preferences, persisted to user://settings.cfg.

enum Quality { LOW, MEDIUM, HIGH }

const PATH: String = "user://settings.cfg"
const QUALITY_NAMES: PackedStringArray = ["Low", "Medium", "High"]

var mouse_sensitivity: float = 1.0
var invert_y: bool = false
var level_assist: bool = true
var camera_shake: float = 0.6
var master_volume: float = 0.8
var quality: Quality = Quality.HIGH
var fullscreen: bool = false
var aircraft: int = 1   ## last aircraft flown (Airframes.Id)
var snow_showers: bool = true   ## test weather: local snow showers on a clear day
var map: String = "alpine"      ## last map flown (TerrainData.MAPS id)


static func load_or_default() -> GameSettings:
	var s: GameSettings = GameSettings.new()
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(PATH) == OK:
		s.mouse_sensitivity = float(cfg.get_value("controls", "mouse_sensitivity", s.mouse_sensitivity))
		s.invert_y = bool(cfg.get_value("controls", "invert_y", s.invert_y))
		s.level_assist = bool(cfg.get_value("controls", "level_assist", s.level_assist))
		s.camera_shake = float(cfg.get_value("camera", "shake", s.camera_shake))
		s.master_volume = float(cfg.get_value("audio", "master_volume", s.master_volume))
		s.quality = clampi(int(cfg.get_value("graphics", "quality", s.quality)), 0, 2) as Quality
		s.fullscreen = bool(cfg.get_value("graphics", "fullscreen", s.fullscreen))
		s.snow_showers = bool(cfg.get_value("game", "snow_showers", s.snow_showers))
		s.aircraft = clampi(int(cfg.get_value("game", "aircraft", s.aircraft)), 0, 2)
		s.map = String(cfg.get_value("game", "map", s.map))
	return s


func save() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value("controls", "mouse_sensitivity", mouse_sensitivity)
	cfg.set_value("controls", "invert_y", invert_y)
	cfg.set_value("controls", "level_assist", level_assist)
	cfg.set_value("camera", "shake", camera_shake)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("graphics", "quality", quality)
	cfg.set_value("graphics", "fullscreen", fullscreen)
	cfg.set_value("game", "aircraft", aircraft)
	cfg.set_value("game", "snow_showers", snow_showers)
	cfg.set_value("game", "map", map)
	cfg.save(PATH)


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
