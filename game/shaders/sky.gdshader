shader_type sky;
// Golden-hour sky: warm horizon toward the sun, cool zenith, a soft sun halo
// and a thin high cirrus layer. Static, so the radiance map is built once.

uniform vec3 zenith : source_color = vec3(0.20, 0.38, 0.66);
uniform vec3 horizon : source_color = vec3(0.80, 0.80, 0.78);
uniform vec3 horizon_sun : source_color = vec3(1.0, 0.70, 0.42);
uniform vec3 ground : source_color = vec3(0.42, 0.42, 0.40);
uniform sampler2D cirrus : filter_linear_mipmap, repeat_enable;
uniform float sun_disk_strength = 40.0;

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 s = normalize(LIGHT0_DIRECTION);
	float cos_sun = dot(d, s);
	float toward_sun = max(cos_sun, 0.0);
	float up = clamp(d.y, 0.0, 1.0);

	float horizon_weight = pow(1.0 - up, 5.0);
	vec3 col = mix(zenith, horizon, horizon_weight);
	float sun_side = pow(toward_sun, 2.5);
	col = mix(col, horizon_sun, sun_side * pow(1.0 - up, 3.0) * 0.9);
	col += horizon_sun * pow(toward_sun, 24.0) * 0.55;
	col += vec3(1.0, 0.86, 0.66) * pow(toward_sun, 300.0) * 1.6;

	if (d.y > 0.0) {
		vec2 p = d.xz / (d.y + 0.06);
		float c = texture(cirrus, p * vec2(0.11, 0.035)).r;
		c = smoothstep(0.6, 0.92, c) * smoothstep(0.015, 0.2, d.y) * (1.0 - smoothstep(0.55, 0.95, d.y));
		vec3 lit = mix(vec3(1.0, 0.90, 0.80), vec3(1.0, 0.66, 0.46), sun_side) * 1.05;
		col = mix(col, lit + horizon_sun * pow(toward_sun, 10.0) * 0.7, c * 0.3);
	}

	if (!AT_CUBEMAP_PASS) {
		float disk = smoothstep(0.99975, 0.99988, cos_sun);
		col += vec3(1.0, 0.85, 0.62) * disk * sun_disk_strength;
	}

	// Below the horizon fade to haze so distant ground blends into the sky.
	if (d.y < 0.0) {
		col = mix(col, ground, smoothstep(0.0, -0.25, d.y));
	}
	COLOR = col;
}
