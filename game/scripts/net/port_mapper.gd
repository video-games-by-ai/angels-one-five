class_name PortMapper
extends Node
## Asks the router to forward the hosting port (UPnP), only when the host turns
## it on. Discovery blocks for a couple of seconds, so it runs on a thread. The
## mapping is requested with a one-hour lease, renewed every half hour, so a
## crashed game cannot leave it open for long; it is removed when hosting stops.
## Routers that only accept permanent mappings get one, removed the same way.

signal finished(ok: bool, external_address: String, text: String)

const LEASE: int = 3600
const DESCRIPTION: String = "Airflight"

var port: int = 0
var mapped: bool = false
var external_address: String = ""
var text: String = ""
var busy: bool = false
var _upnp: UPNP
var _thread: Thread
var _renew_timer: Timer


func open(listen_port: int) -> void:
	port = listen_port
	text = "Asking the router to open UDP port %d…" % port
	_start(_work_open)
	_renew_timer = Timer.new()
	_renew_timer.wait_time = LEASE * 0.5
	_renew_timer.timeout.connect(func() -> void:
		if mapped and not busy:
			_start(_work_open))
	add_child(_renew_timer)
	_renew_timer.start()


func close() -> void:
	if _renew_timer != null:
		_renew_timer.stop()
	_join()
	if mapped and _upnp != null:
		_upnp.delete_port_mapping(port, "UDP")
		mapped = false
		text = "Port closed again."


func _exit_tree() -> void:
	close()


func _start(work: Callable) -> void:
	_join()
	busy = true
	_thread = Thread.new()
	_thread.start(work)


func _join() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


func _work_open() -> void:
	var upnp: UPNP = _upnp if _upnp != null else UPNP.new()
	var ok: bool = false
	var message: String = ""
	if _upnp == null:
		var err: int = upnp.discover(2000, 2, "")
		if err != UPNP.UPNP_RESULT_SUCCESS or upnp.get_gateway() == null or not upnp.get_gateway().is_valid_gateway():
			_done.call_deferred(false, "", "No router with automatic port opening (UPnP) answered. Forward UDP %d by hand instead." % port)
			return
	var result: int = upnp.add_port_mapping(port, port, DESCRIPTION, "UDP", LEASE)
	if result == UPNP.UPNP_RESULT_ONLY_PERMANENT_LEASE_SUPPORTED:
		result = upnp.add_port_mapping(port, port, DESCRIPTION, "UDP", 0)
	ok = result == UPNP.UPNP_RESULT_SUCCESS
	var external: String = upnp.query_external_address() if ok else ""
	if ok:
		message = "The router opened UDP %d." % port
	else:
		message = "The router refused to open the port (UPnP error %d). Forward UDP %d by hand instead." % [result, port]
	_upnp = upnp
	_done.call_deferred(ok, external, message)


func _done(ok: bool, external: String, message: String) -> void:
	busy = false
	mapped = mapped or ok
	if external != "":
		external_address = external
	text = message
	finished.emit(ok, external_address, text)
