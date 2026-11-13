class_name Hud
extends Control
## In-flight interface: steering circle and gun cross near the action, markers
## and a lead pip on opponents, five health dots on the aircraft in front of the
## guns, a radar map in the top left, status strip at the bottom, score bar at
## the top, see-through airframe damage panel on the middle right. Everything is
## drawn in _draw so it stays crisp at any resolution.

const TEXT: Color = Color("fbf4e6")
const DIM: Color = Color("e6d8bf")
const PANEL: Color = Color(0.09, 0.07, 0.05, 0.58)
const EDGE: Color = Color(1.0, 0.84, 0.59, 0.42)
const AMBER: Color = Color("ffc766")
const WARN: Color = Color("ff6a3c")
const ZONE_OK: Color = Color(1, 1, 1, 0.14)
const ZONE_DAMAGED: Color = Color("f5b942")
const ZONE_CRITICAL: Color = Color("ff5a3c")
const HOSTILE: Color = Color("ff7a4d")
const FRIEND: Color = Color("fbf4e6")
const DOT_RED: Color = Color("ff5a4a")
const LEAD_RANGE: float = 1000.0
const HEALTH_DOTS: int = 5
const DOTS_FADE_IN: float = 0.15      ## seconds for the health dots to appear
const DOTS_LINGER: float = 2.0        ## seconds they stay after the guns move off or a hit lands
const DOTS_FADE_OUT: float = 0.35
const RADAR_SIZE: float = 210.0       ## px across at 1080p

var font: Font
var font_bold: Font
var model: FlightModel
var camera: Camera3D
var terrain: TerrainData
var input: PlayerInput
var player: Combatant
var opponents: Array[Combatant] = []
var aircraft_name: String = ""
var mode_label: String = "PRACTICE DOGFIGHT"
var airframe_id: int = -1
var outline_extent: Vector3 = Vector3.ZERO
var hit_marker: float = 0.0       ## flashes when one of our rounds lands
var damage_flash: float = 0.0     ## flashes when we are hit
var message: String = ""
var message_time: float = 0.0
var lost_reason: String = "AIRCRAFT LOST"
var clock: float = 0.0
var show_fps: bool = false
var hint_time: float = 14.0
var crash_time: float = 0.0
var zone_polygons: Array[PackedVector2Array] = []
var ui_scale: float = 1.0
var frame_delta: float = 0.0
var dots_shown: Dictionary = {}       ## combatant id -> health-dot opacity 0..1
var dots_hold: Dictionary = {}        ## combatant id -> seconds the dots stay up
var radar: Radar


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = load("res://assets/fonts/Montserrat-Regular.otf")
	font_bold = load("res://assets/fonts/Montserrat-SemiBold.otf")


## Point the HUD at the player's aircraft for a new sortie.
func attach(pilot: Combatant, enemies: Array[Combatant]) -> void:
	player = pilot
	model = pilot.model
	opponents = enemies
	airframe_id = pilot.frame_id
	aircraft_name = String(model.spec.name)
	zone_polygons = AirframeOutline.zones(airframe_id)
	outline_extent = AirframeOutline.extent(airframe_id)
	clock = 0.0
	hint_time = 16.0
	crash_time = 0.0
	hit_marker = 0.0
	damage_flash = 0.0
	message_time = 0.0
	dots_shown.clear()
	dots_hold.clear()
	if radar == null and terrain != null:
		radar = Radar.new()
		radar.hud = self
		add_child(radar)
		radar.setup(terrain)


## One of our rounds struck `target`: keep its health dots up for a while.
func target_hit(target: Combatant) -> void:
	dots_hold[target.id] = DOTS_LINGER
	dots_shown[target.id] = maxf(float(dots_shown.get(target.id, 0.0)), 0.6)


func is_friend(other: Combatant) -> bool:
	return player != null and other.team == player.team


## Health dots for a hull share: one per fifth of the hull, at least one while flying.
static func health_dots(hull_share: float) -> int:
	if hull_share <= 0.0:
		return 0
	return clampi(ceili(hull_share * HEALTH_DOTS - 0.001), 1, HEALTH_DOTS)


func announce(text: String) -> void:
	message = text
	message_time = 3.5


func _process(delta: float) -> void:
	clock += delta
	hint_time = maxf(hint_time - delta, 0.0)
	hit_marker = maxf(hit_marker - delta, 0.0)
	damage_flash = maxf(damage_flash - delta * 1.8, 0.0)
	message_time = maxf(message_time - delta, 0.0)
	ui_scale = clampf(size.y / 1080.0, 0.7, 2.0)
	frame_delta = delta
	if radar != null:
		radar.visible = model != null
		radar.position = Vector2(26.0, 34.0) * ui_scale
		radar.size = Vector2.ONE * RADAR_SIZE * ui_scale
		radar.queue_redraw()
	queue_redraw()


func _draw() -> void:
	if model == null or camera == null:
		return
	var s: float = ui_scale
	if damage_flash > 0.0:
		_draw_damage_flash()
	_draw_targets(s)
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
		if hit_marker > 0.0:
			# Hit confirmation: a brief X on the gun cross.
			var a: float = clampf(hit_marker / 0.12, 0.0, 1.0)
			for d: Vector2 in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
				draw_line(n + d * 7.0 * s, n + d * 15.0 * s, Color(WARN, a), 2.4 * s)


func _draw_damage_flash() -> void:
	var a: float = clampf(damage_flash, 0.0, 1.0) * 0.5
	var edge: float = size.y * 0.16
	var clear: Color = Color(WARN, 0.0)
	var tint: Color = Color(WARN, a)
	draw_polygon([Vector2.ZERO, Vector2(size.x, 0), Vector2(size.x, edge), Vector2(0, edge)], [tint, tint, clear, clear])
	draw_polygon([Vector2(0, size.y), Vector2(size.x, size.y), Vector2(size.x, size.y - edge), Vector2(0, size.y - edge)], [tint, tint, clear, clear])
	draw_polygon([Vector2.ZERO, Vector2(0, size.y), Vector2(edge, size.y), Vector2(edge, 0)], [tint, tint, clear, clear])
	draw_polygon([Vector2(size.x, 0), Vector2(size.x, size.y), Vector2(size.x - edge, size.y), Vector2(size.x - edge, 0)], [tint, tint, clear, clear])


## Brackets, range and a lead pip on each opponent; an edge arrow when off
## screen; health dots on the one the guns point at. Friends are drawn in white
## and get no lead pip.
func _draw_targets(s: float) -> void:
	if not model.alive:
		return
	var gun_cross: Variant = _project(model.position + model.forward() * 650.0)
	var aim_point: Variant = _project(model.position + input.aim_direction * 1200.0)
	# Only the aircraft nearest the sights counts as aimed at, so targets that
	# overlap far away do not all show their dots.
	var best: Combatant = null
	var best_score: float = INF
	for enemy in opponents:
		if enemy.model.alive and not enemy.left:
			var score: float = _draw_target(enemy, s, gun_cross, aim_point)
			if score < best_score:
				best_score = score
				best = enemy
	for enemy in opponents:
		_update_dots(enemy, enemy == best)


## Draws one opponent's marker. Returns how close the sights are to it, as a
## share of its catch radius (below 1 = aimed at), or INF when they are off it.
func _draw_target(enemy: Combatant, s: float, gun_cross: Variant, aim_point: Variant) -> float:
	var friend: bool = is_friend(enemy)
	var colour: Color = FRIEND if friend else HOSTILE
	var where: Vector3 = enemy.model.position
	if enemy.aircraft != null:
		where = enemy.aircraft.get_global_transform_interpolated().origin
	var dist: float = where.distance_to(model.position)
	var screen: Variant = _project(where)
	var margin: float = 46.0 * s
	var inside: Rect2 = Rect2(Vector2(margin, margin), size - Vector2(margin, margin) * 2.0)
	if screen == null or not inside.has_point(screen):
		_draw_edge_arrow(where, dist, s, colour)
		return INF
	var c: Vector2 = screen
	var half: float = clampf(9.0 * size.y / maxf(dist, 1.0), 13.0 * s, 60.0 * s)
	var arm: float = half * 0.42
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var p: Vector2 = c + corner * half
		draw_line(p, p - Vector2(corner.x * arm, 0), colour, 1.8 * s)
		draw_line(p, p - Vector2(0, corner.y * arm), colour, 1.8 * s)
	var tag: String = String(enemy.model.spec.short) if enemy.pilot_name == "" else "%s · %s" % [enemy.pilot_name.to_upper(), String(enemy.model.spec.short)]
	_text(Vector2(c.x - 140 * s, c.y - half - 8 * s), "%s  %d m" % [tag, int(dist)], 12 * s, colour, true, HORIZONTAL_ALIGNMENT_CENTER, 280 * s)
	var reach: float = maxf(half * 1.25, 28.0 * s)
	var aimed: float = INF
	for point: Variant in [gun_cross, aim_point]:
		if point != null and (point as Vector2).distance_to(c) < reach:
			aimed = minf(aimed, (point as Vector2).distance_to(c) / reach)
	if dist < LEAD_RANGE and not friend:
		# Where to put the gun cross so the rounds and the target meet.
		var flight_time: float = dist / BulletField.SPEED
		var lead: Variant = _project(where + (enemy.model.velocity() - model.velocity()) * flight_time)
		if lead != null:
			var l: Vector2 = lead
			draw_line(c, l, Color(HOSTILE, 0.35), 1.0 * s)
			draw_arc(l, 7.0 * s, 0.0, TAU, 20, Color(0, 0, 0, 0.4), 3.6 * s)
			draw_arc(l, 7.0 * s, 0.0, TAU, 20, HOSTILE, 1.8 * s)
			draw_circle(l, 1.8 * s, HOSTILE)
			for point: Variant in [gun_cross, aim_point]:
				if point != null and (point as Vector2).distance_to(l) < 24.0 * s:
					aimed = minf(aimed, (point as Vector2).distance_to(l) / (24.0 * s))
	var shown: float = float(dots_shown.get(enemy.id, 0.0))
	if shown > 0.0:
		_draw_health_dots(Vector2(c.x, c.y + half + 11.0 * s), health_dots(enemy.model.hull_ratio()), DOT_RED if not friend else FRIEND, shown, s)
	return aimed


## Fade the health dots in while the guns are on an aircraft; keep them a while after.
func _update_dots(enemy: Combatant, aimed: bool) -> void:
	var hold: float = float(dots_hold.get(enemy.id, 0.0))
	var shown: float = float(dots_shown.get(enemy.id, 0.0))
	if aimed:
		hold = DOTS_LINGER
	else:
		hold = maxf(hold - frame_delta, 0.0)
	if not enemy.model.alive or enemy.left:
		hold = 0.0
		shown = 0.0
	elif hold > 0.0:
		shown = minf(shown + frame_delta / DOTS_FADE_IN, 1.0)
	else:
		shown = maxf(shown - frame_delta / DOTS_FADE_OUT, 0.0)
	dots_hold[enemy.id] = hold
	dots_shown[enemy.id] = shown


func _draw_health_dots(centre: Vector2, filled: int, colour: Color, alpha: float, s: float) -> void:
	var r: float = 4.0 * s
	var gap: float = 13.0 * s
	for i in range(HEALTH_DOTS):
		var p: Vector2 = centre + Vector2((i - (HEALTH_DOTS - 1) * 0.5) * gap, 0.0)
		if i < filled:
			draw_circle(p, r + 1.3 * s, Color(0, 0, 0, 0.3 * alpha))
			draw_circle(p, r, Color(colour, 0.92 * alpha))
		else:
			draw_circle(p, r - 0.7 * s, Color(0, 0, 0, 0.25 * alpha))
			draw_arc(p, r - 0.7 * s, 0.0, TAU, 16, Color(colour, 0.8 * alpha), 1.4 * s, true)


func _draw_edge_arrow(where: Vector3, dist: float, s: float, colour: Color = HOSTILE) -> void:
	var local: Vector3 = camera.global_transform.affine_inverse() * where
	var dir: Vector2 = Vector2(local.x, -local.y)
	if dir.length_squared() < 0.0001:
		dir = Vector2.DOWN
	dir = dir.normalized()
	var half: Vector2 = size * 0.5 - Vector2(70, 70) * s
	var reach: float = minf(half.x / maxf(absf(dir.x), 0.001), half.y / maxf(absf(dir.y), 0.001))
	var tip: Vector2 = size * 0.5 + dir * reach
	var side: Vector2 = dir.orthogonal()
	draw_colored_polygon([tip + dir * 13.0 * s, tip - dir * 9.0 * s + side * 10.0 * s, tip - dir * 9.0 * s - side * 10.0 * s], colour)
	_text(tip - dir * 30.0 * s + Vector2(-50 * s, 5 * s), "%d m" % int(dist), 12 * s, colour, true, HORIZONTAL_ALIGNMENT_CENTER, 100 * s)


func _draw_top(s: float) -> void:
	var w: float = 420.0 * s
	var rect: Rect2 = Rect2(size.x * 0.5 - w * 0.5, 18 * s, w, 56 * s)
	_panel(rect)
	_text(Vector2(rect.position.x, rect.position.y + 24 * s), mode_label, 15 * s, DIM, true, HORIZONTAL_ALIGNMENT_CENTER, w)
	var minutes: int = int(clock) / 60
	var seconds: int = int(clock) % 60
	_text(Vector2(rect.position.x, rect.position.y + 47 * s), "%02d:%02d" % [minutes, seconds], 19 * s, TEXT, true, HORIZONTAL_ALIGNMENT_CENTER, w)
	if player != null:
		_text(Vector2(rect.position.x + 18 * s, rect.position.y + 47 * s), "KILLS %d" % player.kills, 16 * s, AMBER, true)
		_text(Vector2(rect.position.x, rect.position.y + 47 * s), "LOST %d" % player.losses, 16 * s, DIM, true, HORIZONTAL_ALIGNMENT_RIGHT, w - 18 * s)
	if message_time > 0.0:
		_text(Vector2(0, rect.end.y + 34 * s), message, 20 * s, Color(AMBER, clampf(message_time, 0.0, 1.0)), true, HORIZONTAL_ALIGNMENT_CENTER, size.x)


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
	var hull: float = model.hull_ratio()
	x += _bar(Vector2(x, y), "HULL", hull, TEXT if hull > 0.5 else (ZONE_DAMAGED if hull > 0.25 else ZONE_CRITICAL), s, 150.0)
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
	_text(rect.position + Vector2(0, 24 * s), String(model.spec.short), 12 * s, DIM, false, HORIZONTAL_ALIGNMENT_RIGHT, w - 14 * s)
	# Fit this aircraft's planform into the panel, whatever its size.
	var room: Vector2 = Vector2(w - 28 * s, h - 78 * s)
	var scale_px: float = minf(room.x / (outline_extent.z * 2.0), room.y / (outline_extent.y - outline_extent.x))
	var origin: Vector2 = rect.position + Vector2(w * 0.5, 36 * s + room.y * 0.5 - (outline_extent.x + outline_extent.y) * 0.5 * scale_px)
	for i in range(zone_polygons.size()):
		var poly: PackedVector2Array = PackedVector2Array()
		for p in zone_polygons[i]:
			poly.append(origin + p * scale_px)
		var health: float = model.zone_health[i]
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
		_text(Vector2(0, size.y * 0.45), lost_reason, 30 * s, TEXT, true, HORIZONTAL_ALIGNMENT_CENTER, size.x)
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
		"LEFT CLICK / SPACE  fire the guns",
		"Put the white cross on the red lead ring",
		"SHIFT  boost      W / S  throttle",
		"A / D  roll      Q / E  rudder",
		"C  centre aim     ESC  pause & change aircraft",
		"F4  snow showers on / off (weather test)",
	]
	var rect: Rect2 = Rect2(Vector2(24 * s, size.y - 298 * s), Vector2(390 * s, 206 * s))
	draw_rect(rect, Color(PANEL, PANEL.a * a), true)
	draw_rect(rect, Color(EDGE, EDGE.a * a), false, 1.0)
	for i in range(lines.size()):
		_text(rect.position + Vector2(16 * s, (30 + i * 26) * s), lines[i], 14 * s, Color(TEXT, a))
