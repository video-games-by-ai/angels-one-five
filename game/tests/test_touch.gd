extends SceneTree
## Headless checks for the touch-screen controls: the stick, the buttons, two
## fingers at once, and that PlayerInput flies from them.
## Run: godot --headless --path game --script res://tests/test_touch.gd

var failures: int = 0


func _initialize() -> void:
	PlayerInput.register_actions()
	var touch: TouchControls = TouchControls.new()
	touch.size = Vector2(2400, 1080)
	root.add_child(touch)
	await process_frame   # the controls are in the tree from the first frame on
	touch.size = Vector2(2400, 1080)

	# Stick: appears under the thumb, reads the push, saturates, and lets go.
	touch.press(0, Vector2(400, 700))
	check(touch.stick == Vector2.ZERO, "a thumb that has just landed does not steer")
	touch.drag(0, Vector2(400 + TouchControls.STICK_RADIUS * 0.5, 700))
	check(is_equal_approx(touch.stick.x, 0.5) and is_zero_approx(touch.stick.y), "half travel right reads 0.5 (%.2f)" % touch.stick.x)
	touch.drag(0, Vector2(400, 700 - TouchControls.STICK_RADIUS * 4.0))
	check(is_equal_approx(touch.stick.length(), 1.0) and touch.stick.y < -0.9, "a long push up saturates at 1")
	touch.drag(0, Vector2(400, 700 - TouchControls.STICK_RADIUS * 3.0))
	check(touch.stick.y > -0.1, "the base follows the thumb, so coming back a little already eases off (%.2f)" % touch.stick.y)

	# Buttons while steering: a second finger fires, a third boosts.
	touch.press(1, touch.button_centre("fire"))
	touch.press(2, touch.button_centre("boost") + Vector2(20, -15))
	check(touch.fire and touch.boost and not touch.brake, "FIRE and BOOST are held by other fingers")
	check(touch.touches.get(0, "") == "stick", "the steering thumb keeps the stick")
	touch.drag(1, Vector2(100, 100))
	check(touch.fire, "a finger sliding off FIRE keeps firing until it lifts")
	touch.release(1)
	check(not touch.fire and touch.boost, "lifting the finger stops the guns only")
	touch.release(2)
	touch.release(0)
	check(touch.stick == Vector2.ZERO and touch.touches.is_empty(), "everything released")

	# Taps.
	var taps: Array[String] = []
	touch.zoom_pressed.connect(func() -> void: taps.append("zoom"))
	touch.pause_pressed.connect(func() -> void: taps.append("pause"))
	touch.press(0, touch.button_centre("zoom"))
	touch.release(0)
	touch.press(0, touch.button_centre("pause"))
	touch.release(0)
	check(taps == ["zoom", "pause"], "ZOOM and pause report their taps")

	# Places that do nothing: the right half away from buttons, and the radar corner.
	touch.press(0, Vector2(1500, 400))
	touch.press(1, Vector2(100, 100))
	check(touch.touches.is_empty(), "touches away from the stick area and the buttons are ignored")
	check(touch.button_centre("fire").x > 2400 * TouchControls.STICK_ZONE, "the buttons sit outside the stick area")

	# Hiding the controls drops whatever was held.
	touch.press(0, touch.button_centre("fire"))
	touch.visible = false
	check(not touch.fire, "hiding the controls releases FIRE")
	touch.visible = true

	# PlayerInput flies from the stick and the buttons.
	var input: PlayerInput = PlayerInput.new()
	input.settings = GameSettings.new()
	input.settings.level_assist = false
	input.touch = touch
	input.reset(Vector3.FORWARD)
	touch.press(0, Vector2(400, 700))
	touch.drag(0, Vector2(400 + TouchControls.STICK_RADIUS, 700))
	touch.press(1, touch.button_centre("brake"))
	var command: FlightCommand = null
	var nose: Vector3 = Vector3.FORWARD   # an aircraft that keeps up with the aim
	for i in range(60):
		command = input.sample(1.0 / 60.0, Vector3.ZERO, nose)
		nose = command.aim_direction
	var turned: float = rad_to_deg(Vector3.FORWARD.angle_to(command.aim_direction))
	check(command.aim_direction.x > 0.5, "stick right swings the aim to the right")
	check(turned > 60.0 and turned < 120.0, "a full push turns the aim about 90 degrees in a second (%.0f)" % turned)
	for i in range(120):
		command = input.sample(1.0 / 60.0, Vector3.ZERO, Vector3.FORWARD)
	var lead: float = rad_to_deg(Vector3.FORWARD.angle_to(command.aim_direction))
	check(is_equal_approx(lead, rad_to_deg(PlayerInput.LEAD_MAX)), "the aim stops 50 degrees ahead of an aircraft that cannot follow (%.0f)" % lead)
	input.reset(Vector3.FORWARD)
	check(command.brake and not command.fire and not command.boost, "BRAKE reaches the flight command")
	touch.drag(0, Vector2(400 + TouchControls.STICK_RADIUS, 700 - TouchControls.STICK_RADIUS * 3.0))
	command = input.sample(0.25, Vector3.ZERO, Vector3.FORWARD)
	check(command.aim_direction.y > 0.0, "stick up lifts the aim")
	input.enabled = false
	touch.press(2, touch.button_centre("fire"))
	command = input.sample(1.0 / 60.0, Vector3.ZERO, Vector3.FORWARD)
	check(not command.fire and not command.brake, "disabled input (a menu is open) passes nothing on")
	input.free()
	touch.release_all()
	_test_tilt(touch)

	print("TOUCH TESTS: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)


## Gravity in screen axes for a phone tipped back `tip` degrees from upright,
## then turned like a steering wheel `lean` degrees (right side down).
func held(tip: float, lean: float) -> Vector3:
	var t: float = deg_to_rad(tip)
	var a: float = deg_to_rad(lean)
	return Vector3(cos(t) * sin(a), -cos(t) * cos(a), -sin(t)) * 9.81


## Hold the phone one way for `seconds` and fly; the aircraft follows the aim.
func fly(input: PlayerInput, gravity: Vector3, seconds: float) -> FlightCommand:
	TouchControls.fake_gravity = gravity
	var command: FlightCommand = null
	for i in range(roundi(seconds * 60.0)):
		command = input.sample(1.0 / 60.0, Vector3.ZERO, input.aim_direction)
	return command


func heading_of(direction: Vector3) -> float:
	return rad_to_deg(atan2(direction.x, -direction.z))   # 0 = straight on, positive to the right


func climb_of(direction: Vector3) -> float:
	return rad_to_deg(asin(clampf(direction.y, -1.0, 1.0)))


func _test_tilt(touch: TouchControls) -> void:
	# What the sensor says about how the phone is held.
	var upright: Vector2 = TiltSteering.attitude(held(0.0, 0.0))
	check(is_zero_approx(upright.x) and is_zero_approx(upright.y), "upright and level reads no lean, no tip")
	check(is_equal_approx(rad_to_deg(TiltSteering.attitude(held(40.0, 0.0)).y), 40.0), "tipped back 40 degrees reads 40")
	check(TiltSteering.attitude(Vector3(3.0, -9.0, 0.0)).x > 0.0, "gravity toward the right edge is a lean to the right")
	check(is_equal_approx(rad_to_deg(TiltSteering.attitude(Vector3(0.0, 0.0, -9.81)).y), 90.0), "lying face up reads a quarter turn")
	check(is_equal_approx(rad_to_deg(TiltSteering.attitude(Vector3(0.0, 4.0, -9.0)).y), rad_to_deg(atan2(9.0, -4.0))), "held overhead, lying down, still reads on")

	var input: PlayerInput = PlayerInput.new()
	input.settings = GameSettings.new()
	input.touch = touch
	input.reset(Vector3.FORWARD)

	# No sensor: the stick stays in charge even with tilt chosen.
	TouchControls.fake_gravity = Vector3.ZERO
	touch.steer_by_tilt = true
	check(not touch.tilting(), "without a gravity sensor tilt steering stays off")
	touch.press(0, Vector2(400, 700))
	check(touch.touches.get(0, "") == "stick", "and the stick still answers")
	touch.release(0)

	# Held still, however the phone is tipped, the aircraft flies straight and level.
	touch.tilt.centre()
	var command: FlightCommand = fly(input, held(40.0, 0.0), 2.0)
	check(touch.tilting(), "with a sensor and the choice made, the phone steers")
	check(command.aim_direction.is_equal_approx(Vector3.FORWARD), "held as it was centred: straight and level")
	touch.press(0, Vector2(400, 700))
	check(not touch.touches.values().has("stick") and touch.stick == Vector2.ZERO, "the thumb stick is off while the phone steers")
	touch.release(0)

	# Leaning turns, and coming back to level stops the turn.
	command = fly(input, held(40.0, 1.5), 1.0)
	check(is_zero_approx(heading_of(command.aim_direction)), "a lean inside the play does not turn")
	command = fly(input, held(40.0, 30.0), 1.0)
	var right: float = heading_of(command.aim_direction)
	check(right > 60.0 and right < 110.0, "a full lean to the right turns about 90 degrees in a second (%.0f)" % right)
	check(is_zero_approx(climb_of(command.aim_direction)), "and does not change the climb (%.1f)" % climb_of(command.aim_direction))
	command = fly(input, held(40.0, 0.0), 1.0)
	var settled: float = heading_of(command.aim_direction)
	command = fly(input, held(40.0, 0.0), 1.0)
	check(is_equal_approx(heading_of(command.aim_direction), settled), "level again: the heading holds (%.0f)" % settled)
	command = fly(input, held(40.0, -12.0), 1.0)
	var eased: float = settled - heading_of(command.aim_direction)
	check(eased > 8.0 and eased < 45.0, "half a lean to the left turns left, and gently (%.0f)" % eased)
	fly(input, held(40.0, 0.0), 0.5)

	# Tipping sets the climb, and holding the tip holds it.
	command = fly(input, held(30.0, 0.0), 1.0)   # top edge 10 degrees toward the pilot
	var up: float = climb_of(command.aim_direction)
	check(up > 15.0 and up < 30.0, "tipping the top 10 degrees toward the pilot climbs about 22 degrees (%.0f)" % up)
	command = fly(input, held(30.0, 0.0), 3.0)
	check(is_equal_approx(climb_of(command.aim_direction), up), "held there, the climb holds: nothing drifts")
	command = fly(input, held(50.0, 0.0), 1.0)
	check(climb_of(command.aim_direction) < -15.0, "tipping it away dives (%.0f)" % climb_of(command.aim_direction))
	command = fly(input, held(40.0, 0.0), 1.0)
	check(is_zero_approx(climb_of(command.aim_direction)), "back as it was centred: level flight again")
	command = fly(input, held(0.0, 0.0), 1.0)
	check(is_equal_approx(climb_of(command.aim_direction), 60.0), "the climb asked for stops at 60 degrees (%.0f)" % climb_of(command.aim_direction))
	command = fly(input, held(40.0, 0.0), 1.0)
	check(is_zero_approx(climb_of(command.aim_direction)), "and tipping too far does not move level flight")
	touch.tilt.feed(Vector3(2.0, 0.5, -9.5), 1.0)
	touch.tilt.feed(Vector3(2.0, -0.5, -9.5), 1.0)
	check(absf(touch.tilt.climb) < deg_to_rad(400.0) and not is_nan(touch.tilt.climb), "lying flat and leaned, the reading stays sound")
	fly(input, held(40.0, 0.0), 1.0)
	# Zoomed in the same tip moves the aim less, and nothing jumps going in or out.
	fly(input, held(30.0, 0.0), 1.0)
	input.aim_scale = 1.0 / 3.0
	command = fly(input, held(30.0, 0.0), 0.2)
	check(climb_of(command.aim_direction) > 21.0 and climb_of(command.aim_direction) < 23.0, "zooming in keeps the climb (%.1f)" % climb_of(command.aim_direction))
	command = fly(input, held(27.0, 0.0), 1.0)
	check(climb_of(command.aim_direction) > 23.5 and climb_of(command.aim_direction) < 25.5, "zoomed three times, three degrees of tip move the aim 2.5 (%.1f)" % climb_of(command.aim_direction))
	input.aim_scale = 1.0
	fly(input, held(27.0, 0.0), 0.2)
	touch.tilt.centre()
	fly(input, held(40.0, 0.0), 1.0)
	input.settings.invert_y = true
	command = fly(input, held(30.0, 0.0), 1.0)
	check(climb_of(command.aim_direction) < -15.0, "inverted, tipping toward the pilot dives")
	input.settings.invert_y = false

	# A tap on the ring makes the present hold level flight.
	touch.press(0, touch.ring_centre())
	touch.release(0)
	command = fly(input, held(30.0, 0.0), 1.0)
	check(is_zero_approx(climb_of(command.aim_direction)), "a tap on the ring takes the present hold as level")

	# The aim does not run away from an aircraft that cannot follow.
	input.reset(Vector3.FORWARD)
	TouchControls.fake_gravity = held(30.0, 30.0)
	for i in range(180):
		command = input.sample(1.0 / 60.0, Vector3.ZERO, Vector3.FORWARD)
	check(is_equal_approx(heading_of(command.aim_direction), rad_to_deg(PlayerInput.LEAD_MAX)), "a held lean leads a slow aircraft by 50 degrees, no more (%.0f)" % heading_of(command.aim_direction))

	# The TILT button hands the steering back to the thumb.
	var said: Array = []
	touch.tilt_toggled.connect(func(on: bool) -> void: said.append(on))
	touch.press(0, touch.button_centre("tilt"))
	touch.release(0)
	check(said == [false] and not touch.tilting(), "the TILT button switches to the stick and says so")
	touch.press(0, Vector2(400, 700))
	check(touch.touches.get(0, "") == "stick", "then the thumb steers again")
	touch.release(0)
	touch.press(0, touch.button_centre("tilt"))
	touch.release(0)
	check(said == [false, true] and touch.tilting(), "and back to tilt")

	# The choice is remembered.
	var path: String = "user://test_tilt_settings.cfg"
	var saved: GameSettings = GameSettings.new()
	check(saved.tilt_steering, "tilt steering is on unless the player turns it off")
	saved.tilt_steering = false
	saved.save(path)
	check(not GameSettings.load_or_default(path).tilt_steering, "turning it off is remembered")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	TouchControls.fake_gravity = Vector3.ZERO
	input.free()


func check(condition: bool, label: String) -> void:
	print("  %s %s" % ["ok  " if condition else "FAIL", label])
	if not condition:
		failures += 1
