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
	for i in range(60):
		command = input.sample(1.0 / 60.0, Vector3.ZERO, Vector3.FORWARD)
	var turned: float = rad_to_deg(Vector3.FORWARD.angle_to(command.aim_direction))
	check(command.aim_direction.x > 0.5, "stick right swings the aim to the right")
	check(turned > 60.0 and turned < 120.0, "a full push turns the aim about 90 degrees in a second (%.0f)" % turned)
	check(command.brake and not command.fire and not command.boost, "BRAKE reaches the flight command")
	touch.drag(0, Vector2(400 + TouchControls.STICK_RADIUS, 700 - TouchControls.STICK_RADIUS * 3.0))
	command = input.sample(0.25, Vector3.ZERO, Vector3.FORWARD)
	check(command.aim_direction.y > 0.0, "stick up lifts the aim")
	input.enabled = false
	touch.press(2, touch.button_centre("fire"))
	command = input.sample(1.0 / 60.0, Vector3.ZERO, Vector3.FORWARD)
	check(not command.fire and not command.brake, "disabled input (a menu is open) passes nothing on")
	input.free()

	print("TOUCH TESTS: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)


func check(condition: bool, label: String) -> void:
	print("  %s %s" % ["ok  " if condition else "FAIL", label])
	if not condition:
		failures += 1
