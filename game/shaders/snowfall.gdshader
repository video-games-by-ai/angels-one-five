shader_type spatial;
// Falling snow around the camera. Each flake has a fixed place in a box that
// repeats through the world, so flakes hang in the air while the aircraft flies
// through them and stretch into streaks with speed.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform, fog_disabled;

uniform vec3 box = vec3(70.0, 70.0, 70.0);
uniform vec3 drift = vec3(0.0);            // wind and fall accumulated over time
uniform vec3 fall_velocity = vec3(0.0, -2.0, 0.0);
uniform vec3 eye_velocity = vec3(0.0);
uniform vec3 sun_direction = vec3(0.0, 0.3, -1.0);
uniform float amount = 0.0;                // 0..1 share of flakes shown
uniform float exposure = 0.007;            // seconds of motion smeared into a streak

varying float fade;
varying vec2 corner;
varying float glint;

void vertex() {
	vec3 seed = VERTEX;
	corner = UV * 2.0 - 1.0;
	float pick = UV2.x;
	float radius = mix(0.022, 0.05, UV2.y);
	vec3 home = seed * box + drift;
	home.xz += sin(drift.y * 0.6 + seed.yx * 40.0) * 0.35;
	vec3 rel = mod(home - CAMERA_POSITION_WORLD + box * 0.5, box) - box * 0.5;
	vec3 centre = (VIEW_MATRIX * vec4(CAMERA_POSITION_WORLD + rel, 1.0)).xyz;
	vec3 streak = mat3(VIEW_MATRIX) * (fall_velocity - eye_velocity) * exposure;
	float len = length(streak);
	vec3 axis = len > 0.0001 ? streak / len : vec3(0.0, 1.0, 0.0);
	len = min(len, 1.6);
	vec3 side = cross(axis, normalize(centre));
	side = length(side) > 0.001 ? normalize(side) : vec3(1.0, 0.0, 0.0);
	VERTEX = centre + axis * (len * 0.5 + radius) * corner.y + side * radius * corner.x;
	float reach = length(rel) / (box.x * 0.5);
	fade = (1.0 - smoothstep(0.7, 1.0, reach)) * smoothstep(2.5, 8.0, length(rel));
	// Long streaks spread the same light thinner.
	fade *= clamp(radius * 5.0 / (len + radius * 2.0), 0.3, 1.0);
	fade *= step(pick, amount);
	glint = pow(max(dot(normalize(rel), normalize(sun_direction)), 0.0), 4.0);
	if (fade <= 0.001) {
		VERTEX = vec3(0.0, 0.0, 10.0);  // behind the camera: culled
	}
}

void fragment() {
	float soft = (1.0 - corner.x * corner.x) * (1.0 - pow(abs(corner.y), 4.0));
	ALBEDO = vec3(1.0, 0.98, 0.95) * (1.05 + glint * 1.6);
	ALPHA = clamp(soft * fade * 0.8, 0.0, 1.0);
}
