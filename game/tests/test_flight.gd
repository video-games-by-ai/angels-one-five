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
	_test_level_assist_rolls_level()
	_test_boost_drains_and_speeds_up()
	_test_ground_collision()
	_test_classes_differ()
	_test_mouse_aim()
	_test_fire_rate()
	_test_guns_hit_and_destroy()
	_test_heavy_outlasts_light()
	_test_damage_zones()
	_test_engine_damage_slows()
	_test_ai_hunts_without_crashing()
	_test_tip_vapour_follows_class_speed()
	_test_valley_path()
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
