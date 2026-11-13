shader_type spatial;
// Tracer streak: bright head fading to the tail, kept at least a pixel or two
// wide at any distance so rounds stay visible far down range.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec3 color : source_color = vec3(1.0, 0.72, 0.30);
uniform float intensity = 9.0;

void vertex() {
	float dist = length((MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	VERTEX.xy *= max(1.0, dist * 0.02);
}

void fragment() {
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	float glow = smoothstep(0.0, 0.7, across) * pow(1.0 - UV.y, 1.5);
	ALBEDO = mix(color, vec3(1.0, 0.95, 0.8), smoothstep(0.6, 1.0, across) * (1.0 - UV.y)) * intensity * glow;
	ALPHA = glow;
}
