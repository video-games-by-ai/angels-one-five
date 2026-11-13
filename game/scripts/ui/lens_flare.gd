class_name LensFlare
extends Control
## Additive sun flare: a soft bloom on the sun and a row of faint ghosts mirrored
## through the screen centre. Hidden when terrain blocks the sun.

const GHOSTS: Array[Array] = [  # position along sun->centre axis, radius, colour
	[0.35, 22.0, Color(1.0, 0.75, 0.45, 0.10)],
	[0.7, 9.0, Color(1.0, 0.9, 0.6, 0.16)],
	[1.15, 46.0, Color(0.55, 0.75, 1.0, 0.06)],
	[1.45, 16.0, Color(1.0, 0.6, 0.35, 0.10)],
	[1.9, 70.0, Color(1.0, 0.8, 0.55, 0.045)],
]

var camera: Camera3D
var terrain: TerrainData
var sun_direction: Vector3 = Vector3.UP
var weather: Weather
var visibility: float = 0.0
var glow: GradientTexture2D


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat: CanvasItemMaterial = CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	glow = Aircraft._soft_dot()


func _process(delta: float) -> void:
	var target: float = 0.0
	if camera != null and not camera.is_position_behind(camera.global_position + sun_direction * 1000.0):
		target = 0.0 if _sun_blocked() else 1.0
		if weather != null:
			target *= weather.sun_visibility(camera.global_position)
	visibility = lerpf(visibility, target, 1.0 - exp(-delta * 8.0))
	queue_redraw()


func _sun_blocked() -> bool:
	var p: Vector3 = camera.global_position
	var step: float = 60.0
	var travelled: float = 0.0
	while travelled < 9000.0:
		travelled += step
		var q: Vector3 = p + sun_direction * travelled
		if absf(q.x) > terrain.size * 0.5 or absf(q.z) > terrain.size * 0.5:
			return false
		if q.y < terrain.height_at(q.x, q.z):
			return true
		step *= 1.08
	return false


func _draw() -> void:
	if visibility < 0.01 or camera == null:
		return
	var sun: Vector2 = camera.unproject_position(camera.global_position + sun_direction * 1000.0)
	var centre: Vector2 = size * 0.5
	var s: float = size.y / 1080.0
	var edge: float = clampf(1.2 - (sun - centre).length() / (size.length() * 0.6), 0.0, 1.0)
	var strength: float = visibility * edge
	draw_texture_rect(glow, Rect2(sun - Vector2(260, 260) * s, Vector2(520, 520) * s), false, Color(1.0, 0.8, 0.55, 0.22 * strength))
	draw_texture_rect(glow, Rect2(sun - Vector2(900, 7) * s, Vector2(1800, 14) * s), false, Color(1.0, 0.85, 0.65, 0.16 * strength))
	for ghost in GHOSTS:
		var pos: Vector2 = sun.lerp(centre, float(ghost[0]))
		var r: float = float(ghost[1]) * s
		var c: Color = ghost[2]
		draw_texture_rect(glow, Rect2(pos - Vector2(r, r), Vector2(r, r) * 2.0), false, Color(c, c.a * strength * 1.6))
