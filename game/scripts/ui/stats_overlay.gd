class_name StatsOverlay
extends Control
## The performance readout in the top-right corner (F3, or the pause menu).
##
## BRIEF is one line: frame rate, frame time and, online, the ping. FULL adds:
##  - 1% low and the slowest frame of the last five seconds, and a graph of
##    recent frame times. Stutter shows here while the average still looks fine.
##  - Where a frame's time goes: the graphics card, the processor preparing the
##    picture, and the game's own simulation. The largest is what limits the rate.
##  - How much is drawn (draw calls, triangles) and the memory in use.
##  - What is being measured: resolution, quality, vsync, graphics card.
##  - Online: the ping, the data rate, and for each other player the DELAY (how
##    old the picture of their aircraft is: the network journey plus the
##    smoothing), reports LOST, and how often their aircraft was a GUESS.

enum Level { OFF, BRIEF, FULL }

const LEVEL_NAMES: PackedStringArray = ["Off", "Frame rate", "Everything"]
const REFRESH: float = 0.25           ## seconds between redraws; the figures themselves change slower
const WIDTH: float = 380.0            ## px at 1080 lines
const PAD: float = 12.0
const GRAPH_HEIGHT: float = 44.0
const BAR: float = 2.0                ## px per frame in the graph
const SMOOTH_MS: float = 1000.0 / 60.0
const SLOW_MS: float = 1000.0 / 30.0
const GOOD: Color = Color(1.0, 0.96, 0.9, 0.62)

var level: int = Level.OFF: set = set_level
var frames: FrameStats = FrameStats.new()
var settings: GameSettings
var session: NetSession               ## the online session, or null
var remotes: Array[Combatant] = []    ## the other players' aircraft while a match is flown
var right_inset: float = 0.0          ## room kept on the right, at 1080 lines (the touch pause button)

var font: Font
var font_bold: Font
var _wait: float = 0.0
var _fps: float = 0.0
var _gpu_ms: float = 0.0
var _cpu_ms: float = 0.0
var _gpu_sum: float = 0.0
var _cpu_sum: float = 0.0
var _timed: int = 0
var _measuring: bool = false          ## the viewport is timing its rendering for us


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	font = load("res://assets/fonts/Montserrat-Regular.otf")
	font_bold = load("res://assets/fonts/Montserrat-SemiBold.otf")
	_apply_level()


func set_level(value: int) -> void:
	level = clampi(value, Level.OFF, Level.FULL)
	if is_inside_tree():
		_apply_level()


func _apply_level() -> void:
	visible = level != Level.OFF
	if level == Level.OFF:
		frames.clear()
	_wait = REFRESH   # show at once
	# Timing the rendering costs a little, so it runs only while it is shown.
	var want: bool = level == Level.FULL
	if want != _measuring:
		_measuring = want
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), want)
		_gpu_sum = 0.0
		_cpu_sum = 0.0
		_timed = 0


func _exit_tree() -> void:
	if _measuring:
		_measuring = false
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false)


func _process(delta: float) -> void:
	if level == Level.OFF:
		return
	frames.add(delta)
	if _measuring:
		var rid: RID = get_viewport().get_viewport_rid()
		_gpu_sum += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		_cpu_sum += RenderingServer.viewport_get_measured_render_time_cpu(rid) + RenderingServer.get_frame_setup_time_cpu()
		_timed += 1
	_wait += delta
	if _wait < REFRESH:
		return
	_wait = 0.0
	frames.summarise()
	_fps = Engine.get_frames_per_second()
	if _timed > 0:
		_gpu_ms = _gpu_sum / _timed
		_cpu_ms = _cpu_sum / _timed
		_gpu_sum = 0.0
		_cpu_sum = 0.0
		_timed = 0
	queue_redraw()


## Round trip of the local player to the host in ms; -1 when hosting, offline or unknown.
func my_ping() -> float:
	if session == null or session.role != NetSession.Role.CLIENT:
		return -1.0
	return session.ping_ms(session.my_id())


## How old the picture of a remote aircraft is, in ms: its report's journey
## here plus the delay the smoothing adds. -1 while either is unknown.
static func view_delay_ms(net: NetSession, c: Combatant) -> float:
	if net == null or c.buffer == null or c.buffer.behind < 0.0:
		return -1.0
	var transit: float = net.transit_ms(c.peer_id)
	return transit + c.buffer.behind * 1000.0 if transit >= 0.0 else -1.0


func _draw() -> void:
	if level == Level.OFF or font == null:
		return
	var s: float = clampf(size.y / 1080.0, 0.7, 2.0)
	var online: bool = session != null and session.role != NetSession.Role.NONE and not session.players.is_empty()
	var ping: float = my_ping()
	var w: float = WIDTH * s
	var line: float = 19.0 * s
	if level == Level.BRIEF:
		var text: String = "%d FPS  ·  %.1f ms" % [roundi(_fps), 1000.0 / maxf(_fps, 1.0)]
		if ping >= 0.0:
			text += "  ·  PING %d ms" % roundi(ping)
		var tw: float = font_bold.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(15 * s)).x + 2.0 * PAD * s
		var box: Rect2 = Rect2(size.x - tw - (24.0 + right_inset) * s, 18 * s, tw, 30 * s)
		_panel(box)
		_text(box.position + Vector2(PAD * s, 21 * s), text, 15 * s, _rate_colour(_fps), true)
		return

	var rows: int = remotes.size() if online else 0
	var h: float = (PAD * 2.0 + 30.0 + 19.0 + GRAPH_HEIGHT + 12.0 + 19.0 * 4.0 + 16.0) * s
	if online:
		h += (10.0 + 19.0 * 2.0 + (17.0 + 19.0 * rows if rows > 0 else 0.0)) * s
	var rect: Rect2 = Rect2(size.x - w - (24.0 + right_inset) * s, 18 * s, w, h)
	_panel(rect)
	var x: float = rect.position.x + PAD * s
	var inner: float = w - 2.0 * PAD * s
	var y: float = rect.position.y + PAD * s + 22 * s
	_text(Vector2(x, y), "%d FPS" % roundi(_fps), 24 * s, _rate_colour(_fps), true)
	_text(Vector2(x, y), "%.1f ms a frame" % (1000.0 / maxf(_fps, 1.0)), 15 * s, Hud.TEXT, false, HORIZONTAL_ALIGNMENT_RIGHT, inner)
	y += 8 * s + line
	_text(Vector2(x, y), "1%% LOW  %d FPS" % roundi(frames.low_fps), 13 * s, _rate_colour(frames.low_fps), true)
	_text(Vector2(x, y), "SLOWEST FRAME  %d ms" % roundi(frames.worst_ms), 13 * s, _frame_colour(frames.worst_ms), true, HORIZONTAL_ALIGNMENT_RIGHT, inner)
	y += 8 * s
	_draw_graph(Rect2(x, y, inner, GRAPH_HEIGHT * s), s)
	y += (GRAPH_HEIGHT + 4.0) * s + line

	var gpu: String = "%.1f ms" % _gpu_ms if _gpu_ms > 0.0 else "not measured"
	var sim_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_text(Vector2(x, y), "GPU  %s   ·   CPU  %.1f draw + %.1f game" % [gpu, _cpu_ms, sim_ms], 13 * s, Hud.TEXT, true)
	y += line
	_text(Vector2(x, y), "%d DRAW CALLS   ·   %s TRIANGLES" % [int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		_count(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))], 13 * s, Hud.DIM, true)
	y += line
	_text(Vector2(x, y), "MEMORY  %d MB video   ·   %d MB game" % [int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0),
		int(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0)], 13 * s, Hud.DIM, true)
	y += line
	_text(Vector2(x, y), _setup_line(), 13 * s, Hud.DIM, true)
	y += 16 * s
	_text(Vector2(x, y), RenderingServer.get_video_adapter_name().left(48), 11 * s, Color(Hud.DIM, 0.75))
	if not online:
		return

	y += 10 * s
	draw_line(Vector2(x, y), Vector2(x + inner, y), Hud.EDGE, 1.0)
	y += line
	if ping >= 0.0:
		_text(Vector2(x, y), "YOUR PING  %d ms" % roundi(ping), 13 * s, _delay_colour(ping, 120.0, 250.0), true)
		_text(Vector2(x, y), "varies by ± %d ms" % roundi(session.ping_jitter), 13 * s, Hud.DIM, false, HORIZONTAL_ALIGNMENT_RIGHT, inner)
	else:
		_text(Vector2(x, y), "HOSTING  ·  %d PLAYERS" % session.players.size(), 13 * s, Hud.TEXT, true)
	y += line
	_text(Vector2(x, y), "DATA  %.1f kB/s out   ·   %.1f kB/s in" % [session.sent_rate / 1000.0, session.received_rate / 1000.0], 13 * s, Hud.DIM, true)
	if rows == 0:
		return
	# One row per other player. Columns end at these shares of the width.
	var cols: Array[float] = [0.52, 0.72, 0.86, 1.0]
	var heads: Array[String] = ["PING", "DELAY", "LOST", "GUESS"]
	y += 17 * s
	_text(Vector2(x, y), "OTHER PLAYERS", 11 * s, Color(Hud.DIM, 0.75), true)
	for k in range(cols.size()):
		_text(Vector2(x, y), heads[k], 11 * s, Color(Hud.DIM, 0.75), true, HORIZONTAL_ALIGNMENT_RIGHT, inner * cols[k])
	for c in remotes:
		y += line
		var gone: bool = c.left
		_text(Vector2(x, y), c.pilot_name.left(12), 13 * s, Hud.DIM if gone else Hud.TEXT, true)
		if gone:
			_text(Vector2(x, y), "left", 13 * s, Hud.DIM, false, HORIZONTAL_ALIGNMENT_RIGHT, inner)
			continue
		var their_ping: float = session.ping_ms(c.peer_id)
		var delay: float = view_delay_ms(session, c)
		var measured: bool = c.buffer != null and c.buffer.behind >= 0.0
		var cells: Array[String] = [
			"host" if c.peer_id == 1 else ("%d ms" % roundi(their_ping) if their_ping >= 0.0 else "–"),
			"%d ms" % roundi(delay) if delay >= 0.0 else "–",
			"%d%%" % roundi(c.buffer.lost * 100.0) if measured else "–",
			"%d%%" % roundi(c.buffer.guessed * 100.0) if measured else "–"]
		var colours: Array[Color] = [
			_delay_colour(their_ping, 120.0, 250.0), _delay_colour(delay, 200.0, 350.0),
			_delay_colour(c.buffer.lost * 100.0 if measured else 0.0, 5.0, 15.0),
			_delay_colour(c.buffer.guessed * 100.0 if measured else 0.0, 5.0, 15.0)]
		for k in range(cols.size()):
			_text(Vector2(x, y), cells[k], 13 * s, colours[k], true, HORIZONTAL_ALIGNMENT_RIGHT, inner * cols[k])


## Recent frames as bars, newest on the right, with lines at the frame times
## of 60 and 30 frames a second. A tall bar is a hitch.
func _draw_graph(rect: Rect2, s: float) -> void:
	draw_rect(rect, Color(0, 0, 0, 0.25), true)
	var bar: float = BAR * s
	var times: PackedFloat32Array = frames.recent(int(rect.size.x / bar))
	# The scale follows the slowest frame in view, so fast frames still show
	# their unevenness; one long stall must not flatten everything else.
	var top_ms: float = 0.0
	for ms in times:
		top_ms = maxf(top_ms, ms)
	top_ms = clampf(top_ms * 1.3, SMOOTH_MS * 1.25, 200.0)
	var left: float = rect.end.x - times.size() * bar
	for i in range(times.size()):
		var tall: float = clampf(times[i] / top_ms, 0.0, 1.0) * rect.size.y
		draw_rect(Rect2(left + i * bar, rect.end.y - tall, bar, tall), _frame_colour(times[i], GOOD), true)
	for mark: float in [SMOOTH_MS, SLOW_MS]:
		if mark > top_ms * 0.97:
			continue
		var my: float = rect.end.y - mark / top_ms * rect.size.y
		draw_line(Vector2(rect.position.x, my), Vector2(rect.end.x, my), Color(1, 1, 1, 0.28), 1.0)
		_text(Vector2(rect.position.x + 3 * s, my - 2 * s), "%d" % roundi(1000.0 / mark), 10 * s, Color(1, 1, 1, 0.6))


## What the figures were measured at: pixels drawn, quality, vsync.
func _setup_line() -> String:
	var window: Vector2i = get_window().size
	var scale_3d: float = get_viewport().scaling_3d_scale
	var text: String = "%d×%d" % [window.x, window.y]
	if absf(scale_3d - 1.0) > 0.01:
		text += " at %d%%" % roundi(scale_3d * 100.0)
	if settings != null:
		text += "   ·   %s" % GameSettings.QUALITY_NAMES[settings.quality].to_upper()
	if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED:
		text += "   ·   VSYNC OFF"
	else:
		var hz: float = DisplayServer.screen_get_refresh_rate()
		text += "   ·   VSYNC %d Hz" % roundi(hz) if hz > 0.0 else "   ·   VSYNC ON"
	return text


static func _count(n: float) -> String:
	if n >= 1.0e6:
		return "%.2f M" % (n / 1.0e6)
	if n >= 1.0e4:
		return "%d K" % roundi(n / 1000.0)
	return "%d" % int(n)


func _rate_colour(fps: float) -> Color:
	return Hud.WARN if fps < 28.0 else (Hud.AMBER if fps < 50.0 else Hud.TEXT)


func _frame_colour(ms: float, good: Color = Hud.TEXT) -> Color:
	return Hud.WARN if ms > SLOW_MS * 1.05 else (Hud.AMBER if ms > SMOOTH_MS * 1.25 else good)


## Amber from `high`, red from `bad`; anything unknown (negative) is dim.
func _delay_colour(value: float, high: float, bad: float) -> Color:
	if value < 0.0:
		return Hud.DIM
	return Hud.WARN if value >= bad else (Hud.AMBER if value >= high else Hud.TEXT)


func _panel(rect: Rect2) -> void:
	draw_rect(rect, Hud.PANEL, true)
	draw_rect(rect, Hud.EDGE, false, 1.0)


func _text(pos: Vector2, text: String, px: float, color: Color = Hud.TEXT, bold: bool = false, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1) -> void:
	draw_string(font_bold if bold else font, pos, text, align, width, int(px), color)
