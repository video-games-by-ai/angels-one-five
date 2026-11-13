class_name AirframeOutline
extends RefCounted
## Top-down outline of each aircraft split into the five damage zones (engine,
## body, left wing, right wing, tail). Units are metres, nose up (-y), following
## the same planform formulas as the Blender models in tools/build_aircraft.py.

const HALF_SPANS: Array[float] = [5.61, 5.64, 6.21]
const TAIL_SPANS: Array[float] = [1.62, 2.08, 2.46]
const FUSELAGES: Array[Array] = [  # z, half width (spinner tip to tail cone)
	[Vector2(-4.46, 0.0), Vector2(-4.1, 0.22), Vector2(-3.76, 0.30), Vector2(-3.0, 0.39), Vector2(-1.8, 0.43),
		Vector2(-0.5, 0.44), Vector2(0.9, 0.40), Vector2(1.6, 0.35), Vector2(2.4, 0.28), Vector2(3.2, 0.20),
		Vector2(4.0, 0.12), Vector2(4.6, 0.06), Vector2(4.98, 0.02)],
	[Vector2(-4.55, 0.0), Vector2(-4.2, 0.24), Vector2(-3.86, 0.33), Vector2(-3.1, 0.42), Vector2(-1.9, 0.46),
		Vector2(-1.3, 0.47), Vector2(-0.6, 0.48), Vector2(1.0, 0.44), Vector2(2.6, 0.33), Vector2(3.4, 0.26),
		Vector2(4.2, 0.18), Vector2(4.9, 0.11), Vector2(5.3, 0.03)],
	[Vector2(-5.14, 0.0), Vector2(-4.95, 0.18), Vector2(-4.72, 0.21), Vector2(-4.68, 0.50), Vector2(-4.56, 0.62),
		Vector2(-4.2, 0.66), Vector2(-2.7, 0.68), Vector2(-0.9, 0.65), Vector2(0.9, 0.57), Vector2(1.8, 0.50),
		Vector2(2.7, 0.41), Vector2(3.6, 0.31), Vector2(4.5, 0.20), Vector2(5.3, 0.10), Vector2(5.86, 0.03)],
]


## Leading-edge z and chord of the wing at span position x.
static func wing(id: int, x: float) -> Vector2:
	match id:
		Airframes.Id.SPITFIRE:
			var t: float = minf(x / 5.61, 0.9995)
			var chord: float = maxf(2.55 * sqrt(1.0 - t * t), 0.10)
			return Vector2(-0.38 - 0.34 * chord, chord)
		Airframes.Id.THUNDERBOLT:
			var t: float = minf(x / 6.21, 0.9995)
			return Vector2(-2.45 + 0.50 * t + 0.30 * pow(t, 6.0), maxf(2.90 * pow(1.0 - pow(t, 2.5), 0.6), 0.12))
		_:
			var t: float = x / 5.64
			var le: float = -1.05 + 0.70 * t
			return _round_tip(x, le, (1.60 - 0.75 * t) - le, 4.95, 5.64, 0.3, 0.12)


## Leading-edge z and chord of the tailplane at span position x.
static func tailplane(id: int, x: float) -> Vector2:
	match id:
		Airframes.Id.SPITFIRE:
			var t: float = minf(x / 1.62, 0.999)
			var chord: float = maxf(1.22 * sqrt(1.0 - t * t), 0.08)
			return Vector2(4.22 - 0.42 * chord, chord)
		Airframes.Id.THUNDERBOLT:
			var t: float = minf(x / 2.46, 0.999)
			return Vector2(4.36 + 0.34 * t + 0.10 * pow(t, 6.0), maxf(1.48 * pow(1.0 - pow(t, 2.4), 0.6), 0.10))
		_:
			var t: float = x / 2.08
			var le: float = 4.05 + 0.42 * t
			return _round_tip(x, le, (5.27 - 0.08 * t) - le, 1.55, 2.08, 0.3, 0.15)


static func _round_tip(x: float, le: float, chord: float, start: float, end: float, pivot: float, floor_k: float) -> Vector2:
	if x <= start:
		return Vector2(le, chord)
	var k: float = sqrt(maxf(0.0, 1.0 - pow((x - start) / (end - start + 0.02), 2.0)))
	var q: float = le + chord * pivot
	chord *= maxf(k, floor_k)
	return Vector2(q - chord * pivot, chord)


static func _fuselage_width(id: int, z: float) -> float:
	var profile: Array = FUSELAGES[id]
	for i in range(profile.size() - 1):
		var a: Vector2 = profile[i]
		var b: Vector2 = profile[i + 1]
		if z >= a.x and z <= b.x:
			return lerpf(a.y, b.y, inverse_lerp(a.x, b.x, z))
	return 0.0


static func _fuselage_band(id: int, z0: float, z1: float) -> PackedVector2Array:
	var right: PackedVector2Array = PackedVector2Array()
	var left: PackedVector2Array = PackedVector2Array()
	var steps: int = 10
	for i in range(steps + 1):
		var z: float = lerpf(z0, z1, float(i) / steps)
		var w: float = maxf(_fuselage_width(id, z), 0.02)
		right.append(Vector2(w, z))
		left.append(Vector2(-w, z))
	left.reverse()
	right.append_array(left)
	return right


static func _wing_polygon(id: int, sign_x: float) -> PackedVector2Array:
	var front: PackedVector2Array = PackedVector2Array()
	var back: PackedVector2Array = PackedVector2Array()
	var steps: int = 18
	for i in range(steps + 1):
		# Stations bunch up toward the tip so its curve stays smooth.
		var x: float = lerpf(0.5, HALF_SPANS[id] - 0.01, sin(float(i) / steps * PI * 0.5))
		var w: Vector2 = wing(id, x)
		front.append(Vector2(x * sign_x, w.x))
		back.append(Vector2(x * sign_x, w.x + w.y))
	back.reverse()
	front.append_array(back)
	return front


static func _tail_polygon(id: int, z0: float) -> PackedVector2Array:
	var right: PackedVector2Array = PackedVector2Array()
	var profile: Array = FUSELAGES[id]
	var end_z: float = (profile[profile.size() - 1] as Vector2).x + 0.05
	var root: Vector2 = tailplane(id, 0.2)
	right.append(Vector2(_fuselage_width(id, z0), z0))
	right.append(Vector2(_fuselage_width(id, root.x), root.x))
	var steps: int = 10
	var back: PackedVector2Array = PackedVector2Array()
	for i in range(steps + 1):
		var x: float = lerpf(0.2, TAIL_SPANS[id] - 0.01, sin(float(i) / steps * PI * 0.5))
		var t: Vector2 = tailplane(id, x)
		right.append(Vector2(x, t.x))
		back.append(Vector2(x, t.x + t.y))
	back.reverse()
	right.append_array(back)
	right.append(Vector2(0.03, maxf(end_z, root.x + root.y + 0.02)))
	var left: PackedVector2Array = PackedVector2Array()
	for p in right:
		left.append(Vector2(-p.x, p.y))
	left.reverse()
	right.append_array(left)
	return right


## Polygons in Airframes.Zone order: engine, body, left wing, right wing, tail.
static func zones(id: int) -> Array[PackedVector2Array]:
	var spec: Dictionary = Airframes.spec(id)
	var nose: float = (FUSELAGES[id][0] as Vector2).x
	var engine_z: float = float(spec.engine_z)
	var tail_z: float = float(spec.tail_z)
	return [_fuselage_band(id, nose, engine_z - 0.05), _fuselage_band(id, engine_z + 0.05, tail_z - 0.05),
		_wing_polygon(id, -1.0), _wing_polygon(id, 1.0), _tail_polygon(id, tail_z + 0.05)]


## Nose z, tail z and half span, for fitting the outline into a panel.
static func extent(id: int) -> Vector3:
	var profile: Array = FUSELAGES[id]
	return Vector3((profile[0] as Vector2).x, (profile[profile.size() - 1] as Vector2).x + 0.05, HALF_SPANS[id])
