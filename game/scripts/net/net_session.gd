class_name NetSession
extends Node
## One hosted or joined network match: transport, encryption, the invite secret
## check, the lobby roster and message passing. See docs/multiplayer-design.md.
##
## ENet over DTLS. The invite carries a hash of the host's certificate, not the
## certificate, so a joiner connects twice:
##
## 1. Fetch. It connects without checking who answered, sends one byte asking
##    for the certificate and nothing else, and accepts the answer only if its
##    size and hash match the invite. The bytes are parsed after that, not before.
## 2. Join. It reconnects trusting exactly that certificate, so it cannot be
##    fooled by a fake host, and only then sends the invite's secret.
##
## The host holds every new connection in Godot's authentication phase, where
## it cannot reach game code, until it has sent the secret. Wrong or missing
## secrets are dropped and repeated failures from one address block it for a
## while, as do repeated certificate requests that never lead to a join.
##
## The session lives under the scene tree root, so it survives the scene reload
## a joiner does to load the host's map. `NetSession.current` finds it.

signal changed                                   ## roster, status or invite changed
signal message(peer: int, msg: Dictionary)       ## a game message passed every check
signal welcomed(map_id: String, in_match: bool)  ## joiner: the host accepted us
signal player_left(peer: int)
signal ended(reason: String)                     ## the session is over
signal chat_received(line: Dictionary)           ## a chat line everyone in the session sees

enum Role { NONE, HOST, CLIENT }

const DEFAULT_PORT: int = 24555
const CERT_NAME: String = "airflight-host"
const AUTH_TIMEOUT: float = 5.0
const HELLO_TIMEOUT: float = 5.0
const BLOCK_AFTER: int = 5
const FETCH_LIMIT: int = 10        ## certificate requests from one address without a join; one more blocks it
const CERT_REQUEST: int = 0x43     ## the one byte a joiner sends on its first, unverified connection
const BLOCK_SECONDS: float = 600.0
const BAD_PACKET_LIMIT: int = 25
const CHAT_KEEP: int = 20          ## chat lines remembered (the chat box shows the newest few)
const CHAT_BURST: int = 4          ## host: messages one joiner may send at once…
const CHAT_REFILL: float = 1.5     ## …then one more per this many seconds; extra ones are dropped

static var current: NetSession

var role: Role = Role.NONE
var mp: SceneMultiplayer
var enet: ENetMultiplayerPeer
var port: int = DEFAULT_PORT
var dedicated: bool = false
var max_players: int = NetProtocol.MAX_PLAYERS
var map_id: String = ""
var in_match: bool = false
var address: String = ""         ## host: the public address or name written into invites
var local_name: String = "Pilot"
var local_frame: int = Airframes.Id.MUSTANG
var players: Array[Dictionary] = []   ## lobby roster in join order: {peer, name, frame}
var status: String = ""
var reached_from_outside: bool = false
## Chat lines, oldest first: {peer, name, text, at} with `at` in Time.get_ticks_msec().
## Kept here so lines survive the scene reload a joiner does to load the host's map.
var chat_log: Array[Dictionary] = []
var port_mapper: PortMapper

var _key: CryptoKey
var _cert: X509Certificate
var _cert_der: PackedByteArray = PackedByteArray()   ## host: what joiners fetch and the invite's hash covers
var _secret: PackedByteArray = PackedByteArray()
var _join_invite: Invite
var _host_cert: X509Certificate       ## joiner: the host's certificate once it matched the invite
var _rejoin: bool = false             ## joiner: certificate checked, reconnect trusting it after this poll
var _refusal: String = ""             ## joiner: why the join ends after this poll
var _crypto: Crypto = Crypto.new()
var _auth_address: Dictionary = {}    ## peer -> address while authenticating
var _greeted: Dictionary = {}         ## peer -> true once its HELLO was accepted
var _hello_deadline: Dictionary = {}  ## peer -> seconds left to send HELLO
var _bad_packets: Dictionary = {}     ## peer -> count
var _failures: Dictionary = {}        ## address -> failed attempts
var _fetches: Dictionary = {}         ## address -> certificate requests not yet followed by a join
var _blocked: Dictionary = {}         ## address -> unblock time (s)
var _clock: float = 0.0
var _close_reason: String = ""
var _closing: bool = false
var _sandbox: Node
var _queue: Array = []
var _chat_allowance: Dictionary = {}  ## host: peer -> messages it may still send now


func _init() -> void:
	name = "NetSession"
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -100   # receive before the game simulates the tick


func _ready() -> void:
	# Lookups SceneMultiplayer might do for remote calls resolve inside an empty
	# node, never the game. The game defines no remote-callable methods anyway.
	_sandbox = Node.new()
	_sandbox.name = "Sandbox"
	add_child(_sandbox)
	if mp != null:
		mp.root_path = _sandbox.get_path()   # the actual path, should the name have changed


func _new_multiplayer() -> void:
	mp = SceneMultiplayer.new()
	mp.allow_object_decoding = false
	mp.server_relay = false
	mp.auth_timeout = AUTH_TIMEOUT
	mp.auth_callback = _on_auth_data
	# SceneMultiplayer will not poll without a root path. Point it at the empty
	# sandbox node (made in _ready); the path needs no node until a remote call.
	mp.root_path = _sandbox.get_path() if _sandbox != null and _sandbox.is_inside_tree() else NodePath("/root/NetSession/Sandbox")
	mp.peer_authenticating.connect(_on_peer_authenticating)
	mp.peer_authentication_failed.connect(_on_auth_failed)
	mp.peer_connected.connect(_on_peer_connected)
	mp.peer_disconnected.connect(_on_peer_disconnected)
	mp.peer_packet.connect(_on_packet)
	mp.connected_to_server.connect(_on_connected_to_server)
	mp.connection_failed.connect(_on_connection_failed)
	mp.server_disconnected.connect(_on_server_disconnected)


## Start a session and put it where it outlives scene reloads.
static func create(tree: SceneTree) -> NetSession:
	if current != null:
		current.close("")
	var session: NetSession = NetSession.new()
	current = session
	tree.root.add_child.call_deferred(session)
	return session


# --- Hosting -------------------------------------------------------------------

## Listen for joiners. A fresh key, certificate and secret are made every time;
## nothing is written to disk.
func host(listen_port: int, player_name: String, frame: int, map: String, is_dedicated: bool = false) -> Error:
	role = Role.HOST
	port = listen_port
	dedicated = is_dedicated
	map_id = map
	local_name = NetProtocol.clean_text(player_name, NetProtocol.NAME_MAX)
	if local_name == "":
		local_name = "Host"
	local_frame = frame
	_key = _crypto.generate_rsa(2048)
	_cert = _crypto.generate_self_signed_certificate(_key, "CN=%s,O=Airflight,C=XX" % CERT_NAME, "20250101000000", "20450101000000")
	_cert_der = Invite.pem_to_der(_cert.save_to_string())
	_secret = _crypto.generate_random_bytes(Invite.SECRET_BYTES)
	_new_multiplayer()
	enet = ENetMultiplayerPeer.new()
	var seats: int = max_players - (0 if dedicated else 1)
	var err: Error = enet.create_server(port, seats + 2)   # two spare slots for joiners being checked
	if err != OK:
		status = "Could not listen on UDP port %d. Is another copy of the game hosting?" % port
		role = Role.NONE
		return err
	err = enet.host.dtls_server_setup(TLSOptions.server(_key, _cert))
	if err != OK:
		enet.close()
		status = "Could not start encryption (error %d)." % err
		role = Role.NONE
		return err
	mp.multiplayer_peer = enet
	players.clear()
	if not dedicated:
		players.append({"peer": 1, "name": local_name, "frame": local_frame})
	status = "Hosting on UDP port %d." % port
	changed.emit()
	return OK


## The invite friends paste, or "" until the public address is known.
func invite_text() -> String:
	if role != Role.HOST or address == "":
		return ""
	var inv: Invite = Invite.new()
	inv.address = address
	inv.port = port
	inv.secret = _secret
	inv.certificate_hash = Invite.hash_of(_cert_der)
	return inv.encode()


## Replace the secret. Players already in stay; the old invite stops working.
func new_invite() -> void:
	_secret = _crypto.generate_random_bytes(Invite.SECRET_BYTES)
	changed.emit()


func set_address(text: String) -> void:
	address = text.strip_edges()
	changed.emit()


## Open the port on the router through UPnP (host's choice, off by default).
func set_auto_port(on: bool) -> void:
	if on and port_mapper == null:
		port_mapper = PortMapper.new()
		add_child(port_mapper)
		port_mapper.finished.connect(func(_ok: bool, _external: String, _text: String) -> void: changed.emit())
		port_mapper.open(port)
	elif not on and port_mapper != null:
		port_mapper.close()
		port_mapper.queue_free()
		port_mapper = null
	changed.emit()


func kick(peer: int, reason: String = "The host removed you from the match.") -> void:
	if role != Role.HOST or peer == 1:
		return
	_send_raw(peer, {"type": NetProtocol.Msg.REJECT, "reason": reason})
	var p: ENetPacketPeer = enet.get_peer(peer)
	if p != null:
		p.peer_disconnect_later()   # after the reason has been delivered


func rename_host(player_name: String) -> void:
	var clean: String = NetProtocol.clean_text(player_name, NetProtocol.NAME_MAX)
	if role != Role.HOST or dedicated or clean == "" or players.is_empty():
		return
	local_name = clean
	players[0].name = clean
	broadcast(_roster())
	changed.emit()


func set_in_match(on: bool) -> void:
	in_match = on
	changed.emit()


# --- Joining -------------------------------------------------------------------

func join(invite: Invite, player_name: String, frame: int) -> Error:
	role = Role.CLIENT
	_join_invite = invite
	_host_cert = null
	_rejoin = false
	_refusal = ""
	local_name = NetProtocol.clean_text(player_name, NetProtocol.NAME_MAX)
	if local_name == "":
		local_name = "Pilot"
	local_frame = frame
	_new_multiplayer()
	var err: Error = _connect_to_host()
	if err != OK:
		role = Role.NONE
		return err
	status = "Connecting to %s…" % invite.address
	changed.emit()
	return OK


## Open a connection to the invite's address: the unverified one that fetches
## the certificate while `_host_cert` is unknown, afterwards the real one that
## trusts exactly that certificate under the fixed name.
func _connect_to_host() -> Error:
	var next: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = next.create_client(_join_invite.address, _join_invite.port)
	if err != OK:
		status = "Could not reach %s." % _join_invite.address
		return err
	var options: TLSOptions = TLSOptions.client_unsafe() if _host_cert == null else TLSOptions.client(_host_cert)
	err = next.host.dtls_client_setup(CERT_NAME, options)
	if err != OK:
		next.close()
		status = "Could not start encryption (error %d)." % err
		return err
	var previous: ENetMultiplayerPeer = enet
	enet = next
	mp.multiplayer_peer = next   # before closing the old one, so no "disconnected" is reported
	if previous != null:
		previous.close()
	return OK


# --- Common --------------------------------------------------------------------

func my_id() -> int:
	return mp.get_unique_id() if mp != null and mp.multiplayer_peer != null else 0


func is_host() -> bool:
	return role == Role.HOST


func player(peer: int) -> Dictionary:
	for p in players:
		if int(p.peer) == peer:
			return p
	return {}


## Send a message to one peer (host: any joiner; joiner: the host is 1).
func send(peer: int, msg: Dictionary) -> void:
	if role == Role.HOST and not _greeted.has(peer):
		return
	_send_raw(peer, msg)


## Host: send to every accepted joiner except `except`.
func broadcast(msg: Dictionary, except: int = 0) -> void:
	if role != Role.HOST:
		return
	var bytes: PackedByteArray = NetProtocol.encode(msg)
	var mode: MultiplayerPeer.TransferMode = _mode(int(msg.type))
	for peer: int in _greeted:
		if peer != except:
			mp.send_bytes(bytes, peer, mode)


func close(reason: String = "") -> void:
	if _closing:
		return
	_closing = true
	if port_mapper != null:
		port_mapper.close()
	if enet != null:
		if role == Role.HOST and not _greeted.is_empty():
			# Say why. Joiners leave on receiving it; wait up to 0.25 s for them, so
			# the reason arrives before the connection closes.
			var leaving: Array[ENetPacketPeer] = []
			for peer: int in _greeted:
				_send_raw(peer, {"type": NetProtocol.Msg.REJECT, "reason": "The host stopped the match."})
				var p: ENetPacketPeer = enet.get_peer(peer)
				if p != null:
					leaving.append(p)
			var until: int = Time.get_ticks_msec() + 250
			while Time.get_ticks_msec() < until and leaving.any(func(p: ENetPacketPeer) -> bool: return p.is_active()):
				enet.host.service()
				OS.delay_msec(5)
		enet.close()
	if mp != null:
		mp.multiplayer_peer = null
	role = Role.NONE
	if current == self:
		current = null
	ended.emit(reason)
	queue_free.call_deferred()   # after the deferred add to the root, if that has not run yet


func _physics_process(delta: float) -> void:
	if mp == null or mp.multiplayer_peer == null:
		return
	_clock += delta
	mp.poll()
	# Decided inside the poll, done after it: the connection cannot be replaced
	# or closed while Godot is still handing out what arrived on it.
	if _refusal != "" and role == Role.CLIENT:
		_end_client(_refusal)
		return
	if _rejoin and role == Role.CLIENT:
		_rejoin = false
		if _connect_to_host() != OK:
			_end_client(status)
		return
	if role == Role.HOST:
		for peer: int in _chat_allowance:
			_chat_allowance[peer] = minf(float(_chat_allowance[peer]) + delta / CHAT_REFILL, CHAT_BURST)
		for peer: int in _hello_deadline.keys():
			_hello_deadline[peer] = float(_hello_deadline[peer]) - delta
			if float(_hello_deadline[peer]) <= 0.0:
				_hello_deadline.erase(peer)
				_drop(peer)


func _exit_tree() -> void:
	if not _closing:
		close("")


func _mode(type: int) -> MultiplayerPeer.TransferMode:
	return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED if NetProtocol.UNRELIABLE.has(type) else MultiplayerPeer.TRANSFER_MODE_RELIABLE


func _send_raw(peer: int, msg: Dictionary) -> void:
	if mp == null or mp.multiplayer_peer == null:
		return
	mp.send_bytes(NetProtocol.encode(msg), peer, _mode(int(msg.type)))


# --- Authentication ------------------------------------------------------------

func _on_peer_authenticating(peer: int) -> void:
	if role == Role.CLIENT:
		if _host_cert == null:
			# Nobody has been verified yet: ask for the certificate, send nothing else.
			mp.send_auth(1, PackedByteArray([CERT_REQUEST]))
			return
		# The DTLS handshake proved this is the host the invite's hash names.
		mp.send_auth(1, _join_invite.secret)
		mp.complete_auth(1)
		return
	var where: String = _address_of(peer)
	if _blocked.has(where):
		if _clock < float(_blocked[where]):
			_drop(peer)
			return
		_blocked.erase(where)
		_failures.erase(where)
		_fetches.erase(where)
	_auth_address[peer] = where
	reached_from_outside = true
	changed.emit()


func _on_auth_data(peer: int, data: PackedByteArray) -> void:
	if role == Role.CLIENT:
		_on_certificate(data)
		return
	if role != Role.HOST:
		return
	if not _auth_address.has(peer):
		_drop(peer)   # it already asked for the certificate; that connection gets nothing more
	elif data.size() == 1 and data[0] == CERT_REQUEST:
		_serve_certificate(peer)
	elif data.size() == _secret.size() and _crypto.constant_time_compare(data, _secret):
		var where: String = String(_auth_address[peer])
		_auth_address.erase(peer)
		_fetches[where] = maxi(int(_fetches.get(where, 0)) - 1, 0)   # this join's own fetch
		mp.complete_auth(peer)
	else:
		_count_failure(peer)
		_drop(peer)


## Host: hand the certificate to a connection that asked for it. It is public
## (every handshake shows it), so this is no failed attempt; but an address
## that keeps asking without ever joining is blocked like one that keeps failing.
func _serve_certificate(peer: int) -> void:
	var where: String = String(_auth_address[peer])
	_auth_address.erase(peer)
	_fetches[where] = int(_fetches.get(where, 0)) + 1
	if int(_fetches[where]) > FETCH_LIMIT:
		_blocked[where] = _clock + BLOCK_SECONDS
		_drop(peer)
		return
	mp.send_auth(peer, _cert_der)


## Joiner: the answer on the unverified connection. Whoever sent it is unknown,
## so only its size and hash are looked at before anything else happens. No
## match ends the join; there is no way to carry on without one.
func _on_certificate(data: PackedByteArray) -> void:
	if _host_cert != null or _rejoin or _refusal != "":
		return
	var cert: X509Certificate = Invite.certificate_from(data) if _join_invite.matches(data) else null
	if cert == null:
		_refusal = "The host that answered is not the one this invite is for. Ask the host for a new invite."
		return
	_host_cert = cert
	_rejoin = true   # reconnect once this poll is over


## A wrong secret, or none before the timeout: count it against the address.
func _on_auth_failed(peer: int) -> void:
	if role != Role.HOST:
		if not _rejoin and _refusal == "":
			status = "The host did not accept this invite."
			changed.emit()
		return
	_count_failure(peer)


## Host: close a connection now. SceneMultiplayer does not report peers it
## disconnects itself, so the bookkeeping runs here.
func _drop(peer: int) -> void:
	if mp == null or mp.multiplayer_peer == null:
		return
	var known: bool = _greeted.has(peer) or _auth_address.has(peer) or _hello_deadline.has(peer)
	mp.disconnect_peer(peer)
	if known:
		_on_peer_disconnected(peer)


func _count_failure(peer: int) -> void:
	var where: String = String(_auth_address.get(peer, ""))
	_auth_address.erase(peer)   # each attempt counts once
	if where == "":
		return
	_failures[where] = int(_failures.get(where, 0)) + 1
	if int(_failures[where]) >= BLOCK_AFTER:
		_blocked[where] = _clock + BLOCK_SECONDS


## Attempts from one address that have failed so far (for tests and the lobby).
func failures_from(where: String) -> int:
	return int(_failures.get(where, 0))


## Certificate requests from one address not yet followed by a join.
func fetches_from(where: String) -> int:
	return int(_fetches.get(where, 0))


func is_blocked(where: String) -> bool:
	return _blocked.has(where) and _clock < float(_blocked[where])


func _address_of(peer: int) -> String:
	if enet == null:
		return ""
	var p: ENetPacketPeer = enet.get_peer(peer)
	return p.get_remote_address() if p != null else ""


# --- Connection events ---------------------------------------------------------

func _on_peer_connected(peer: int) -> void:
	if role == Role.HOST:
		_hello_deadline[peer] = HELLO_TIMEOUT
		var p: ENetPacketPeer = enet.get_peer(peer)
		if p != null:
			p.set_timeout(0, 8000, 15000)


func _on_peer_disconnected(peer: int) -> void:
	if role == Role.HOST and _auth_address.has(peer):
		_count_failure(peer)   # left before proving it had the invite
	_hello_deadline.erase(peer)
	_bad_packets.erase(peer)
	_chat_allowance.erase(peer)
	if role != Role.HOST or not _greeted.has(peer):
		return
	_greeted.erase(peer)
	for i in range(players.size()):
		if int(players[i].peer) == peer:
			players.remove_at(i)
			break
	_update_capacity()
	broadcast(_roster())
	player_left.emit(peer)
	changed.emit()


func _on_connected_to_server() -> void:
	var p: ENetPacketPeer = enet.get_peer(1)
	if p != null:
		p.set_timeout(0, 8000, 15000)
	status = "Connected. Waiting for the host…"
	_send_raw(1, {"type": NetProtocol.Msg.HELLO, "version": NetProtocol.VERSION, "frame": local_frame, "name": local_name})
	changed.emit()


func _on_connection_failed() -> void:
	if _rejoin or _refusal != "":
		return   # the fetch connection going away; what follows is already decided
	_end_client("Could not connect. Check the invite, and that the host is hosting with the port open.")


func _on_server_disconnected() -> void:
	if _rejoin or _refusal != "":
		return
	_end_client(_close_reason if _close_reason != "" else "The connection to the host was lost.")


func _end_client(reason: String) -> void:
	status = reason
	close(reason)


# --- Messages ------------------------------------------------------------------

func _on_packet(peer: int, bytes: PackedByteArray) -> void:
	var msg: Dictionary = NetProtocol.decode(bytes)
	var type: int = int(msg.get("type", 0))
	if role == Role.HOST:
		if msg.is_empty() or not NetProtocol.FROM_CLIENT.has(type) or (type != NetProtocol.Msg.HELLO and not _greeted.has(peer)):
			_bad_packet(peer)
			return
		if type == NetProtocol.Msg.HELLO:
			_on_hello(peer, msg)
		elif type == NetProtocol.Msg.CHAT:
			_on_chat_from(peer, String(msg.text))
		else:
			_deliver(peer, msg)
		return
	if peer != 1 or msg.is_empty() or (NetProtocol.FROM_CLIENT.has(type) and type != NetProtocol.Msg.CHAT):
		return   # chat is the one message that travels both ways
	match type:
		NetProtocol.Msg.WELCOME:
			map_id = String(msg.map)
			max_players = int(msg.max_players)
			in_match = bool(msg.in_match)
			status = "In the lobby."
			welcomed.emit(map_id, in_match)
			changed.emit()
		NetProtocol.Msg.REJECT:
			# Leave at once: a disconnect arriving in the same poll would be
			# handled first and the reason lost.
			_close_reason = String(msg.reason)
			_end_client(_close_reason)
		NetProtocol.Msg.ROSTER:
			players.assign(msg.players)
			changed.emit()
		NetProtocol.Msg.CHAT:
			_add_chat(int(msg.peer), String(msg.name), String(msg.text))
		_:
			_deliver(peer, msg)


## Hand a message to the game. While nobody listens (a joiner reloading the
## scene for the host's map) messages wait, so a match start is not lost.
func _deliver(peer: int, msg: Dictionary) -> void:
	if message.get_connections().is_empty():
		if _queue.size() < 512:
			_queue.append([peer, msg])
		return
	message.emit(peer, msg)


## Deliver messages that arrived while nobody was listening.
func drain() -> void:
	var waiting: Array = _queue.duplicate()
	_queue.clear()
	for item: Array in waiting:
		message.emit(int(item[0]), item[1])


func _bad_packet(peer: int) -> void:
	_bad_packets[peer] = int(_bad_packets.get(peer, 0)) + 1
	if int(_bad_packets[peer]) > BAD_PACKET_LIMIT:
		_drop(peer)


func _on_hello(peer: int, msg: Dictionary) -> void:
	if _greeted.has(peer):
		_bad_packet(peer)
		return
	_hello_deadline.erase(peer)
	if int(msg.version) != NetProtocol.VERSION:
		kick(peer, "Your copy of Airflight is a different version from the host's. Both players need the same version.")
		return
	if players.size() >= max_players:
		kick(peer, "The match is full.")
		return
	var player_name: String = String(msg.name)
	if player_name == "":
		player_name = "Pilot"
	_greeted[peer] = true
	_chat_allowance[peer] = float(CHAT_BURST)
	players.append({"peer": peer, "name": player_name, "frame": int(msg.frame)})
	_update_capacity()
	send(peer, {"type": NetProtocol.Msg.WELCOME, "map": map_id, "max_players": max_players, "in_match": in_match})
	broadcast(_roster())
	changed.emit()


# --- Chat ----------------------------------------------------------------------
# Joiners send their line to the host; the host stamps it with who sent it and
# relays it to everyone, the sender included, so all players see the same list.

## Send a chat line from this player. Empty lines are ignored.
func say(text: String) -> void:
	var clean: String = NetProtocol.clean_text(text, NetProtocol.CHAT_MAX)
	if clean == "" or role == Role.NONE:
		return
	if role == Role.HOST:
		if not dedicated:
			_relay_chat(1, local_name, clean)
	else:
		_send_raw(1, {"type": NetProtocol.Msg.CHAT, "text": clean})


## Host: a joiner's chat line. Past its allowance it is dropped quietly.
func _on_chat_from(peer: int, text: String) -> void:
	if float(_chat_allowance.get(peer, 0.0)) < 1.0:
		return
	_chat_allowance[peer] = float(_chat_allowance[peer]) - 1.0
	var who: Dictionary = player(peer)
	_relay_chat(peer, String(who.get("name", "Pilot")), text)


func _relay_chat(peer: int, from_name: String, text: String) -> void:
	broadcast({"type": NetProtocol.Msg.CHAT, "peer": peer, "name": from_name, "text": text})
	_add_chat(peer, from_name, text)


func _add_chat(peer: int, from_name: String, text: String) -> void:
	var line: Dictionary = {"peer": peer, "name": from_name if from_name != "" else "Pilot", "text": text, "at": Time.get_ticks_msec()}
	chat_log.append(line)
	if chat_log.size() > CHAT_KEEP:
		chat_log.pop_front()
	chat_received.emit(line)


func _roster() -> Dictionary:
	return {"type": NetProtocol.Msg.ROSTER, "players": players}


func _update_capacity() -> void:
	if enet != null and role == Role.HOST:
		enet.refuse_new_connections = players.size() >= max_players


# --- Address help --------------------------------------------------------------

## A warning when the router's own internet address shows port forwarding cannot
## work, or "" when nothing looks wrong. `wan` is what the router reports,
## `public` what an outside service sees; either may be "".
static func address_warning(wan: String, public: String) -> String:
	if _in_shared_range(wan) or _in_shared_range(public) or (wan != "" and public != "" and wan != public and not _is_private(wan)):
		return "Your internet provider shares one address between customers (carrier-grade NAT), so port forwarding cannot work on this connection. Someone else should host, or use a dedicated server."
	if _is_private(wan):
		return "Your router is behind another router. The port has to be forwarded on both."
	return ""


static func _octets(ip: String) -> PackedInt32Array:
	var parts: PackedStringArray = ip.split(".")
	if parts.size() != 4:
		return PackedInt32Array()
	var out: PackedInt32Array = PackedInt32Array()
	for p in parts:
		if not p.is_valid_int():
			return PackedInt32Array()
		out.append(int(p))
	return out


static func _in_shared_range(ip: String) -> bool:
	var o: PackedInt32Array = _octets(ip)
	return o.size() == 4 and o[0] == 100 and o[1] >= 64 and o[1] <= 127


static func _is_private(ip: String) -> bool:
	var o: PackedInt32Array = _octets(ip)
	if o.size() != 4:
		return false
	return o[0] == 10 or (o[0] == 172 and o[1] >= 16 and o[1] <= 31) or (o[0] == 192 and o[1] == 168)
