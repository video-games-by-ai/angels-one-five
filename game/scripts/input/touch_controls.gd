class_name TouchControls
extends Control
## On-screen flying controls for a touch screen.
##
## The left thumb steers: wherever it lands on the left part of the screen a
## stick appears under it, and pushing the stick swings the aim (the same aim the
## mouse moves on a computer) faster the further it is pushed. The right thumb
## has the buttons: FIRE, BOOST and BRAKE are held, ZOOM and pause are taps.
## PlayerInput reads `stick` and the button states each tick.

signal zoom_pressed
signal pause_pressed

const STICK_ZONE: float = 0.45          ## share of the width, from the left, where the stick may start
const STICK_TOP: float = 0.22           ## nothing above this share of the height (the radar is there)
const STICK_RADIUS: float = 150.0       ## travel for full deflection, at 1080 lines
const STICK_DEAD: float = 0.08
const TOUCH_SLACK: float = 1.25         ## buttons are this much larger to the finger than they look

## Button centres in 1080-line units from the bottom-right corner (pause: from
## the top-right), and radii. Kept clear of the HUD's bottom bar and airframe panel.
const BUTTONS: Dictionary = {
	"fire": {"at": Vector2(-190, -205), "radius": 105.0, "label": "FIRE"},
	"boost": {"at": Vector2(-425, -150), "radius": 70.0, "label": "BOOST"},
	"brake": {"at": Vector2(-595, -150), "radius": 62.0, "label": "BRAKE"},
	"zoom": {"at": Vector2(-405, -350), "radius": 58.0, "label": "ZOOM"},
	"pause": {"at": Vector2(-80, 80), "radius": 44.0, "label": "II", "top": true},
}
const LINE: Color = Color(1.0, 1.0, 1.0, 0.55)
const FILL: Color = Color(1.0, 1.0, 1.0, 0.10)
const HELD: Color = Color(1.0, 0.75, 0.3, 0.42)

var stick: Vector2 = Vector2.ZERO       ## -1..1 each way; right and down are positive, as on the screen
var fire: bool = false
var boost: bool = false
var brake: bool = false
var touches: Dictionary = {}            ## finger index -> "stick" or a button name
var stick_origin: Vector2 = Vector2.ZERO


## True when the game should fly by touch: a touch screen, or --touch on a computer.
static func wanted() -> bool:
	return DisplayServer.is_touchscreen_available() or OS.get_cmdline_user_args().has("--touch")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS   # a finger lifted while the game is paused must still be seen
	visibility_changed.connect(release_all)
	resized.connect(queue_redraw)


func scale_1080() -> float:
	return size.y / 1080.0


func button_centre(id: String) -> Vector2:
	var b: Dictionary = BUTTONS[id]
	var at: Vector2 = (b.at as Vector2) * scale_1080()
	return Vector2(size.x + at.x, at.y if b.get("top", false) else size.y + at.y)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		var touch: InputEventScreenTouch = event
		if touch.pressed and not get_tree().paused:
			press(touch.index, touch.position)
		elif not touch.pressed:
			release(touch.index)
	elif event is InputEventScreenDrag:
		drag((event as InputEventScreenDrag).index, (event as InputEventScreenDrag).position)


## A finger went down at `at` (in this control's coordinates).
func press(index: int, at: Vector2) -> void:
	for id: String in BUTTONS:
		if at.distance_to(button_centre(id)) <= float(BUTTONS[id].radius) * scale_1080() * TOUCH_SLACK:
			touches[index] = id
			match id:
				"zoom":
					zoom_pressed.emit()
				"pause":
					pause_pressed.emit()
			_refresh()
			return
	if at.x < size.x * STICK_ZONE and at.y > size.y * STICK_TOP and not touches.values().has("stick"):
		touches[index] = "stick"
		stick_origin = at
		stick = Vector2.ZERO
		_refresh()


func drag(index: int, at: Vector2) -> void:
	if touches.get(index, "") != "stick":
		return
	var pushed: Vector2 = (at - stick_origin) / (STICK_RADIUS * scale_1080())
	var amount: float = pushed.length()
	if amount > 1.0:
		# The base follows a thumb that slides past full travel, so reversing is immediate.
		stick_origin += (at - stick_origin) * (1.0 - 1.0 / amount)
		pushed /= amount
		amount = 1.0
	stick = Vector2.ZERO if amount < STICK_DEAD else pushed
	queue_redraw()


func release(index: int) -> void:
	if touches.get(index, "") == "stick":
		stick = Vector2.ZERO
	touches.erase(index)
	_refresh()


## Let go of everything (the controls were hidden, or the game paused).
func release_all() -> void:
	touches.clear()
	stick = Vector2.ZERO
	_refresh()


func _refresh() -> void:
	var held: Array = touches.values()
	fire = held.has("fire")
	boost = held.has("boost")
	brake = held.has("brake")
	queue_redraw()


func _draw() -> void:
	var s: float = scale_1080()
	var font: Font = ThemeDB.fallback_font
	var held: Array = touches.values()
	for id: String in BUTTONS:
		var centre: Vector2 = button_centre(id)
		var radius: float = float(BUTTONS[id].radius) * s
		draw_circle(centre, radius, HELD if held.has(id) else FILL)
		draw_arc(centre, radius, 0.0, TAU, 48, LINE, 2.5 * s, true)
		var px: int = int(radius * (0.36 if String(BUTTONS[id].label).length() > 2 else 0.7))
		draw_string(font, centre + Vector2(-radius, px * 0.36), String(BUTTONS[id].label), HORIZONTAL_ALIGNMENT_CENTER, radius * 2.0, px, LINE)
	var steering: bool = held.has("stick")
	var base: Vector2 = stick_origin if steering else Vector2(330.0 * s, size.y - 330.0 * s)
	var travel: float = STICK_RADIUS * s
	draw_arc(base, travel, 0.0, TAU, 64, LINE if steering else Color(LINE, 0.25), 2.5 * s, true)
	draw_circle(base + stick * travel, 58.0 * s, HELD if steering else FILL)
	if not steering:
		draw_string(font, base + Vector2(-travel, travel + 34.0 * s), "STEER", HORIZONTAL_ALIGNMENT_CENTER, travel * 2.0, int(20 * s), Color(LINE, 0.35))
