shader_type spatial;
// Muzzle flame: a ragged tongue, white-hot at the root and orange toward the tip.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec3 color : source_color = vec3(1.0, 0.62, 0.22);
uniform float intensity = 7.0;

void fragment() {
	float across = abs(UV.x * 2.0 - 1.0);
	float along = UV.y;
	// Widest a little way out, pinched at the root and the tip.
	float width = sin(clamp(along * 1.25 + 0.12, 0.0, 1.0) * PI) * (0.55 + 0.45 * sin(along * 23.0 + UV.x * 5.0));
	float shape = (1.0 - smoothstep(width * 0.25, width + 0.001, across)) * (1.0 - along) * smoothstep(0.0, 0.05, along);
	vec3 hot = mix(color, vec3(1.0, 0.95, 0.82), (1.0 - smoothstep(0.0, 0.5, across)) * (1.0 - along));
	ALBEDO = hot * intensity;
	ALPHA = clamp(shape, 0.0, 1.0);
}
