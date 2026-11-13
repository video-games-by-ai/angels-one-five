class_name ChaseCamera
extends Camera3D
## Third-person chase camera. It looks along the pilot's aim, sits behind and above
## the aircraft so the plane rides in the lower middle of the screen, widens and
## pulls back under boost, and shakes (adjustably) with speed, g-load and boost.

const BASE_FOV: float = 68.0
const BOOST_FOV: float = 9.0
const DISTANCE: float = 16.5
const HEIGHT: float = 3.6

var settings: GameSettings
var rig: Basis = Basis.IDENTITY
var up_vector: Vector3 = Vector3.UP
var boost_blend: float = 0.0
var shake_noise: FastNoiseLite = FastNoiseLite.new()
var shake_time: float = 0.0
var extra_shake: float = 0.0


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	near = 0.25
	far = 42000.0
	fov = BASE_FOV
	shake_noise.frequency = 1.6
	shake_noise.fractal_octaves = 2


func snap(aim: Vector3, target: Vector3) -> void:
	rig = Basis.looking_at(aim, Vector3.UP)
	up_vector = Vector3.UP
	global_transform = Transform3D(rig, target + rig * Vector3(0.0, HEIGHT, DISTANCE))


## Called every rendered frame with the interpolated aircraft transform.
func follow(delta: float, aim: Vector3, aircraft: Transform3D, model: FlightModel) -> void:
	# Keep world-up unless looking nearly straight up/down (loops), then keep the
	# previous up so the camera carries over the top instead of flipping.
	if absf(aim.y) < 0.88:
		up_vector = up_vector.slerp(Vector3.UP, 1.0 - exp(-delta * 3.0)).normalized()
	else:
		up_vector = rig.y
	var wanted: Basis = Basis.looking_at(aim, up_vector)
	rig = Basis(Quaternion(rig.orthonormalized()).slerp(Quaternion(wanted.orthonormalized()), 1.0 - exp(-delta * 9.0)))

	boost_blend = lerpf(boost_blend, 1.0 if model.boosting else 0.0, 1.0 - exp(-delta * 3.0))
	var speed_ratio: float = clampf(model.speed / float(model.spec.top_speed), 0.4, 1.3)
	var distance: float = DISTANCE + boost_blend * 3.2 + (speed_ratio - 0.8) * 2.0
	var height: float = HEIGHT + boost_blend * 0.5
	var target: Vector3 = aircraft.origin + aircraft.basis.y * 0.4
	var pos: Vector3 = target + rig * Vector3(0.0, height, distance)

	var view: Basis = rig
	shake_time += delta
	var amount: float = settings.camera_shake * (0.10 * smoothstep(0.8, 1.15, speed_ratio) + 0.25 * boost_blend + 0.05 * clampf(model.g_load - 3.0, 0.0, 5.0) + extra_shake)
	if amount > 0.0001:
		var t: float = shake_time * 12.0
		var pitch: float = shake_noise.get_noise_2d(t, 0.0) * deg_to_rad(0.9) * amount
		var yaw: float = shake_noise.get_noise_2d(0.0, t) * deg_to_rad(0.9) * amount
		view = view * Basis.from_euler(Vector3(pitch, yaw, 0.0))
	extra_shake = maxf(extra_shake - delta * 2.0, 0.0)
	global_transform = Transform3D(view, pos)
	fov = BASE_FOV + boost_blend * BOOST_FOV + (speed_ratio - 0.8) * 4.0
