class_name MatchReferee
extends RefCounted
## The host's rules for a networked match. Each player's own game flies its
## aircraft and reports its motion and the hits its rounds made; the referee
## checks those reports against what is physically possible and alone decides
## damage, kills, respawns and the winner. It produces event messages (the same
## Dictionaries NetProtocol sends) and never touches rendering, so it runs the
## same on a dedicated server and in tests.

const RESPAWN_DELAY: float = 3.0
const FIRING_GRACE: float = 0.6          ## a hit may arrive this long after the trigger was seen
const GUN_REACH: float = BulletField.SPEED * BulletField.LIFETIME + 350.0   ## round range plus lag margin
const MOVE_SLACK: float = 45.0           ## metres of tolerance per motion report
const CLOCK_SLACK: float = 1.0           ## a sender's clock may run this far ahead of real time
const STRIKE_LIMIT: float = 40.0         ## bad reports (decaying) before a player is removed
const STRIKE_DECAY: float = 2.0          ## per second
const SPAWN_SEPARATION: float = 2200.0     ## close enough to find each other, far enough to set up

var terrain: TerrainData
var combatants: Array[Combatant] = []
var score_limit: int = 5
var running: bool = false
var time: float = 0.0
var tracks: Array[Dictionary] = []
var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func setup(arena: TerrainData, everyone: Array[Combatant], limit: int, seed_value: int) -> void:
	terrain = arena
	combatants = everyone
	score_limit = maxi(limit, 1)
	rng.seed = seed_value
	time = 0.0
	running = true
	tracks.clear()
	for c in combatants:
		tracks.append({"valid": false, "position": Vector3.ZERO, "tick": 0, "time": 0.0, "first_tick": 0, "first_time": 0.0,
			"last_firing": -100.0, "budget": 0.0, "strikes": 0.0, "down": false})


## Where each slot starts: spread along the valley either side of its middle,
## everyone facing the middle.
func start_positions(count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var mid_along: float = terrain.path_length * 0.5
	var mid: Vector3 = terrain.path_point(mid_along)
	var offsets: Array[float] = [-1000.0, 1000.0, -1800.0, 1800.0]   # about 2 km between the first two
	for k in range(count):
		var p: Vector3 = terrain.path_point(clampf(mid_along + offsets[k % offsets.size()], 0.0, terrain.path_length))
		var at: Vector3 = Vector3(p.x, terrain.surface_at(p.x, p.z) + 420.0 + 60.0 * k, p.z)
		var to_mid: Vector3 = mid - at
		out.append({"position": at, "heading": atan2(-to_mid.x, -to_mid.z)})
	return out


## A respawn point a few kilometres from the nearest opponent, facing them.
func respawn_point(c: Combatant) -> Dictionary:
	var best: Vector3 = terrain.valley_path[0]
	var best_score: float = INF
	for point in terrain.valley_path:
		var nearest: float = INF
		for other in combatants:
			if other != c and not other.left and other.model.alive and other.team != c.team:
				nearest = minf(nearest, other.model.position.distance_to(point))
		var score: float = (absf(nearest - SPAWN_SEPARATION) if nearest < INF else 0.0) + rng.randf() * 900.0
		if score < best_score:
			best_score = score
			best = point
	var at: Vector3 = Vector3(best.x, terrain.surface_at(best.x, best.z) + rng.randf_range(320.0, 520.0), best.z)
	var target: Vector3 = terrain.path_point(terrain.path_length * 0.5)
	var closest: float = INF
	for other in combatants:
		if other != c and not other.left and other.model.alive and other.model.position.distance_to(at) < closest:
			closest = other.model.position.distance_to(at)
			target = other.model.position
	var to: Vector3 = target - at
	return {"position": at, "heading": atan2(-to.x, -to.z)}


## The player starts (or restarts) at a known point: motion checks begin there.
func placed(c: Combatant, at: Vector3) -> void:
	var t: Dictionary = tracks[c.id]
	t.valid = false
	t.position = at
	t.time = time
	t.down = false


## Check one motion report. Returns false (and counts a strike) if it is not
## possible for that aircraft; the caller then ignores it.
func accept_state(c: Combatant, s: Dictionary) -> bool:
	if c.left or not c.model.alive or (int(s.life) & 255) != (c.life & 255):
		return false   # stale or from a previous life: ignored, not suspicious
	var t: Dictionary = tracks[c.id]
	var spec: Dictionary = c.model.spec
	var top: float = float(spec.boost_speed) * 1.25 + 1.0
	var p: Vector3 = s.position
	var half: float = terrain.size * 0.5
	var ok: bool = float(s.speed) <= top and absf(p.x) <= half and absf(p.z) <= half and p.y > terrain.water_level - 60.0 and p.y < 4400.0
	var tick: int = int(s.tick)
	if ok and t.valid:
		var dt: float = (tick - int(t.tick)) / 60.0
		if dt <= 0.0:
			return false   # out of order: ignored
		var ran_ahead: float = (tick - int(t.first_tick)) / 60.0 - (time - float(t.first_time))
		ok = ran_ahead < CLOCK_SLACK and p.distance_to(t.position) <= top * dt * 1.15 + MOVE_SLACK
	elif ok:
		# First report after a spawn: it must be near the spawn point.
		ok = p.distance_to(t.position) <= top * maxf(time - float(t.time), 0.0) * 1.15 + 120.0
		if ok:
			t.first_tick = tick
			t.first_time = time
	if not ok:
		t.strikes = float(t.strikes) + 1.0
		return false
	t.valid = true
	t.position = p
	t.tick = tick
	if (int(s.flags) & NetProtocol.FLAG_FIRING) != 0:
		t.last_firing = time
	return true


## Hits a player's rounds made, as {target, life, zone, rounds}. Returns events.
func claim_hits(shooter: Combatant, claims: Array) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if not running or shooter.left or not shooter.model.alive:
		return events
	var st: Dictionary = tracks[shooter.id]
	var spec: Dictionary = shooter.model.spec
	for claim: Dictionary in claims:
		var id: int = int(claim.target)
		if id < 0 or id >= combatants.size() or id == shooter.id:
			st.strikes = float(st.strikes) + 1.0
			continue
		var target: Combatant = combatants[id]
		if target.left or not target.model.alive or (int(claim.life) & 255) != (target.life & 255):
			continue   # it died or respawned in the meantime: a race, not cheating
		var in_range: bool = _where(shooter).distance_to(_where(target)) <= GUN_REACH
		var trigger: bool = time - float(st.last_firing) <= FIRING_GRACE
		if target.team == shooter.team or not in_range or not trigger:
			st.strikes = float(st.strikes) + 1.0
			continue
		var rounds: int = mini(int(claim.rounds), int(floor(float(st.budget))))
		if rounds <= 0:
			st.strikes = float(st.strikes) + 0.5
			continue
		st.budget = float(st.budget) - rounds
		var destroyed: bool = target.model.apply_damage(float(spec.gun_damage) * rounds, int(claim.zone))
		events.append({"type": NetProtocol.Msg.DAMAGE, "target": target.id, "shooter": shooter.id, "zone": int(claim.zone),
			"hull": target.model.hull, "zones": target.model.zone_health.duplicate()})
		if destroyed:
			events.append_array(_destroyed(target, shooter))
	return events


## The owner reports its aircraft flew into the ground.
## The host's own aircraft has already been marked dead by its flight model.
func crashed(c: Combatant, life: int) -> Array[Dictionary]:
	if not running or c.left or bool(tracks[c.id].down) or (life & 255) != (c.life & 255):
		return []
	c.model.alive = false
	c.model.hull = 0.0
	return _destroyed(c, null)


## A player left mid-match: they stop counting.
func remove(c: Combatant) -> Array[Dictionary]:
	c.left = true
	c.model.alive = false
	var events: Array[Dictionary] = [{"type": NetProtocol.Msg.LEFT, "id": c.id}]
	var present: int = 0
	for other in combatants:
		present += 0 if other.left else 1
	if running and present < 2:
		events.append(_end())
	return events


## Advance the referee's clock: refill gun budgets, run respawn timers.
func tick(dt: float) -> Array[Dictionary]:
	time += dt
	var events: Array[Dictionary] = []
	for c in combatants:
		var t: Dictionary = tracks[c.id]
		var rate: float = float(c.model.spec.fire_rate)
		t.budget = minf(float(t.budget) + rate * dt, rate * 1.0)
		t.strikes = maxf(float(t.strikes) - STRIKE_DECAY * dt, 0.0)
		if not running or c.left or not bool(t.down):
			continue
		c.respawn_timer -= dt
		if c.respawn_timer <= 0.0:
			c.life = (c.life + 1) & 255
			var spot: Dictionary = respawn_point(c)
			events.append({"type": NetProtocol.Msg.SPAWN, "id": c.id, "life": c.life, "position": spot.position, "heading": spot.heading})
	return events


func strikes_exceeded(c: Combatant) -> bool:
	return float(tracks[c.id].strikes) > STRIKE_LIMIT


func _where(c: Combatant) -> Vector3:
	var t: Dictionary = tracks[c.id]
	return t.position if bool(t.valid) else c.model.position


func _destroyed(target: Combatant, by: Combatant) -> Array[Dictionary]:
	tracks[target.id].down = true
	target.losses += 1
	target.respawn_timer = RESPAWN_DELAY
	if by != null:
		by.kills += 1
	var events: Array[Dictionary] = [{"type": NetProtocol.Msg.DESTROYED, "target": target.id,
		"by": by.id if by != null else NetProtocol.NO_ONE, "losses": target.losses, "kills": by.kills if by != null else 0}]
	if by != null and by.kills >= score_limit:
		events.append(_end())
	return events


func _end() -> Dictionary:
	running = false
	var winner: int = NetProtocol.NO_ONE
	var best: int = -1
	var scores: Array[Dictionary] = []
	for c in combatants:
		scores.append({"id": c.id, "kills": c.kills, "losses": c.losses})
		if not c.left and c.kills > best:
			best = c.kills
			winner = c.id
	return {"type": NetProtocol.Msg.MATCH_END, "winner": winner, "scores": scores}
