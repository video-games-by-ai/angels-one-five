class_name Airframes
extends RefCounted
## Balance data for the selectable aircraft. Network clients send an id, never stats.
## Speeds in m/s, rates in rad/s. Only the Mustang has a finished model so far;
## the light and heavy classes reuse it until their own models are built.

enum Id { SPITFIRE, MUSTANG, THUNDERBOLT }

const SPECS: Array[Dictionary] = [
	{"name": "Spitfire Mk IX", "class": "LIGHT", "model": "res://assets/models/mustang.glb",
		"hull": 80.0, "top_speed": 172.0, "boost_speed": 205.0, "stall": 48.0, "thrust": 15.5,
		"pitch_rate": 1.75, "roll_rate": 4.4, "yaw_rate": 0.42, "response": 7.0,
		"gun_damage": 8.0, "target_scale": 0.9},
	{"name": "P-51D Mustang", "class": "MEDIUM", "model": "res://assets/models/mustang.glb",
		"hull": 100.0, "top_speed": 162.0, "boost_speed": 192.0, "stall": 50.0, "thrust": 14.0,
		"pitch_rate": 1.5, "roll_rate": 3.8, "yaw_rate": 0.36, "response": 6.0,
		"gun_damage": 10.0, "target_scale": 1.0},
	{"name": "P-47D Thunderbolt", "class": "HEAVY", "model": "res://assets/models/mustang.glb",
		"hull": 135.0, "top_speed": 150.0, "boost_speed": 178.0, "stall": 54.0, "thrust": 12.5,
		"pitch_rate": 1.25, "roll_rate": 3.1, "yaw_rate": 0.30, "response": 5.0,
		"gun_damage": 14.0, "target_scale": 1.15},
]


static func spec(id: int) -> Dictionary:
	return SPECS[clampi(id, 0, SPECS.size() - 1)]
