shader_type spatial;
// Conifer needles: darker toward the trunk and base, per-tree tint, a gentle
// sway and the same pre-computed mountain shadow as the terrain.
render_mode cull_disabled;

uniform vec3 needle_dark : source_color = vec3(0.06, 0.11, 0.07);
uniform vec3 needle_light : source_color = vec3(0.20, 0.30, 0.15);
uniform vec3 needle_dry : source_color = vec3(0.27, 0.30, 0.16);
uniform float fresh_snow_scale = 0.0;   // 1 while the snow showers are on
uniform float snow_line = 100000.0;     // trees near and above this height carry snow

varying float sun_visibility;
varying float tint;
varying float height_t;
varying float radial;
varying float fresh_snow;

void vertex() {
	sun_visibility = INSTANCE_CUSTOM.a;
	tint = INSTANCE_CUSTOM.r;
	height_t = clamp(VERTEX.y / 22.0, 0.0, 1.0);
	radial = clamp(length(VERTEX.xz) / 3.5, 0.0, 1.0);
	vec3 world_origin = MODEL_MATRIX[3].xyz;
	fresh_snow = max(INSTANCE_CUSTOM.b * fresh_snow_scale, smoothstep(snow_line - 260.0, snow_line + 40.0, world_origin.y) * 0.9);
	float sway = sin(TIME * 1.1 + world_origin.x * 0.05 + world_origin.z * 0.03) * 0.03;
	VERTEX.x += sway * VERTEX.y * height_t;
}

void fragment() {
	vec3 col = mix(needle_dark, needle_light, radial * 0.7 + height_t * 0.3);
	col = mix(col, needle_dry, tint * 0.35);
	col *= 0.8 + 0.4 * tint;
	// Fresh snow settles on the branch tips and the upper boughs.
	float frost = fresh_snow * (0.2 + 0.5 * radial) * (0.55 + 0.45 * height_t) * (0.75 + 0.5 * tint);
	col = mix(col, vec3(0.90, 0.92, 0.96), clamp(frost, 0.0, 0.7));
	ALBEDO = col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.15;
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT) * 0.6 + 0.4, 0.0, 1.0);
	DIFFUSE_LIGHT += ndl * ATTENUATION * LIGHT_COLOR * sun_visibility / PI;
}
