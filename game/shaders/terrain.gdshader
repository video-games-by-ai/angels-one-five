shader_type spatial;
// Heightmap-displaced terrain tiles. Every LOD samples the same heightmap, normals
// are rebuilt per pixel, and pre-computed mountain shadows tint the sun light.
render_mode cull_back;

uniform sampler2D heightmap : filter_linear, repeat_disable;
uniform sampler2D masks : filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_large : filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_detail : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float world_size = 24000.0;
uniform float samples = 2048.0;
uniform float water_level = 432.0;
uniform float skirt_depth = 60.0;
uniform float light_scale = 1.0;

uniform vec3 grass_low : source_color = vec3(0.36, 0.43, 0.16);
uniform vec3 grass_dry : source_color = vec3(0.55, 0.53, 0.27);
uniform vec3 meadow : source_color = vec3(0.45, 0.52, 0.20);
uniform vec3 forest : source_color = vec3(0.29, 0.35, 0.18);
uniform vec3 alpine : source_color = vec3(0.46, 0.44, 0.30);
uniform vec3 rock : source_color = vec3(0.42, 0.40, 0.38);
uniform vec3 rock_dark : source_color = vec3(0.27, 0.26, 0.26);
uniform vec3 snow : source_color = vec3(0.93, 0.94, 0.97);
uniform vec3 shore : source_color = vec3(0.52, 0.49, 0.42);

varying vec3 world_pos;
varying float sun_visibility;

vec2 height_uv(vec2 xz) {
	vec2 index = (xz + world_size * 0.5) / world_size * (samples - 1.0);
	return (index + 0.5) / samples;
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 uv = height_uv(wp.xz);
	float h = textureLod(heightmap, uv, 0.0).r;
	VERTEX.y = h - COLOR.r * skirt_depth;
	world_pos = vec3(wp.x, VERTEX.y, wp.z);
	sun_visibility = textureLod(masks, uv, 0.0).r;
}

vec3 terrain_normal(vec2 uv) {
	float px = 1.0 / samples;
	float texel = world_size / (samples - 1.0);
	float hl = texture(heightmap, uv - vec2(px, 0.0)).r;
	float hr = texture(heightmap, uv + vec2(px, 0.0)).r;
	float hd = texture(heightmap, uv - vec2(0.0, px)).r;
	float hu = texture(heightmap, uv + vec2(0.0, px)).r;
	return normalize(vec3(hl - hr, 2.0 * texel, hd - hu));
}

void fragment() {
	vec2 uv = height_uv(world_pos.xz);
	vec3 n = terrain_normal(uv);
	vec4 m = texture(masks, uv);
	float h = world_pos.y;
	float dist = length(world_pos - CAMERA_POSITION_WORLD);

	float n_large = texture(noise_large, world_pos.xz / 1800.0).r;
	float n_mid = texture(noise_large, world_pos.xz / 260.0).r;
	float n_small = texture(noise_large, world_pos.xz / 31.0).r;
	float slope = 1.0 - n.y;

	// Grass that dries and yellows with altitude, with soft patchiness.
	vec3 col = mix(grass_low, grass_dry, smoothstep(0.35, 0.8, n_large) * 0.6);
	col = mix(col, alpine, smoothstep(1350.0, 1800.0, h + (n_mid - 0.5) * 250.0));
	col = mix(col, meadow, m.a * 0.7);

	// Hay meadows on the flat valley floor: long plots following the valley,
	// each mown or grown differently, with darker field margins.
	vec2 fp = mat2(vec2(0.96, 0.28), vec2(-0.28, 0.96)) * world_pos.xz + (n_large - 0.5) * 90.0;
	vec2 plot_size = vec2(95.0, 260.0);
	vec2 plot = floor(fp / plot_size);
	float plot_hash = fract(sin(dot(plot, vec2(127.1, 311.7))) * 43758.5453);
	vec2 plot_edge = abs(fract(fp / plot_size) - 0.5) * plot_size;
	float margin = (1.0 - smoothstep(1.2, 2.6, min(plot_edge.x, plot_edge.y))) * step(0.55, fract(plot_hash * 7.31));
	vec3 plot_col = mix(vec3(0.33, 0.42, 0.14), vec3(0.62, 0.58, 0.30), plot_hash * plot_hash);
	plot_col = mix(plot_col, vec3(0.42, 0.50, 0.17), step(0.82, plot_hash));
	float fields = m.a * (1.0 - smoothstep(0.0, 0.035, 1.0 - n.y)) * (1.0 - smoothstep(water_level + 70.0, water_level + 110.0, h));
	col = mix(col, plot_col * (0.92 + 0.16 * n_small), fields * 0.75);
	col = mix(col, vec3(0.20, 0.25, 0.11), fields * margin * 0.45);

	float forest_amount = smoothstep(0.18, 0.55, m.b + (n_mid - 0.5) * 0.25);
	// Valley-floor copses are drawn as real trees; only tint the grass beneath them.
	forest_amount *= mix(1.0, 0.3, m.a);
	float canopy = texture(noise_large, world_pos.xz / 11.0).r;
	col = mix(col, forest * (0.85 + 0.35 * n_small) * (0.85 + 0.35 * canopy), forest_amount);

	// Rock on steep faces and high crests; banded strata on cliffs.
	float strata = 0.5 + 0.5 * sin(h * 0.07 + n_mid * 6.0);
	vec3 rock_col = mix(rock_dark, rock, 0.35 + 0.65 * strata * n_small);
	float rock_amount = smoothstep(0.30, 0.46, slope + (n_mid - 0.5) * 0.18);
	rock_amount = max(rock_amount, smoothstep(2350.0, 2700.0, h) * smoothstep(0.08, 0.22, slope));
	col = mix(col, rock_col, rock_amount);

	// Snow: altitude with noise, slides off steep rock.
	float snow_line = 2150.0 + (n_large - 0.5) * 420.0 - (1.0 - sun_visibility) * 120.0;
	float snow_amount = smoothstep(snow_line, snow_line + 140.0, h) * (1.0 - smoothstep(0.38, 0.58, slope + (n_small - 0.5) * 0.1));
	col = mix(col, snow, snow_amount);

	// Gravel shore around the lake.
	col = mix(col, shore, 1.0 - smoothstep(water_level + 1.0, water_level + 6.0, h));

	// Concave ground (gullies, valley floors) is a little darker.
	col *= clamp(1.15 - (m.g - 0.5) * 1.2, 0.7, 1.15);
	col *= 0.86 + 0.28 * n_small;

	// Close-up detail normal, faded out with distance.
	float detail_fade = 1.0 - smoothstep(300.0, 2200.0, dist);
	vec3 detail = texture(noise_detail, world_pos.xz / 24.0).xyz * 2.0 - 1.0;
	vec3 detail2 = texture(noise_detail, world_pos.xz / 170.0).xyz * 2.0 - 1.0;
	vec3 bump = (detail.xzy * 0.35 + detail2.xzy * 0.5) * detail_fade * (0.4 + rock_amount + forest_amount * 0.6);
	n = normalize(n + vec3(bump.x, 0.0, bump.z));

	ALBEDO = col;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	ROUGHNESS = mix(0.95, 0.55, snow_amount);
	SPECULAR = mix(0.2, 0.5, snow_amount);
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	// Soft wrap so grazing golden-hour light does not crush the shaded slopes.
	float wrap = clamp((dot(NORMAL, LIGHT) + 0.15) / 1.15, 0.0, 1.0);
	DIFFUSE_LIGHT += mix(ndl, wrap, 0.35) * ATTENUATION * LIGHT_COLOR * sun_visibility * light_scale / PI;
}
