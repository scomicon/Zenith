// src: Wronski 2014 volumetric fog, Hillaire 2020 atmosphere, Henyey and Greenstein 1941, Kasten and Young 1989; Horizon Shader API 0.2 translucent shadow map transmission (shadow_map_translucent, shadow_color)
// Volumetric light: RGB in-scattering and optional history depth, fixed at half of 1080p.
//
// Method: single scattering in a thin homogeneous haze, integrated by ray marching from the camera to the
// visible surface and testing each sample against the shadow map (light is added where the sample sees
// the sun or moon). This is the standard shadow-map ray-marching formulation of in-scattering
// (e.g. Wronski, "Volumetric fog: unified compute shader based solution to atmospheric scattering",
// SIGGRAPH 2014; Hillaire 2015/2020 for the integral). Own choices: the step distribution (quadratic, finer
// near the camera), the density model (exponential in height, thicker in rain) and all constants.
//
// Phase function: Henyey-Greenstein (L. Henyey, J. Greenstein, "Diffuse radiation in the Galaxy", 1941),
// a forward lobe plus a weaker backward lobe, normalised so that 1.0 is isotropic scattering.
//
// Light colour: Rayleigh extinction through the atmosphere at the light's elevation, with sea-level
// Rayleigh coefficients (5.802, 13.558, 33.1) e-6 per metre and an 8 km scale height (S. Hillaire,
// "A Scalable and Production Ready Sky and Atmosphere Rendering Technique", EGSR 2020, Table 1) and the
// air-mass formula of F. Kasten and A. Young, Applied Optics 28(22), 1989.
//
// The result is noisy by design (one jitter per pixel); compose.wgsl filters it with a 4x4 box.
//
// Sky pixels (depth 0): their ray is the view ray of the bobbed projection, taken as the homogeneous
// far-minus-near difference (translation cancels), exactly like compose.wgsl's sky reprojection. Unprojecting
// depth 0.5 instead treats the sky as a point a fraction of a block away, so the camera's view-bob translation
// swings the direction by degrees, and the forward-scatter lobe around the sun swayed with every step.
//
// Under water the sun's shafts used to come out as sharp parallel stripes (terrain steps cast hard shadow edges
// into a 16-tap march). Under water the march therefore blurs the ray (per-pixel angular jitter, which the 4x4
// box in compose then averages), filters the shadow test over a few jittered taps, adds taps, and pulls the
// lit/shadowed contrast toward its middle (light scattered in from the lit water around), same mean brightness.

override volumetric_light: f32 = 0.6;
override temporal_light: bool = false;
override colored_shadows: bool = true;

override quality_mode: u32 = 1u;     // 0 = Performance, 1 = Balanced, 2 = Quality (manifest order)
override atmospheric_fog: f32 = 1.0; // density of the shared medium (shared/fog.wgsl), as compose.wgsl reads it

const ZP_STEPS_BY_MODE: vec4<i32> = vec4<i32>(12, 24, 40, 72);  // shadow-map taps per pixel (own choices)
const ZP_AIR_RANGE: f32 = 6000.0;     // blocks: rays to distant terrain (LODs) keep scattering past the shadow map
const ZP_TAIL_STEPS: i32 = 8;         // unshadowed samples between the shadow map's end and the surface
const ZP_TAIL_VISIBILITY: f32 = 0.82; // share of the sun that reaches the medium past the shadow map (own choice)
const ZP_SUN_RADIANCE: f32 = 2.3;     // the sun's strength in the post chain's units, for the shafts (own choice)
const ZP_SIGMA_CLEAR: f32 = 0.0014;   // scattering coefficient in fair weather, per block (keeps distant terrain crisp)
const ZP_SIGMA_RAIN: f32 = 0.0055;    // ... in rain
const ZP_MAX_RANGE: f32 = 160.0;      // blocks
const ZP_SEA_LEVEL: f32 = 64.0;       // haze is densest at and below this world height
const ZP_HEIGHT_FALLOFF: f32 = 0.03;  // per block above it
const ZP_WATER_RANGE: f32 = 40.0;     // blocks, ray length cap under water
const ZP_WATER_LIGHT: vec3<f32> = vec3<f32>(0.24, 0.52, 0.56);   // shaft gain under water: balanced deep-water scatter
const ZP_WATER_BLUR_ANGLE: f32 = 0.012;   // radians: crisp underwater beam separation
const ZP_WATER_PCF_TEXELS: f32 = 2.0;     // shadow-map texels: tighter PCF radius under water
const ZP_WATER_LIT_MID: f32 = 0.30;       // restrained background scatter floor inside shadow
const ZP_WATER_LIT_PULL: f32 = 0.10;      // keep shadowed water calm so sunlit shafts stand out
const ZP_WATER_EXTRA_STEPS: i32 = 8;      // extra taps under water (the quadratic distribution is coarse far out)

fn zp_underwater_refracted_dir(light_dir: vec3<f32>) -> vec3<f32> {
    let sin_h = length(light_dir.xz);
    let cos_t = sqrt(max(1.0 - 0.5625 * sin_h * sin_h, 0.12));
    return normalize(vec3<f32>(light_dir.x * 0.75, cos_t, light_dir.z * 0.75));
}

// Caustic filament modulation and spectral Beer-Lambert absorption for underwater shafts.
fn zp_underwater_beam(world_pos: vec3<f32>, pos: vec3<f32>, t: f32, refr_light: vec3<f32>) -> vec3<f32> {
    let raw_caustic = zn_water_caustic_rgb(world_pos, refr_light, frame.time);
    let caustic_focus = mix(vec3<f32>(0.76), raw_caustic * 0.96 + vec3<f32>(0.24), smoothstep(32.0, 2.0, t));
    let water_path = max(-pos.y, 0.0) * 0.55 + t * 0.35;
    let spectral_atten = exp(-vec3<f32>(0.095, 0.032, 0.018) * min(water_path, 36.0));
    return caustic_focus * spectral_atten;
}
const ZP_PI: f32 = 3.14159265;

fn zp_hg(cos_t: f32, g: f32) -> f32 {
    let g2 = g * g;
    return (1.0 - g2) / (4.0 * ZP_PI * pow(max(1.0 + g2 - 2.0 * g * cos_t, 1e-4), 1.5));
}

// Colour of the light reaching the haze: the sun (Rayleigh-reddened near the horizon) or, at night, the moon.
fn zp_light_colour(light_elevation: f32) -> vec3<f32> {
    let mu = clamp(light_elevation, 0.0, 1.0);
    let zenith_deg = degrees(acos(mu));
    let air_mass = 1.0 / (mu + 0.50572 * pow(max(96.07995 - zenith_deg, 1e-3), -1.6364));
    let tau = vec3<f32>(0.04642, 0.10846, 0.26480) * air_mass;   // beta_R * 8000 m * air mass
    let sun = exp(-tau);
    let moon = vec3<f32>(0.28, 0.38, 0.68) * 0.032;
    let body_weights = zn_celestial_weights(frame.sun_direction.y, frame.moon_direction.y);
    return moon * body_weights.y + sun * body_weights.x;
}

// World-axes unit direction of the sky at `uv` for the bobbed projection (see the header).
fn zp_sky_ray(uv: vec2<f32>) -> vec3<f32> {
    let clip_xy = vec2<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let near = frame.projection_inverse * vec4<f32>(clip_xy, 1.0, 1.0);
    let far = frame.projection_inverse * vec4<f32>(clip_xy, 0.0, 1.0);
    let ray_view = far.xyz * near.w - near.xyz * far.w;
    let ray_world = (frame.view_inverse * vec4<f32>(ray_view, 0.0)).xyz;
    // The sign of a homogeneous difference follows the projection's w convention: orient it with the
    // plain unprojection, which always looks forward.
    let reference = view_position(uv, 0.5);
    let len = length(ray_world);
    if (len < 1e-6) {
        return normalize(reference);
    }
    return select(-ray_world, ray_world, dot(ray_world, reference) >= 0.0) / len;
}

// Shadow test of one sample; `blur` (0..1) widens it into a small jittered filter under water.
// Returns colored transmission when rays pass through stained glass or translucent ice.
fn zp_shadow_lit(pos: vec3<f32>, blur: f32, angle: f32) -> vec3<f32> {
    let sp = shadow_position(pos);
    if (!(all(sp.xy > vec2<f32>(0.0)) && all(sp.xy < vec2<f32>(1.0)))) {
        return vec3<f32>(1.0);
    }
    if (sp.z <= 0.0 || sp.z >= 1.0) {
        return vec3<f32>(smoothstep(0.15, 0.50, max(frame.eye_light_smooth.y, frame.eye_light.y)));
    }
    if (blur < 0.01) {
        let solid = textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy, sp.z);
        if (colored_shadows && solid > 0.02) {
            let trans = textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, sp.xy, sp.z);
            if (trans < 0.98) {
                let sc_dims = vec2<i32>(textureDimensions(shadow_color));
                let sc_coord = clamp(
                    vec2<i32>(sp.xy * vec2<f32>(sc_dims)),
                    vec2<i32>(0),
                    max(sc_dims - vec2<i32>(1), vec2<i32>(0))
                );
                let sc = textureLoad(shadow_color, sc_coord, 0);
                if (sc.a < 0.995) {
                    let max_c = max(max(sc.r, sc.g), max(sc.b, 1e-3));
                    let chroma = sc.rgb / max_c;
                    let tint = mix(vec3<f32>(1.0), mix(chroma, sc.rgb * 1.6, 0.25), clamp(sc.a * 1.5, 0.55, 0.98));
                    return vec3<f32>(solid) * mix(tint * 3.6, vec3<f32>(1.0), trans);
                }
            }
        }
        return vec3<f32>(solid);
    }
    let texel = 1.0 / vec2<f32>(textureDimensions(shadow_map));
    let r = ZP_WATER_PCF_TEXELS * blur;
    var sum = 0.0;
    // Two taps on opposite sides of the centre, the axis rotated per pixel and per step.
    for (var k = 0; k < 2; k = k + 1) {
        let o = vec2<f32>(cos(angle), sin(angle)) * (r * (1.0 - 2.0 * f32(k)));
        sum = sum + textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy + o * texel, sp.z);
    }
    return vec3<f32>(sum * 0.5);
}

// Under water: the former single-scattering march, unchanged (blurred ray, caustic beams, spectral absorption).
fn zp_underwater_shafts(input: PostInput, dir_in: vec3<f32>, ray_len: f32, jitter: f32, light_dir: vec3<f32>, gate: f32, d: f32) -> vec3<f32> {
    // Angular blur of the ray, perpendicular to it; the per-pixel offsets average out in compose's 4x4 box.
    let up = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(dir_in.y) > 0.99);
    let b1 = normalize(cross(up, dir_in));
    let b2 = cross(dir_in, b1);
    let spread = (zn_hash22(input.pixel + vec2<f32>(7.0, 3.0)) - vec2<f32>(0.5)) * (2.0 * ZP_WATER_BLUR_ANGLE);
    let ray_dir = normalize(dir_in + b1 * spread.x + b2 * spread.y);
    let steps = ZP_STEPS_BY_MODE[min(quality_mode, 3u)] + ZP_WATER_EXTRA_STEPS;
    let pcf_angle = jitter * 2.0 * ZP_PI;
    let n = f32(steps);
    var lit_density = vec3<f32>(0.0);
    let refr_light = zp_underwater_refracted_dir(light_dir);
    if gate > 0.001 {
        for (var i = 0; i < steps; i = i + 1) {
            let u = (f32(i) + jitter) / n;
            let t = ray_len * u * u;
            let dt = ray_len * 2.0 * u / n;
            let pos = ray_dir * t;
            let world_pos = frame.camera_position + pos;
            var lit = zp_shadow_lit(pos, 1.0, pcf_angle + f32(i) * 2.399963);
            lit = mix(lit, vec3<f32>(ZP_WATER_LIT_MID), ZP_WATER_LIT_PULL);
            lit = lit * zp_underwater_beam(world_pos, pos, t, refr_light);
            let density = min(exp(-max(world_pos.y - ZP_SEA_LEVEL, 0.0) * ZP_HEIGHT_FALLOFF), 1.5);
            lit_density = lit_density + lit * (density * dt);
        }
    }
    let sigma = mix(ZP_SIGMA_CLEAR, ZP_SIGMA_RAIN, frame.rain);
    let cos_uw = dot(ray_dir, refr_light);
    let phase = min(mix(zp_hg(cos_uw, 0.68), zp_hg(cos_uw, -0.18), 0.16) * 4.0 * ZP_PI, 4.5);
    let surface_scale = select(0.38, 0.68, d > 0.0);
    let light = zp_light_colour(light_dir.y) * gate * ZP_WATER_LIGHT;
    let raw_rgb = light * lit_density * (sigma * phase * volumetric_light * surface_scale);
    return min(raw_rgb / (1.0 + zn_luma(raw_rgb) * 1.8), vec3<f32>(2.5));
}

// Rolling ground fog: two octaves of 3D value noise drifting with the wind (own choice), 0.35..1.65.
fn zp_fog_hash(p: vec3<f32>) -> f32 {
    let q = fract(p * vec3<f32>(0.1031, 0.1030, 0.0973));
    let r = q + dot(q, q.yxz + vec3<f32>(33.33));
    return fract((r.x + r.y) * r.z);
}

fn zp_fog_noise(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(mix(zp_fog_hash(i), zp_fog_hash(i + vec3<f32>(1.0, 0.0, 0.0)), u.x),
        mix(zp_fog_hash(i + vec3<f32>(0.0, 1.0, 0.0)), zp_fog_hash(i + vec3<f32>(1.0, 1.0, 0.0)), u.x), u.y);
    let b = mix(mix(zp_fog_hash(i + vec3<f32>(0.0, 0.0, 1.0)), zp_fog_hash(i + vec3<f32>(1.0, 0.0, 1.0)), u.x),
        mix(zp_fog_hash(i + vec3<f32>(0.0, 1.0, 1.0)), zp_fog_hash(i + vec3<f32>(1.0, 1.0, 1.0)), u.x), u.y);
    return mix(a, b, u.z);
}

fn zp_fog_patches(world: vec3<f32>, t: f32) -> f32 {
    let drift = zn_water_mist_drift(frame.time) * 3.0;
    let q = vec3<f32>(world.x * 0.018 + drift.x, world.y * 0.05, world.z * 0.018 + drift.y);
    let n = zp_fog_noise(q) * 0.65 + zp_fog_noise(q * 2.7 + vec3<f32>(11.3, 4.1, 7.7)) * 0.35;
    // Fade the patches out with distance, where one step spans many of them.
    return mix(1.0, 0.35 + 1.3 * smoothstep(0.25, 0.75, n), 1.0 - smoothstep(120.0, 260.0, t));
}

// Sunlight scattered toward the camera by the shared medium (shared/fog.wgsl), single scattering:
// the integral of T(0, t) * sigma_s(t) * phase * visibility(t) dt, with T in closed form and visibility from the
// shadow map over the shadowed part. Past the shadow map the march carries on to the surface unshadowed, so
// distant terrain (LODs included) still takes the sun's glow. Returns radiance before the light's strength.
fn zp_air_shafts(ray_dir: vec3<f32>, ray_len: f32, shadow_len: f32, has_surface: bool, air_weight: f32, jitter: f32, light_dir: vec3<f32>) -> vec3<f32> {
    var medium = zn_atmo_medium(atmospheric_fog);
    medium.air = medium.air * air_weight;   // The sky's own model already holds the Rayleigh air.
    let cos_t = dot(ray_dir, light_dir);
    let mie_phase = min(zn_atmo_mie_phase(cos_t), 14.0);
    let air_phase = zn_atmo_rayleigh_phase(cos_t);
    let y0 = frame.camera_position.y;
    let steps = ZP_STEPS_BY_MODE[min(quality_mode, 3u)];
    let n = f32(steps);
    let pcf_angle = jitter * 2.0 * ZP_PI;
    var sum = vec3<f32>(0.0);
    for (var i = 0; i < steps; i = i + 1) {
        let u = (f32(i) + jitter) / n;
        let t = shadow_len * u * u;
        let dt = shadow_len * 2.0 * u / n;
        let pos = ray_dir * t;
        let world = frame.camera_position + pos;
        let lit = zp_shadow_lit(pos, 0.0, pcf_angle + f32(i) * 2.399963);
        if max(lit.r, max(lit.g, lit.b)) <= 0.0 { continue; }
        let haze = medium.haze * zn_atmo_profile(world.y, ZN_ATMO_HAZE_H);
        let ground = medium.ground * zn_atmo_profile(world.y, ZN_ATMO_GROUND_H) * zp_fog_patches(world, t);
        let air = ZN_ATMO_AIR * (medium.air * zn_atmo_profile(world.y, ZN_ATMO_AIR_H));
        let scatter = vec3<f32>((haze + ground) * mie_phase) + air * air_phase;
        let transmittance = exp(-zn_atmo_optical_depth(y0, ray_dir.y, t, medium));
        sum += lit * transmittance * scatter * dt;
    }
    // Unshadowed tail past the shadow map, toward distant terrain.
    if has_surface && ray_len > shadow_len + 1.0 {
        let tail = ray_len - shadow_len;
        let tail_steps = select(ZP_TAIL_STEPS, ZP_TAIL_STEPS * 2, quality_mode >= 3u);
        for (var i = 0; i < tail_steps; i = i + 1) {
            let u0 = (f32(i) + 0.5) / f32(tail_steps);
            let t = shadow_len + tail * u0 * u0;
            let dt = tail * 2.0 * u0 / f32(tail_steps);
            let world = frame.camera_position + ray_dir * t;
            let haze = medium.haze * zn_atmo_profile(world.y, ZN_ATMO_HAZE_H);
            let ground = medium.ground * zn_atmo_profile(world.y, ZN_ATMO_GROUND_H);
            let air = ZN_ATMO_AIR * (medium.air * zn_atmo_profile(world.y, ZN_ATMO_AIR_H));
            let scatter = vec3<f32>((haze + ground) * mie_phase) + air * air_phase;
            let transmittance = exp(-zn_atmo_optical_depth(y0, ray_dir.y, t, medium));
            sum += ZP_TAIL_VISIBILITY * transmittance * scatter * dt;
        }
    }
    let raw = zp_light_colour(light_dir.y) * (ZP_SUN_RADIANCE * volumetric_light / 0.6) * sum;
    // A soft shoulder keeps the glow around a low sun from clipping before the tone curve.
    return raw / (1.0 + zn_luma(raw) * 0.18);
}

fn post(input: PostInput) -> vec4<f32> {
    // Overworld sunlight/moonlight shafts have no meaning in the End or Nether.
    // Their synthetic celestial directions otherwise wash both sky and terrain grey.
    if (volumetric_light <= 0.0 || frame.has_shadow == 0u || frame.dimension != 0) {
        return vec4<f32>(0.0);
    }
    let uv = input.uv;
    let d = depth_at(uv);

    let light_dir = frame.light_direction;
    let light_mask = smoothstep(0.0, 0.15, light_dir.y);
    if (light_mask <= 0.0) {
        return vec4<f32>(0.0);
    }

    // The ray: to the surface (any distance: the march past the shadow map carries on unshadowed), or through the
    // sky to the end of the shadow map.
    var ray_dir: vec3<f32>;
    var ray_len = ZP_AIR_RANGE;
    var surface_dist = 0.0;
    if (d > 0.0) {
        let p = view_position(uv, d);
        let len = length(p);
        surface_dist = len;
        ray_dir = p / max(len, 1e-3);
        ray_len = min(len, ray_len);
    } else {
        ray_dir = zp_sky_ray(uv);
        ray_len = ZP_MAX_RANGE;
        if frame.eye_in == 0u {
            // The sky's ray runs on through the haze (shared/fog.wgsl), as compose.wgsl's haze over the sky does.
            ray_len = zn_atmo_sky_distance(ray_dir);
            surface_dist = ray_len;
        }
    }
    // Under water the haze is thick: shafts fade within a few tens of blocks.
    let water = select(0.0, 1.0, frame.eye_in == 1u);
    ray_len = min(ray_len, mix(ZP_AIR_RANGE, ZP_WATER_RANGE, water));
    let shadow_len = min(ray_len, frame.shadow_distance * 0.95);
    if (ray_len < 0.5) {
        return vec4<f32>(0.0);
    }

    let eye_sky = max(frame.eye_light_smooth.y, frame.eye_light.y);
    let vis_gate = 1.0 - clamp(max(frame.blindness, frame.darkness), 0.0, 1.0);
    let cave_gate = max(smoothstep(0.01, 0.20, eye_sky), select(0.0, 1.0, d <= 0.0))
        * vis_gate * select(0.0, 1.0, frame.eye_in <= 1u);

    var accumulate = false;
    if temporal_light && d > 0.0 && surface_dist <= ZP_MAX_RANGE && frame.eye_in == 0u {
        let surface = surface_at(vec2<i32>(input.uv * frame.resolution));
        accumulate = surface.present && surface.data <= 0.5;
    }
    let jitter = zn_ign(input.pixel, select(0u, frame.frame_index % 64u, accumulate));
    var rgb = vec3<f32>(0.0);
    if (water > 0.5) {
        rgb = zp_underwater_shafts(input, ray_dir, shadow_len, jitter, light_dir, light_mask * cave_gate, d);
    } else if (cave_gate > 0.001) {
        rgb = zp_air_shafts(ray_dir, ray_len, shadow_len, surface_dist > 0.0, select(0.0, 1.0, d > 0.0), jitter, light_dir) * (light_mask * cave_gate);
    }
    if !accumulate {
        return vec4<f32>(rgb, 0.0);
    }
    let point = ray_dir * surface_dist;
    let uv_prev = zp_previous_uv(point);
    var filtered = rgb;
    if all(uv_prev >= vec2<f32>(0.0)) && all(uv_prev < vec2<f32>(1.0)) {
        let dims = vec2<i32>(textureDimensions(vlight_previous));
        let prior = textureLoad(vlight_previous, min(vec2<i32>(uv_prev * vec2<f32>(dims)), dims - 1), 0);
        filtered = zp_history_rgb(prior, rgb, length(point + frame.camera_motion), 0.035, 14.0);
    }
    return vec4<f32>(filtered, surface_dist);
}
