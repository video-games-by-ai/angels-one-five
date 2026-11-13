extends SceneTree
## Headless checks for the flight model and terrain sampling.
## Run: godot --headless --path game --script res://tests/test_flight.gd

var failures: int = 0
var terrain: TerrainData


func _init() -> void:
	terrain = TerrainData.load_default()
	_test_terrain_sampling()
	_test_turn_right_banks_right()
	_test_aim_up_climbs()
	_test_level_assist_rolls_level()
	_test_boost_drains_and_speeds_up()
	_test_ground_collision()
	_test_classes_differ()
	_test_mouse_aim()
	print("FLIGHT TESTS: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)


func check(condition: bool, label: String) -> void:
	print(("  ok   " if condition else "  FAIL ") + label)
	if not condition:
		failures += 1


func _model(id: int = Airframes.Id.MUSTANG) -> FlightModel:
	var m: FlightModel = FlightModel.new()
	m.setup(id, terrain.spawn_position + Vector3(0, 900, 0), 0.0)
	return m


func _fly(m: FlightModel, aim: Vector3, seconds: float, boost: bool = false) -> void:
	var cmd: FlightCommand = FlightCommand.new()
	cmd.aim_direction = aim.normalized()
	cmd.boost = boost
	for i in range(int(seconds * 60.0)):
		m.step(cmd, 1.0 / 60.0, terrain)


func _test_terrain_sampling() -> void:
	var i: int = 1000 * terrain.samples + 1000
	var x: float = -terrain.size * 0.5 + 1000 * terrain.spacing
	var z: float = -terrain.size * 0.5 + 1000 * terrain.spacing
	check(absf(terrain.height_at(x, z) - terrain.heights[i]) < 0.01, "height_at matches heightmap samples")
	check(terrain.surface_at(terrain.spawn_position.x, terrain.spawn_position.z) < terrain.spawn_position.y - 150.0, "spawn point is well above the ground")


func _test_turn_right_banks_right() -> void:
	var m: FlightModel = _model()
	var aim: Vector3 = Vector3(sin(deg_to_rad(40.0)), 0.0, -cos(deg_to_rad(40.0)))  # 40 degrees right
	_fly(m, aim, 0.8)
	check(m.basis().x.y < -0.2, "aiming right banks the right wing down")
	_fly(m, aim, 3.0)
	var heading: Vector3 = m.forward()
	check(heading.x > 0.3, "aircraft turns toward an aim point on the right")


func _test_aim_up_climbs() -> void:
	var m: FlightModel = _model()
	var y0: float = m.position.y
	_fly(m, Vector3(0, 0.45, -1), 3.0)
	check(m.position.y > y0 + 80.0, "aiming above the nose climbs")
	check(m.speed < float(m.spec.top_speed), "climbing bleeds speed")


func _test_level_assist_rolls_level() -> void:
	var m: FlightModel = _model()
	m.orientation = Quaternion(Vector3.FORWARD, deg_to_rad(50.0))  # banked
	_fly(m, m.forward() * Vector3(1, 0, 1), 2.5)
	check(absf(m.basis().x.y) < 0.08, "aim on the nose rolls the wings level")


func _test_boost_drains_and_speeds_up() -> void:
	var a: FlightModel = _model()
	var b: FlightModel = _model()
	_fly(a, Vector3.FORWARD, 4.0, false)
	_fly(b, Vector3.FORWARD, 4.0, true)
	check(b.speed > a.speed + 5.0, "boost increases speed")
	check(b.boost_energy < 0.6 and a.boost_energy > 0.99, "boost drains the reserve")


func _test_ground_collision() -> void:
	var m: FlightModel = _model()
	m.position.y = terrain.surface_at(m.position.x, m.position.z) + 30.0
	_fly(m, Vector3(0, -0.6, -1), 3.0)
	check(not m.alive, "diving into the ground destroys the aircraft")


func _test_classes_differ() -> void:
	var light: Dictionary = Airframes.spec(Airframes.Id.SPITFIRE)
	var heavy: Dictionary = Airframes.spec(Airframes.Id.THUNDERBOLT)
	check(float(light.top_speed) > float(heavy.top_speed) and float(light.roll_rate) > float(heavy.roll_rate), "light class is faster and more agile")
	check(float(heavy.gun_damage) > float(light.gun_damage) and float(heavy.hull) > float(light.hull), "heavy class hits harder and is tougher")


func _test_mouse_aim() -> void:
	var input: PlayerInput = PlayerInput.new()
	input.settings = GameSettings.new()
	input.reset(Vector3.FORWARD)
	input.apply_mouse(Vector2(120, 0))
	check(input.aim_direction.x > 0.1, "mouse right swings the aim right")
	input.reset(Vector3.FORWARD)
	input.apply_mouse(Vector2(0, -120))
	check(input.aim_direction.y > 0.1, "mouse up raises the aim")
	input.settings.invert_y = true
	input.reset(Vector3.FORWARD)
	input.apply_mouse(Vector2(0, -120))
	check(input.aim_direction.y < -0.1, "inverted mouse up lowers the aim")
	input.free()
