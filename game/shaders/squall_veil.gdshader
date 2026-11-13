shader_type spatial;
// Full-screen pass that lays the snow showers over the scene: for every pixel it
// walks the view ray through the shower columns up to whatever is drawn there.
// Drawn before the other transparent things, so tracers and effects stay crisp.
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, skip_vertex_transform, fog_disabled, blend_mix;

#define SQUALL_STEPS 6
#include "squall.gdshaderinc"

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 sun_direction = vec3(0.0, 0.3, -1.0);

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	float depth = texture(depth_texture, SCREEN_UV).r;
	vec2 ndc = SCREEN_UV * 2.0 - 1.0;
	vec4 front = INV_PROJECTION_MATRIX * vec4(ndc, 1.0, 1.0);
	vec3 view_dir = normalize(front.xyz / front.w);
	float dist = 60000.0;
	if (depth > 0.000001) {
		vec4 scene = INV_PROJECTION_MATRIX * vec4(ndc, depth, 1.0);
		dist = min((scene.z / scene.w) / view_dir.z, dist);
	}
	vec3 dir = normalize((INV_VIEW_MATRIX * vec4(view_dir, 0.0)).xyz);
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	vec4 fog = squall_fog(CAMERA_POSITION_WORLD, dir, dist, jitter, normalize(sun_direction));
	ALBEDO = fog.rgb / max(fog.a, 0.0001);
	ALPHA = fog.a;
}
