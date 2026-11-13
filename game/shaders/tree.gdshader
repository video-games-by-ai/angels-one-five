shader_type spatial;
// Conifer needles: darker toward the trunk and base, per-tree tint, a gentle
// sway and the same pre-computed mountain shadow as the terrain.
render_mode cull_disabled;

uniform vec3 needle_dark : source_color = vec3(0.06, 0.11, 0.07);
uniform vec3 needle_light : source_color = vec3(0.20, 0.30, 0.15);
uniform vec3 needle_dry : source_color = vec3(0.27, 0.30, 0.16);

varying float sun_visibility;
varying float tint;
varying float height_t;
varying float radial;

void vertex() {
	sun_visibility = INSTANCE_CUSTOM.a;
	tint = INSTANCE_CUSTOM.r;
	height_t = clamp(VERTEX.y / 22.0, 0.0, 1.0);
	radial = clamp(length(VERTEX.xz) / 3.5, 0.0, 1.0);
	vec3 world_origin = MODEL_MATRIX[3].xyz;
	float sway = sin(TIME * 1.1 + world_origin.x * 0.05 + world_origin.z * 0.03) * 0.03;
	VERTEX.x += sway * VERTEX.y * height_t;
}

void fragment() {
	vec3 col = mix(needle_dark, needle_light, radial * 0.7 + height_t * 0.3);
	col = mix(col, needle_dry, tint * 0.35);
	col *= 0.8 + 0.4 * tint;
	ALBEDO = col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.15;
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT) * 0.6 + 0.4, 0.0, 1.0);
	DIFFUSE_LIGHT += ndl * ATTENUATION * LIGHT_COLOR * sun_visibility / PI;
}
