shader_type spatial;
// Natural-metal skin without textures: panel-to-panel tone and roughness changes,
// thin panel seams, rivet rows, exhaust staining and a hit flash.
render_mode cull_back;

uniform vec3 base_color : source_color = vec3(0.74, 0.76, 0.78);
uniform float metallic = 0.92;
uniform float roughness = 0.30;
uniform float seam_strength = 0.3;
uniform float stain_strength = 1.0;
uniform float hit_flash = 0.0;
uniform float scorch = 0.0;

varying vec3 obj_pos;
varying vec3 obj_normal;

float hash(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

float seam(float coord, float size) {
	float d = abs(fract(coord / size + 0.5) - 0.5) * size;
	float w = fwidth(coord) * 0.75 + 0.0035;
	return 1.0 - smoothstep(w, w * 2.0, d);
}

void vertex() {
	obj_pos = VERTEX;
	obj_normal = NORMAL;
}

void fragment() {
	vec3 p = obj_pos;
	vec3 an = abs(obj_normal);
	// Panels: stations along the length, plus spanwise or vertical splits.
	vec3 cell_size = vec3(0.62, 0.48, 0.66);
	vec3 cell = floor(p / cell_size);
	float tone = hash(cell + 13.0);
	float lines = seam(p.z, cell_size.z);
	if (an.y > 0.55) {
		lines = max(lines, seam(p.x, cell_size.x));
	} else {
		lines = max(lines, seam(p.y, cell_size.y) * step(0.4, an.x));
	}
	// Rivet rows just inside each seam.
	float rivet_row = seam(p.z + 0.035, cell_size.z) * (0.5 + 0.5 * sin(p.x * 260.0 + p.y * 260.0));
	float rivets = smoothstep(0.6, 1.0, rivet_row) * 0.25;

	vec3 col = base_color * (0.95 + 0.08 * tone);
	col *= 1.0 - lines * seam_strength * 0.45 - rivets * 0.2;

	// Exhaust staining streaming back along the fuselage sides.
	float side = smoothstep(0.24, 0.4, abs(p.x)) * step(0.5, an.x);
	float band = smoothstep(-0.12, 0.08, p.y) * (1.0 - smoothstep(0.32, 0.5, p.y));
	float run = smoothstep(-3.3, -2.9, p.z) * (1.0 - smoothstep(-2.6, 1.4, p.z));
	float streak = 0.6 + 0.4 * sin(p.y * 70.0 + p.z * 3.0);
	float stain = side * band * run * streak * stain_strength;
	col = mix(col, vec3(0.08, 0.07, 0.06), stain * 0.75);
	col = mix(col, vec3(0.05, 0.04, 0.035), scorch);

	ALBEDO = col;
	METALLIC = mix(metallic, 0.2, stain * 0.8 + scorch);
	ROUGHNESS = clamp(roughness + (tone - 0.5) * 0.14 + lines * 0.18 + stain * 0.4 + scorch * 0.5, 0.05, 1.0);
	EMISSION = vec3(1.0, 0.55, 0.2) * hit_flash * 2.5;
}
