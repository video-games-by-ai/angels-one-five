shader_type spatial;
// One cloud puff: camera-facing, lit by its position inside the cloud (sunny
// domes, cool shaded bases), bright rims when looking toward the sun, soft
// intersections with terrain and a fade when the camera gets close.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

#define SQUALL_STEPS 4
#include "squall.gdshaderinc"

uniform sampler2D puff_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture;
uniform vec3 sun_direction = vec3(0.0, 0.3, -1.0);
uniform vec3 sun_color : source_color = vec3(1.0, 0.86, 0.68);
uniform vec3 shade_color : source_color = vec3(0.52, 0.55, 0.66);
uniform vec3 base_color : source_color = vec3(0.42, 0.42, 0.50);
uniform float opacity = 0.85;

varying vec3 rel;
varying float seed;
varying vec3 centre_world;
varying float puff_size;
varying vec4 veil;

void vertex() {
	rel = INSTANCE_CUSTOM.xyz;
	seed = INSTANCE_CUSTOM.w;
	centre_world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	puff_size = length(MODEL_MATRIX[0].xyz);
	// Snow showers between the camera and this puff.
	vec3 to_puff = centre_world - CAMERA_POSITION_WORLD;
	veil = squall_fog(CAMERA_POSITION_WORLD, normalize(to_puff), length(to_puff), 0.5, normalize(sun_direction));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(puff_size, 0.0, 0.0, 0.0), vec4(0.0, puff_size, 0.0, 0.0), vec4(0.0, 0.0, puff_size, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	if (r > 1.0) {
		discard;
	}
	float angle = seed * 6.2831;
	mat2 rot = mat2(vec2(cos(angle), sin(angle)), vec2(-sin(angle), cos(angle)));
	vec2 nuv = rot * p * 0.5 + seed * 3.1;
	float n = texture(puff_noise, nuv).r * 0.6 + texture(puff_noise, nuv * 2.3 + 0.4).r * 0.4;
	float shape = smoothstep(1.0, 0.25, r + (n - 0.5) * 0.55);
	float alpha = shape * opacity;

	// Lighting from the puff's place in the cloud plus the pixel's place in the puff.
	vec3 view_dir = normalize(VERTEX);
	vec3 local_normal = normalize(rel + vec3(0.0, 0.45, 0.0));
	vec3 world_view = (INV_VIEW_MATRIX * vec4(view_dir, 0.0)).xyz;
	vec3 sun = normalize(sun_direction);
	vec3 pixel_dir = normalize((INV_VIEW_MATRIX * vec4(p.x, p.y, 0.6, 0.0)).xyz);
	float facing = dot(normalize(local_normal * 0.7 + pixel_dir * 0.3), sun) * 0.5 + 0.5;
	float height = rel.y * 0.5 + 0.5;
	vec3 col = mix(shade_color, sun_color * 1.25, smoothstep(0.25, 0.95, facing));
	col *= mix(0.72, 1.06, smoothstep(0.0, 0.8, height + p.y * 0.15));
	col = mix(base_color, col, smoothstep(0.0, 0.35, height));
	float toward_sun = pow(max(dot(world_view, sun), 0.0), 6.0);
	col += sun_color * toward_sun * (1.0 - shape) * 1.6;
	col *= 0.9 + 0.2 * n;

	// Soft intersection with the terrain behind.
	float depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_dist = -scene.z / scene.w;
	alpha *= clamp((scene_dist - (-VERTEX.z)) / 80.0, 0.0, 1.0);
	// Fade puffs that are almost touching the camera.
	alpha *= smoothstep(puff_size * 0.25, puff_size * 1.1, length(VERTEX));

	ALBEDO = col * (1.0 - veil.a) + veil.rgb;
	// Deep inside a shower a cloud is white on white: let it dissolve.
	alpha *= 1.0 - smoothstep(0.35, 0.9, veil.a);
	ALPHA = clamp(alpha, 0.0, 1.0);
}
