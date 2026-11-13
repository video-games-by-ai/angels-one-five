// Snow showers shared by every shader that needs them: soft vertical columns of
// falling snow under a cloud. The same volumes veil the view, shade themselves
// against the sun and mark where fresh snow lies on the ground.
// Define SQUALL_STEPS before including to use squall_fog().

const int SQUALLS = 4;

uniform vec4 squalls[4];                       // xz centre, radius (m), strength 0..1
uniform sampler2D squall_noise : filter_linear, repeat_enable;
uniform float squall_top = 2050.0;             // cloud base the snow falls from
uniform vec2 squall_wind = vec2(-0.25, -0.97); // unit direction the showers travel
uniform float squall_extinction = 0.0028;      // 1/m at full density
uniform vec3 squall_ambient : source_color = vec3(0.62, 0.67, 0.76);
uniform vec3 squall_sun : source_color = vec3(1.0, 0.84, 0.62);

// Density of one shower column at a point. `warp` bends its outline (1 = round).
float squall_column(int i, vec3 p, float warp) {
	vec2 o = (p.xz - squalls[i].xy) / squalls[i].z;
	float f = max(1.0 - dot(o, o) * warp, 0.0);
	return squalls[i].w * f * f * (1.0 - smoothstep(squall_top - 400.0, squall_top, p.y));
}

// Fresh snow on the ground, 0..1: under each shower and in the trail it left
// behind as it moved with the wind.
float squall_ground(vec2 xz) {
	if (squalls[0].w + squalls[1].w + squalls[2].w + squalls[3].w <= 0.0) {
		return 0.0;
	}
	float lump = textureLod(squall_noise, xz / 1700.0 + 0.37, 0.0).r;
	float g = 0.0;
	for (int i = 0; i < SQUALLS; i++) {
		vec2 o = (xz - squalls[i].xy) / squalls[i].z;
		float along = dot(o, squall_wind);
		vec2 across = o - squall_wind * along;
		along *= along < 0.0 ? 0.62 : 1.0;
		float r = length(across + squall_wind * along) + (lump - 0.5) * 0.8;
		g = max(g, squalls[i].w * (1.0 - smoothstep(0.25, 1.2, r)));
	}
	return g;
}

#ifdef SQUALL_STEPS
// Light the showers scatter toward the eye along a ray of length `dist`.
// rgb is premultiplied scattered light, a is the opacity of the veil.
vec4 squall_fog(vec3 eye, vec3 dir, float dist, float jitter, vec3 sun_dir) {
	vec3 light = vec3(0.0);
	float trans = 1.0;
	float a = dot(dir.xz, dir.xz);
	for (int i = 0; i < SQUALLS; i++) {
		if (squalls[i].w <= 0.001) {
			continue;
		}
		float radius = squalls[i].z * 1.25;
		vec2 oc = eye.xz - squalls[i].xy;
		float c = dot(oc, oc) - radius * radius;
		float t0 = 0.0;
		float t1 = dist;
		if (a > 0.000001) {
			float b = dot(oc, dir.xz);
			float disc = b * b - a * c;
			if (disc <= 0.0) {
				continue;
			}
			float root = sqrt(disc);
			t0 = max(t0, (-b - root) / a);
			t1 = min(t1, (-b + root) / a);
		} else if (c > 0.0) {
			continue;
		}
		// Nothing falls above the cloud base.
		if (dir.y > 0.00001) {
			t1 = min(t1, (squall_top - eye.y) / dir.y);
		} else if (dir.y < -0.00001) {
			t0 = max(t0, (squall_top - eye.y) / dir.y);
		} else if (eye.y > squall_top) {
			continue;
		}
		if (t1 <= t0) {
			continue;
		}
		float dt = (t1 - t0) / float(SQUALL_STEPS);
		for (int k = 0; k < SQUALL_STEPS; k++) {
			vec3 p = eye + dir * (t0 + (float(k) + 0.25 + jitter * 0.5) * dt);
			// Lumpy outline (two slow waves) and slanted fall streaks.
			float lump = sin(dot(p.xz, vec2(0.0023, 0.0012)) + float(i) * 1.7) * sin(dot(p.xz, vec2(-0.0011, 0.0026)));
			float streak = textureLod(squall_noise, (p.xz - squall_wind * p.y * 0.55) / 640.0, 0.0).r;
			float d = squall_column(i, p, 1.0 + lump * 0.35) * mix(0.55, 1.35, streak);
			if (d <= 0.0) {
				continue;
			}
			float absorb = 1.0 - exp(-d * squall_extinction * dt);
			// Sunlit on the side facing the sun, cool and shaded deep inside.
			float lit = exp(-squall_column(i, p + sun_dir * 450.0, 1.0) * 2.2);
			light += trans * absorb * (squall_ambient + squall_sun * lit * 0.85);
			trans *= 1.0 - absorb;
		}
	}
	// The low sun still glows through the falling snow.
	float toward_sun = max(dot(dir, sun_dir), 0.0);
	light += squall_sun * (pow(toward_sun, 5.0) * 0.5 + pow(toward_sun, 40.0) * 0.8) * (1.0 - trans);
	return vec4(light, 1.0 - trans);
}
#endif
