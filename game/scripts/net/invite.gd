class_name Invite
extends RefCounted
## The text a host gives to friends: "AF1." + URL-safe base64 of the host's
## address, port, a one-time secret and the host's certificate. Possessing it
## is what lets a game join, so it is treated as a password.
##
## Layout: version u8 · port u16 · secret[16] · address length u8 · address ·
## certificate (DER, the rest). See docs/multiplayer-design.md.

const PREFIX: String = "AF1."
const VERSION: int = 1
const SECRET_BYTES: int = 16
const MAX_TEXT: int = 2048
const MAX_ADDRESS: int = 253
const MIN_CERT: int = 300
const MAX_CERT: int = 1600
const ADDRESS_CHARS: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:"
const BASE64URL_CHARS: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"

var address: String = ""
var port: int = 0
var secret: PackedByteArray = PackedByteArray()
var certificate_der: PackedByteArray = PackedByteArray()


func encode() -> String:
	var blob: PackedByteArray = PackedByteArray([VERSION, (port >> 8) & 255, port & 255])
	blob.append_array(secret)
	var host_bytes: PackedByteArray = address.to_ascii_buffer()
	blob.append(host_bytes.size())
	blob.append_array(host_bytes)
	blob.append_array(certificate_der)
	return PREFIX + Marshalls.raw_to_base64(blob).replace("+", "-").replace("/", "_").replace("=", "")


## Parse invite text. Returns null and fills `error` with a message for people
## when anything about it is wrong; nothing unchecked reaches the decoders.
static func decode(text: String, error: Array = []) -> Invite:
	var t: String = tidy(text)
	if t.length() > MAX_TEXT:
		return _fail(error, "That invite is too long. Copy it again.")
	if not t.begins_with(PREFIX):
		return _fail(error, "That is not an Airflight invite.")
	var body: String = t.substr(PREFIX.length())
	if body.length() < 40:
		return _fail(error, "That invite is incomplete. Copy it again.")
	for i in range(body.length()):
		if BASE64URL_CHARS.find(body[i]) < 0:
			return _fail(error, "That invite has stray characters. Copy it again.")
	# No whole invite has this length, so characters were lost or added. The rest
	# is still read (without the odd last character) to say how many.
	var ragged: bool = body.length() % 4 == 1
	var b64: String = body.substr(0, body.length() - int(ragged)).replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	var blob: PackedByteArray = Marshalls.base64_to_raw(b64)
	if blob.size() < 1 + 2 + SECRET_BYTES + 1 + 1 + MIN_CERT:
		return _fail(error, "That invite is incomplete. Copy it again.")
	if blob[0] != VERSION:
		return _fail(error, "This invite is from a different version of Airflight.")
	var inv: Invite = Invite.new()
	inv.port = (blob[1] << 8) | blob[2]
	if inv.port < 1:
		return _fail(error, "That invite has no valid port.")
	inv.secret = blob.slice(3, 3 + SECRET_BYTES)
	var at: int = 3 + SECRET_BYTES
	var length: int = blob[at]
	at += 1
	if length < 1 or length > MAX_ADDRESS or at + length > blob.size():
		return _fail(error, "That invite has no valid address.")
	var host_bytes: PackedByteArray = blob.slice(at, at + length)
	for b in host_bytes:
		if ADDRESS_CHARS.find(char(b)) < 0:
			return _fail(error, "That invite has no valid address.")
	inv.address = host_bytes.get_string_from_ascii()
	at += length
	inv.certificate_der = blob.slice(at)
	var n: int = inv.certificate_der.size()
	# A DER certificate is one SEQUENCE with a two-byte length that covers the rest.
	if n < MIN_CERT or n > MAX_CERT or inv.certificate_der[0] != 0x30 or inv.certificate_der[1] != 0x82:
		return _fail(error, "That invite's security certificate is damaged. Copy it again.")
	# That length says how long the whole invite must be, so a copy that lost its
	# end (or a character somewhere) can be told apart from other damage.
	var declared: int = ((inv.certificate_der[2] << 8) | inv.certificate_der[3]) + 4
	if declared != n or ragged:
		var whole: int = PREFIX.length() + ((at + declared) * 4 + 2) / 3
		if declared >= MIN_CERT and declared <= MAX_CERT and t.length() < whole:
			return _fail(error, "That invite is cut short: %d of its %d characters arrived. Copy the whole invite again." % [t.length(), whole])
		if declared >= MIN_CERT and declared <= MAX_CERT and t.length() > whole:
			return _fail(error, "That invite has %d characters too many (%d instead of %d). Copy it again." % [t.length() - whole, t.length(), whole])
		return _fail(error, "That invite's security certificate is damaged. Copy it again.")
	if inv.certificate() == null:
		return _fail(error, "That invite's security certificate is damaged. Copy it again.")
	return inv


## Invite text as it was meant: without the spaces, line breaks and invisible
## characters that chat and mail programs put around and inside long text.
static func tidy(text: String) -> String:
	var out: String = ""
	for i in range(text.length()):
		var c: int = text.unicode_at(i)
		if c <= 0x20 or c == 0xA0 or c == 0xAD or (c >= 0x200B and c <= 0x200F) or c == 0x2028 or c == 0x2029 or c == 0x2060 or c == 0xFEFF:
			continue
		out += text[i]
	return out


## The host's certificate as Godot needs it, or null if it does not parse.
func certificate() -> X509Certificate:
	var cert: X509Certificate = X509Certificate.new()
	if cert.load_from_string(der_to_pem(certificate_der)) != OK:
		return null
	return cert


static func _fail(error: Array, message: String) -> Invite:
	error.clear()
	error.append(message)
	return null


static func pem_to_der(pem: String) -> PackedByteArray:
	var body: String = ""
	for line in pem.split("\n"):
		var l: String = line.strip_edges()
		if not l.begins_with("-----"):
			body += l
	return Marshalls.base64_to_raw(body)


static func der_to_pem(der: PackedByteArray) -> String:
	var b64: String = Marshalls.raw_to_base64(der)
	var out: String = "-----BEGIN CERTIFICATE-----\n"
	for i in range(0, b64.length(), 64):
		out += b64.substr(i, 64) + "\n"
	return out + "-----END CERTIFICATE-----\n"
