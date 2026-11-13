shader_type canvas_item;
// Ground under the HUD radar: a see-through dark disc with the lake and faint
// height contours of the terrain around the player. North is up.

uniform sampler2D heights : filter_linear, repeat_disable;
uniform vec2 centre_uv;           // the player's position on the map, 0..1
uniform float span_uv = 0.19;     // radar radius as a share of the map
uniform float water_level = 0.0;
uniform float contour_step = 300.0;
uniform float fill_alpha = 0.36;

void fragment() {
	vec2 d = UV * 2.0 - 1.0;
	float r = length(d);
	if (r > 1.0) {
		discard;
	}
	vec4 col = vec4(0.055, 0.047, 0.035, fill_alpha);
	vec2 uv = centre_uv + d * span_uv;
	if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
		float h = texture(heights, uv).r;
		float water = 1.0 - smoothstep(water_level + 0.5, water_level + 4.0, h);
		col.rgb = mix(col.rgb, vec3(0.55, 0.78, 0.90), water * 0.55);
		col.a += water * 0.06;
		float c = h / contour_step;
		float line = 1.0 - smoothstep(0.0, 1.3, abs(fract(c - 0.5) - 0.5) / max(fwidth(c), 1e-4));
		col.rgb = mix(col.rgb, vec3(0.98, 0.95, 0.88), line * 0.35 * (1.0 - water));
		col.a += line * 0.08 * (1.0 - water);
	}
	col.a *= 1.0 - smoothstep(0.975, 1.0, r);
	COLOR = col;
}
