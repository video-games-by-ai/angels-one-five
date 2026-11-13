class_name Atmosphere
extends Node3D
## Sun, sky, haze and post-processing for the golden-hour look.

const HORIZON: Color = Color("e4d3bd")
const HAZE: Color = Color("d8c2a4")

var environment: Environment
var sun: DirectionalLight3D
var sun_direction: Vector3 = Vector3.UP


func build(sun_dir: Vector3, altitude_offset: float = 0.0) -> void:
	sun_direction = sun_dir.normalized()
	environment = Environment.new()
	var sky: Sky = Sky.new()
	var sky_material: ShaderMaterial = ShaderMaterial.new()
	sky_material.shader = load("res://shaders/sky.gdshader")
	sky_material.set_shader_parameter("horizon", HORIZON)
	sky_material.set_shader_parameter("cirrus", _cirrus_texture())
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 1.0
	environment.ambient_light_energy = 0.9
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 0.95
	environment.tonemap_white = 6.0

	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	environment.fog_light_color = HAZE
	environment.fog_light_energy = 1.0
	environment.fog_sun_scatter = 0.28
	environment.fog_density = 0.000085
	environment.fog_aerial_perspective = 0.55
	environment.fog_sky_affect = 0.0
	environment.fog_height = 650.0 + altitude_offset
	environment.fog_height_density = 0.0005

	environment.glow_enabled = true
	environment.glow_intensity = 0.6
	environment.glow_strength = 0.9
	environment.glow_bloom = 0.04
	environment.glow_hdr_threshold = 1.1
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.08
	environment.adjustment_contrast = 1.04

	var world: WorldEnvironment = WorldEnvironment.new()
	world.environment = environment
	add_child(world)

	sun = DirectionalLight3D.new()
	sun.light_color = Color("ffd2a1")
	sun.light_energy = 2.1
	sun.light_angular_distance = 0.6
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.6
	sun.shadow_blur = 1.2
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.85
	add_child(sun)
	sun.basis = Basis.looking_at(-sun_direction, Vector3.UP)


func apply_quality(profile: Dictionary) -> void:
	sun.directional_shadow_max_distance = float(profile.shadow_distance)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if int(profile.shadow_splits) == 4 else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	environment.ssr_enabled = bool(profile.ssr)
	environment.ssr_max_steps = 56
	environment.ssr_fade_in = 0.15
	environment.ssr_fade_out = 2.0
	environment.ssr_depth_tolerance = 0.5
	environment.ssao_enabled = bool(profile.ssao)
	environment.ssao_radius = 2.0
	environment.ssao_intensity = 1.4
	environment.glow_enabled = bool(profile.glow)


static func _cirrus_texture() -> NoiseTexture2D:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = 31
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.006
	noise.fractal_octaves = 6
	noise.domain_warp_enabled = true
	noise.domain_warp_amplitude = 40.0
	var texture: NoiseTexture2D = NoiseTexture2D.new()
	texture.width = 1024
	texture.height = 1024
	texture.seamless = true
	texture.generate_mipmaps = true
	texture.noise = noise
	return texture
