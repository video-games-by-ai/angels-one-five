class_name Combatant
extends RefCounted
## One aircraft in the fight: its simulated state, who flies it, its visuals and
## its score. The player and the AI opponents are all Combatants.

const PLAYER_HIT_RADIUS: float = 4.4   ## the player is a slightly smaller target
const ENEMY_HIT_RADIUS: float = 7.0    ## forgiving aim against opponents

var id: int = 0
var team: int = 0
var is_player: bool = false
var frame_id: int = Airframes.Id.MUSTANG
var model: FlightModel = FlightModel.new()
var aircraft: Aircraft            ## visual node; null in headless tests
var ai: AiPilot                   ## null for the player
var hit_radius: float = ENEMY_HIT_RADIUS
var respawn_timer: float = 0.0
var gun_index: int = 0
var kills: int = 0
var losses: int = 0
var hit_flash: float = 0.0


func setup(new_id: int, new_team: int, airframe: int, player: bool) -> void:
	id = new_id
	team = new_team
	frame_id = airframe
	is_player = player
	hit_radius = (PLAYER_HIT_RADIUS if player else ENEMY_HIT_RADIUS) * float(Airframes.spec(airframe).target_scale)


func spawn(at: Vector3, heading: float) -> void:
	model.setup(frame_id, at, heading)
	gun_index = 0
	hit_flash = 0.0
	if aircraft != null:
		aircraft.transform = model.transform()
		aircraft.reset_physics_interpolation()
		aircraft.reset_effects()
		aircraft.set_damage(1.0)
		aircraft.visible = true


## Fire whatever rounds are due this step into the bullet field. Returns how many.
func shoot(trigger: bool, dt: float, bullets: BulletField, damage_scale: float = 1.0) -> int:
	var rounds: int = model.rounds_this_step(trigger, dt)
	for r in range(rounds):
		var gun: Array[Vector3] = model.muzzle(gun_index)
		gun_index += 1
		bullets.fire(id, team, gun[0], gun[1], model.velocity(), float(model.spec.gun_damage) * damage_scale)
	return rounds
