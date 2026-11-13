class_name Airframes
extends RefCounted
## Balance and presentation data for the selectable aircraft. Network clients send
## an id, never stats. Speeds in m/s, rates in rad/s, positions in metres in the
## aircraft's own space (+X right wing, +Y up, -Z nose).
##
## The three are real 1940s fighters, balanced for play rather than history:
## the Spitfire is quick and nimble but lightly armed and fragile, the Mustang is
## the all-rounder, the Thunderbolt is slow to turn but hits hardest and absorbs
## the most punishment. The heavier the guns, the further the gunsight zooms
## (`zoom`, times), so the big aircraft are the long-range shots. Guns overheat
## after `gun_heat_time` seconds of unbroken fire (see FlightModel): the heavier
## the battery, the sooner. `engine_sound` and `gun_sound` name groups of files
## (see Sfx.engine_loop and Sfx.gun_stream).

enum Id { SPITFIRE, MUSTANG, THUNDERBOLT }
enum Zone { ENGINE, BODY, WING_L, WING_R, TAIL }

const COUNT: int = 3
## Share of the hull a single zone can absorb before it reads as destroyed.
const ZONE_CAPACITY: float = 0.45

const SPECS: Array[Dictionary] = [
	{"name": "Spitfire Mk IX", "short": "SPITFIRE", "class": "LIGHT", "origin": "Supermarine · Britain · 1942",
		"blurb": "Fastest and most agile. Light guns and a thin skin: hit and run.",
		"engine_label": "Rolls-Royce Merlin 66 · V-12 · 1,720 hp", "guns_label": "2 × 20 mm cannon · 4 × .303",
		"model": "res://assets/models/spitfire.glb", "engine_sound": "res://assets/audio/engine_spitfire",
		"gun_sound": "res://assets/audio/gun_light", "gun_pitch": 1.0,
		"hull": 80.0, "top_speed": 172.0, "boost_speed": 205.0, "stall": 48.0, "thrust": 15.5,
		"pitch_rate": 1.75, "roll_rate": 4.4, "yaw_rate": 0.42, "response": 7.0,
		"gun_damage": 8.0, "fire_rate": 12.0, "gun_heat_time": 8.0, "target_scale": 0.9, "zoom": 3.0,
		"muzzles": [Vector3(-1.92, -0.19, -2.14), Vector3(1.92, -0.19, -2.14)],
		"prop_radius": 1.63, "engine_z": -1.25, "tail_z": 3.0, "body_half_width": 0.6, "smoke_z": -2.4,
		"paint": {"base_color": Color(0.33, 0.37, 0.40), "paint_b": Color(0.19, 0.25, 0.16), "camo": 1.0,
			"underside_color": Color(0.56, 0.60, 0.64), "underside": 1.0, "metallic": 0.05, "roughness": 0.52, "stain_strength": 0.6}},
	{"name": "P-51D Mustang", "short": "MUSTANG", "class": "MEDIUM", "origin": "North American · USA · 1944",
		"blurb": "The all-rounder. Good speed, six heavy machine guns, a solid airframe.",
		"engine_label": "Packard Merlin V-1650 · V-12 · 1,490 hp", "guns_label": "6 × .50 cal machine guns",
		"model": "res://assets/models/mustang.glb", "engine_sound": "res://assets/audio/engine_mustang",
		"gun_sound": "res://assets/audio/gun_medium", "gun_pitch": 1.0,
		"hull": 100.0, "top_speed": 162.0, "boost_speed": 192.0, "stall": 50.0, "thrust": 14.0,
		"pitch_rate": 1.5, "roll_rate": 3.8, "yaw_rate": 0.36, "response": 6.0,
		"gun_damage": 10.0, "fire_rate": 13.0, "gun_heat_time": 7.0, "target_scale": 1.0, "zoom": 4.0,
		"muzzles": [Vector3(-2.22, -0.18, -1.02), Vector3(2.22, -0.18, -1.02)],
		"prop_radius": 1.70, "engine_z": -1.35, "tail_z": 3.2, "body_half_width": 0.62, "smoke_z": -2.6,
		"paint": {"base_color": Color(0.74, 0.76, 0.78), "paint_b": Color(0.74, 0.76, 0.78), "camo": 0.0,
			"underside_color": Color(0.74, 0.76, 0.78), "underside": 0.0, "metallic": 0.92, "roughness": 0.30, "stain_strength": 1.0}},
	{"name": "P-47D Thunderbolt", "short": "THUNDERBOLT", "class": "HEAVY", "origin": "Republic · USA · 1943",
		"blurb": "Big, tough and hard-hitting. Slower to turn and an easier target.",
		"engine_label": "Pratt & Whitney R-2800 · 18-cyl radial · 2,000 hp", "guns_label": "8 × .50 cal machine guns",
		"model": "res://assets/models/thunderbolt.glb", "engine_sound": "res://assets/audio/engine_thunderbolt",
		"gun_sound": "res://assets/audio/gun_heavy", "gun_pitch": 1.0,
		"hull": 135.0, "top_speed": 150.0, "boost_speed": 178.0, "stall": 54.0, "thrust": 12.5,
		"pitch_rate": 1.25, "roll_rate": 3.1, "yaw_rate": 0.30, "response": 5.0,
		"gun_damage": 14.0, "fire_rate": 14.0, "gun_heat_time": 6.0, "target_scale": 1.15, "zoom": 6.0,
		"muzzles": [Vector3(-2.89, -0.27, -2.59), Vector3(2.89, -0.27, -2.59)],
		"prop_radius": 1.98, "engine_z": -2.3, "tail_z": 3.6, "body_half_width": 0.8, "smoke_z": -3.4,
		"paint": {"base_color": Color(0.25, 0.26, 0.15), "paint_b": Color(0.31, 0.31, 0.20), "camo": 0.6,
			"underside_color": Color(0.47, 0.49, 0.51), "underside": 1.0, "metallic": 0.05, "roughness": 0.6, "stain_strength": 0.0}},
]


static func spec(id: int) -> Dictionary:
	return SPECS[clampi(id, 0, SPECS.size() - 1)]


## A magnification as shown to the player: "3×", "2.5×".
static func zoom_label(times: float) -> String:
	return ("%.1f" % times).trim_suffix(".0") + "×"


## Damage per second with every round on target.
static func firepower(id: int) -> float:
	var s: Dictionary = spec(id)
	return float(s.gun_damage) * float(s.fire_rate)


## Hangar ratings in the order speed, agility, firepower, armour. The best
## aircraft in a category scores 1 and the weakest 0.5, so the bars show the
## differences clearly.
static func ratings(id: int) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for k in range(4):
		var low: float = INF
		var high: float = -INF
		for i in range(SPECS.size()):
			low = minf(low, _rating_value(i, k))
			high = maxf(high, _rating_value(i, k))
		out[k] = 0.5 + 0.5 * (_rating_value(id, k) - low) / maxf(high - low, 0.0001)
	return out


static func _rating_value(id: int, category: int) -> float:
	var s: Dictionary = spec(id)
	match category:
		0:
			return float(s.top_speed)
		1:
			return float(s.roll_rate) * float(s.pitch_rate)
		2:
			return firepower(id)
		_:
			return float(s.hull)


## Which damage zone a hit lands in, from its position in the aircraft's space.
static func zone_at(s: Dictionary, local: Vector3) -> int:
	if local.z > float(s.tail_z):
		return Zone.TAIL
	if absf(local.x) > float(s.body_half_width):
		return Zone.WING_L if local.x < 0.0 else Zone.WING_R
	if local.z < float(s.engine_z):
		return Zone.ENGINE
	return Zone.BODY
