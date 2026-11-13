shader_type spatial;
// Tracer round: a ribbon turned to face the camera, with a white-hot core inside
// a coloured glow that tapers and fades toward the tail, and a small sparkling
// point at the head so a round is seen even when it flies straight away from
// the eye. Both keep a few pixels of width at any range and any zoom.
//
// Per round: COLOR is its tint; INSTANCE_CUSTOM is (streak length in metres,
// smoke length (unused here), a random number, brightness 0..1).
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;

uniform float glow_energy = 2.6;     // the coloured glow: bright enough to bloom, not so bright it turns white
uniform float core_energy = 4.6;     // the white-hot centre
uniform float width = 0.42;          // half-width of the glow in metres, up close
uniform float min_width = 0.012;     // and at range, as a share of the screen height

varying vec3 tint;
varying float kind;        // 0 = streak, 1 = head point
varying float seed;
varying float brightness;

void vertex() {
	tint = COLOR.rgb;
	kind = UV2.x;
	seed = INSTANCE_CUSTOM.z;
	brightness = INSTANCE_CUSTOM.w;
	vec3 head = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float keep = min_width / PROJECTION_MATRIX[1][1];   // metres per metre of distance
	if (kind < 0.5) {
		vec3 along = normalize((MODELVIEW_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz);   // toward the tail
		vec3 at = head + along * VERTEX.z * INSTANCE_CUSTOM.x;
		vec3 side = cross(along, at);
		side /= max(length(side), 0.0001);
		VERTEX = at + side * VERTEX.x * max(width, length(at) * keep);
	} else {
		float size = max(0.9, length(head) * keep * 1.7);
		VERTEX = head + vec3(VERTEX.xy * size, 0.0);
	}
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	vec3 white = mix(tint, vec3(1.0, 0.96, 0.86), 0.62);   // the hot centre keeps a little of the round's colour
	float flicker = 0.86 + 0.14 * sin(TIME * 47.0 + seed * 90.0);
	if (kind < 0.5) {
		float across = abs(UV.x * 2.0 - 1.0);
		float along = UV.y;
		float taper = mix(1.0, 0.4, along);
		float core = exp(-pow(across / (0.2 * taper), 2.0));
		float glow = exp(-pow(across / (0.55 * taper), 2.0));
		// Burning unevenly: the tail breaks up a little.
		float burn = 0.8 + 0.2 * sin(along * 31.0 - TIME * 55.0 + seed * 40.0);
		float fade = pow(1.0 - along, 1.6) * smoothstep(0.0, 0.03, along) * burn;
		ALBEDO = (tint * glow * glow_energy + white * core * core_energy) * flicker;
		ALPHA = clamp(fade * brightness, 0.0, 1.0);
	} else {
		vec2 p = UV * 2.0 - 1.0;
		float r2 = dot(p, p);
		float core = exp(-r2 * 26.0);
		float glow = exp(-r2 * 7.0) * 0.45;
		// Four fine rays, turning slowly: the sparkle.
		float spin = seed * 6.28 + TIME * 3.0;
		vec2 q = vec2(p.x * cos(spin) - p.y * sin(spin), p.x * sin(spin) + p.y * cos(spin));
		float rays = (exp(-abs(q.x) * 30.0) * exp(-abs(q.y) * 3.2) + exp(-abs(q.y) * 30.0) * exp(-abs(q.x) * 3.2)) * 0.5;
		ALBEDO = (tint * (glow + rays) * glow_energy * 1.4 + white * core * core_energy) * flicker * (1.0 - smoothstep(0.8, 1.0, r2));
		ALPHA = clamp(brightness, 0.0, 1.0);
	}
}
