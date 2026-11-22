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

const ZP_STEPS_BY_MODE: vec3<i32> = vec3<i32>(8, 16, 24);   // shadow-map taps per pixel (own choices)
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

    // The ray: to the surface, or to the end of the range through the sky.
    var ray_dir: vec3<f32>;
    var ray_len = ZP_MAX_RANGE;
    var surface_dist = 0.0;
    if (d > 0.0) {
        let p = view_position(uv, d);
        let len = length(p);
        surface_dist = len;
        ray_dir = p / max(len, 1e-3);
        ray_len = min(len, ray_len);
    } else {
        ray_dir = zp_sky_ray(uv);
    }
    // Under water the haze is thick: shafts fade within a few tens of blocks.
    let water = select(0.0, 1.0, frame.eye_in == 1u);
    ray_len = min(ray_len, mix(ZP_MAX_RANGE, ZP_WATER_RANGE, water));
    ray_len = min(ray_len, frame.shadow_distance * 0.95);
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
    if (water > 0.01) {
        // Angular blur of the ray, perpendicular to it; the per-pixel offsets average out in compose's 4x4 box.
        let up = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(ray_dir.y) > 0.99);
        let b1 = normalize(cross(up, ray_dir));
        let b2 = cross(ray_dir, b1);
        let spread = (zn_hash22(input.pixel + vec2<f32>(7.0, 3.0)) - vec2<f32>(0.5)) * (2.0 * ZP_WATER_BLUR_ANGLE * water);
        ray_dir = normalize(ray_dir + b1 * spread.x + b2 * spread.y);
    }
    let zp_steps = ZP_STEPS_BY_MODE[min(quality_mode, 2u)] + select(0, ZP_WATER_EXTRA_STEPS, water > 0.5);
    let pcf_angle = jitter * 2.0 * ZP_PI;
    let n = f32(zp_steps);
    var lit_density = vec3<f32>(0.0);
    let refr_light = zp_underwater_refracted_dir(light_dir);
    if (cave_gate > 0.001) {
        for (var i = 0; i < zp_steps; i = i + 1) {
            let u = (f32(i) + jitter) / n;
            let t = ray_len * u * u;
            let dt = ray_len * 2.0 * u / n;
            let pos = ray_dir * t;
            let world_pos = frame.camera_position + pos;

            var lit = zp_shadow_lit(pos, water, pcf_angle + f32(i) * 2.399963);
            lit = mix(lit, vec3<f32>(ZP_WATER_LIT_MID), ZP_WATER_LIT_PULL * water);
            if water > 0.5 {
                lit = lit * zp_underwater_beam(world_pos, pos, t, refr_light);
            }
            let world_y = world_pos.y;
            let density = min(exp(-max(world_y - ZP_SEA_LEVEL, 0.0) * ZP_HEIGHT_FALLOFF), 1.5);
            lit_density = lit_density + lit * (density * dt);
        }
    }

    let sigma = mix(ZP_SIGMA_CLEAR, ZP_SIGMA_RAIN, frame.rain);
    let cos_air = dot(ray_dir, light_dir);
    let cos_uw = dot(ray_dir, refr_light);
    let phase_air = min(mix(zp_hg(cos_air, 0.50), zp_hg(cos_air, -0.25), 0.25) * 4.0 * ZP_PI, 3.8);
    let phase_uw = min(mix(zp_hg(cos_uw, 0.68), zp_hg(cos_uw, -0.18), 0.16) * 4.0 * ZP_PI, 4.5);
    let phase = mix(phase_air, phase_uw, water);
    let surface_scale = select(select(0.72, 0.45, d <= 0.0), select(0.68, 0.38, d <= 0.0), water > 0.5);
    let light = zp_light_colour(light_dir.y) * (light_mask * cave_gate) * mix(vec3<f32>(1.0), ZP_WATER_LIGHT, water);
    let raw_rgb = light * lit_density * (sigma * phase * volumetric_light * surface_scale);
    let rgb = min(raw_rgb / (1.0 + zn_luma(raw_rgb) * 1.8), vec3<f32>(2.5));
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
