class_name Hud
extends Control
## In-flight interface: gunsight and nose marker near the action, status strip at
## the bottom, match bar at the top, see-through airframe damage panel on the
## middle right. Everything is drawn in _draw so it stays crisp at any resolution.

const TEXT: Color = Color("fbf4e6")
const DIM: Color = Color("e6d8bf")
const PANEL: Color = Color(0.09, 0.07, 0.05, 0.58)
const EDGE: Color = Color(1.0, 0.84, 0.59, 0.42)
const AMBER: Color = Color("ffc766")
const WARN: Color = Color("ff6a3c")
const ZONE_OK: Color = Color(1, 1, 1, 0.14)
const ZONE_DAMAGED: Color = Color("f5b942")
const ZONE_CRITICAL: Color = Color("ff5a3c")
const ZONE_NAMES: PackedStringArray = ["ENG", "BODY", "L WING", "R WING", "TAIL"]

var font: Font
var font_bold: Font
var model: FlightModel
var camera: Camera3D
var terrain: TerrainData
var input: PlayerInput
var aircraft_name: String = ""
var mode_label: String = "FREE FLIGHT"
var clock: float = 0.0
var show_fps: bool = false
var hint_time: float = 14.0
var crash_time: float = 0.0
var zone_health: PackedFloat32Array = PackedFloat32Array([1, 1, 1, 1, 1])
var zone_polygons: Array[PackedVector2Array] = []
var ui_scale: float = 1.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = load("res://assets/fonts/Montserrat-Regular.otf")
	font_bold = load("res://assets/fonts/Montserrat-SemiBold.otf")
	zone_polygons = AirframeOutline.zones()


func _process(delta: float) -> void:
	clock += delta
	hint_time = maxf(hint_time - delta, 0.0)
	ui_scale = clampf(size.y / 1080.0, 0.7, 2.0)
	queue_redraw()


func _draw() -> void:
	if model == null or camera == null:
		return
	var s: float = ui_scale
	_draw_sights(s)
	_draw_top(s)
	_draw_bottom(s)
	_draw_airframe(s)
	_draw_warnings(s)
	if hint_time > 0.0:
		_draw_hints(s)
	if show_fps:
		var fps: String = "%d FPS  %.1f ms" % [Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0)]
		draw_string(font, Vector2(size.x - 24 * s, 34 * s), fps, HORIZONTAL_ALIGNMENT_RIGHT, -1, int(15 * s), TEXT)


func _panel(rect: Rect2) -> void:
	draw_rect(rect, PANEL, true)
	draw_rect(rect, EDGE, false, 1.0)


func _text(pos: Vector2, text: String, px: float, color: Color = TEXT, bold: bool = false, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1) -> void:
	draw_string(font_bold if bold else font, pos, text, align, width, int(px), color)


func _project(world: Vector3) -> Variant:
	if camera.is_position_behind(world):
		return null
	return camera.unproject_position(world)


func _draw_sights(s: float) -> void:
	if not model.alive:
		return
	var aim_point: Variant = _project(model.position + input.aim_direction * 1200.0)
	if aim_point != null:
		var c: Vector2 = aim_point
		var r: float = 30.0 * s
		for k in range(4):
			var a0: float = k * TAU / 4.0 + 0.35
			draw_arc(c, r, a0, a0 + TAU / 4.0 - 0.7, 16, Color(0, 0, 0, 0.35), 4.0 * s)
			draw_arc(c, r, a0, a0 + TAU / 4.0 - 0.7, 16, AMBER, 1.6 * s)
		draw_circle(c, 2.4 * s, AMBER)
	var nose: Variant = _project(model.position + model.forward() * 650.0)
	if nose != null:
		var n: Vector2 = nose
		var w: float = 14.0 * s
		var shadow: Color = Color(0, 0, 0, 0.35)
		for col: Color in [shadow, TEXT]:
			var t: float = 4.0 * s if col == shadow else 1.6 * s
			draw_line(n + Vector2(-w * 1.8, 0), n + Vector2(-w * 0.6, 0), col, t)
			draw_line(n + Vector2(w * 0.6, 0), n + Vector2(w * 1.8, 0), col, t)
			draw_line(n + Vector2(0, -w * 0.6), n + Vector2(0, -w * 1.2), col, t)
		draw_circle(n, 2.0 * s, TEXT)


func _draw_top(s: float) -> void:
	var w: float = 360.0 * s
	var rect: Rect2 = Rect2(size.x * 0.5 - w * 0.5, 18 * s, w, 56 * s)
	_panel(rect)
	_text(Vector2(rect.position.x, rect.position.y + 24 * s), mode_label, 15 * s, DIM, true, HORIZONTAL_ALIGNMENT_CENTER, w)
	var minutes: int = int(clock) / 60
	var seconds: int = int(clock) % 60
	_text(Vector2(rect.position.x, rect.position.y + 47 * s), "%02d:%02d" % [minutes, seconds], 19 * s, TEXT, true, HORIZONTAL_ALIGNMENT_CENTER, w)


func _bar(pos: Vector2, label: String, value: float, color: Color, s: float, width: float = 150.0) -> float:
	_text(pos + Vector2(0, 5 * s), label, 13 * s, DIM, true)
	var bar: Rect2 = Rect2(pos + Vector2(70 * s, -4 * s), Vector2(width * s, 10 * s))
	draw_rect(bar, Color(1, 1, 1, 0.12), true)
	draw_rect(Rect2(bar.position + Vector2(1, 1) * s, Vector2((bar.size.x - 2 * s) * clampf(value, 0, 1), bar.size.y - 2 * s)), color, true)
	draw_rect(bar, Color(1, 1, 1, 0.5), false, 1.0)
	_text(bar.position + Vector2(bar.size.x + 10 * s, 10 * s), str(int(round(value * 100))), 17 * s, TEXT, true)
	return 70 * s + bar.size.x + 50 * s


func _draw_bottom(s: float) -> void:
	var w: float = 1060.0 * s
	var rect: Rect2 = Rect2(size.x * 0.5 - w * 0.5, size.y - 74 * s, w, 50 * s)
	_panel(rect)
	var x: float = rect.position.x + 22 * s
	var y: float = rect.position.y + 29 * s
	var hull: float = (zone_health[0] + zone_health[1] + zone_health[2] + zone_health[3] + zone_health[4]) / 5.0
	x += _bar(Vector2(x, y), "HULL", hull, TEXT if hull > 0.5 else ZONE_DAMAGED, s, 150.0)
	x += _bar(Vector2(x, y), "BOOST", model.boost_energy, AMBER if not model.boosting else Color("ffe4a0"), s, 150.0)
	x += _bar(Vector2(x, y), "THR", model.throttle, DIM, s, 90.0)
	var kmh: int = int(round(model.speed * 3.6))
	var alt: int = int(round(model.position.y))
	_text(Vector2(x, y + 7 * s), "%d km/h" % kmh, 19 * s, TEXT, true)
	_text(Vector2(x + 120 * s, y + 7 * s), "ALT %d m" % alt, 19 * s, TEXT, true)


func _draw_airframe(s: float) -> void:
	var w: float = 230.0 * s
	var h: float = 250.0 * s
	var rect: Rect2 = Rect2(size.x - w - 24 * s, size.y * 0.5 - h * 0.5 - 30 * s, w, h)
	_panel(rect)
	_text(rect.position + Vector2(14 * s, 24 * s), "AIRFRAME", 13 * s, DIM, true)
	_text(rect.position + Vector2(0, 24 * s), aircraft_name.to_upper(), 12 * s, DIM, false, HORIZONTAL_ALIGNMENT_RIGHT, w - 14 * s)
	var origin: Vector2 = rect.position + Vector2(w * 0.5, 40 * s + 92 * s)
	var scale_px: float = 17.0 * s
	for i in range(zone_polygons.size()):
		var poly: PackedVector2Array = PackedVector2Array()
		for p in zone_polygons[i]:
			poly.append(origin + p * scale_px)
		var health: float = zone_health[i]
		var fill: Color = ZONE_OK if health > 0.7 else (ZONE_DAMAGED if health > 0.3 else ZONE_CRITICAL)
		if health <= 0.7:
			fill.a = 0.85
		draw_colored_polygon(poly, fill)
		var outline: PackedVector2Array = poly.duplicate()
		outline.append(poly[0])
		draw_polyline(outline, Color(1, 0.96, 0.87, 0.85), 1.2 * s, true)
	var legend_y: float = rect.end.y - 16 * s
	var lx: float = rect.position.x + 14 * s
	for item: Array in [["OK", ZONE_OK, true], ["DAMAGED", ZONE_DAMAGED, false], ["CRITICAL", ZONE_CRITICAL, false]]:
		var box: Rect2 = Rect2(Vector2(lx, legend_y - 9 * s), Vector2(9, 9) * s)
		if item[2]:
			draw_rect(box, Color(1, 1, 1, 0.8), false, 1.0)
		else:
			draw_rect(box, item[1], true)
		_text(Vector2(lx + 14 * s, legend_y), item[0], 11 * s, DIM)
		lx += (36.0 + item[0].length() * 6.5) * s


func _draw_warnings(s: float) -> void:
	var y: float = size.y * 0.66
	if not model.alive:
		var t: float = clampf(crash_time * 2.0, 0.0, 1.0)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.04, 0.03, 0.35 * t), true)
		_text(Vector2(0, size.y * 0.45), "AIRCRAFT LOST", 30 * s, TEXT, true, HORIZONTAL_ALIGNMENT_CENTER, size.x)
		_text(Vector2(0, size.y * 0.45 + 34 * s), "Respawning…", 17 * s, DIM, false, HORIZONTAL_ALIGNMENT_CENTER, size.x)
		return
	var tti: float = model.time_to_impact(terrain, 3.0)
	if tti < 2.6 and int(clock * 4.0) % 2 == 0:
		_text(Vector2(0, y), "PULL UP", 26 * s, WARN, true, HORIZONTAL_ALIGNMENT_CENTER, size.x)
		y += 32 * s
	if input.arena_warning:
		_text(Vector2(0, y), "LEAVING THE VALLEY — TURN BACK", 17 * s, AMBER, true, HORIZONTAL_ALIGNMENT_CENTER, size.x)


func _draw_hints(s: float) -> void:
	var a: float = clampf(hint_time / 2.0, 0.0, 1.0)
	var lines: PackedStringArray = [
		"MOUSE  steer toward the aim circle",
		"SHIFT  boost      W / S  throttle",
		"A / D  roll      Q / E  rudder",
		"C  centre aim     ESC  pause & settings",
	]
	var rect: Rect2 = Rect2(Vector2(24 * s, size.y - 220 * s), Vector2(340 * s, 128 * s))
	draw_rect(rect, Color(PANEL, PANEL.a * a), true)
	draw_rect(rect, Color(EDGE, EDGE.a * a), false, 1.0)
	for i in range(lines.size()):
		_text(rect.position + Vector2(16 * s, (30 + i * 26) * s), lines[i], 14 * s, Color(TEXT, a))
