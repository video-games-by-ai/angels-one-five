class_name AirframeOutline
extends RefCounted
## Top-down outline of the aircraft split into the five damage zones
## (engine, body, left wing, right wing, tail). Units are metres, nose up (-y),
## matching the Blender model's planform.

const FUSELAGE: Array[Vector2] = [  # z, half width
	Vector2(-4.55, 0.0), Vector2(-4.2, 0.24), Vector2(-3.86, 0.33), Vector2(-3.1, 0.42), Vector2(-1.9, 0.46),
	Vector2(-1.3, 0.47), Vector2(-0.6, 0.48), Vector2(1.0, 0.44), Vector2(2.6, 0.33), Vector2(3.4, 0.26),
	Vector2(4.2, 0.18), Vector2(4.9, 0.11), Vector2(5.3, 0.03)]
const HALF_SPAN: float = 5.64


static func _fuselage_width(z: float) -> float:
	for i in range(FUSELAGE.size() - 1):
		var a: Vector2 = FUSELAGE[i]
		var b: Vector2 = FUSELAGE[i + 1]
		if z >= a.x and z <= b.x:
			return lerpf(a.y, b.y, inverse_lerp(a.x, b.x, z))
	return 0.0


static func _fuselage_band(z0: float, z1: float) -> PackedVector2Array:
	var right: PackedVector2Array = PackedVector2Array()
	var left: PackedVector2Array = PackedVector2Array()
	var steps: int = 8
	for i in range(steps + 1):
		var z: float = lerpf(z0, z1, float(i) / steps)
		var w: float = maxf(_fuselage_width(z), 0.02)
		right.append(Vector2(w, z))
		left.append(Vector2(-w, z))
	left.reverse()
	right.append_array(left)
	return right


static func _wing(sign_x: float) -> PackedVector2Array:
	var front: PackedVector2Array = PackedVector2Array()
	var back: PackedVector2Array = PackedVector2Array()
	var steps: int = 14
	for i in range(steps + 1):
		var x: float = lerpf(0.5, HALF_SPAN, float(i) / steps)
		var t: float = x / HALF_SPAN
		var le: float = -1.05 + 0.70 * t
		var te: float = 1.60 - 0.75 * t
		var chord: float = te - le
		if x > 4.95:
			var k: float = sqrt(maxf(0.0, 1.0 - pow((x - 4.95) / (HALF_SPAN - 4.93), 2.0)))
			var q: float = le + chord * 0.3
			chord *= maxf(k, 0.12)
			le = q - chord * 0.3
		front.append(Vector2(x * sign_x, le))
		back.append(Vector2(x * sign_x, le + chord))
	back.reverse()
	front.append_array(back)
	return front


static func _tail() -> PackedVector2Array:
	var pts: PackedVector2Array = PackedVector2Array()
	pts.append(Vector2(0.22, 3.3))
	pts.append(Vector2(0.17, 4.05))
	pts.append(Vector2(1.6, 4.4))
	pts.append(Vector2(2.06, 4.75))
	pts.append(Vector2(1.95, 5.15))
	pts.append(Vector2(0.4, 5.25))
	pts.append(Vector2(0.03, 5.35))
	pts.append(Vector2(-0.03, 5.35))
	pts.append(Vector2(-0.4, 5.25))
	pts.append(Vector2(-1.95, 5.15))
	pts.append(Vector2(-2.06, 4.75))
	pts.append(Vector2(-1.6, 4.4))
	pts.append(Vector2(-0.17, 4.05))
	pts.append(Vector2(-0.22, 3.3))
	return pts


## Polygons in order: engine, body, left wing, right wing, tail.
static func zones() -> Array[PackedVector2Array]:
	return [_fuselage_band(-4.55, -1.35), _fuselage_band(-1.25, 3.2), _wing(-1.0), _wing(1.0), _tail()]
