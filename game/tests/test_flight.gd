extends SceneTree
## Headless checks for the flight model, terrain sampling, guns, damage and the AI.
## Run: godot --headless --path game --script res://tests/test_flight.gd

var failures: int = 0
var label_prefix: String = ""
var terrain: TerrainData


func _init() -> void:
	terrain = TerrainData.load_default()
	_test_terrain_sampling()
	_test_turn_right_banks_right()
	_test_aim_up_climbs()
	_test_climbing_costs_speed()
	_test_engine_follows_the_flying()
	_test_level_assist_rolls_level()
	_test_boost_drains_and_speeds_up()
	_test_brake()
	_test_ground_collision()
	_test_classes_differ()
	_test_mouse_aim()
	_test_fire_rate()
	_test_gun_heat()
	_test_scatter_and_near_misses()
	_test_engine_sound_mix()
	_test_spotting_scale()
	_test_guns_hit_and_destroy()
	_test_heavy_outlasts_light()
	_test_damage_zones()
	_test_engine_damage_slows()
	_test_burning_aircraft_slows()
	_test_trail_darkens_with_damage()
	_test_health_dots()
	_test_hit_marks()
	_test_target_panel()
	_test_radar_plot()
	_test_camera_up_settles()
	_test_ai_hunts_without_crashing()
	_test_tip_vapour_follows_class_speed()
	_test_flaps_and_wing_flex()
	_test_valley_path()
	_test_volume_settings_persist()
	# The second map: same terrain, route and AI checks on its own data.
	terrain = TerrainData.load_map("plav")
	Weather.use_map(terrain)
	label_prefix = "[plav] "
	_test_terrain_sampling()
	_test_plav_shape()
	_test_valley_path()
	_test_autopilot_flies_the_route()
	_test_ai_hunts_without_crashing(false)
	print("FLIGHT TESTS: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)


func check(condition: bool, label: String) -> void:
	print(("  ok   " if condition else "  FAIL ") + label_prefix + label)
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


## Shallow climbs are cheap, steep ones are not, nothing hangs on its propeller,
## and an aircraft that runs out of speed drops its nose and flies again.
func _test_climbing_costs_speed() -> void:
	var cmd: FlightCommand = FlightCommand.new()
	for frame in range(Airframes.COUNT):
		var spec: Dictionary = Airframes.spec(frame)
		var short: String = String(spec.short)
		var stall: float = float(spec.stall)
		var boost_pull: float = float(spec.thrust) * pow(float(spec.boost_speed) / float(spec.top_speed), 2.0)
		check(boost_pull * FlightModel.climb_thrust(1.0) < FlightModel.GRAVITY * 0.6, "%s: straight up, gravity beats the engine even on boost" % short)
		# Straight up at full throttle with boost: the speed runs out, the nose
		# falls through the horizon and the aircraft is flying again soon after.
		var m: FlightModel = _model(frame)
		cmd.aim_direction = Vector3(0.0, 1.0, -0.02).normalized()
		cmd.throttle_axis = 1.0
		cmd.boost = true
		var stalled_at: float = -1.0
		var top_y: float = m.position.y
		var nose_fell: bool = false
		var recovered_at: float = -1.0
		for i in range(30 * 60):
			m.step(cmd, 1.0 / 60.0, terrain)
			top_y = maxf(top_y, m.position.y)
			if stalled_at < 0.0 and m.stalled:
				stalled_at = i / 60.0
			if stalled_at >= 0.0 and m.forward().y < 0.0:
				nose_fell = true
			if nose_fell and not m.stalled:
				recovered_at = i / 60.0
				break
		var gained: float = top_y - (terrain.spawn_position.y + 900.0)
		check(stalled_at > 4.0 and stalled_at < 14.0 and gained < 1100.0, "%s: a vertical climb on boost runs out of speed (after %.1f s, %d m up)" % [short, stalled_at, int(gained)])
		check(nose_fell and recovered_at > 0.0 and recovered_at - stalled_at < 6.0 and m.alive and not m.near_stall(),
			"%s: stalled, the nose falls below the horizon and it flies again (%.1f s later)" % [short, recovered_at - stalled_at])
		# A 15 degree climb at the default throttle goes on for as long as you like.
		m = _model(frame)
		_fly(m, Vector3(0.0, sin(deg_to_rad(15.0)), -cos(deg_to_rad(15.0))), 15.0)
		check(m.speed > stall * 1.6 and m.speed < float(spec.top_speed) * 0.82 and m.forward().y > 0.2,
			"%s: a 15 degree climb settles at a slower, safe speed (%d m/s)" % [short, int(m.speed)])
		# A 45 degree dive runs past the level top speed.
		m = _model(frame)
		m.position.y += 1200.0
		_fly(m, Vector3(0.0, -1.0, -1.0), 10.0)
		check(m.alive and m.speed > float(spec.top_speed) * 1.05, "%s: a dive runs past the level top speed (%d m/s)" % [short, int(m.speed)])
	check(is_equal_approx(FlightModel.climb_thrust(-0.5), 1.0) and FlightModel.climb_thrust(0.17) > 0.97 and FlightModel.climb_thrust(0.7) < 0.65,
		"the engine pulls fully in a dive and a 10 degree climb, and loses over a third at 45 degrees")


## The engine note follows the flying: it labours uphill and runs away downhill
## at the same throttle setting.
func _test_engine_follows_the_flying() -> void:
	var level: FlightModel = _model()
	level.throttle = 1.0
	level.speed = float(level.spec.top_speed)
	var climbing: FlightModel = _model()
	climbing.throttle = 1.0
	climbing.orientation = Quaternion(Vector3.RIGHT, deg_to_rad(70.0))
	climbing.speed = float(climbing.spec.top_speed) * 0.45
	var diving: FlightModel = _model()
	diving.throttle = 1.0
	diving.orientation = Quaternion(Vector3.RIGHT, deg_to_rad(-70.0))
	diving.speed = float(diving.spec.top_speed) * 1.25
	var pulling: FlightModel = _model()
	pulling.throttle = 1.0
	pulling.speed = float(pulling.spec.top_speed)
	pulling.g_load = 6.0
	check(is_zero_approx(level.engine_load()) and climbing.engine_load() > 0.8 and diving.engine_load() < -0.8 and pulling.engine_load() > 0.2,
		"the engine is loaded in a climb and a hard pull, unloaded in a dive")
	var r_level: float = Sfx.engine_rpm(level)
	var r_climb: float = Sfx.engine_rpm(climbing)
	var r_dive: float = Sfx.engine_rpm(diving)
	check(r_climb < r_level - 0.18 and r_dive > r_level + 0.1 and Sfx.engine_rpm(pulling) < r_level - 0.03,
		"the revs sag in a steep climb and run up in a dive (%.2f, %.2f level, %.2f)" % [r_climb, r_level, r_dive])
	check(Sfx.engine_layers(r_climb)[1] > 0.95 and Sfx.engine_layers(r_dive)[3] > 0.95, "a labouring engine is on its low loop, a diving one on its high loop")
	climbing.throttle = 0.25
	check(climbing.engine_load() < 0.65, "a throttled-back engine labours less")


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


## Space: the engine goes to idle and the flaps come down. It sheds speed far
## faster than throttling back, holds a dive, and held too long it stalls.
func _test_brake() -> void:
	PlayerInput.register_actions()
	var space: InputEventKey = InputEventKey.new()
	space.physical_keycode = KEY_SPACE
	check(InputMap.action_has_event("brake", space) and not InputMap.action_has_event("fire", space), "Space is the brake, not the trigger")
	var input: PlayerInput = PlayerInput.new()
	input.settings = GameSettings.new()
	input.reset(Vector3.FORWARD)
	Input.action_press("brake")
	var held: bool = input.sample(0.016, Vector3.ZERO, Vector3.FORWARD).brake
	input.typing = true
	var typed: bool = input.sample(0.016, Vector3.ZERO, Vector3.FORWARD).brake
	Input.action_release("brake")
	input.typing = false
	check(held and not typed and not input.sample(0.016, Vector3.ZERO, Vector3.FORWARD).brake, "the brake is on while Space is held, and not while typing")
	input.free()

	var cmd: FlightCommand = FlightCommand.new()
	cmd.aim_direction = Vector3.FORWARD
	for id in [Airframes.Id.SPITFIRE, Airframes.Id.MUSTANG, Airframes.Id.THUNDERBOLT]:
		var s: Dictionary = Airframes.spec(id)
		var name: String = String(s.short)
		var top: float = float(s.top_speed)
		# Four seconds from top speed: throttled right back, and braking.
		var eased: FlightModel = _model(id)
		var braked: FlightModel = _model(id)
		for m: FlightModel in [eased, braked]:
			m.speed = top
			m.throttle = 1.0
		cmd.brake = false
		cmd.throttle_axis = -1.0
		for i in range(240):
			eased.step(cmd, 1.0 / 60.0, terrain)
		cmd.brake = true
		cmd.throttle_axis = 0.0
		cmd.boost = true
		var after_one_step: float = 0.0
		for i in range(240):
			braked.step(cmd, 1.0 / 60.0, terrain)
			if i == 0:
				after_one_step = top - braked.speed
		check(top - braked.speed > 50.0 and braked.speed < eased.speed - 25.0,
			"%s: 4 s of brake from top speed sheds %.0f km/h (throttling back: %.0f)" % [name, (top - braked.speed) * 3.6, (top - eased.speed) * 3.6])
		check(after_one_step < 0.2, "%s: the brake comes on smoothly, not as a jolt" % name)
		check(braked.braking and not braked.boosting and braked.boost_energy > 0.99, "%s: boost does not cut in while braking" % name)
		check(braked.throttle == 1.0 and is_equal_approx(braked.engine_throttle(), FlightModel.BRAKE_POWER), "%s: the engine idles and the throttle setting is kept" % name)
		check(Sfx.engine_rpm(braked) < Sfx.engine_rpm(eased), "%s: the engine is heard dropping to idle" % name)
		# Released: the engine is back and the speed returns.
		cmd.brake = false
		cmd.boost = false
		var slow: float = braked.speed
		for i in range(180):
			braked.step(cmd, 1.0 / 60.0, terrain)
		check(not braked.braking and braked.brake_amount == 0.0 and braked.engine_throttle() == 1.0 and braked.speed > slow + 8.0,
			"%s: released, it accelerates again (%.0f to %.0f km/h in 3 s)" % [name, slow * 3.6, braked.speed * 3.6])
		# Held in level flight it ends in the stall.
		cmd.brake = true
		var stalled_after: float = -1.0
		for i in range(1500):
			if braked.step(cmd, 1.0 / 60.0, terrain):
				break
			if braked.stalled:
				stalled_after = i / 60.0
				break
		check(stalled_after > 3.0, "%s: held in level flight, the brake ends in a stall (after %.1f s)" % [name, stalled_after])
		# A 40 degree dive from cruise: clean it runs past top speed, braked it is held well under.
		var dive: Vector3 = Vector3(0.0, -sin(deg_to_rad(40.0)), -cos(deg_to_rad(40.0)))
		var speeds: Array[float] = []
		for brake: bool in [false, true]:
			var m: FlightModel = _model(id)
			m.position.y += 1500.0
			m.throttle = 1.0
			cmd.aim_direction = dive
			cmd.brake = brake
			for i in range(480):
				if m.step(cmd, 1.0 / 60.0, terrain):
					break
			speeds.append(m.speed)
		cmd.aim_direction = Vector3.FORWARD
		check(speeds[0] > top and speeds[1] < top * 0.75, "%s: the brake holds a 40 degree dive (%.0f km/h, %.0f clean)" % [name, speeds[1] * 3.6, speeds[0] * 3.6])

		# The flaps go all the way down at any speed, and back up when it is released.
		var a: Aircraft = Aircraft.new()
		root.add_child(a)
		a.build(s, 0, false)
		var shown: FlightModel = _model(id)
		shown.speed = top
		shown.braking = true
		for i in range(120):
			a.animate(shown, 1.0 / 60.0)
		var down: float = a.flap_amount
		shown.braking = false
		for i in range(120):
			a.animate(shown, 1.0 / 60.0)
		check(down == 1.0 and a.flap_amount == 0.0, "%s: braking drops the flaps fully at top speed; released, they go up" % name)
		a.free()


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


func _combatant(id: int, team: int, frame: int, at: Vector3, heading: float = 0.0) -> Combatant:
	var c: Combatant = Combatant.new()
	c.setup(id, team, frame, false)
	c.spawn(at, heading)
	return c


func _test_fire_rate() -> void:
	for frame in range(Airframes.COUNT):
		var m: FlightModel = _model(frame)
		var rounds: int = 0
		for i in range(120):
			rounds += m.rounds_this_step(true, 1.0 / 60.0)
		var expected: float = float(m.spec.fire_rate) * 2.0
		check(absf(rounds - expected) <= 1.5, "%s fires %d rounds in 2 s (rate %d/s)" % [m.spec.short, rounds, int(m.spec.fire_rate)])
	var idle: FlightModel = _model()
	check(idle.rounds_this_step(false, 1.0 / 60.0) == 0, "no rounds without the trigger")
	check(Airframes.firepower(Airframes.Id.SPITFIRE) < Airframes.firepower(Airframes.Id.MUSTANG)
		and Airframes.firepower(Airframes.Id.MUSTANG) < Airframes.firepower(Airframes.Id.THUNDERBOLT), "firepower rises light < medium < heavy")
	var s: Dictionary = Airframes.spec(Airframes.Id.SPITFIRE)
	var t: Dictionary = Airframes.spec(Airframes.Id.THUNDERBOLT)
	var mid: Dictionary = Airframes.spec(Airframes.Id.MUSTANG)
	check(float(s.top_speed) > float(mid.top_speed) and float(mid.top_speed) > float(t.top_speed), "speed falls light > medium > heavy")
	check(float(s.hull) < float(mid.hull) and float(mid.hull) < float(t.hull), "hull rises light < medium < heavy")


## Holding the trigger: full rate at first, slower as the guns heat, then they
## stop and must cool. Bursts with pauses never overheat.
func _test_gun_heat() -> void:
	var dt: float = 1.0 / 60.0
	for frame in range(Airframes.COUNT):
		var m: FlightModel = _model(frame)
		var limit: float = float(m.spec.gun_heat_time)
		var rate: float = float(m.spec.fire_rate)
		var early: int = 0
		var late: int = 0
		var time: float = 0.0
		while not m.gun_overheated and time < 30.0:
			var rounds: int = m.rounds_this_step(true, dt)
			if time < 1.0:
				early += rounds
			elif time >= limit - 1.0:
				late += rounds
			time += dt
		check(absf(time - limit) < 0.35, "%s guns overheat after %.1f s of unbroken fire (%.2f s)" % [m.spec.short, limit, time])
		check(absf(early - rate) <= 1.5 and late < early * 0.6, "%s fires slower as the guns heat (%d rounds in the first second, %d in the last)" % [m.spec.short, early, late])
		var stopped: int = 0
		for i in range(60):
			stopped += m.rounds_this_step(true, dt)
		check(stopped == 0 and not m.firing, "%s overheated guns do not fire" % m.spec.short)
	var m: FlightModel = _model()
	while not m.gun_overheated:
		m.rounds_this_step(true, dt)
	var wait: float = 0.0
	while m.rounds_this_step(true, dt) == 0 and wait < 30.0:
		wait += dt
	var expected: float = (1.0 - FlightModel.GUN_RESUME) * FlightModel.GUN_COOL_TIME
	check(absf(wait - expected) < 0.2, "overheated guns fire again after %.1f s of cooling (%.2f s)" % [expected, wait])
	m = _model()
	m.gun_heat = 1.0
	m.gun_overheated = true
	var cooling: float = 0.0
	while m.gun_heat > 0.0 and cooling < 30.0:
		m.rounds_this_step(false, dt)
		cooling += dt
	check(absf(cooling - FlightModel.GUN_COOL_TIME) < 0.2, "red-hot guns cool completely in %d s (%.2f s)" % [int(FlightModel.GUN_COOL_TIME), cooling])
	# One-second bursts with two-second pauses, for a minute: never too hot.
	m = _model()
	var hottest: float = 0.0
	for i in range(3600):
		m.rounds_this_step(i % 180 < 60, dt)
		hottest = maxf(hottest, m.gun_heat)
	check(not m.gun_overheated and hottest < FlightModel.GUN_SLOW_FROM, "short bursts with pauses keep the guns at full rate (hottest %.2f)" % hottest)
	check(is_equal_approx(FlightModel.gun_rate_factor(0.3), 1.0) and is_equal_approx(FlightModel.gun_rate_factor(1.0), FlightModel.GUN_SLOWEST)
		and FlightModel.gun_scatter_factor(1.0) > FlightModel.gun_scatter_factor(0.0), "hot guns fire slower and scatter more")


func _test_scatter_and_near_misses() -> void:
	var furthest: float = 0.0
	var centre: Vector2 = Vector2.ZERO
	for i in range(200):
		furthest = maxf(furthest, Combatant.scatter(i).length())
		centre += Combatant.scatter(i) / 200.0
	check(furthest <= 1.0 and furthest > 0.9 and centre.length() < 0.08, "the scatter pattern fills a unit disc evenly (reach %.2f, centre off by %.3f)" % [furthest, centre.length()])
	check(Combatant.scatter(17) == Combatant.scatter(17), "the scatter pattern repeats exactly")
	# Rounds leave within the cold spread of the gun line.
	var high: Vector3 = terrain.spawn_position + Vector3(0, 900, 0)
	var shooter: Combatant = _combatant(0, 0, Airframes.Id.MUSTANG, high)
	var field: BulletField = BulletField.new()
	field.viewer_id = 5
	field.viewer_team = 1
	for i in range(30):
		shooter.shoot(true, 1.0 / 60.0, field)
	var widest: float = 0.0
	for v in field.velocities:
		# Measured from straight ahead, so it includes the guns' slight toe-in.
		widest = maxf(widest, (v - shooter.model.velocity()).normalized().angle_to(Vector3.FORWARD))
	check(widest < 0.012, "rounds leave close to the gun line (widest %.4f rad)" % widest)
	check(field.tints[0] == BulletField.TINT_HOSTILE, "another side's rounds are drawn in the hostile colour")
	field.clear()
	field.viewer_id = 0
	field.viewer_team = 0
	for i in range(10):
		shooter.shoot(true, 1.0 / 60.0, field)
	check(field.count() > 0 and field.tints[0] == BulletField.TINT_OWN, "the viewer's own rounds are drawn in their own colour")
	field.free()
	# A round passing 10 m from the listener is heard once; one 60 m away is not.
	var from: Vector3 = Vector3(0, 0, 0)
	var to: Vector3 = Vector3(0, 0, -14.7)
	check(BulletField.passes_close(from, to, Vector3(10, 0, -7), BulletField.NEAR_MISS), "a round passing 10 m away counts as a near miss")
	check(not BulletField.passes_close(from, to, Vector3(10, 0, -30), BulletField.NEAR_MISS), "it counts only in the step where it passes")
	check(not BulletField.passes_close(from, to, Vector3(60, 0, -7), BulletField.NEAR_MISS), "a round 60 m away is not a near miss")


## The two engine loops hand over smoothly as the revs rise.
func _test_engine_sound_mix() -> void:
	var ok: bool = true
	var last_low: float = 2.0
	for i in range(41):
		var rpm: float = lerpf(0.6, 1.4, i / 40.0)
		var layers: PackedFloat32Array = Sfx.engine_layers(rpm)
		ok = ok and absf(layers[1] * layers[1] + layers[3] * layers[3] - 1.0) < 0.001 and layers[1] <= last_low + 0.0001
		last_low = layers[1]
	check(ok, "the engine loops crossfade at constant power, low loop fading as revs rise")
	check(is_equal_approx(Sfx.engine_layers(Sfx.ENGINE_LOW_AT)[0], 1.0) and is_equal_approx(Sfx.engine_layers(Sfx.ENGINE_HIGH_AT)[2], 1.0),
		"each engine loop plays at its natural speed at its own RPM")
	check(Sfx.engine_layers(0.7)[3] < 0.01 and Sfx.engine_layers(1.2)[1] < 0.01, "idle is all low loop, boost all high loop")
	var m: FlightModel = _model()
	m.throttle = 0.25
	var idle: float = Sfx.engine_rpm(m)
	m.throttle = 1.0
	var full: float = Sfx.engine_rpm(m)
	m.boosting = true
	var boost: float = Sfx.engine_rpm(m)
	m.zone_health[Airframes.Zone.ENGINE] = 0.0
	check(idle < full and full < boost and Sfx.engine_rpm(m) < boost, "engine RPM rises with throttle and boost, and a shot-up engine labours")
	var away: float = Sfx.doppler(Vector3(0, 0, -500), Vector3(0, 0, -150), Vector3.ZERO, Vector3.ZERO)
	var toward: float = Sfx.doppler(Vector3(0, 0, -500), Vector3(0, 0, 150), Vector3.ZERO, Vector3.ZERO)
	check(away < 0.75 and toward > 1.3 and is_equal_approx(Sfx.doppler(Vector3(0, 0, -500), Vector3(150, 0, 0), Vector3.ZERO, Vector3.ZERO), 1.0),
		"an aircraft sounds higher coming at you and lower going away (%.2f, %.2f)" % [toward, away])
	for frame in range(Airframes.COUNT):
		var spec: Dictionary = Airframes.spec(frame)
		var found: bool = true
		for suffix: String in ["_low.wav", "_high.wav"]:
			found = found and ResourceLoader.exists(String(spec.engine_sound) + suffix)
		# The loops are kept exactly as generated (no lossy compression) and never touch full scale.
		var clean: bool = true
		var loudest: int = 0
		for high: bool in [false, true]:
			var loop: AudioStreamWAV = Sfx.engine_loop(spec, high)
			clean = clean and loop.format == AudioStreamWAV.FORMAT_16_BITS and loop.stereo
			var data: PackedByteArray = loop.data
			for at in range(0, data.size() - 1, 2):
				loudest = maxi(loudest, absi(data.decode_s16(at)))
		check(clean and loudest > 12000 and loudest < 30000, "%s engine loops are uncompressed and unclipped (peak %.1f dB)" % [String(spec.short), linear_to_db(loudest / 32768.0)])
		for take in range(1, Sfx.GUN_TAKES + 1):
			found = found and ResourceLoader.exists("%s_%d.wav" % [String(spec.gun_sound), take])
		check(found, "%s has both engine loops and every gun take" % spec.short)


func _test_spotting_scale() -> void:
	check(is_equal_approx(Aircraft.spot_scale(100.0), 1.0) and is_equal_approx(Aircraft.spot_scale(Aircraft.SPOT_FROM), 1.0), "aircraft are true to size at gun range")
	var grows: bool = true
	var shrinks_on_screen: bool = true
	for d in range(700, 6000, 100):
		grows = grows and Aircraft.spot_scale(d + 100.0) >= Aircraft.spot_scale(float(d))
		shrinks_on_screen = shrinks_on_screen and Aircraft.spot_scale(d + 100.0) / (d + 100.0) < Aircraft.spot_scale(float(d)) / d
	check(grows and shrinks_on_screen and Aircraft.spot_scale(9000.0) <= Aircraft.SPOT_MAX, "distant aircraft are drawn larger but still look smaller the further away they are")
	check(Aircraft.spot_scale(2000.0) > 1.8, "an aircraft 2 km away is drawn about twice life size (%.2f)" % Aircraft.spot_scale(2000.0))
	check(is_equal_approx(Effects.far_scale(100.0), 1.0) and Effects.far_scale(900.0) > 2.0 and Effects.far_scale(5000.0) <= Effects.FAR_MAX, "strike effects grow with distance up to a limit")


## Seconds of sustained fire from `shooter_frame`, from dead astern, to destroy `target_frame`.
func _time_to_kill(shooter_frame: int, target_frame: int) -> float:
	var high: Vector3 = terrain.spawn_position + Vector3(0, 900, 0)
	var target: Combatant = _combatant(1, 1, target_frame, high)
	var shooter: Combatant = _combatant(0, 0, shooter_frame, high + Vector3(0, 0, 300.0))
	var field: BulletField = BulletField.new()
	var everyone: Array[Combatant] = [shooter, target]
	var level: FlightCommand = FlightCommand.new()
	var dt: float = 1.0 / 60.0
	var time: float = 0.0
	while target.model.alive and time < 30.0:
		for c in everyone:
			level.aim_direction = Vector3.FORWARD
			c.model.step(level, dt, terrain)
		# Hold station behind the target so only the guns and hull differ.
		shooter.model.position = target.model.position + Vector3(0, 0, 300.0)
		shooter.shoot(true, dt, field)
		for impact in field.step(dt, terrain, everyone):
			if impact.has("target"):
				(impact.target as Combatant).model.apply_damage(float(impact.damage), int(impact.zone))
		time += dt
	field.free()
	return time


func _test_guns_hit_and_destroy() -> void:
	var ttk: float = _time_to_kill(Airframes.Id.MUSTANG, Airframes.Id.MUSTANG)
	check(ttk > 0.5 and ttk < 3.0, "sustained fire from astern destroys a Mustang (%.2f s)" % ttk)
	# Rounds must not hit the aircraft that fired them, nor a team-mate.
	var high: Vector3 = terrain.spawn_position + Vector3(0, 900, 0)
	var shooter: Combatant = _combatant(0, 0, Airframes.Id.MUSTANG, high)
	var friend: Combatant = _combatant(1, 0, Airframes.Id.MUSTANG, high + Vector3(0, 0, -250.0))
	var field: BulletField = BulletField.new()
	var hits: int = 0
	for i in range(90):
		shooter.shoot(true, 1.0 / 60.0, field)
		for impact in field.step(1.0 / 60.0, terrain, [shooter, friend] as Array[Combatant]):
			hits += 1 if impact.has("target") else 0
	check(hits == 0 and field.count() > 0, "rounds pass through the shooter's own side")
	# A miss: target well off the line of fire.
	var bystander: Combatant = _combatant(2, 1, Airframes.Id.MUSTANG, high + Vector3(120.0, 0, -300.0))
	hits = 0
	for i in range(90):
		shooter.shoot(true, 1.0 / 60.0, field)
		for impact in field.step(1.0 / 60.0, terrain, [shooter, bystander] as Array[Combatant]):
			hits += 1 if impact.has("target") else 0
	check(hits == 0, "rounds miss a target 120 m off the line of fire")
	field.free()


func _test_heavy_outlasts_light() -> void:
	var gun: int = Airframes.Id.MUSTANG
	var light: float = _time_to_kill(gun, Airframes.Id.SPITFIRE)
	var medium: float = _time_to_kill(gun, Airframes.Id.MUSTANG)
	var heavy: float = _time_to_kill(gun, Airframes.Id.THUNDERBOLT)
	check(light < medium and medium < heavy, "same guns take longer on tougher aircraft (%.2f < %.2f < %.2f s)" % [light, medium, heavy])
	var by_light: float = _time_to_kill(Airframes.Id.SPITFIRE, gun)
	var by_heavy: float = _time_to_kill(Airframes.Id.THUNDERBOLT, gun)
	check(by_heavy < medium and medium < by_light, "heavier guns destroy the same target sooner (%.2f < %.2f < %.2f s)" % [by_heavy, medium, by_light])


func _test_damage_zones() -> void:
	for frame in range(Airframes.COUNT):
		var spec: Dictionary = Airframes.spec(frame)
		var ok: bool = Airframes.zone_at(spec, Vector3(0, 0, -3.5)) == Airframes.Zone.ENGINE \
			and Airframes.zone_at(spec, Vector3(0.1, 0.2, 0.3)) == Airframes.Zone.BODY \
			and Airframes.zone_at(spec, Vector3(-3.0, 0, 0)) == Airframes.Zone.WING_L \
			and Airframes.zone_at(spec, Vector3(3.0, 0, 0)) == Airframes.Zone.WING_R \
			and Airframes.zone_at(spec, Vector3(1.2, 0.3, 4.6)) == Airframes.Zone.TAIL
		check(ok, "%s hits map to engine, body, wings and tail" % spec.short)
		check(AirframeOutline.zones(frame).size() == 5, "%s has a five-zone damage outline" % spec.short)
	var m: FlightModel = _model()
	check(not m.apply_damage(30.0, Airframes.Zone.WING_L) and m.zone_health[Airframes.Zone.WING_L] < 0.5 and m.zone_health[Airframes.Zone.WING_R] == 1.0,
		"damage is recorded in the zone that was hit")
	check(absf(m.hull - 70.0) < 0.01 and m.alive, "hull drops by the damage taken")
	check(m.apply_damage(80.0, Airframes.Zone.BODY) and not m.alive, "hull at zero destroys the aircraft")
	m.setup(Airframes.Id.MUSTANG, m.position, 0.0)
	check(m.alive and m.hull == 100.0 and m.zone_health[Airframes.Zone.WING_L] == 1.0, "a fresh aircraft starts undamaged")


func _test_engine_damage_slows() -> void:
	var healthy: FlightModel = _model()
	var hurt: FlightModel = _model()
	hurt.apply_damage(40.0, Airframes.Zone.ENGINE)
	_fly(healthy, Vector3.FORWARD, 12.0)
	_fly(hurt, Vector3.FORWARD, 12.0)
	check(hurt.speed < healthy.speed - 8.0, "a damaged engine lowers speed (%d vs %d m/s)" % [int(hurt.speed), int(healthy.speed)])
	var agile: FlightModel = _model()
	var holed: FlightModel = _model()
	holed.apply_damage(40.0, Airframes.Zone.WING_R)
	var aim: Vector3 = Vector3(1, 0, -0.2)
	_fly(agile, aim, 0.5)
	_fly(holed, aim, 0.5)
	check(absf(holed.basis().x.y) < absf(agile.basis().x.y), "a damaged wing rolls more slowly")


## Below 40% hull an aircraft loses power, reaching about 28% lower speed under
## 20%; an engine hit and a burning airframe never stack.
func _test_burning_aircraft_slows() -> void:
	check(FlightModel.damage_power(1.0, 1.0) == 1.0 and FlightModel.damage_power(1.0, 0.45) == 1.0, "no power loss above 40% hull")
	check(is_equal_approx(FlightModel.damage_power(1.0, 0.15), 0.52), "a burning airframe keeps 52% power")
	check(is_equal_approx(FlightModel.damage_power(0.0, 0.15), 0.5), "engine and hull losses do not stack")
	var healthy: FlightModel = _model()
	var holed: FlightModel = _model()
	var burning: FlightModel = _model()
	holed.apply_damage(55.0, Airframes.Zone.BODY)
	burning.apply_damage(85.0, Airframes.Zone.BODY)
	for m in [healthy, holed, burning]:
		_fly(m, Vector3.FORWARD, 20.0)
	check(healthy.alive and holed.alive and burning.alive, "all three stay airborne for the speed check")
	check(absf(holed.speed - healthy.speed) < 1.0, "45%% hull flies at full speed (%d vs %d m/s)" % [int(holed.speed), int(healthy.speed)])
	var ratio: float = burning.speed / healthy.speed
	check(ratio > 0.68 and ratio < 0.8, "15%% hull flies about 28%% slower (%.0f%% of full speed)" % (ratio * 100.0))


## The flight-path line goes from a faint white line to black smoke as the hull
## is shot away, getting wider, and never jumps between stages.
func _test_trail_darkens_with_damage() -> void:
	var healthy: Array = DamageTrail.look(1.0)
	var hit: Array = DamageTrail.look(0.7)
	check((healthy[0] as Color).a < 0.3 and (healthy[0] as Color).v > 0.95, "a healthy aircraft leaves a faint white line")
	check((hit[0] as Color).a > 0.5 and (hit[0] as Color).v > 0.95, "a hit aircraft leaves a solid white line")
	var smooth: bool = true
	var darker: bool = true
	var previous: Array = DamageTrail.look(1.0)
	for i in range(1, 101):
		var current: Array = DamageTrail.look(1.0 - i / 100.0)
		darker = darker and (current[0] as Color).v <= (previous[0] as Color).v + 0.0001 and float(current[1]) >= float(previous[1]) - 0.0001
		smooth = smooth and absf((current[0] as Color).v - (previous[0] as Color).v) < 0.05
		previous = current
	check(darker, "the line darkens and widens as damage mounts")
	check(smooth, "the line changes smoothly between stages")
	check((DamageTrail.look(0.1)[0] as Color).v < 0.1, "a nearly destroyed aircraft trails black smoke")


func _test_health_dots() -> void:
	var cases: Dictionary = {1.0: 5, 0.85: 5, 0.79: 4, 0.6: 3, 0.5: 3, 0.3: 2, 0.15: 1, 0.01: 1, 0.0: 0}
	var ok: bool = true
	for share: float in cases:
		ok = ok and Hud.health_dots(share) == int(cases[share])
	check(ok, "five health dots, one per fifth of the hull, at least one while flying")


## Bullet holes land on the outline of the zone that was hit, even when the
## round passed through the (larger) hit sphere outside the aircraft's skin.
func _test_hit_marks() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 7
	var on_skin: bool = true
	var anchors_inside: bool = true
	for frame in range(Airframes.COUNT):
		var polys: Array[PackedVector2Array] = AirframeOutline.cached_zones(frame)
		for zone in range(5):
			anchors_inside = anchors_inside and Geometry2D.is_point_in_polygon(AirframeOutline.anchors(frame)[zone], polys[zone])
			for k in range(12):
				var stray: Vector2 = Vector2(rng.randf_range(-7.0, 7.0), rng.randf_range(-7.0, 7.0))
				on_skin = on_skin and Geometry2D.is_point_in_polygon(AirframeOutline.place_hit(frame, zone, stray), polys[zone])
				on_skin = on_skin and Geometry2D.is_point_in_polygon(AirframeOutline.random_spot(frame, zone, rng), polys[zone])
	check(anchors_inside, "every damage zone has a point inside it to pull stray hits toward")
	check(on_skin, "bullet holes always land inside the zone that was hit")
	var inside: Vector2 = Vector2(3.0, -0.2)
	check(AirframeOutline.place_hit(Airframes.Id.MUSTANG, Airframes.Zone.WING_R, inside) == inside, "a hit already on the wing stays where it struck")
	var m: FlightModel = _model()
	for k in range(FlightModel.MAX_HIT_MARKS + 5):
		m.mark_hit(Airframes.Zone.BODY, Vector2(0.0, 0.5))
	check(m.hit_marks.size() == FlightModel.MAX_HIT_MARKS, "holes are capped at %d per aircraft" % FlightModel.MAX_HIT_MARKS)
	m.setup(Airframes.Id.SPITFIRE, m.position, 0.0)
	check(m.hit_marks.is_empty(), "a fresh aircraft has no bullet holes")
	# A real burst: every hit reports where it struck in the target's own space.
	var shooter: Combatant = _combatant(0, 0, Airframes.Id.MUSTANG, terrain.spawn_position + Vector3(0, 900, 0))
	var target: Combatant = _combatant(1, 1, Airframes.Id.SPITFIRE, terrain.spawn_position + Vector3(0, 900, -250))
	var field: BulletField = BulletField.new()
	var all: Array[Combatant] = [shooter, target]
	var hits: int = 0
	for i in range(60):
		shooter.shoot(true, 1.0 / 60.0, field)
		for impact in field.step(1.0 / 60.0, terrain, all):
			if impact.has("target"):
				hits += 1
				var local: Vector3 = impact.local
				target.model.mark_hit(int(impact.zone), Vector2(local.x, local.z))
	field.free()
	check(hits > 0 and target.model.hit_marks.size() == mini(hits, FlightModel.MAX_HIT_MARKS), "each round that strikes leaves a hole (%d hits)" % hits)


## The left damage panel follows the opponent in the sights, lingers, fades out
## slowly and swaps straight to another opponent.
func _test_target_panel() -> void:
	var hud: Hud = Hud.new()
	var me: Combatant = _combatant(0, 0, Airframes.Id.MUSTANG, Vector3.ZERO)
	var a: Combatant = _combatant(1, 1, Airframes.Id.SPITFIRE, Vector3.ZERO)
	var b: Combatant = _combatant(2, 1, Airframes.Id.THUNDERBOLT, Vector3.ZERO)
	var mate: Combatant = _combatant(3, 0, Airframes.Id.SPITFIRE, Vector3.ZERO)
	hud.player = me
	hud.frame_delta = 0.05
	for i in range(4):
		hud.update_target_panel(a)
	check(hud.panel_target == a and hud.panel_alpha >= 1.0, "aiming at an opponent shows its panel within 0.2 s")
	for i in range(30):
		hud.update_target_panel(null)
	check(hud.panel_target == a and hud.panel_alpha >= 1.0, "the panel stays up for a while after the guns move off")
	for i in range(10):
		hud.update_target_panel(null)
	check(hud.panel_target == a and hud.panel_alpha > 0.0 and hud.panel_alpha < 1.0, "then it fades out slowly")
	hud.update_target_panel(b)
	check(hud.panel_target == b, "aiming at another opponent swaps the panel over")
	for i in range(80):
		hud.update_target_panel(null)
	check(hud.panel_target == null and hud.panel_alpha == 0.0, "the panel is gone once fully faded")
	hud.update_target_panel(mate)
	check(hud.panel_target == null, "friends do not get a target panel")
	hud.update_target_panel(a)
	hud.target_hit(b)
	check(hud.panel_target == a, "a stray hit on another opponent does not steal the panel")
	hud.update_target_panel(null)
	hud.target_hit(b)
	check(hud.panel_target == b, "a hit with nobody in the sights shows the one that was hit")
	b.model.alive = false
	hud.update_target_panel(null)
	check(hud.panel_target == b and hud.panel_hold == 0.0, "a destroyed target starts fading straight away")
	hud.free()
	var zones: PackedFloat32Array = PackedFloat32Array([0.2, 1.0, 1.0, 0.5, 0.9])
	check(Hud.damage_summary(zones) == PackedStringArray(["ENGINE CRITICAL", "R WING DAMAGED"]), "damage summary names the worst zones first")
	check(Hud.damage_summary(PackedFloat32Array([1, 1, 1, 1, 1])) == PackedStringArray(["NO DAMAGE"]), "an untouched aircraft reads no damage")
	check(Hud.damage_summary(zones, false) == PackedStringArray(["DESTROYED"]), "a shot-down aircraft reads destroyed")


func _test_radar_plot() -> void:
	var at: Vector3 = Vector3(1000, 900, -2000)
	check(Radar.plot(at, at + Vector3(Radar.RANGE * 0.5, 300, 0), 100.0).is_equal_approx(Vector2(50, 0)), "radar: east is right, height ignored")
	check(Radar.plot(at, at + Vector3(0, 0, -Radar.RANGE), 100.0).is_equal_approx(Vector2(0, -100)), "radar: north is up, range at the rim")


## After a loop the camera's up vector eases back to exactly world up, rather than
## sticking a hair away from it with a rotation error every frame.
func _test_camera_up_settles() -> void:
	var up: Vector3 = Vector3(0.3, 0.9, -0.2).normalized()
	var weight: float = 1.0 - exp(-3.0 / 60.0)
	var after_one_second: Vector3 = up
	for frame in range(3000):
		up = ChaseCamera.settle_up(up, weight)
		if frame == 59:
			after_one_second = up
	check(after_one_second.dot(Vector3.UP) > 0.99 and after_one_second != Vector3.UP, "the camera still eases back level over about a second")
	check(up == Vector3.UP, "the camera's up vector settles on exactly world up")


## The valley path can be measured along its length from any position.
func _test_valley_path() -> void:
	var mid: Vector3 = terrain.valley_path[terrain.valley_path.size() / 2]
	var along: float = terrain.path_progress(mid + Vector3(40.0, 300.0, -25.0))
	check(terrain.path_point(along).distance_to(mid) < 80.0, "path progress finds the nearest path point")
	var ahead: Vector3 = terrain.valley_point_ahead(mid, 1000.0, 1.0)
	var behind: Vector3 = terrain.valley_point_ahead(mid, 1000.0, -1.0)
	check(absf(terrain.path_progress(ahead) - along - 1000.0) < 60.0 and absf(along - terrain.path_progress(behind) - 1000.0) < 60.0,
		"look-ahead points lie 1 km either way along the path")
	var inside: bool = true
	var clear: bool = true
	for point in terrain.valley_path:
		inside = inside and Vector2(point.x, point.z).length() < 8600.0   # PlayerInput.arena_radius
		clear = clear and terrain.height_at(point.x, point.z) < terrain.water_level + 400.0
	check(inside, "the valley path stays inside the arena")
	check(clear, "the valley path follows low ground")


## Plav & Gusinje: lake at 0 m, summits 2450 m above it, snow from 1500 m.
func _test_plav_shape() -> void:
	check(is_zero_approx(terrain.water_level), "the lake surface is at 0 m")
	check(absf(terrain.height_max - 2450.0) < 10.0, "the highest summit is 2450 m (%d m)" % int(terrain.height_max))
	check(is_equal_approx(float(terrain.look.snow_line), 1500.0), "the snow line is at 1500 m")
	var lake: Vector3 = Vector3(5870.0, 0.0, -3770.0)
	check(terrain.height_at(lake.x, lake.z) < -5.0, "Plav lake is where the map says")
	var highest: Vector3 = Vector3.ZERO
	for z in range(0, terrain.samples, 8):
		for x in range(0, terrain.samples, 8):
			if terrain.heights[z * terrain.samples + x] > highest.y:
				highest = Vector3(x * terrain.spacing - terrain.size * 0.5, terrain.heights[z * terrain.samples + x], z * terrain.spacing - terrain.size * 0.5)
	check(highest.z > 5000.0, "the highest ground is in the south (%d, %d)" % [int(highest.x), int(highest.z)])


## The autopilot flies the whole route both ways without hitting anything.
func _test_autopilot_flies_the_route() -> void:
	var route: Autopilot = Autopilot.new()
	route.terrain = terrain
	var m: FlightModel = FlightModel.new()
	m.setup(Airframes.Id.MUSTANG, terrain.spawn_position, terrain.spawn_heading)
	var crashed: bool = false
	var furthest: float = 0.0
	var turned_back: bool = false
	for tick in range(360 * 60):
		if m.step(route.sample(m), 1.0 / 60.0, terrain):
			crashed = true
			break
		furthest = maxf(furthest, terrain.path_progress(m.position))
		turned_back = turned_back or route.heading_sign < 0.0
	check(not crashed, "the autopilot flies six minutes without crashing")
	check(turned_back and furthest > terrain.path_length - 2000.0, "the autopilot reaches the far end and turns back")


## Two opponents hunt a target flying the valley for three minutes of game time.
## `gunnery` also requires hits; a map check only needs the flying to be safe.
func _test_ai_hunts_without_crashing(gunnery: bool = true) -> void:
	var route: Autopilot = Autopilot.new()
	route.terrain = terrain
	var prey: Combatant = _combatant(0, 0, Airframes.Id.MUSTANG, terrain.spawn_position, terrain.spawn_heading)
	prey.is_player = true
	var everyone: Array[Combatant] = [prey]
	var hunters: Array[Combatant] = []
	for i in range(2):
		var at: Vector3 = terrain.valley_path[10 + i * 8]
		var hunter: Combatant = _combatant(i + 1, 1, (i * 2) % Airframes.COUNT, Vector3(at.x, terrain.surface_at(at.x, at.z) + 400.0, at.z), PI * i)
		hunter.ai = AiPilot.new()
		hunter.ai.setup(terrain, 100 + i)
		hunters.append(hunter)
		everyone.append(hunter)
	var field: BulletField = BulletField.new()
	var dt: float = 1.0 / 60.0
	var crashes: int = 0
	var hits: int = 0
	var shots: int = 0
	var closest: float = INF
	for tick in range(180 * 60):
		if prey.model.alive:
			prey.model.step(route.sample(prey.model), dt, terrain)
		else:
			prey.spawn(terrain.spawn_position, terrain.spawn_heading)
		for hunter in hunters:
			if not hunter.model.alive:
				continue
			var cmd: FlightCommand = hunter.ai.sample(hunter.model, prey.model, dt)
			if hunter.model.step(cmd, dt, terrain):
				crashes += 1
				continue
			shots += hunter.shoot(cmd.fire, dt, field)
			closest = minf(closest, hunter.model.position.distance_to(prey.model.position))
		for impact in field.step(dt, terrain, everyone):
			if impact.has("target"):
				hits += 1
				(impact.target as Combatant).model.apply_damage(float(impact.damage) * 0.5, int(impact.zone))
	field.free()
	check(crashes == 0, "AI pilots never fly into the ground (%d crashes in 3 min)" % crashes)
	check(closest < 600.0, "AI pilots close to gun range (closest %d m)" % int(closest))
	if gunnery:
		check(shots > 20 and hits > 0, "AI pilots fire and score hits (%d rounds, %d hits)" % [shots, hits])
	else:
		check(shots > 0, "AI pilots get their guns to bear (%d rounds)" % shots)


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
	# Zoomed, the same mouse movement swings the aim less, by the magnification,
	# so the aim circle crosses the screen at the same pace.
	input.settings.invert_y = false
	input.reset(Vector3.FORWARD)
	input.apply_mouse(Vector2(120, 0))
	var normal_swing: float = input.aim_direction.angle_to(Vector3.FORWARD)
	var camera: ChaseCamera = ChaseCamera.new()
	camera.zoom_now = 3.0
	input.reset(Vector3.FORWARD)
	input.aim_scale = camera.aim_scale()
	input.apply_mouse(Vector2(120, 0))
	check(is_equal_approx(input.aim_direction.angle_to(Vector3.FORWARD) * 3.0, normal_swing), "zoomed 3x, the mouse swings the aim a third as far")
	check(is_equal_approx(ChaseCamera.magnification(ChaseCamera.fov_for(4.0)), 4.0), "the zoomed field of view magnifies by the level asked for")
	camera.free()
	input.free()
	_test_zoom_levels()


## Z toggles the gunsight zoom, the wheel steps it, and each aircraft's sight
## sets how far it goes: the heavier the guns, the further.
func _test_zoom_levels() -> void:
	var limits: Array[float] = []
	for id in range(Airframes.COUNT):
		limits.append(float(Airframes.spec(id).zoom))
	check(limits[0] < limits[1] and limits[1] < limits[2], "heavier aircraft zoom further (%s)" % str(limits))
	var input: PlayerInput = PlayerInput.new()
	input.settings = GameSettings.new()
	input.max_zoom = limits[Airframes.Id.THUNDERBOLT]
	input.toggle_zoom()
	check(is_equal_approx(input.zoom_level, PlayerInput.ZOOM_DEFAULT), "Z zooms to the default level first")
	input.toggle_zoom()
	check(input.zoom_level == 1.0, "Z again returns to the normal view")
	for notch in range(3):
		input.step_zoom(1)
	check(absf(input.zoom_level - 2.0) < 0.01, "three wheel notches double the magnification (%.2f)" % input.zoom_level)
	for notch in range(20):
		input.step_zoom(1)
	check(input.zoom_level == input.max_zoom, "the wheel stops at the aircraft's limit")
	input.toggle_zoom()
	input.toggle_zoom()
	check(input.zoom_level == input.max_zoom, "Z returns to the level the wheel chose")
	input.max_zoom = limits[Airframes.Id.SPITFIRE]
	input.toggle_zoom()
	input.toggle_zoom()
	check(input.zoom_level == input.max_zoom, "a lighter aircraft's sight caps the remembered level")
	for notch in range(20):
		input.step_zoom(-1)
	check(input.zoom_level == 1.0, "the wheel zooms all the way back out")
	input.step_zoom(1)
	input.reset(Vector3.FORWARD)
	check(input.zoom_level == 1.0, "a new life starts zoomed out")
	input.free()


func _test_tip_vapour_follows_class_speed() -> void:
	var ok: bool = true
	for id in [Airframes.Id.MUSTANG, Airframes.Id.SPITFIRE, Airframes.Id.THUNDERBOLT]:
		var s: Dictionary = Airframes.spec(id)
		var top: float = float(s.top_speed)
		var boost: float = float(s.boost_speed)
		var cruise: float = TipTrail.vapour_strength(1.0, top * 0.82, top, boost)
		var at_top: float = TipTrail.vapour_strength(1.0, top, top, boost)
		var at_boost: float = TipTrail.vapour_strength(1.0, boost, top, boost)
		ok = ok and cruise == 0.0 and at_top > 0.1 and at_boost > at_top * 2.0
	check(ok, "every class shows tip vapour near its own top speed, none at cruise")
	check(is_equal_approx(TipTrail.vapour_strength(6.0, 100.0, 172.0, 205.0), 1.0), "a hard pull gives the full tip ribbon at any speed")


## Flaps drop when slow and part way in a firm turn on every aircraft, the same
## way at any frame rate, and swing down on both wings; the wings bend upward
## under load and straighten in level flight.
func _test_flaps_and_wing_flex() -> void:
	check(Aircraft.flex_target(1.0, 0.28) == 0.0 and is_equal_approx(Aircraft.flex_target(Aircraft.FLEX_FULL_LOAD, 0.28), 0.28)
		and Aircraft.flex_target(30.0, 0.28) <= 0.28, "wings are straight at 1 g and bend their full amount in the hardest pull")
	check(Aircraft.flex_target(-1.0, 0.28) < 0.0, "pushing below 1 g bends them down")
	for id in [Airframes.Id.SPITFIRE, Airframes.Id.MUSTANG, Airframes.Id.THUNDERBOLT]:
		var s: Dictionary = Airframes.spec(id)
		var name: String = String(s.short)
		var stall: float = float(s.stall)
		var top: float = float(s.top_speed)
		var boost: float = float(s.boost_speed)
		# The load of a pull at `share` of the hardest the aircraft can make at `speed`.
		var pull: Callable = func(speed: float, share: float) -> float:
			return 1.0 + share * float(s.pitch_rate) * speed / FlightModel.GRAVITY
		check(Aircraft.flap_target(top * 0.82, 1.0, s) == 0.0 and Aircraft.flap_target(top, 1.0, s) == 0.0, "%s flaps stay up in level flight at cruise and top speed" % name)
		check(Aircraft.flap_target(stall * 1.2, 1.0, s) == 1.0 and Aircraft.flap_target(stall * 2.0, 1.0, s) == 0.0, "%s flaps are fully down near the stall" % name)
		check(Aircraft.flap_target(top * 0.8, pull.call(top * 0.8, 0.08), s) == 0.0, "%s flaps stay up in a gentle turn" % name)
		var firm: float = Aircraft.flap_target(top * 0.8, pull.call(top * 0.8, 0.5), s)
		var hard: float = Aircraft.flap_target(top * 0.8, pull.call(top * 0.8, 1.0), s)
		check(is_equal_approx(firm, Aircraft.COMBAT_FLAPS) and is_equal_approx(hard, Aircraft.COMBAT_FLAPS), "%s flaps drop part way in a firm turn and no further in the hardest (%.2f, %.2f)" % [name, firm, hard])
		var at_top: float = Aircraft.flap_target(top, pull.call(top, 1.0), s)
		check(at_top > 0.2 and at_top < firm, "%s flaps drop less in a hard turn at top speed (%.2f)" % [name, at_top])
		check(Aircraft.flap_target(boost, pull.call(boost, 1.0), s) == 0.0, "%s flaps stay up at boost speed" % name)
		check(Aircraft.flap_target(top * 0.8, -3.0, s) == 0.0, "%s flaps stay up when pushing" % name)

		var a: Aircraft = Aircraft.new()
		root.add_child(a)
		a.build(s, 0, false)
		check(a.flaps.size() >= 2 and a.flaps.size() % 2 == 0 and a.flex_meshes.size() >= 10, "%s has flaps on both wings and bending wing parts" % name)
		var up: Dictionary = _flap_low_points(a)
		a.flap_amount = 1.0
		a._pose_flaps()
		var down: Dictionary = _flap_low_points(a)
		a.reset_pose()
		var least: float = INF
		var uneven: float = 0.0
		for flap: String in up:
			least = minf(least, float(up[flap]) - float(down[flap]))
			if flap.contains("_L_"):
				uneven = maxf(uneven, absf(float(down[flap]) - float(down[flap.replace("_L_", "_R_")])))
		check(least > 0.35 and uneven < 0.01, "%s flaps swing down on both wings alike (at least %.2f m, %.3f m apart)" % [name, least, uneven])

		# A firm level turn, drawn at 60 and at 240 frames a second.
		var seen: Array[float] = []
		for frames: int in [1, 4]:
			a.reset_pose()
			var m: FlightModel = _model(id)
			var cmd: FlightCommand = FlightCommand.new()
			var most: float = 0.0
			var hardest: float = 0.0
			for i in range(180):
				var f: Vector3 = m.forward()
				cmd.aim_direction = Vector3(f.x, 0.0, f.z).normalized().rotated(Vector3.UP, -deg_to_rad(15.0))   # held 15 degrees to the right
				m.step(cmd, 1.0 / 60.0, terrain)
				for k in range(frames):
					a.animate(m, 1.0 / (60.0 * frames))
				most = maxf(most, a.flex_bend)
				hardest = maxf(hardest, a.felt_load)
				if i == 59:
					seen.append(a.felt_load)
			if frames == 1:
				check(hardest > 2.0 and most > 0.5 * float(s.flex), "%s wings bend up in a firm turn (%.1f g, tips %.2f m)" % [name, hardest, most])
				check(a.flap_amount > Aircraft.COMBAT_FLAPS - 0.05 and a.flap_amount < Aircraft.COMBAT_FLAPS + 0.01, "%s flaps are part way down in a firm turn (%.2f)" % [name, a.flap_amount])
				cmd.aim_direction = m.forward() * Vector3(1.0, 0.0, 1.0)
				for i in range(360):
					m.step(cmd, 1.0 / 60.0, terrain)
					a.animate(m, 1.0 / 60.0)
				check(absf(a.felt_load - 1.0) < 0.25 and absf(a.flex_bend) < 0.03, "%s wings settle straight in level flight (%.2f g, tips %.3f m)" % [name, a.felt_load, a.flex_bend])
				check(a.flap_amount == 0.0, "%s flaps go back up in level flight" % name)
		check(absf(seen[0] - seen[1]) < 0.08 * seen[0], "%s wings feel the same load at 60 and 240 frames a second (%.1f g, %.1f g)" % [name, seen[0], seen[1]])
		a.free()


## The lowest point of each flap, by name, in the aircraft's own space.
func _flap_low_points(a: Aircraft) -> Dictionary:
	var out: Dictionary = {}
	for flap in a.flaps:
		var mesh_instance: MeshInstance3D = flap
		var to_aircraft: Transform3D = Transform3D.IDENTITY
		var n: Node = flap
		while n != a:
			to_aircraft = (n as Node3D).transform * to_aircraft
			n = n.get_parent()
		var low: float = INF
		for surface in range(mesh_instance.mesh.get_surface_count()):
			for v: Vector3 in mesh_instance.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
				low = minf(low, (to_aircraft * v).y)
		out[String(flap.name)] = low
	return out


## Volumes survive a save and reload, and drive their own audio buses.
func _test_volume_settings_persist() -> void:
	var path: String = "user://test_settings.cfg"
	var s: GameSettings = GameSettings.new()
	s.master_volume = 0.35
	s.engine_volume = 0.5
	s.effects_volume = 0.0
	s.save(path)
	var loaded: GameSettings = GameSettings.load_or_default(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	check(is_equal_approx(loaded.master_volume, 0.35) and is_equal_approx(loaded.engine_volume, 0.5)
		and is_equal_approx(loaded.effects_volume, 0.0), "volume settings persist across a reload")
	loaded.apply_audio()
	var engine_bus: int = AudioServer.get_bus_index(GameSettings.BUS_ENGINE)
	var effects_bus: int = AudioServer.get_bus_index(GameSettings.BUS_EFFECTS)
	check(engine_bus > 0 and effects_bus > 0, "engine and effects buses exist")
	loaded.apply_audio()
	var limiters: int = 0
	for i in range(AudioServer.get_bus_effect_count(0)):
		if AudioServer.get_bus_effect(0, i) is AudioEffectHardLimiter:
			limiters += 1
	check(limiters == 1, "the output has one limiter, however often the volumes are applied")
	check(absf(AudioServer.get_bus_volume_db(0) - linear_to_db(0.35)) < 0.01
		and absf(AudioServer.get_bus_volume_db(engine_bus) - linear_to_db(0.5)) < 0.01, "bus volumes follow the settings")
	check(AudioServer.is_bus_mute(effects_bus), "zero volume mutes the effects bus")
	loaded.apply_audio()
	check(AudioServer.bus_count == 3, "applying twice adds no duplicate buses")
