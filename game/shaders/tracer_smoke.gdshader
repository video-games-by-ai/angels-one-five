shader_type spatial;
// The thin smoke a tracer leaves along its path: a pale, broken wisp behind the
// round that widens and thins out toward its end. Drawn as a ribbon facing the
// camera. It fades out close to the eye so the player's own fire never hazes
// the view.
//
// INSTANCE_CUSTOM is (streak length (unused here), smoke length in metres, a
// random number, brightness 0..1).
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;

uniform vec3 color : source_color = vec3(0.93, 0.92, 0.9);
uniform float density = 0.2;
uniform float width = 0.3;           // half-width in metres at the round, up close
uniform float min_width = 0.0022;    // and at range, as a share of the screen height
uniform float near_from = 14.0;      // metres from the eye: invisible nearer than this
uniform float near_to = 70.0;        // and full strength from here

varying float seed;
varying float brightness;
varying float metres;
varying float reach;

void vertex() {
	seed = INSTANCE_CUSTOM.z;
	brightness = INSTANCE_CUSTOM.w;
	metres = INSTANCE_CUSTOM.y;
	vec3 head = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 along = normalize((MODELVIEW_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz);
	vec3 at = head + along * VERTEX.z * metres;
	vec3 side = cross(along, at);
	side /= max(length(side), 0.0001);
	float spread = 1.0 + VERTEX.z * 2.6;   // it widens as it ages
	VERTEX = at + side * VERTEX.x * max(width * spread, length(at) * min_width / PROJECTION_MATRIX[1][1]);
	NORMAL = vec3(0.0, 0.0, 1.0);
	reach = length(at);
}

float hash(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

float noise(float x) {
	float i = floor(x);
	float f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(hash(i), hash(i + 1.0), f);
}

void fragment() {
	float across = abs(UV.x * 2.0 - 1.0);
	float along = UV.y;
	// Broken into puffs every few metres, different for every round.
	float place = along * metres;
	float puffs = 0.45 + 0.75 * noise(place * 0.22 + seed * 57.0) * noise(place * 0.61 + seed * 13.0 + 4.0);
	float body = exp(-across * across * 3.2);
	float fade = smoothstep(0.0, 0.1, along) * pow(1.0 - along, 1.25);
	ALBEDO = color;
	ALPHA = clamp(body * fade * puffs * density * brightness * smoothstep(near_from, near_to, reach), 0.0, 1.0);
}
