class_name Radar
extends Control
## Round, see-through radar map in the HUD's top left corner. North is up and
## the map stays still; the player is the amber dot in the centre with a tick
## along the nose, a wedge shows what the camera sees, enemies are red dots and
## friends white. Aircraft beyond the range sit as rings on the rim, in the
## direction to fly. A sweep line turns for looks and makes dots glow as it passes.

const RANGE: float = 4500.0           ## metres from the centre to the rim
const RINGS: int = 3                  ## range rings, 1.5 km apart
const SWEEP_PERIOD: float = 3.0       ## seconds per turn
const SWEEP_TAIL: float = 0.85        ## radians of fading tail behind the sweep line
const TEXTURE_SIZE: int = 512

const TEXT: Color = Color("fbf4e6")
const DIM: Color = Color("e6d8bf")
const AMBER: Color = Color("ffc766")
const HOSTILE: Color = Color("ff5a4a")
const FRIEND: Color = Color("fbf4e6")

var hud: Hud
var backdrop: ColorRect
var backdrop_material: ShaderMaterial
var map_size: float = 24000.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Prepare the ground picture for this map. Safe to call again for another map.
func setup(terrain: TerrainData) -> void:
	map_size = terrain.size
	var image: Image = terrain.height_image()
	image.resize(TEXTURE_SIZE, TEXTURE_SIZE, Image.INTERPOLATE_BILINEAR)
	if backdrop == null:
		backdrop_material = ShaderMaterial.new()
		backdrop_material.shader = load("res://shaders/radar_map.gdshader")
		backdrop = ColorRect.new()
		backdrop.material = backdrop_material
		backdrop.show_behind_parent = true
		backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(backdrop)
	backdrop_material.set_shader_parameter("heights", ImageTexture.create_from_image(image))
	backdrop_material.set_shader_parameter("water_level", terrain.water_level)
	backdrop_material.set_shader_parameter("span_uv", RANGE / map_size)


## Where a world position lands on the radar, relative to its centre, in pixels
## for a radar of the given radius. North (-Z) is up, east (+X) right.
static func plot(from: Vector3, to: Vector3, radius: float) -> Vector2:
	return Vector2(to.x - from.x, to.z - from.z) / RANGE * radius


func _draw() -> void:
	if hud == null or hud.model == null or hud.camera == null:
		return
	var model: FlightModel = hud.model
	var r: float = size.x * 0.5
	var c: Vector2 = size * 0.5
	var s: float = hud.ui_scale
	if backdrop_material != null:
		backdrop_material.set_shader_parameter("centre_uv", Vector2(model.position.x / map_size + 0.5, model.position.z / map_size + 0.5))
	_draw_view_wedge(c, r)
	var sweep: float = hud.clock * TAU / SWEEP_PERIOD - PI * 0.5
	_draw_sweep(c, r, sweep)
	for k in range(1, RINGS + 1):
		draw_arc(c, r * k / RINGS, 0.0, TAU, 64, Color(TEXT, 0.55 if k == RINGS else 0.22), maxf(1.2 * s, 1.0), true)
	draw_line(c - Vector2(r, 0), c + Vector2(r, 0), Color(TEXT, 0.1), 1.0)
	draw_line(c - Vector2(0, r), c + Vector2(0, r), Color(TEXT, 0.1), 1.0)
	draw_string(hud.font_bold, Vector2(c.x - 20 * s, -5 * s), "N", HORIZONTAL_ALIGNMENT_CENTER, 40 * s, int(14 * s), Color(0, 0, 0, 0.45))
	draw_string(hud.font_bold, Vector2(c.x - 20 * s, -6 * s), "N", HORIZONTAL_ALIGNMENT_CENTER, 40 * s, int(14 * s), TEXT)
	var dot: float = 4.6 * s
	for other in hud.opponents:
		if other.left or not other.model.alive:
			continue
		var colour: Color = FRIEND if hud.is_friend(other) else HOSTILE
		var offset: Vector2 = plot(model.position, other.model.position, r)
		if offset.length() > r:
			var rim: Vector2 = c + offset.normalized() * r
			draw_circle(rim, dot, Color(0.05, 0.04, 0.03, 0.6))
			draw_arc(rim, dot, 0.0, TAU, 20, colour, maxf(1.6 * s, 1.0), true)
			continue
		# Glow briefly once the sweep has passed over the dot.
		var behind: float = wrapf(sweep - offset.angle(), 0.0, TAU)
		var glow: float = clampf(1.0 - behind / SWEEP_TAIL, 0.0, 1.0)
		if glow > 0.0:
			draw_circle(c + offset, dot * (1.0 + glow * 1.4), Color(colour, 0.28 * glow))
		draw_circle(c + offset, dot + 1.4 * s, Color(0, 0, 0, 0.35))
		draw_circle(c + offset, dot, colour)
	# You: the centre dot with a tick along the nose.
	var nose: Vector2 = Vector2(model.forward().x, model.forward().z)
	if nose.length_squared() > 0.0001:
		draw_line(c, c + nose.normalized() * 15.0 * s, AMBER, maxf(2.2 * s, 1.5), true)
	draw_circle(c, 5.0 * s, Color(0, 0, 0, 0.35))
	draw_circle(c, 4.2 * s, AMBER)


## The camera's horizontal field of view: an aircraft inside it is on screen.
func _draw_view_wedge(c: Vector2, r: float) -> void:
	var look: Vector3 = -hud.camera.global_transform.basis.z
	var dir: Vector2 = Vector2(look.x, look.z)
	if dir.length_squared() < 0.01:
		dir = Vector2(hud.model.forward().x, hud.model.forward().z)
	if dir.length_squared() < 0.0001:
		return
	var aspect: float = hud.size.x / maxf(hud.size.y, 1.0)
	var half: float = atan(tan(deg_to_rad(hud.camera.fov) * 0.5) * aspect)
	var centre_angle: float = dir.angle()
	var points: PackedVector2Array = PackedVector2Array([c])
	var colours: PackedColorArray = PackedColorArray([Color(TEXT, 0.24)])
	var steps: int = 20
	for i in range(steps + 1):
		points.append(c + Vector2.from_angle(centre_angle - half + 2.0 * half * i / steps) * r)
		colours.append(Color(TEXT, 0.04))
	draw_polygon(points, colours)
	for side in [-1.0, 1.0]:
		draw_line(c, c + Vector2.from_angle(centre_angle + half * side) * r, Color(TEXT, 0.35), 1.0, true)


func _draw_sweep(c: Vector2, r: float, sweep: float) -> void:
	var steps: int = 18
	for i in range(steps):
		var a0: float = sweep - SWEEP_TAIL * (i + 1) / steps
		var a1: float = sweep - SWEEP_TAIL * i / steps
		var alpha: float = 0.2 * pow(1.0 - float(i) / steps, 1.6)
		draw_colored_polygon(PackedVector2Array([c, c + Vector2.from_angle(a0) * r, c + Vector2.from_angle(a1) * r]), Color(AMBER, alpha))
	draw_line(c, c + Vector2.from_angle(sweep) * r, Color(AMBER, 0.75), maxf(1.6 * hud.ui_scale, 1.0), true)
