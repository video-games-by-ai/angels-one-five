class_name AddressProbe
extends Node
## "Detect my address": asks a public what-is-my-IP service over HTTPS, only when
## the host presses the button. Tries a second service if the first fails.

signal finished(address: String, error: String)

const SERVICES: PackedStringArray = ["https://api.ipify.org", "https://icanhazip.com"]

var _request: HTTPRequest
var _index: int = 0


func detect() -> void:
	_index = 0
	_try()


func _try() -> void:
	if _request != null:
		_request.queue_free()
	_request = HTTPRequest.new()
	_request.timeout = 6.0
	_request.body_size_limit = 256
	add_child(_request)
	_request.request_completed.connect(_on_completed)
	if _request.request(SERVICES[_index]) != OK:
		_next("Could not start the request.")


func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var text: String = body.get_string_from_ascii().strip_edges() if NetProtocol.valid_utf8(body) else ""
	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and text.is_valid_ip_address():
		finished.emit(text, "")
		return
	_next("The address service did not answer.")


func _next(error: String) -> void:
	_index += 1
	if _index < SERVICES.size():
		_try()
	else:
		finished.emit("", error + " Type your address in instead.")
