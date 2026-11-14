class_name Invite
extends RefCounted
## The text a host gives to friends: "AF2." + URL-safe base64 of the host's
## address, port, a one-time secret and a hash of the host's certificate.
## Possessing it is what lets a game join, so it is treated as a password.
##
## The certificate itself is fetched from the host when joining and accepted
## only if it matches the hash here (see NetSession and
## docs/multiplayer-design.md), which keeps the invite to about 70 characters.
##
## Layout: version u8 · address length u8 · port u16 · address · secret[16] ·
## certificate hash[16] · check[3]. The check is the start of the SHA-256 of
## everything before it; it only catches copying mistakes.

const PREFIX: String = "AF2."
const OLD_PREFIX: String = "AF1."
const VERSION: int = 2
const SECRET_BYTES: int = 16
const HASH_BYTES: int = 16
const CHECK_BYTES: int = 3
const FIXED_BYTES: int = 4 + SECRET_BYTES + HASH_BYTES + CHECK_BYTES   ## everything but the address
const MAX_ADDRESS: int = 253
const MAX_TEXT: int = 400
const MIN_CERT: int = 300
const MAX_CERT: int = 1600
const ADDRESS_CHARS: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:"
const BASE64URL_CHARS: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"

var address: String = ""
var port: int = 0
var secret: PackedByteArray = PackedByteArray()
var certificate_hash: PackedByteArray = PackedByteArray()


func encode() -> String:
	var host_bytes: PackedByteArray = address.to_ascii_buffer()
	var blob: PackedByteArray = PackedByteArray([VERSION, host_bytes.size(), (port >> 8) & 255, port & 255])
	blob.append_array(host_bytes)
	blob.append_array(secret)
	blob.append_array(certificate_hash)
	blob.append_array(_sha256(blob).slice(0, CHECK_BYTES))
	return PREFIX + Marshalls.raw_to_base64(blob).replace("+", "-").replace("/", "_").replace("=", "")


## Parse invite text. Returns null and fills `error` with a message for people
## when anything about it is wrong; nothing unchecked reaches the decoders.
static func decode(text: String, error: Array = []) -> Invite:
	var t: String = tidy(text)
	if t.length() > MAX_TEXT:
		return _fail(error, "That invite is too long. Copy it again.")
	if t.begins_with(OLD_PREFIX):
		return _fail(error, "This invite is from an older version of Airflight. Both players need the same version.")
	if not t.begins_with(PREFIX):
		return _fail(error, "That is not an Airflight invite.")
	var body: String = t.substr(PREFIX.length())
	for i in range(body.length()):
		if BASE64URL_CHARS.find(body[i]) < 0:
			return _fail(error, "That invite has stray characters. Copy it again.")
	if body.length() < 3:
		return _fail(error, "That invite is incomplete. Copy it again.")
	# No whole invite has a length of 4n+1, so characters were lost or added. The
	# rest is still read (without the odd last character) to say how many.
	var ragged: bool = body.length() % 4 == 1
	var b64: String = body.substr(0, body.length() - int(ragged)).replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	var blob: PackedByteArray = Marshalls.base64_to_raw(b64)
	if blob.size() < 2:
		return _fail(error, "That invite is incomplete. Copy it again.")
	if blob[0] != VERSION:
		return _fail(error, "This invite is from a different version of Airflight.")
	var length: int = blob[1]
	if length < 1 or length > MAX_ADDRESS:
		return _fail(error, "That invite has no valid address.")
	# The address length says how long the whole invite must be, so a copy that
	# lost its end (or a character somewhere) can be told apart from other damage.
	var whole_bytes: int = FIXED_BYTES + length
	var whole: int = PREFIX.length() + (whole_bytes * 4 + 2) / 3
	if t.length() < whole:
		return _fail(error, "That invite is cut short: %d of its %d characters arrived. Copy the whole invite again." % [t.length(), whole])
	if t.length() > whole:
		return _fail(error, "That invite has %d characters too many (%d instead of %d). Copy it again." % [t.length() - whole, t.length(), whole])
	var body_end: int = whole_bytes - CHECK_BYTES
	if blob.size() != whole_bytes or _sha256(blob.slice(0, body_end)).slice(0, CHECK_BYTES) != blob.slice(body_end):
		return _fail(error, "That invite has a mistake in it. Copy it again.")
	var inv: Invite = Invite.new()
	inv.port = (blob[2] << 8) | blob[3]
	if inv.port < 1:
		return _fail(error, "That invite has no valid port.")
	var host_bytes: PackedByteArray = blob.slice(4, 4 + length)
	for b in host_bytes:
		if ADDRESS_CHARS.find(char(b)) < 0:
			return _fail(error, "That invite has no valid address.")
	inv.address = host_bytes.get_string_from_ascii()
	var at: int = 4 + length
	inv.secret = blob.slice(at, at + SECRET_BYTES)
	inv.certificate_hash = blob.slice(at + SECRET_BYTES, at + SECRET_BYTES + HASH_BYTES)
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


## What an invite says about a certificate (DER bytes): the start of its SHA-256.
static func hash_of(certificate_der: PackedByteArray) -> PackedByteArray:
	return _sha256(certificate_der).slice(0, HASH_BYTES)


## Whether these bytes, received from a host nobody has verified yet, are the
## certificate this invite was made for. Only their size and hash are looked
## at; nothing is parsed here.
func matches(certificate_der: PackedByteArray) -> bool:
	return certificate_der.size() >= MIN_CERT and certificate_der.size() <= MAX_CERT \
			and certificate_hash.size() == HASH_BYTES and hash_of(certificate_der) == certificate_hash


static func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish()


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


## A certificate from DER bytes as Godot needs it, or null if it does not parse.
static func certificate_from(der: PackedByteArray) -> X509Certificate:
	var cert: X509Certificate = X509Certificate.new()
	if cert.load_from_string(der_to_pem(der)) != OK:
		return null
	return cert
