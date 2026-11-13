shader_type spatial;
// Spinning propeller blur: faint dark disc, streaks and a yellow tip ring.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform float spin = 0.0;
uniform float opacity = 1.0;
uniform vec3 tip_color : source_color = vec3(0.95, 0.78, 0.1);

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	if (r > 1.0 || r < 0.18) {
		discard;
	}
	float a = atan(p.y, p.x);
	float streak = 0.5 + 0.5 * sin(a * 4.0 + spin);
	float body = 0.10 + 0.08 * streak;
	float tip = smoothstep(0.86, 0.9, r) * (1.0 - smoothstep(0.97, 1.0, r));
	vec3 col = mix(vec3(0.02), tip_color, tip);
	ALBEDO = col;
	ALPHA = (body * 0.8 * (1.0 - smoothstep(0.9, 1.0, r)) + tip * 0.12) * opacity;
}
