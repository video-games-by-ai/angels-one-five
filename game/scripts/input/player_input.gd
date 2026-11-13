class_name PlayerInput
extends Node
## Mouse and keyboard pilot. The mouse swings a free aim direction around the
## camera; the aircraft flies toward it. A touch or gamepad scheme would produce
## the same FlightCommand.

const MOUSE_SCALE: float = 0.0021
const LEVEL_DELAY: float = 1.1

var command: FlightCommand = FlightCommand.new()
var settings: GameSettings
var aim_direction: Vector3 = Vector3.FORWARD
var camera_up: Vector3 = Vector3.UP
var enabled: bool = true
var idle_time: float = 0.0
var arena_radius: float = 8600.0
var arena_warning: bool = false


static func register_actions() -> void:
	var keys: Dictionary = {
		"throttle_up": [KEY_W, KEY_UP], "throttle_down": [KEY_S, KEY_DOWN],
		"roll_left": [KEY_A, KEY_LEFT], "roll_right": [KEY_D, KEY_RIGHT],
		"yaw_left": [KEY_Q], "yaw_right": [KEY_E], "boost": [KEY_SHIFT],
		"center_aim": [KEY_C], "pause": [KEY_ESCAPE], "toggle_fps": [KEY_F3],
		"fullscreen": [KEY_F11],
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


func _unhandled_input(event: InputEvent) -> void:
	if not enabled or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		apply_mouse((event as InputEventMouseMotion).relative)


## Swing the aim around the camera's axes: right/left yaws, up/down pitches.
func apply_mouse(relative: Vector2) -> void:
	var sens: float = MOUSE_SCALE * settings.mouse_sensitivity
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
	if Input.is_action_just_pressed("center_aim"):
		aim_direction = nose
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
	command.throttle_axis = Input.get_axis("throttle_down", "throttle_up") if enabled else 0.0
	command.roll_axis = Input.get_axis("roll_left", "roll_right") if enabled else 0.0
	command.yaw_axis = Input.get_axis("yaw_left", "yaw_right") if enabled else 0.0
	command.boost = enabled and Input.is_action_pressed("boost")
	command.fire = enabled and Input.is_action_pressed("fire")
	command.rocket = enabled and Input.is_action_just_pressed("rocket")
	return command
