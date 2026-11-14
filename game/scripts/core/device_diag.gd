class_name DeviceDiag
extends RefCounted
## A self-reporting test flight for a device whose log we cannot read, such as a
## phone with no debugging cable. Started with --diag, or by a build exported with
## the "diag" feature.
##
## The run is a list of short autopilot flights (stages). The first is the game
## as it is; each later one switches one more graphics feature off, so the stage
## at which a fault disappears names its cause. Every stage runs in a fresh
## process (the game restarts itself) and the progress is kept in a state file, so
## a stage that kills the game is recorded as "stopped" on the next start and the
## run carries on with the one after it.
##
## Apart from that run, every start on Android keeps a log in the same folder
## (open_log, heartbeat): engine messages and one line per second, so a crash
## leaves its last moments behind.
##
## Everything is written to one folder (on Android the game's own documents
## folder, which a computer can read over USB):
##   airflight_log.txt    engine messages and one line per second of flight
##   diag_state.json      results so far
##   shot_NN_name.jpg     one frame from each stage

const LOG_LIMIT: int = 1500000          ## bytes; a longer log starts again
const BUILD: String = "diag-3"          ## a different value starts the run again
const STAGE_SECONDS: float = 10.0
const WARMUP_SECONDS: float = 3.0       ## not counted in the frame rate
const SHOT_AT: float = 6.0

## `profile` overrides GameSettings.profile(); "reload" arrives by a scene reload
## instead of a restart, which is how the game changes aircraft and leaves a match.
const STAGES: Array[Dictionary] = [
	{"name": "low quality, as it is", "quality": 0},
	{"name": "three-quarter resolution", "quality": 0, "profile": {"render_scale": 0.75}},
	{"name": "no snow showers", "quality": 0, "snow": false},
	{"name": "no edge smoothing", "quality": 0, "snow": false, "profile": {"fxaa": false}},
	{"name": "no glow", "quality": 0, "snow": false, "profile": {"fxaa": false, "glow": false}},
	{"name": "no clouds", "quality": 0, "snow": false, "profile": {"fxaa": false, "glow": false, "no_clouds": true}},
	{"name": "no trees", "quality": 0, "snow": false, "profile": {"fxaa": false, "glow": false, "no_clouds": true, "no_trees": true}},
	{"name": "no shadows", "quality": 0, "snow": false, "profile": {"fxaa": false, "glow": false, "no_clouds": true, "no_trees": true, "shadows": false}},
	{"name": "no haze", "quality": 0, "snow": false, "profile": {"fxaa": false, "glow": false, "no_clouds": true, "no_trees": true, "shadows": false, "fog": false}},
	{"name": "medium quality", "quality": 1},
	{"name": "high quality", "quality": 2},
	{"name": "low quality after a scene reload", "quality": 0, "reload": true},
]

static var active: bool = false
static var dir: String = ""
static var state: Dictionary = {}
static var stage: Dictionary = {}
static var _log: FileAccess
static var _mutex: Mutex = Mutex.new()
static var _logger: Logger
static var _writing: bool = false
static var _time: float = 0.0
static var _beat: int = 0
static var _frames: int = 0
static var _worst: float = 0.0
static var _shot: bool = false
static var _pulse: float = 0.0


## Engine messages (errors, warnings, prints) go to the log file as they happen.
class FileLogger extends Logger:
	func _log_message(message: String, error: bool) -> void:
		DeviceDiag.write(("! " if error else "> ") + message.strip_edges())

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		DeviceDiag.write("! engine %d: %s %s (%s:%d in %s)" % [error_type, code, rationale, file, line, function])


## True when this start should fly the test: a "diag" build, --diag, or a run
## asked for from the aircraft screen (request) that has not finished yet.
static func wanted() -> bool:
	if OS.has_feature("diag") or OS.get_cmdline_user_args().has("--diag"):
		return true
	_set_dir()
	return bool(_load_state().get("requested", false))


## Start a fresh run at the next start of the game.
static func request() -> void:
	_set_dir()
	state = {"build": BUILD, "next": 0, "running": "", "results": [], "requested": true}
	_save_state()


static func _set_dir() -> void:
	dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS, false) if OS.has_feature("android") else "user://diag"


## Start (or, after a scene reload, continue) the run. Returns the stage to fly,
## or an empty dictionary when every stage has been flown.
static func begin() -> Dictionary:
	if not active:
		active = true
		open_log()
		state = _load_state()
		if String(state.running) != "":
			write("the last start stopped during stage: %s" % state.running)
			(state.results as Array).append({"name": state.running, "status": "stopped"})
			state.running = ""
			state.next = int(state.next) + 1
	var next: int = int(state.next)
	if next >= STAGES.size():
		stage = {}
		state.requested = false   # a run asked for from the aircraft screen is over: next start is the game
		_save_state()
		return stage
	stage = STAGES[next]
	state.running = stage.name
	_save_state()
	_time = 0.0
	_beat = 0
	_frames = 0
	_worst = 0.0
	_shot = false
	write("--- stage %d of %d: %s" % [next + 1, STAGES.size(), stage.name])
	return stage


## Start the log file (once per process) and send engine messages to it.
static func open_log() -> void:
	if _logger != null:
		return
	_set_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var log_path: String = dir.path_join("airflight_log.txt")
	var keep: bool = FileAccess.file_exists(log_path)
	_log = FileAccess.open(log_path, FileAccess.READ_WRITE if keep else FileAccess.WRITE)
	if _log != null and _log.get_length() > LOG_LIMIT:
		_log = FileAccess.open(log_path, FileAccess.WRITE)
	if _log != null:
		_log.seek_end()
	_logger = FileLogger.new()
	OS.add_logger(_logger)
	write("=== start %s | %s | %s %s | Godot %s | %s" % [Time.get_datetime_string_from_system(), OS.get_model_name(),
		OS.get_name(), OS.get_version(), Engine.get_version_info().string, BUILD])


## Ordinary play: one line per second with what the game is doing (`note`).
static func heartbeat(delta: float, note: String) -> void:
	if _log == null:
		return
	_pulse += delta
	if _pulse >= 1.0:
		_pulse = 0.0
		write("%s %s" % [note, _stats()])


static func _stats() -> String:
	return "fps=%d mem=%dMB vram=%dMB tex=%dMB draws=%d objects=%d" % [int(Engine.get_frames_per_second()),
		int(OS.get_static_memory_usage() / 1048576.0),
		int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0),
		int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))]


## Called once per drawn frame while a stage flies. True when the stage is over.
static func tick(delta: float, viewport: Viewport) -> bool:
	if _time == 0.0:
		var size: Vector2i = DisplayServer.window_get_size()
		write("renderer %s | %s | %s | window %dx%d | %.0f Hz" % [RenderingServer.get_current_rendering_method(),
			RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version(), size.x, size.y,
			DisplayServer.screen_get_refresh_rate()])
	_time += delta
	if _time >= WARMUP_SECONDS:
		_frames += 1
		_worst = maxf(_worst, delta)
	if int(_time) != _beat:
		_beat = int(_time)
		write("t=%d %s" % [_beat, _stats()])
	if not _shot and _time >= SHOT_AT:
		_shot = true
		var image: Image = viewport.get_texture().get_image()
		if image != null:
			image.save_jpg(dir.path_join("shot_%02d_%s.jpg" % [int(state.next) + 1, String(stage.name).replace(",", "").replace(" ", "_")]), 0.8)
	return _time >= STAGE_SECONDS


## Record the stage just flown. Returns the next stage, or empty when done.
static func finish_stage() -> Dictionary:
	var measured: float = maxf(_time - WARMUP_SECONDS, 0.001)
	var result: Dictionary = {"name": stage.name, "status": "ok", "fps": snappedf(_frames / measured, 0.1), "worst_ms": snappedf(_worst * 1000.0, 0.1)}
	(state.results as Array).append(result)
	write("stage done: %s" % JSON.stringify(result))
	state.running = ""
	state.next = int(state.next) + 1
	var following: Dictionary = STAGES[int(state.next)] if int(state.next) < STAGES.size() else {}
	if bool(following.get("reload", false)):
		state.running = following.name   # a crash inside the reload belongs to that stage
	if following.is_empty():
		state.requested = false
	_save_state()
	return following


## Text for the on-screen banner while a stage flies.
static func banner() -> String:
	return "TEST %d of %d  ·  %s" % [int(state.next) + 1, STAGES.size(), String(stage.name).to_upper()]


## The finished run, one line per stage.
static func report() -> String:
	var lines: PackedStringArray = PackedStringArray(["AIRFLIGHT DEVICE TEST  ·  FINISHED", ""])
	var number: int = 0
	for r: Dictionary in state.results:
		number += 1
		if String(r.status) == "ok":
			lines.append("%d  %s:  %.0f fps  (slowest frame %.0f ms)" % [number, r.name, float(r.fps), float(r.worst_ms)])
		else:
			lines.append("%d  %s:  STOPPED" % [number, r.name])
	lines.append("")
	lines.append("Close the game. The results are saved on the device.")
	return "\n".join(lines)


## A progress note from the game ("clouds"); nothing unless the log is open.
static func mark(step: String) -> void:
	if _log != null:
		write(". %s" % step)


static func write(line: String) -> void:
	_mutex.lock()
	if _log != null and not _writing:
		_writing = true   # a failing write must not log its own error
		_log.store_line(line)
		_log.flush()
		_writing = false
	_mutex.unlock()


static func _load_state() -> Dictionary:
	var fresh: Dictionary = {"build": BUILD, "next": 0, "running": "", "results": []}
	var f: FileAccess = FileAccess.open(dir.path_join("diag_state.json"), FileAccess.READ)
	if f == null:
		return fresh
	var saved: Variant = JSON.parse_string(f.get_as_text())
	if saved is Dictionary and String((saved as Dictionary).get("build", "")) == BUILD:
		return saved
	return fresh


static func _save_state() -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var f: FileAccess = FileAccess.open(dir.path_join("diag_state.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(state, "  "))
		f.flush()
