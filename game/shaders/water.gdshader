shader_type spatial;
// Opaque lake surface so screen-space reflections can mirror the mountains.
// Depth colouring comes from the terrain heightmap instead of the depth buffer.
render_mode cull_back;

uniform sampler2D heightmap : filter_linear, repeat_disable;
uniform sampler2D wave_a : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D wave_b : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D foam_noise : filter_linear_mipmap, repeat_enable;
uniform float world_size = 24000.0;
uniform float samples = 2048.0;
uniform float water_level = 432.0;
uniform vec3 shallow : source_color = vec3(0.24, 0.42, 0.38);
uniform vec3 deep : source_color = vec3(0.03, 0.10, 0.13);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 index = (world_pos.xz + world_size * 0.5) / world_size * (samples - 1.0);
	float ground = texture(heightmap, (index + 0.5) / samples).r;
	float depth = max(water_level - ground, 0.0);
	float dist = length(world_pos - CAMERA_POSITION_WORLD);

	vec2 uv1 = world_pos.xz / 46.0 + TIME * vec2(0.018, 0.011);
	vec2 uv2 = world_pos.xz / 17.0 + TIME * vec2(-0.013, 0.021);
	vec3 n1 = texture(wave_a, uv1).rgb;
	vec3 n2 = texture(wave_b, uv2).rgb;
	NORMAL_MAP = normalize(mix(n1, n2, 0.45));
	NORMAL_MAP_DEPTH = mix(0.55, 0.12, smoothstep(150.0, 2500.0, dist));

	float foam = smoothstep(1.4, 0.2, depth) * smoothstep(0.35, 0.75, texture(foam_noise, world_pos.xz / 9.0 + TIME * 0.02).r);
	vec3 col = mix(shallow, deep, smoothstep(0.5, 14.0, depth));
	ALBEDO = mix(col, vec3(0.85, 0.88, 0.86), foam * 0.7);
	ROUGHNESS = mix(0.04, 0.6, foam);
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
