class_name PlayerInput
extends Node
## Mouse and keyboard pilot. The mouse swings a free aim direction around the
## camera; the aircraft flies toward it. A touch or gamepad scheme would produce
## the same FlightCommand.

const MOUSE_SCALE: float = 0.0021
const LEVEL_DELAY: float = 1.1
const ZOOM_STEP: float = 1.26       ## one wheel notch; three notches double the magnification
const ZOOM_DEFAULT: float = 3.0     ## where Z zooms to until the wheel has picked a level

var command: FlightCommand = FlightCommand.new()
var settings: GameSettings
var aim_direction: Vector3 = Vector3.FORWARD
var camera_up: Vector3 = Vector3.UP
var enabled: bool = true
var zoom_level: float = 1.0       ## gunsight magnification asked for; 1 = the normal view
var zoom_preferred: float = ZOOM_DEFAULT   ## the level Z returns to: the last one the wheel chose
var max_zoom: float = ZOOM_DEFAULT         ## how far this aircraft's sight zooms
var aim_scale: float = 1.0        ## mouse sensitivity share; the camera lowers it while zoomed
var typing: bool = false          ## a chat line is open: keys write text, the mouse still flies
var idle_time: float = 0.0
var arena_radius: float = 8600.0
var arena_warning: bool = false


static func register_actions() -> void:
	var keys: Dictionary = {
		"throttle_up": [KEY_W, KEY_UP], "throttle_down": [KEY_S, KEY_DOWN],
		"roll_left": [KEY_A, KEY_LEFT], "roll_right": [KEY_D, KEY_RIGHT],
		"yaw_left": [KEY_Q], "yaw_right": [KEY_E], "boost": [KEY_SHIFT],
		"center_aim": [KEY_C], "zoom": [KEY_Z], "pause": [KEY_ESCAPE], "toggle_fps": [KEY_F3],
		"fullscreen": [KEY_F11], "toggle_weather": [KEY_F4],
	}
	for action: String in keys:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key: Key in keys[action]:
			var ev: InputEventKey = InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
	for pair: Array in [["fire", MOUSE_BUTTON_LEFT], ["rocket", MOUSE_BUTTON_RIGHT]]:
		if not InputMap.has_action(pair[0]):
			InputMap.add_action(pair[0])
			var mb: InputEventMouseButton = InputEventMouseButton.new()
			mb.button_index = pair[1]
			InputMap.action_add_event(pair[0], mb)
	if not InputMap.action_has_event("fire", _key_event(KEY_SPACE)):
		InputMap.action_add_event("fire", _key_event(KEY_SPACE))


static func _key_event(key: Key) -> InputEventKey:
	var ev: InputEventKey = InputEventKey.new()
	ev.physical_keycode = key
	return ev


func reset(direction: Vector3) -> void:
	aim_direction = direction.normalized()
	camera_up = Vector3.UP
	idle_time = 0.0
	zoom_level = 1.0


func _unhandled_input(event: InputEvent) -> void:
	if not enabled or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		apply_mouse((event as InputEventMouseMotion).relative)
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		match (event as InputEventMouseButton).button_index:
			MOUSE_BUTTON_WHEEL_UP:
				step_zoom(1)
			MOUSE_BUTTON_WHEEL_DOWN:
				step_zoom(-1)


## Z: jump between the normal view and the zoom level used last.
func toggle_zoom() -> void:
	zoom_level = 1.0 if zoom_level > 1.0 else clampf(zoom_preferred, 1.0, max_zoom)


## Mouse wheel: zoom in (positive) or out by notches, up to the aircraft's limit
## and back down to the normal view.
func step_zoom(notches: int) -> void:
	var level: float = clampf(zoom_level * pow(ZOOM_STEP, notches), 1.0, max_zoom)
	zoom_level = 1.0 if level < 1.1 else level
	if zoom_level > 1.0:
		zoom_preferred = zoom_level


## Swing the aim around the camera's axes: right/left yaws, up/down pitches.
func apply_mouse(relative: Vector2) -> void:
	var sens: float = MOUSE_SCALE * settings.mouse_sensitivity * aim_scale
	var dy: float = relative.y * (-1.0 if settings.invert_y else 1.0)
	var right: Vector3 = aim_direction.cross(camera_up).normalized()
	if right.length_squared() < 0.5:
		right = aim_direction.cross(Vector3.FORWARD).normalized()
	var up: Vector3 = right.cross(aim_direction).normalized()
	aim_direction = aim_direction.rotated(up, -relative.x * sens)
	aim_direction = aim_direction.rotated(right, -dy * sens).normalized()
	if relative.length() > 0.5:
		idle_time = 0.0


## Build this tick's command. `nose` is the aircraft's forward direction.
func sample(delta: float, aircraft_position: Vector3, nose: Vector3) -> FlightCommand:
	idle_time += delta
	if not typing and Input.is_action_just_pressed("center_aim"):
		aim_direction = nose
	if enabled and not typing and Input.is_action_just_pressed("zoom"):
		toggle_zoom()
	# Assisted levelling: an idle aim drifts back to the horizon.
	if settings.level_assist and idle_time > LEVEL_DELAY and absf(aim_direction.y) < 0.85:
		var flat: Vector3 = Vector3(aim_direction.x, 0.0, aim_direction.z).normalized()
		var rate: float = clampf((idle_time - LEVEL_DELAY) * 0.5, 0.0, 1.0) * 0.45
		aim_direction = aim_direction.slerp(flat, 1.0 - exp(-delta * rate)).normalized()
	# Soft arena boundary: nudge the aim back toward the valley.
	var flat_pos: Vector2 = Vector2(aircraft_position.x, aircraft_position.z)
	arena_warning = flat_pos.length() > arena_radius
	if arena_warning:
		var home: Vector3 = Vector3(-aircraft_position.x, 0.0, -aircraft_position.z).normalized()
		var push: float = clampf((flat_pos.length() - arena_radius) / 900.0, 0.0, 1.0)
		var target: Vector3 = Vector3(home.x, aim_direction.y, home.z).normalized()
		aim_direction = aim_direction.slerp(target, 1.0 - exp(-delta * push * 1.2)).normalized()

	command.aim_direction = aim_direction
	var keys: bool = enabled and not typing
	command.throttle_axis = Input.get_axis("throttle_down", "throttle_up") if keys else 0.0
	command.roll_axis = Input.get_axis("roll_left", "roll_right") if keys else 0.0
	command.yaw_axis = Input.get_axis("yaw_left", "yaw_right") if keys else 0.0
	command.boost = keys and Input.is_action_pressed("boost")
	# While typing, Space is a space: only the mouse button fires.
	command.fire = enabled and (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) if typing else Input.is_action_pressed("fire"))
	command.rocket = enabled and Input.is_action_just_pressed("rocket")
	return command
