class_name NetProtocol
extends RefCounted
## Every network message as a small typed byte packet. `encode` turns a message
## Dictionary into bytes and `decode` turns bytes back, checking the type, the
## exact length and every value first; anything malformed decodes to {}. This is
## the only code that reads bytes from another machine.

const VERSION: int = 3   ## 2: chat, 3: brake flag
const MAX_PLAYERS: int = 4
const NAME_MAX: int = 16
const REASON_MAX: int = 120
const MAP_MAX: int = 32
const CHAT_MAX: int = 80             ## characters in one chat message
const MAX_CLAIMS: int = 8
const MAX_ROUNDS_PER_CLAIM: int = 40
const ZONES: int = 5
const NO_ONE: int = 255

enum Msg { HELLO = 1, WELCOME, REJECT, ROSTER, MATCH_START, STATE, WORLD, HIT_CLAIM, DAMAGE, CRASHED, DESTROYED, SPAWN, MATCH_END, LOBBY, LEFT, CHAT }

## What a joiner may send. Everything else only the host may send.
const FROM_CLIENT: Array[int] = [Msg.HELLO, Msg.STATE, Msg.HIT_CLAIM, Msg.CRASHED, Msg.CHAT]
## Messages that are sent unreliably (a newer one replaces a lost one).
const UNRELIABLE: Array[int] = [Msg.STATE, Msg.WORLD]

const FLAG_BOOSTING: int = 1
const FLAG_FIRING: int = 2
const FLAG_BRAKING: int = 4


static func encode(m: Dictionary) -> PackedByteArray:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	var type: int = int(m.type)
	w.put_u8(type)
	match type:
		Msg.HELLO:
			w.put_u16(int(m.version))
			w.put_u8(int(m.frame))
			_put_text(w, String(m.name), NAME_MAX)
		Msg.WELCOME:
			_put_text(w, String(m.map), MAP_MAX)
			w.put_u8(int(m.max_players))
			w.put_u8(1 if bool(m.in_match) else 0)
		Msg.REJECT:
			_put_text(w, String(m.reason), REASON_MAX)
		Msg.ROSTER:
			var players: Array = m.players
			w.put_u8(players.size())
			for p: Dictionary in players:
				w.put_u32(int(p.peer))
				w.put_u8(int(p.frame))
				_put_text(w, String(p.name), NAME_MAX)
		Msg.MATCH_START:
			w.put_u8(int(m.score_limit))
			var entries: Array = m.entries
			w.put_u8(entries.size())
			for e: Dictionary in entries:
				w.put_u8(int(e.id))
				w.put_u32(int(e.peer))
				w.put_u8(int(e.team))
				w.put_u8(int(e.frame))
				_put_text(w, String(e.name), NAME_MAX)
				_put_vec3(w, e.position)
				w.put_float(float(e.heading))
		Msg.STATE:
			_put_state(w, m.state)
		Msg.WORLD:
			var states: Array = m.states
			w.put_u8(states.size())
			for s: Dictionary in states:
				w.put_u8(int(s.id))
				_put_state(w, s)
		Msg.HIT_CLAIM:
			var claims: Array = m.claims
			w.put_u8(claims.size())
			for c: Dictionary in claims:
				w.put_u8(int(c.target))
				w.put_u8(int(c.life) & 255)
				w.put_u8(int(c.zone))
				w.put_u8(int(c.rounds))
		Msg.DAMAGE:
			w.put_u8(int(m.target))
			w.put_u8(int(m.shooter))
			w.put_u8(int(m.zone))
			w.put_float(float(m.hull))
			var zones: PackedFloat32Array = m.zones
			for k in range(ZONES):
				w.put_u8(int(round(clampf(zones[k], 0.0, 1.0) * 255.0)))
		Msg.CRASHED:
			w.put_u8(int(m.life) & 255)
		Msg.DESTROYED:
			w.put_u8(int(m.target))
			w.put_u8(int(m.by))
			w.put_u16(int(m.losses))
			w.put_u16(int(m.kills))
		Msg.SPAWN:
			w.put_u8(int(m.id))
			w.put_u8(int(m.life) & 255)
			_put_vec3(w, m.position)
			w.put_float(float(m.heading))
		Msg.MATCH_END:
			w.put_u8(int(m.winner))
			var scores: Array = m.scores
			w.put_u8(scores.size())
			for s: Dictionary in scores:
				w.put_u8(int(s.id))
				w.put_u16(int(s.kills))
				w.put_u16(int(s.losses))
		Msg.LOBBY:
			pass
		Msg.LEFT:
			w.put_u8(int(m.id))
		Msg.CHAT:
			# A joiner sends peer 0 and no name; the host fills both in when relaying.
			w.put_u32(int(m.get("peer", 0)))
			_put_text(w, String(m.get("name", "")), NAME_MAX)
			_put_text(w, String(m.text), CHAT_MAX)
		_:
			push_error("NetProtocol: unknown message type %d" % type)
			return PackedByteArray()
	return w.data_array


static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty() or bytes.size() > 1200:
		return {}
	var r: Reader = Reader.new(bytes)
	var type: int = r.u8()
	var m: Dictionary = {"type": type}
	match type:
		Msg.HELLO:
			m.version = r.u16()
			m.frame = r.u8()
			m.name = r.text(NAME_MAX)
			r.require(int(m.frame) < Airframes.COUNT)
		Msg.WELCOME:
			m.map = r.text(MAP_MAX)
			m.max_players = r.u8()
			m.in_match = r.u8() != 0
			r.require(int(m.max_players) >= 2 and int(m.max_players) <= MAX_PLAYERS)
		Msg.REJECT:
			m.reason = r.text(REASON_MAX)
		Msg.ROSTER:
			var n: int = r.u8()
			r.require(n >= 1 and n <= MAX_PLAYERS)
			var players: Array[Dictionary] = []
			for i in range(n if r.ok else 0):
				var p: Dictionary = {"peer": r.u32(), "frame": r.u8(), "name": r.text(NAME_MAX)}
				r.require(int(p.peer) >= 1 and int(p.frame) < Airframes.COUNT)
				players.append(p)
			m.players = players
		Msg.MATCH_START:
			m.score_limit = r.u8()
			var n: int = r.u8()
			r.require(int(m.score_limit) >= 1 and n >= 2 and n <= MAX_PLAYERS)
			var entries: Array[Dictionary] = []
			for i in range(n if r.ok else 0):
				var e: Dictionary = {"id": r.u8(), "peer": r.u32(), "team": r.u8(), "frame": r.u8(), "name": r.text(NAME_MAX),
					"position": r.vec3(), "heading": r.f32()}
				r.require(int(e.id) == i and int(e.team) < MAX_PLAYERS and int(e.frame) < Airframes.COUNT and int(e.peer) >= 1)
				entries.append(e)
			m.entries = entries
		Msg.STATE:
			m.state = _get_state(r)
		Msg.WORLD:
			var n: int = r.u8()
			r.require(n <= MAX_PLAYERS)
			var states: Array[Dictionary] = []
			for i in range(n if r.ok else 0):
				var id: int = r.u8()
				var s: Dictionary = _get_state(r)
				s.id = id
				r.require(id < MAX_PLAYERS)
				states.append(s)
			m.states = states
		Msg.HIT_CLAIM:
			var n: int = r.u8()
			r.require(n >= 1 and n <= MAX_CLAIMS)
			var claims: Array[Dictionary] = []
			for i in range(n if r.ok else 0):
				var c: Dictionary = {"target": r.u8(), "life": r.u8(), "zone": r.u8(), "rounds": r.u8()}
				r.require(int(c.target) < MAX_PLAYERS and int(c.zone) < ZONES and int(c.rounds) >= 1 and int(c.rounds) <= MAX_ROUNDS_PER_CLAIM)
				claims.append(c)
			m.claims = claims
		Msg.DAMAGE:
			m.target = r.u8()
			m.shooter = r.u8()
			m.zone = r.u8()
			m.hull = r.f32()
			var zones: PackedFloat32Array = PackedFloat32Array()
			for k in range(ZONES):
				zones.append(r.u8() / 255.0)
			m.zones = zones
			r.require(int(m.target) < MAX_PLAYERS and int(m.shooter) < MAX_PLAYERS and int(m.zone) < ZONES and float(m.hull) >= 0.0 and float(m.hull) < 1000.0)
		Msg.CRASHED:
			m.life = r.u8()
		Msg.DESTROYED:
			m.target = r.u8()
			m.by = r.u8()
			m.losses = r.u16()
			m.kills = r.u16()
			r.require(int(m.target) < MAX_PLAYERS and (int(m.by) < MAX_PLAYERS or int(m.by) == NO_ONE))
		Msg.SPAWN:
			m.id = r.u8()
			m.life = r.u8()
			m.position = r.vec3()
			m.heading = r.f32()
			r.require(int(m.id) < MAX_PLAYERS)
		Msg.MATCH_END:
			m.winner = r.u8()
			var n: int = r.u8()
			r.require(n <= MAX_PLAYERS and (int(m.winner) < MAX_PLAYERS or int(m.winner) == NO_ONE))
			var scores: Array[Dictionary] = []
			for i in range(n if r.ok else 0):
				var s: Dictionary = {"id": r.u8(), "kills": r.u16(), "losses": r.u16()}
				r.require(int(s.id) < MAX_PLAYERS)
				scores.append(s)
			m.scores = scores
		Msg.LOBBY:
			pass
		Msg.LEFT:
			m.id = r.u8()
			r.require(int(m.id) < MAX_PLAYERS)
		Msg.CHAT:
			m.peer = r.u32()
			m.name = r.text(NAME_MAX)
			m.text = r.text(CHAT_MAX)
			r.require(String(m.text) != "")
		_:
			return {}
	if not r.ok or not r.at_end():
		return {}
	return m


## One aircraft's motion as its owner reports it. About 50 bytes.
static func _put_state(w: StreamPeerBuffer, s: Dictionary) -> void:
	w.put_u8(int(s.life) & 255)
	w.put_u32(int(s.tick))
	_put_vec3(w, s.position)
	var q: Quaternion = s.orientation
	w.put_float(q.x)
	w.put_float(q.y)
	w.put_float(q.z)
	w.put_float(q.w)
	_put_vec3(w, s.direction)
	w.put_float(float(s.speed))
	w.put_u8(int(round(clampf(float(s.throttle), 0.0, 1.0) * 255.0)))
	var c: Vector3 = s.controls
	for v: float in [c.x, c.y, c.z]:
		w.put_8(int(round(clampf(v, -1.0, 1.0) * 127.0)))
	w.put_u8(int(s.flags))


static func _get_state(r: Reader) -> Dictionary:
	var s: Dictionary = {"life": r.u8(), "tick": r.u32(), "position": r.vec3()}
	var q: Quaternion = Quaternion(r.f32(), r.f32(), r.f32(), r.f32())
	var d: Vector3 = r.vec3()
	s.speed = r.f32()
	s.throttle = r.u8() / 255.0
	s.controls = Vector3(r.s8(), r.s8(), r.s8()) / 127.0
	s.flags = r.u8()
	r.require(absf(q.length() - 1.0) < 0.05 and absf(d.length() - 1.0) < 0.05 and float(s.speed) >= 0.0 and int(s.flags) < 8)
	s.orientation = q.normalized() if r.ok else Quaternion.IDENTITY
	s.direction = d.normalized() if r.ok else Vector3.FORWARD
	return s


static func _put_vec3(w: StreamPeerBuffer, v: Vector3) -> void:
	w.put_float(v.x)
	w.put_float(v.y)
	w.put_float(v.z)


static func _put_text(w: StreamPeerBuffer, text: String, limit: int) -> void:
	var clean: String = clean_text(text, limit)
	var bytes: PackedByteArray = clean.to_utf8_buffer()
	while bytes.size() > 255:   # the length is one byte: drop whole characters until it fits
		clean = clean.left(-1)
		bytes = clean.to_utf8_buffer()
	w.put_u8(bytes.size())
	w.put_data(bytes)


## A name or message safe to show: printable characters only, trimmed, short.
static func clean_text(text: String, limit: int) -> String:
	var out: String = ""
	for i in range(text.length()):
		var code: int = text.unicode_at(i)
		if code >= 32 and code != 127 and not (code >= 0x80 and code < 0xA0) and not (code >= 0x200B and code <= 0x206F):
			out += text[i]
	out = out.strip_edges()
	return out.substr(0, limit)


## Bounds-checked reading. Any short read or bad value clears `ok` and later
## reads return zeros, so a decoder never indexes past the packet.
class Reader:
	var data: PackedByteArray
	var at: int = 0
	var ok: bool = true

	func _init(bytes: PackedByteArray) -> void:
		data = bytes

	func _have(n: int) -> bool:
		if not ok or at + n > data.size():
			ok = false
			return false
		return true

	func require(condition: bool) -> void:
		ok = ok and condition

	func at_end() -> bool:
		return at == data.size()

	func u8() -> int:
		if not _have(1):
			return 0
		at += 1
		return data[at - 1]

	func s8() -> int:
		var v: int = u8()
		return v - 256 if v > 127 else v

	func u16() -> int:
		if not _have(2):
			return 0
		at += 2
		return data.decode_u16(at - 2)

	func u32() -> int:
		if not _have(4):
			return 0
		at += 4
		return data.decode_u32(at - 4)

	func f32() -> float:
		if not _have(4):
			return 0.0
		at += 4
		var v: float = data.decode_float(at - 4)
		if is_nan(v) or is_inf(v) or absf(v) > 1.0e6:
			ok = false
			return 0.0
		return v

	func vec3() -> Vector3:
		return Vector3(f32(), f32(), f32())

	func text(limit: int) -> String:
		var n: int = u8()
		if n > limit * 4 or not _have(n):
			ok = false
			return ""
		var raw: PackedByteArray = data.slice(at, at + n)
		at += n
		if not NetProtocol.valid_utf8(raw):
			ok = false
			return ""
		return NetProtocol.clean_text(raw.get_string_from_utf8(), limit)


## Well-formed UTF-8 without NUL, so bad bytes are refused quietly instead of
## making the engine log decoding errors.
static func valid_utf8(bytes: PackedByteArray) -> bool:
	var i: int = 0
	var n: int = bytes.size()
	while i < n:
		var b: int = bytes[i]
		var extra: int = 0
		var lowest: int = 0
		if b == 0:
			return false   # NUL: never part of a name, and the engine logs it as an error
		if b < 0x80:
			i += 1
			continue
		elif b >= 0xC2 and b <= 0xDF:
			extra = 1
			lowest = 0x80
		elif b >= 0xE0 and b <= 0xEF:
			extra = 2
			lowest = 0x800
		elif b >= 0xF0 and b <= 0xF4:
			extra = 3
			lowest = 0x10000
		else:
			return false
		if i + extra >= n:
			return false
		var code: int = b & (0x1F if extra == 1 else (0x0F if extra == 2 else 0x07))
		for k in range(1, extra + 1):
			var c: int = bytes[i + k]
			if (c & 0xC0) != 0x80:
				return false
			code = (code << 6) | (c & 0x3F)
		if code < lowest or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF):
			return false
		i += extra + 1
	return true
