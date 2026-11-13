extends SceneTree
## Headless checks for online play: invites, packets, the host's referee,
## remote aircraft smoothing, and real loopback connections for every security
## requirement in docs/multiplayer-design.md.
## Run: godot --headless --path game --script res://tests/test_net.gd

const PORT: int = 24631

var failures: int = 0
var crypto: Crypto = Crypto.new()
var terrain: TerrainData


func _init() -> void:
	terrain = TerrainData.load_default()
	_test_invite()
	_test_protocol()
	_test_protocol_fuzz()
	_test_snapshot_buffer()
	_test_referee_states()
	_test_referee_hits()
	_test_referee_respawn_and_end()
	_test_address_warning()
	_test_no_remote_calls()
	_test_connect_and_talk()
	_test_wrong_certificate()
	_test_wrong_and_missing_secret()
	_test_blocking()
	_test_unencrypted_client()
	_test_bad_packets()
	_test_version_mismatch()
	_test_host_stop_reason()
	print("NET TESTS: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)


func check(condition: bool, label: String) -> void:
	print(("  ok   " if condition else "  FAIL ") + label)
	if not condition:
		failures += 1


# --- Invite --------------------------------------------------------------------

func _cert_der() -> PackedByteArray:
	var key: CryptoKey = crypto.generate_rsa(2048)
	var cert: X509Certificate = crypto.generate_self_signed_certificate(key, "CN=airflight-host,O=Airflight,C=XX")
	return Invite.pem_to_der(cert.save_to_string())


func _test_invite() -> void:
	var inv: Invite = Invite.new()
	inv.address = "203.0.113.5"
	inv.port = 24555
	inv.secret = crypto.generate_random_bytes(16)
	inv.certificate_der = _cert_der()
	var text: String = inv.encode()
	var back: Invite = Invite.decode(text)
	check(back != null and back.address == inv.address and back.port == inv.port and back.secret == inv.secret and back.certificate_der == inv.certificate_der,
		"an invite survives encoding (%d characters)" % text.length())
	check(back != null and back.certificate() != null, "the certificate in an invite loads")
	check(Invite.decode("  " + text + "\n") != null, "surrounding whitespace from a paste is ignored")
	var named: Invite = Invite.new()
	named.address = "pilots.example.net"
	named.port = 30000
	named.secret = inv.secret
	named.certificate_der = inv.certificate_der
	check(Invite.decode(named.encode()) != null and Invite.decode(named.encode()).address == "pilots.example.net", "a DNS name works as the address")
	var bad: Dictionary = {
		"empty": "", "not ours": "hello", "truncated": text.substr(0, text.length() - 120), "half": text.substr(0, 60),
		"stray characters": text.substr(0, 50) + "!@#" + text.substr(53), "oversized": text + "A".repeat(2100),
		"wrong prefix": "AF2." + text.substr(4),
	}
	var error: Array = []
	var all_refused: bool = true
	for name: String in bad:
		var refused: bool = Invite.decode(bad[name], error) == null and not error.is_empty()
		all_refused = all_refused and refused
		if not refused:
			print("       accepted a bad invite: ", name)
	check(all_refused, "damaged, truncated, oversized and foreign invites are refused with a message")
	# Field-level damage inside otherwise valid base64.
	var raw: PackedByteArray = _raw(text)
	var versions: PackedByteArray = raw.duplicate()
	versions[0] = 9
	var address_chars: PackedByteArray = raw.duplicate()
	address_chars[3 + 16 + 1] = 0x20
	var cert_len: PackedByteArray = raw.duplicate()
	cert_len[raw.size() - inv.certificate_der.size() + 3] ^= 0x01
	var no_port: PackedByteArray = raw.duplicate()
	no_port[1] = 0
	no_port[2] = 0
	check(Invite.decode(_text(versions)) == null and Invite.decode(_text(address_chars)) == null and Invite.decode(_text(cert_len)) == null
		and Invite.decode(_text(no_port)) == null, "wrong version, bad address, damaged certificate and port 0 are refused")


func _raw(text: String) -> PackedByteArray:
	var b64: String = text.substr(4).replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	return Marshalls.base64_to_raw(b64)


func _text(raw: PackedByteArray) -> String:
	return Invite.PREFIX + Marshalls.raw_to_base64(raw).replace("+", "-").replace("/", "_").replace("=", "")


# --- Protocol ------------------------------------------------------------------

func _state(tick: int = 120) -> Dictionary:
	return {"life": 3, "tick": tick, "position": Vector3(100.5, 900.25, -2000.0), "orientation": Quaternion(Vector3.UP, 0.7),
		"direction": Vector3(0.0, 0.1, -1.0).normalized(), "speed": 150.0, "throttle": 0.8, "controls": Vector3(0.5, -0.25, 1.0),
		"flags": NetProtocol.FLAG_FIRING}


func _samples() -> Array[Dictionary]:
	var s: Dictionary = _state()
	var world_state: Dictionary = _state()
	world_state.id = 1
	return [
		{"type": NetProtocol.Msg.HELLO, "version": NetProtocol.VERSION, "frame": 2, "name": "Alija"},
		{"type": NetProtocol.Msg.WELCOME, "map": "plav", "max_players": 4, "in_match": true},
		{"type": NetProtocol.Msg.REJECT, "reason": "The match is full."},
		{"type": NetProtocol.Msg.ROSTER, "players": [{"peer": 1, "frame": 0, "name": "Host"}, {"peer": 77, "frame": 2, "name": "Ana"}]},
		{"type": NetProtocol.Msg.MATCH_START, "score_limit": 5, "entries": [
			{"id": 0, "peer": 1, "team": 0, "frame": 1, "name": "Host", "position": Vector3(1, 2, 3), "heading": 0.5},
			{"id": 1, "peer": 77, "team": 1, "frame": 2, "name": "Ana", "position": Vector3(-1, 2, -3), "heading": -2.5}]},
		{"type": NetProtocol.Msg.STATE, "state": s},
		{"type": NetProtocol.Msg.WORLD, "states": [world_state]},
		{"type": NetProtocol.Msg.HIT_CLAIM, "claims": [{"target": 1, "life": 3, "zone": 4, "rounds": 2}]},
		{"type": NetProtocol.Msg.DAMAGE, "target": 1, "shooter": 0, "zone": 2, "hull": 62.5, "zones": PackedFloat32Array([1.0, 0.8, 0.2, 1.0, 1.0])},
		{"type": NetProtocol.Msg.CRASHED, "life": 3},
		{"type": NetProtocol.Msg.DESTROYED, "target": 1, "by": 0, "losses": 4, "kills": 5},
		{"type": NetProtocol.Msg.SPAWN, "id": 1, "life": 4, "position": Vector3(5, 600, 7), "heading": 1.0},
		{"type": NetProtocol.Msg.MATCH_END, "winner": 0, "scores": [{"id": 0, "kills": 5, "losses": 1}, {"id": 1, "kills": 1, "losses": 5}]},
		{"type": NetProtocol.Msg.LOBBY},
		{"type": NetProtocol.Msg.LEFT, "id": 1},
	]


func _test_protocol() -> void:
	var round_trip: bool = true
	var truncation: bool = true
	var trailing: bool = true
	var largest: int = 0
	for m in _samples():
		var bytes: PackedByteArray = NetProtocol.encode(m)
		largest = maxi(largest, bytes.size())
		var back: Dictionary = NetProtocol.decode(bytes)
		round_trip = round_trip and not back.is_empty() and int(back.type) == int(m.type)
		for n in range(bytes.size()):
			truncation = truncation and NetProtocol.decode(bytes.slice(0, n)).is_empty()
		var longer: PackedByteArray = bytes.duplicate()
		longer.append(0)
		trailing = trailing and NetProtocol.decode(longer).is_empty()
	check(round_trip, "every message type survives encoding")
	check(truncation, "every truncated message is refused")
	check(trailing, "a message with extra bytes is refused")
	var state_size: int = NetProtocol.encode({"type": NetProtocol.Msg.STATE, "state": _state()}).size()
	check(state_size <= 60, "a motion report is small (%d bytes)" % state_size)
	var s: Dictionary = NetProtocol.decode(NetProtocol.encode({"type": NetProtocol.Msg.STATE, "state": _state()})).state
	check((s.position as Vector3).is_equal_approx(_state().position) and int(s.tick) == 120 and int(s.flags) == NetProtocol.FLAG_FIRING
		and absf(float(s.throttle) - 0.8) < 0.01 and (s.controls as Vector3).distance_to(Vector3(0.5, -0.25, 1.0)) < 0.02,
		"motion report values arrive intact")
	# Values that encode but must not be accepted.
	var nan_state: Dictionary = _state()
	nan_state.position = Vector3(NAN, 0, 0)
	var huge: Dictionary = _state()
	huge.speed = 1.0e9
	var skewed: Dictionary = _state()
	skewed.orientation = Quaternion(0.0, 0.0, 0.0, 0.2)
	check(NetProtocol.decode(NetProtocol.encode({"type": NetProtocol.Msg.STATE, "state": nan_state})).is_empty()
		and NetProtocol.decode(NetProtocol.encode({"type": NetProtocol.Msg.STATE, "state": huge})).is_empty()
		and NetProtocol.decode(NetProtocol.encode({"type": NetProtocol.Msg.STATE, "state": skewed})).is_empty(),
		"NaN, absurd and non-unit values are refused")
	var bad_zone: Dictionary = {"type": NetProtocol.Msg.HIT_CLAIM, "claims": [{"target": 1, "life": 0, "zone": 9, "rounds": 1}]}
	var bad_frame: Dictionary = {"type": NetProtocol.Msg.HELLO, "version": 1, "frame": 7, "name": "x"}
	check(NetProtocol.decode(NetProtocol.encode(bad_zone)).is_empty() and NetProtocol.decode(NetProtocol.encode(bad_frame)).is_empty(),
		"out-of-range zones and aircraft ids are refused")
	# A name with control characters is cleaned; invalid UTF-8 is refused.
	var hello: Dictionary = NetProtocol.decode(NetProtocol.encode({"type": NetProtocol.Msg.HELLO, "version": 1, "frame": 0, "name": "  Al\nija\u0007 "}))
	check(String(hello.name) == "Alija", "names are cleaned of control characters")
	var raw: PackedByteArray = PackedByteArray([NetProtocol.Msg.HELLO, 1, 0, 0, 2, 0xC3, 0x28])
	check(NetProtocol.decode(raw).is_empty(), "invalid UTF-8 in a name is refused")
	check(NetProtocol.decode(PackedByteArray([200])).is_empty() and NetProtocol.decode(PackedByteArray()).is_empty(), "unknown and empty messages are refused")


## Random bytes, and random damage to real messages, never crash the decoder.
func _test_protocol_fuzz() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 7
	var samples: Array[Dictionary] = _samples()
	var survived: int = 0
	for i in range(4000):
		var bytes: PackedByteArray
		if i % 2 == 0:
			bytes = crypto.generate_random_bytes(rng.randi_range(1, 120))
			bytes[0] = rng.randi_range(1, 15)
		else:
			bytes = NetProtocol.encode(samples[i % samples.size()])
			for k in range(rng.randi_range(1, 3)):
				bytes[rng.randi_range(0, bytes.size() - 1)] = rng.randi_range(0, 255)
		var m: Dictionary = NetProtocol.decode(bytes)
		if not m.is_empty():
			survived += 1
			# Whatever passes must be internally consistent: re-encoding works.
			NetProtocol.encode(m)
	check(true, "4000 random and damaged packets decoded without a crash (%d passed the checks)" % survived)


# --- Snapshot smoothing --------------------------------------------------------

func _test_snapshot_buffer() -> void:
	var buffer: SnapshotBuffer = SnapshotBuffer.new()
	var speed: float = 150.0
	var tick: int = 0
	var worst: float = 0.0
	var lag_ok: bool = true
	for step in range(240):
		tick += 1
		if tick % 2 == 0:
			var s: Dictionary = _state(tick)
			s.position = Vector3(0, 900, -speed * tick / 60.0)
			s.direction = Vector3.FORWARD
			s.speed = speed
			s.orientation = Quaternion.IDENTITY
			buffer.push(s)
		var out: Dictionary = buffer.sample(1.0 / 60.0)
		if step > 60:
			var truth: float = -speed * (tick / 60.0 - SnapshotBuffer.DELAY)
			worst = maxf(worst, absf((out.position as Vector3).z - truth))
			lag_ok = lag_ok and (out.position as Vector3).z > -speed * tick / 60.0
	check(worst < 3.0, "a remote aircraft is drawn smoothly %.0f ms behind (worst error %.2f m)" % [SnapshotBuffer.DELAY * 1000.0, worst])
	check(lag_ok, "it is drawn behind its newest report, never ahead")
	# Reports stop: it carries on briefly, then holds.
	var last_z: float = 0.0
	for i in range(60):
		last_z = (buffer.sample(1.0 / 60.0).position as Vector3).z
	var newest: float = -speed * tick / 60.0
	check(last_z >= newest - speed * SnapshotBuffer.MAX_EXTRAPOLATE - 0.5, "without reports it extrapolates at most %.0f ms, then holds" % (SnapshotBuffer.MAX_EXTRAPOLATE * 1000.0))
	var before: int = buffer.snaps.size()
	buffer.push(_state(10))
	check(buffer.snaps.size() == before, "a late, older report is ignored")
	_test_snapshot_under_loss()


## A turning aircraft reported over a poor connection: 30 % of reports lost,
## up to 60 ms of jitter so some arrive out of order. It must still be drawn
## close to where it really was 100 ms earlier, without jumps.
func _test_snapshot_under_loss() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 5
	var buffer: SnapshotBuffer = SnapshotBuffer.new()
	var speed: float = 150.0
	var radius: float = 900.0
	var in_flight: Array = []   # [arrival tick, report]
	var worst: float = 0.0
	var biggest_step: float = 0.0
	var last: Vector3 = Vector3.ZERO
	for tick in range(1, 60 * 20):
		if tick % 2 == 0 and rng.randf() > 0.3:
			var angle: float = speed * tick / 60.0 / radius
			var s: Dictionary = _state(tick)
			s.position = Vector3(radius * sin(angle), 900.0, -radius * cos(angle))
			s.direction = Vector3(cos(angle), 0.0, sin(angle))
			s.speed = speed
			in_flight.append([tick + 3 + rng.randi_range(0, 3), s])   # 50 ms latency plus up to 50 ms jitter
		for item: Array in in_flight.duplicate():
			if int(item[0]) <= tick:
				buffer.push(item[1])
				in_flight.erase(item)
		var out: Dictionary = buffer.sample(1.0 / 60.0)
		if out.is_empty():
			continue
		var p: Vector3 = out.position
		if tick > 120:
			# Where it was at the moment being drawn (its own clock minus the delay).
			var shown_at: float = buffer.play_time
			var a: float = speed * shown_at / radius
			worst = maxf(worst, p.distance_to(Vector3(radius * sin(a), 900.0, -radius * cos(a))))
			biggest_step = maxf(biggest_step, p.distance_to(last))
		last = p
	check(worst < 4.0, "with 30%% loss and jitter the drawn path stays within %.2f m of the true one" % worst)
	check(biggest_step < speed / 60.0 * 1.6, "and it moves without jumps (largest step %.2f m per frame at %.2f m nominal)" % [biggest_step, speed / 60.0])


# --- Referee -------------------------------------------------------------------

func _match(count: int = 2) -> Array:
	var everyone: Array[Combatant] = []
	var referee: MatchReferee = MatchReferee.new()
	referee.terrain = terrain
	var spots: Array[Dictionary] = referee.start_positions(count)
	for i in range(count):
		var c: Combatant = Combatant.new()
		c.setup(i, i, Airframes.Id.MUSTANG, i == 0)
		c.spawn(spots[i].position, spots[i].heading)
		everyone.append(c)
	referee.setup(terrain, everyone, 3, 11)
	for c in everyone:
		referee.placed(c, c.model.position)
	return [referee, everyone]


func _report(c: Combatant, tick: int, firing: bool = false) -> Dictionary:
	var s: Dictionary = SnapshotBuffer.capture(c.model, c.life, tick)
	if firing:
		s.flags = NetProtocol.FLAG_FIRING
	return s


func _test_referee_states() -> void:
	var setup: Array = _match()
	var referee: MatchReferee = setup[0]
	var a: Combatant = setup[1][0]
	var b: Combatant = setup[1][1]
	check(a.model.position.distance_to(b.model.position) > 1500.0 and a.model.position.y > terrain.surface_at(a.model.position.x, a.model.position.z) + 300.0,
		"players start kilometres apart, well above the ground")
	referee.tick(0.1)
	check(referee.accept_state(a, _report(a, 6)), "a first report near the start point is accepted")
	a.model.position += a.model.forward() * 5.0
	referee.tick(2.0 / 60.0)
	check(referee.accept_state(a, _report(a, 8)), "normal flight is accepted")
	a.model.position += Vector3(3000, 0, 0)
	referee.tick(2.0 / 60.0)
	check(not referee.accept_state(a, _report(a, 10)), "a teleport is refused")
	a.model.position -= Vector3(3000, 0, 0)
	var fast: Dictionary = _report(a, 12)
	fast.speed = 400.0
	check(not referee.accept_state(a, fast), "an impossible speed is refused")
	var outside: Dictionary = _report(a, 12)
	outside.position = Vector3(terrain.size, 900, 0)
	check(not referee.accept_state(a, outside), "a position outside the map is refused")
	var old_life: Dictionary = _report(a, 14)
	old_life.life = a.life + 1
	var strikes_before: float = float(referee.tracks[a.id].strikes)
	check(not referee.accept_state(a, old_life) and float(referee.tracks[a.id].strikes) == strikes_before, "a report from another life is ignored without a strike")
	var ahead: Dictionary = _report(a, 14 + 60 * 5)
	check(not referee.accept_state(a, ahead), "a clock running far ahead of real time is refused")
	for i in range(60):
		referee.accept_state(a, outside)
	check(referee.strikes_exceeded(a), "repeated impossible reports mark the player for removal")


func _test_referee_hits() -> void:
	var setup: Array = _match()
	var referee: MatchReferee = setup[0]
	var a: Combatant = setup[1][0]
	var b: Combatant = setup[1][1]
	# Bring b within gun range of a.
	b.spawn(a.model.position + a.model.forward() * 300.0, 0.0)
	referee.placed(b, b.model.position)
	referee.tick(1.0)
	var claim: Array = [{"target": b.id, "life": b.life, "zone": Airframes.Zone.BODY, "rounds": 3}]
	check(referee.claim_hits(a, claim).is_empty(), "hits are refused while the shooter's trigger was not seen")
	referee.accept_state(a, _report(a, 60, true))
	referee.accept_state(b, _report(b, 60))
	var events: Array[Dictionary] = referee.claim_hits(a, claim)
	var damage: float = float(Airframes.spec(Airframes.Id.MUSTANG).gun_damage) * 3.0
	check(events.size() == 1 and int(events[0].type) == NetProtocol.Msg.DAMAGE and is_equal_approx(float(events[0].hull), float(b.model.spec.hull) - damage),
		"valid hits cost the host's own damage figure (%.0f for 3 rounds)" % damage)
	var greedy: Array = [{"target": b.id, "life": b.life, "zone": Airframes.Zone.BODY, "rounds": 40}]
	var hull_before: float = b.model.hull
	referee.claim_hits(a, greedy)
	var allowed: float = float(Airframes.spec(Airframes.Id.MUSTANG).fire_rate)
	check(hull_before - b.model.hull <= damage / 3.0 * allowed + 0.01, "claims beyond the gun's rate of fire are cut down")
	var stale: Array = [{"target": b.id, "life": b.life + 1, "zone": 0, "rounds": 1}]
	referee.tick(1.0)
	referee.accept_state(a, _report(a, 120, true))
	check(referee.claim_hits(a, stale).is_empty(), "a hit on a previous life is ignored")
	var self_hit: Array = [{"target": a.id, "life": a.life, "zone": 0, "rounds": 1}]
	check(referee.claim_hits(a, self_hit).is_empty(), "a player cannot hit themself")
	# Out of range.
	b.model.position = a.model.position + Vector3(0, 0, 3000)
	referee.placed(b, b.model.position)
	check(referee.claim_hits(a, [{"target": b.id, "life": b.life, "zone": 0, "rounds": 1}]).is_empty(), "hits beyond gun range are refused")


func _test_referee_respawn_and_end() -> void:
	var setup: Array = _match()
	var referee: MatchReferee = setup[0]
	var a: Combatant = setup[1][0]
	var b: Combatant = setup[1][1]
	var kills: int = 0
	var ended: Dictionary = {}
	var spawned: Dictionary = {}
	var tick: int = 0
	for round in range(3):
		b.spawn(a.model.position + a.model.forward() * 250.0, 0.0)
		referee.placed(b, b.model.position)
		for i in range(200):
			referee.tick(1.0 / 60.0)
			tick += 1
			referee.accept_state(a, _report(a, tick, true))
			for e in referee.claim_hits(a, [{"target": b.id, "life": b.life, "zone": 1, "rounds": 1}]):
				if int(e.type) == NetProtocol.Msg.DESTROYED:
					kills += 1
				elif int(e.type) == NetProtocol.Msg.MATCH_END:
					ended = e
			if not b.model.alive:
				break
		var waited: float = 0.0
		while ended.is_empty() and spawned.is_empty() and waited < 10.0:
			for e in referee.tick(0.1):
				if int(e.type) == NetProtocol.Msg.SPAWN:
					spawned = e
			waited += 0.1
		if round == 0:
			check(not spawned.is_empty() and absf(waited - MatchReferee.RESPAWN_DELAY) < 0.25 and int(spawned.life) == 1,
				"a destroyed aircraft respawns after %.0f s with a new life" % MatchReferee.RESPAWN_DELAY)
		if not spawned.is_empty():
			b.life = int(spawned.life)
			b.spawn(spawned.position, float(spawned.heading))
			spawned = {}
	check(kills == 3 and a.kills == 3 and b.losses == 3, "kills and losses are counted (%d kills)" % kills)
	check(not ended.is_empty() and int(ended.winner) == a.id and not referee.running, "the first to the score limit wins and the match stops")
	check(referee.claim_hits(a, [{"target": b.id, "life": b.life, "zone": 1, "rounds": 1}]).is_empty(), "no damage after the match has ended")
	# Crashes and departures.
	var other: Array = _match()
	var r2: MatchReferee = other[0]
	var c0: Combatant = other[1][0]
	c0.model.alive = false   # its own flight model saw the ground
	var crash: Array[Dictionary] = r2.crashed(c0, c0.life)
	check(crash.size() == 1 and int(crash[0].by) == NetProtocol.NO_ONE and c0.losses == 1, "a crash counts as a loss with no one credited")
	check(r2.crashed(c0, c0.life).is_empty(), "a repeated crash report is ignored")
	var gone: Array[Dictionary] = r2.remove(other[1][1])
	check(gone.size() == 2 and int(gone[0].type) == NetProtocol.Msg.LEFT and int(gone[1].type) == NetProtocol.Msg.MATCH_END,
		"when only one player is left, the match ends")


func _test_address_warning() -> void:
	check(NetSession.address_warning("100.72.1.9", "") != "", "a router address in 100.64.0.0/10 warns of carrier-grade NAT")
	check(NetSession.address_warning("198.51.100.7", "203.0.113.9") != "", "a router address different from the public one warns")
	check(NetSession.address_warning("192.168.1.20", "") != "", "a private router address warns of a second router")
	check(NetSession.address_warning("198.51.100.7", "198.51.100.7") == "" and NetSession.address_warning("", "") == "", "a normal connection gives no warning")


## No script defines remote-callable methods, and object decoding is off.
func _test_no_remote_calls() -> void:
	var found: PackedStringArray = PackedStringArray()
	for dir: String in ["res://scripts", "res://scripts/net", "res://scripts/ui", "res://scripts/combat", "res://scripts/aircraft",
			"res://scripts/world", "res://scripts/core", "res://scripts/input", "res://scripts/camera"]:
		for file in DirAccess.get_files_at(dir):
			if file.ends_with(".gd"):
				var text: String = FileAccess.get_file_as_string(dir + "/" + file)
				if text.contains("@" + "rpc") or text.contains(".rpc(") or text.contains("rpc_id("):
					found.append(file)
	check(found.is_empty(), "no script contains remote procedure calls %s" % str(found))
	var session: NetSession = NetSession.new()
	session.host(PORT + 40, "T", 0, "alpine")
	check(not session.mp.allow_object_decoding and not session.mp.server_relay, "object decoding and peer relaying are off")
	session.close()
	session.free()


# --- Live connections over loopback --------------------------------------------

func _pump(sessions: Array, seconds: float, until: Callable = Callable()) -> bool:
	var end: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		for s in sessions:
			if is_instance_valid(s) and s.mp != null and s.mp.multiplayer_peer != null:
				s._physics_process(0.016)
		if until.is_valid() and until.call():
			return true
		OS.delay_msec(4)
	return false


func _host(port: int) -> NetSession:
	var h: NetSession = NetSession.new()
	var err: Error = h.host(port, "Host", Airframes.Id.MUSTANG, "alpine")
	h.set_address("127.0.0.1")
	if err != OK:
		print("       host failed: ", h.status)
	return h


func _client(invite: Invite, player_name: String = "Ana") -> NetSession:
	var c: NetSession = NetSession.new()
	c.join(invite, player_name, Airframes.Id.SPITFIRE)
	return c


func _ended(s: NetSession) -> bool:
	return s.role == NetSession.Role.NONE


func _test_connect_and_talk() -> void:
	var host: NetSession = _host(PORT)
	var invite: Invite = Invite.decode(host.invite_text())
	var client: NetSession = _client(invite)
	var host_got: Array = []
	var client_got: Array = []
	var welcomed: Array = []
	host.message.connect(func(peer: int, m: Dictionary) -> void: host_got.append([peer, m]))
	client.message.connect(func(peer: int, m: Dictionary) -> void: client_got.append([peer, m]))
	client.welcomed.connect(func(map_id: String, _in: bool) -> void: welcomed.append(map_id))
	var joined: bool = _pump([host, client], 6.0, func() -> bool: return host.players.size() == 2 and client.players.size() == 2)
	check(joined, "a joiner with the right invite reaches the lobby")
	check(welcomed == ["alpine"], "the joiner learns the host's map")
	check(joined and String(host.players[1].name) == "Ana" and int(host.players[1].frame) == Airframes.Id.SPITFIRE, "the host sees the joiner's name and aircraft")
	check(host.reached_from_outside, "the host records that someone reached it")
	client.send(1, {"type": NetProtocol.Msg.STATE, "state": _state()})
	host.broadcast({"type": NetProtocol.Msg.LEFT, "id": 1})
	_pump([host, client], 2.0, func() -> bool: return not host_got.is_empty() and not client_got.is_empty())
	check(host_got.size() == 1 and int(host_got[0][1].type) == NetProtocol.Msg.STATE and int(host_got[0][0]) == client.my_id(), "the host receives the joiner's motion report")
	check(client_got.size() == 1 and int(client_got[0][1].type) == NetProtocol.Msg.LEFT, "the joiner receives the host's messages")
	# Direction rules: a joiner cannot send host messages.
	host_got.clear()
	client._send_raw(1, {"type": NetProtocol.Msg.DAMAGE, "target": 0, "shooter": 1, "zone": 0, "hull": 1.0, "zones": PackedFloat32Array([0, 0, 0, 0, 0])})
	_pump([host, client], 0.6)
	check(host_got.is_empty(), "a joiner's attempt to send a host-only message is dropped")
	# Kick.
	var reason: Array = []
	client.ended.connect(func(r: String) -> void: reason.append(r))
	host.kick(client.my_id())
	_pump([host, client], 4.0, func() -> bool: return _ended(client) and host.players.size() == 1)
	check(_ended(client) and host.players.size() == 1 and not reason.is_empty() and String(reason[0]).contains("removed"),
		"Kick removes the joiner and tells them why")
	# A new invite stops the old one working.
	var old_invite: Invite = invite
	host.new_invite()
	var late: NetSession = _client(old_invite, "Late")
	_pump([host, late], 3.0, func() -> bool: return _ended(late))
	check(_ended(late) and host.players.size() == 1, "after New invite, the old invite no longer works")
	host.close()
	_pump([host], 0.2)
	var probe: PacketPeerUDP = PacketPeerUDP.new()
	check(probe.bind(PORT) == OK, "after hosting stops, nothing listens on the port")
	probe.close()


func _other_cert_invite(real: Invite) -> Invite:
	var fake: Invite = Invite.new()
	fake.address = real.address
	fake.port = real.port
	fake.secret = real.secret
	fake.certificate_der = _cert_der()
	return fake


func _test_wrong_certificate() -> void:
	var host: NetSession = _host(PORT + 1)
	var real: Invite = Invite.decode(host.invite_text())
	var auth_seen: Array = []
	host.mp.peer_authenticating.connect(func(id: int) -> void: auth_seen.append(id))
	var client: NetSession = _client(_other_cert_invite(real))
	_pump([host, client], 4.0, func() -> bool: return _ended(client))
	check(_ended(client), "a joiner expecting a different certificate refuses the host")
	check(auth_seen.is_empty() and host.failures_from("127.0.0.1") == 0 and host.players.size() == 1,
		"it gives up during the handshake, before any secret is sent")
	host.close()


func _test_wrong_and_missing_secret() -> void:
	var host: NetSession = _host(PORT + 2)
	host.mp.auth_timeout = 1.0
	var real: Invite = Invite.decode(host.invite_text())
	var connected: Array = []
	host.mp.peer_connected.connect(func(id: int) -> void: connected.append(id))
	var wrong: Invite = Invite.decode(host.invite_text())
	wrong.secret = crypto.generate_random_bytes(16)
	var client: NetSession = _client(wrong)
	_pump([host, client], 4.0, func() -> bool: return _ended(client))
	check(_ended(client) and connected.is_empty() and host.players.size() == 1, "a joiner with the wrong secret is dropped and never connected")
	check(host.failures_from("127.0.0.1") == 1, "the failed attempt is counted")
	# A client that completes DTLS but never sends a secret.
	var silent: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	silent.create_client("127.0.0.1", real.port)
	silent.host.dtls_client_setup(NetSession.CERT_NAME, TLSOptions.client(real.certificate()))
	var mp: SceneMultiplayer = SceneMultiplayer.new()
	mp.auth_callback = func(_id: int, _d: PackedByteArray) -> void: pass
	mp.multiplayer_peer = silent
	var dropped: Array = []
	mp.server_disconnected.connect(func() -> void: dropped.append(1))
	mp.peer_authentication_failed.connect(func(_id: int) -> void: dropped.append(2))
	var end: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < end and dropped.is_empty():
		host._physics_process(0.016)
		mp.poll()
		OS.delay_msec(4)
	check(not dropped.is_empty() and connected.is_empty() and host.failures_from("127.0.0.1") == 2, "a joiner that sends no secret is dropped at the timeout")
	silent.close()
	host.close()


func _test_blocking() -> void:
	var host: NetSession = _host(PORT + 3)
	var real: Invite = Invite.decode(host.invite_text())
	for i in range(NetSession.BLOCK_AFTER):
		var wrong: Invite = Invite.decode(host.invite_text())
		wrong.secret = crypto.generate_random_bytes(16)
		var c: NetSession = _client(wrong)
		_pump([host, c], 4.0, func() -> bool: return _ended(c))
	check(host.is_blocked("127.0.0.1"), "%d failed attempts block the address" % NetSession.BLOCK_AFTER)
	var good: NetSession = _client(real)
	_pump([host, good], 4.0, func() -> bool: return _ended(good) or host.players.size() == 2)
	check(_ended(good) and host.players.size() == 1, "a blocked address is refused even with the right invite")
	host._clock += NetSession.BLOCK_SECONDS + 1.0
	var later: NetSession = _client(real)
	_pump([host, later], 5.0, func() -> bool: return host.players.size() == 2)
	check(host.players.size() == 2, "the block expires after %d minutes" % int(NetSession.BLOCK_SECONDS / 60.0))
	later.close()
	host.close()


func _test_unencrypted_client() -> void:
	var host: NetSession = _host(PORT + 4)
	var plain: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	plain.create_client("127.0.0.1", PORT + 4)
	var end: int = Time.get_ticks_msec() + 2500
	var connected: bool = false
	while Time.get_ticks_msec() < end:
		host._physics_process(0.016)
		plain.poll()
		if plain.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			connected = true
			break
		OS.delay_msec(4)
	check(not connected and host.players.size() == 1, "an unencrypted ENet client cannot connect")
	plain.close()
	host.close()


func _test_bad_packets() -> void:
	var host: NetSession = _host(PORT + 5)
	var client: NetSession = _client(Invite.decode(host.invite_text()))
	_pump([host, client], 6.0, func() -> bool: return host.players.size() == 2)
	var got: Array = []
	host.message.connect(func(_p: int, m: Dictionary) -> void: got.append(m))
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 3
	for i in range(NetSession.BAD_PACKET_LIMIT + 5):
		var junk: PackedByteArray = crypto.generate_random_bytes(rng.randi_range(2, 80))
		junk[0] = NetProtocol.Msg.STATE
		client.mp.send_bytes(junk, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	_pump([host, client], 4.0, func() -> bool: return _ended(client))
	check(got.is_empty(), "malformed packets never reach the game")
	check(_ended(client) and host.players.size() == 1, "a joiner that keeps sending malformed packets is disconnected")
	host.close()


func _test_version_mismatch() -> void:
	var host: NetSession = _host(PORT + 6)
	var invite: Invite = Invite.decode(host.invite_text())
	var client: NetSession = NetSession.new()
	client.join(invite, "Old", 0)
	# Pretend to be an older build: replace the HELLO the session sends.
	client.mp.connected_to_server.disconnect(client._on_connected_to_server)
	client.mp.connected_to_server.connect(func() -> void:
		client._send_raw(1, {"type": NetProtocol.Msg.HELLO, "version": NetProtocol.VERSION + 1, "frame": 0, "name": "Old"}))
	var reason: Array = []
	client.ended.connect(func(r: String) -> void: reason.append(r))
	_pump([host, client], 5.0, func() -> bool: return _ended(client))
	check(_ended(client) and not reason.is_empty() and String(reason[0]).contains("version") and host.players.size() == 1,
		"a different game version is refused with a clear message")
	host.close()


func _test_host_stop_reason() -> void:
	var host: NetSession = _host(PORT + 7)
	var client: NetSession = _client(Invite.decode(host.invite_text()))
	_pump([host, client], 6.0, func() -> bool: return host.players.size() == 2)
	var reason: Array = []
	client.ended.connect(func(r: String) -> void: reason.append(r))
	# The joiner is another machine: it keeps polling while the host stops.
	var worker: Thread = Thread.new()
	worker.start(func() -> void: _pump([client], 3.0, func() -> bool: return _ended(client)))
	OS.delay_msec(30)
	host.close()
	worker.wait_to_finish()
	check(_ended(client) and reason == ["The host stopped the match."], "when the host stops, joiners are told so (%s)" % str(reason))
