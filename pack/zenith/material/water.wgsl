// src: Jerry Tessendorf, "Simulating Ocean Water", SIGGRAPH 2001 (wave superposition); Bruneton, Neyret & Holzschuch, Eurographics 2010 (scale-dependent ocean normals and roughness); Schlick 1994 and Karis 2013 (Fresnel and GGX); Beer-Lambert absorption; Horizon Shader API 0.2 (opaque depth/color and planar reflection).
// Zenith Shader Pack — Water Shading (Multi-Directional Waves, Rain Ripples, Beer-Lambert Depth, True Refraction, Foam & Mirror Reflection)

fn mat_water_rain_ripples_layer(p: vec2<f32>, t: f32) -> f32 {
    let base_cell = floor(p - vec2<f32>(0.5));
    var sum: f32 = 0.0;
    for (var j: i32 = 0; j < 2; j = j + 1) {
        for (var i: i32 = 0; i < 2; i = i + 1) {
            let cell = base_cell + vec2<f32>(f32(i), f32(j));
            let rnd = zn_hash22(cell);
            let age = fract(t * 1.28 + zn_hash21(cell + vec2<f32>(19.7, 43.1)));
            let center = cell + vec2<f32>(0.22) + rnd * 0.56;
            let radius = age * 0.44;
            let d = length(p - center) - radius;
            let ring_mask = 1.0 - smoothstep(0.12, 0.24, abs(d));
            let env = smoothstep(0.0, 0.06, age) * (1.0 - age) * (1.0 - age) * exp(-d * d * 82.0) * ring_mask;
            sum = sum + sin(d * 34.0) * env;
        }
    }
    return sum;
}

// Dual seamless cellular raindrop ripple rings on open horizontal water surfaces.
fn mat_water_rain_ripples(xz: vec2<f32>, t: f32) -> f32 {
    let rot = vec2<f32>(0.8 * xz.x - 0.6 * xz.y, 0.6 * xz.x + 0.8 * xz.y);
    return mat_water_rain_ripples_layer(xz * 1.65, t) * 0.65
         + mat_water_rain_ripples_layer(rot * 2.45 + vec2<f32>(7.3, 11.9), t * 1.13 + 0.41) * 0.45;
}

fn mat_water_height(xz: vec2<f32>, t: f32, storm: f32, detail_fade: f32, rain_w: f32) -> f32 {
    let speed = 1.35 + 0.55 * storm;

    // Multi-directional swells across four non-harmonic directions
    let ph1 = dot(xz, vec2<f32>(0.86, 0.51)) * 1.35 + t * 1.45 * speed;
    let ph2 = dot(xz, vec2<f32>(-0.54, 0.84)) * 1.85 - t * 1.20 * speed;
    let ph3 = dot(xz, vec2<f32>(0.31, -0.95)) * 2.65 + t * 1.65 * speed;
    let ph4 = dot(xz, vec2<f32>(-0.92, -0.39)) * 3.80 - t * 2.05 * speed;

    let s1 = sin(ph1);
    let crest1 = s1 + 0.14 * (1.0 - abs(s1));
    let w3_fade = smoothstep(0.05, 0.5, detail_fade + 0.25);
    let swell = crest1 * 0.28 + sin(ph2) * 0.22 + sin(ph3) * 0.12 * w3_fade + sin(ph4) * 0.07 * detail_fade;

    var ripple = 0.0;
    if detail_fade > 0.001 {
        let fine_fade = smoothstep(0.2, 0.8, detail_fade);
        let p1 = xz * 1.15 + vec2<f32>(t * 0.42 * speed, t * 0.27 * speed);
        let p2 = xz * 2.45 + vec2<f32>(-t * 0.36 * speed, t * 0.48 * speed);
        let n1 = zn_noise2(p1) - 0.5;
        let n2 = (zn_noise2(p2) - 0.5) * fine_fade;
        ripple = (n1 * 0.65 + n2 * 0.35) * 0.82 * detail_fade;
    }

    var rain_rings = 0.0;
    if rain_w > 0.001 {
        rain_rings = mat_water_rain_ripples(xz, t) * 0.34 * rain_w;
    }

    return swell + ripple * (1.0 + 0.45 * storm) + rain_rings;
}

fn mat_water_swell_blend(dist: f32) -> f32 {
    return smoothstep(23.0, 77.0, dist);
}

// Analytic slopes of three long waves. The Gaussian approximates averaging a
// sinusoid across one pixel, retaining long slopes after the fine ripples fade.
fn mat_water_band(xz: vec2<f32>, t: f32, k: vec2<f32>, amplitude: f32, footprint: f32) -> vec2<f32> {
    let filter_width = footprint * 1.35;
    let gain = exp(-dot(k, k) * filter_width * filter_width / 24.0);
    let phase = dot(k, xz) + t;
    return k * (amplitude * cos(phase) * gain);
}

fn mat_water_long_slope(xz: vec2<f32>, t: f32, footprint: f32, storm: f32) -> vec2<f32> {
    let speed = t * (1.0 + 0.35 * storm);
    let groups = 0.72 + 0.28 * sin(dot(xz, vec2<f32>(0.071, -0.048)) + speed * 0.31);
    let a = mat_water_band(xz, -speed * 0.93, vec2<f32>(0.18, 0.23), 0.43 * groups, footprint);
    let b = mat_water_band(xz, speed * 1.29 + 1.1, vec2<f32>(-0.47, 0.18), 0.24, footprint);
    let c = mat_water_band(xz, -speed * 1.67 + 2.3, vec2<f32>(0.42, -0.56), 0.12, footprint);
    return (a + b + c) * (1.0 + storm * 0.24);
}

fn mat_water_wave_normal(world_pos: vec3<f32>, geom_n: vec3<f32>, sky_light: f32) -> vec3<f32> {
    if water_wave_strength <= 0.001 {
        return geom_n;
    }

    let dist = length(world_pos - frame.camera_position);
    let wave_fade = 1.0 - smoothstep(16.0, 80.0, dist);
    let swell_blend = select(0.0, mat_water_swell_blend(dist), geom_n.y > 0.45 && frame.eye_in == 0u);
    if wave_fade <= 0.001 && swell_blend <= 0.001 {
        return geom_n;
    }

    let storm = clamp(frame.rain * 0.7 + frame.thunder * 0.3, 0.0, 1.0);
    // Integrate slopes over a growing world-space footprint instead of retaining
    // a fixed 0.045-block derivative at the horizon. No fragment derivatives are
    // used here: the material dispatcher calls water in non-uniform control flow.
    let view = mat_safe_normalize(frame.camera_position - world_pos);
    let footprint = (2.0 * dist) / max(frame.resolution.y * abs(frame.projection[1][1]) * max(abs(dot(geom_n, view)), 0.08), 1.0);
    let eps = clamp(max(0.045, footprint * 1.5), 0.045, 1.25);
    let xz = world_pos.xz + vec2<f32>(world_pos.y * 0.35);
    let detail_fade = (1.0 - smoothstep(10.0, 44.0, dist)) * (1.0 - smoothstep(0.08, 0.40, footprint));
    let rain_w = (1.0 - smoothstep(10.0, 28.0, dist))
        * smoothstep(0.02, 0.25, frame.rain)
        * smoothstep(0.65, 0.92, sky_light)
        * select(0.0, 1.0, geom_n.y > 0.45 && frame.dimension == 0);

    let strength = (0.22 * water_wave_strength / (1.0 + dist * 0.018)) * wave_fade;
    var slope = vec2<f32>(0.0);
    if swell_blend < 0.999 {
        let h_c = mat_water_height(xz, frame.time, storm, detail_fade, rain_w);
        let h_x = mat_water_height(xz + vec2<f32>(eps, 0.0), frame.time, storm, detail_fade, rain_w);
        let h_z = mat_water_height(xz + vec2<f32>(0.0, eps), frame.time, storm, detail_fade, rain_w);
        slope = vec2<f32>(h_x - h_c, h_z - h_c) * strength / eps;
    }
    if swell_blend > 0.001 {
        let long_slope = mat_water_long_slope(xz, frame.time, footprint, storm) * water_wave_strength;
        slope = mix(slope, long_slope, swell_blend);
    }

    if geom_n.y > 0.45 {
        return mat_safe_normalize(geom_n - vec3<f32>(slope.x, 0.0, slope.y));
    }
    if geom_n.y < -0.45 {
        // Underside of horizontal water surface: gentle attenuated ripples, never waterfall side stripes.
        return mat_safe_normalize(geom_n + vec3<f32>(slope.x, 0.0, slope.y) * 0.25);
    }

    // Flowing side faces (waterfalls): gently ripple along tangent space.
    let side_ripple = sin(world_pos.y * 4.5 + frame.time * 4.2 + (world_pos.x + world_pos.z) * 2.0) * 0.06 * water_wave_strength * wave_fade;
    return mat_safe_normalize(geom_n + vec3<f32>(side_ripple, 0.04 * strength, -side_ripple));
}

// Underside of the water surface: attenuated ripple normal, Snell's window (~48.6 deg half-angle),
// calm underwater total internal reflection outside the cone, and no GGX glint or sky-mirror bands.
fn mat_water_underside_alpha(ndotv: f32, has_bg: bool, water_depth: f32, depth_opacity: f32) -> f32 {
    let window_t = smoothstep(0.34, 0.68, ndotv);
    let f_window = mat_fresnel_schlick_scalar(clamp((ndotv - 0.34) / 0.66, 0.0, 1.0), 0.0204);
    let window_alpha = select(0.68, 0.14, has_bg);
    let uw_alpha = mix(0.84, window_alpha, window_t * (1.0 - f_window));
    let shore_contact = select(1.0, smoothstep(0.0, 1.0, water_depth), has_bg);
    return clamp(mix(min(uw_alpha, depth_opacity), uw_alpha, shore_contact), 0.14, 0.90);
}

fn mat_underwater_fog_color(raw_fog: vec3<f32>, sun_y: f32, sky_light: f32, calibrate: bool) -> vec3<f32> {
    let clean = max(raw_fog, vec3<f32>(0.0));
    if (!calibrate) {
        return clean;
    }
    let peak = max(clean.r, max(clean.g, clean.b));
    if (peak <= 1e-5) {
        return vec3<f32>(0.0);
    }
    let norm = clean / peak;
    let base_peak = min(peak, 0.20 + 0.04 * clamp(peak, 0.0, 1.0)) * 0.30;
    let uw_day = mix(0.18, 1.0, smoothstep(-0.10, 0.16, sun_y));
    let uw_sky = mix(0.08, 1.0, smoothstep(0.02, 0.55, sky_light));
    let calm_tint = mix(norm, vec3<f32>(0.38, 0.64, 0.76), 0.68);
    return calm_tint * (base_peak * uw_day * uw_sky);
}

fn mat_shade_water_underside(
    input: MaterialInput,
    N: vec3<f32>,
    V: vec3<f32>,
    L: vec3<f32>,
    water_body: vec3<f32>,
    transmittance: vec3<f32>,
    has_bg: bool,
    water_depth: f32,
    sun_rad: vec3<f32>,
    sun_visibility: vec3<f32>,
) -> Surface {
    let ndotv = max(dot(N, V), 0.0);
    // Critical angle for water (IOR 1.333) -> air (IOR 1.0): cos(asin(1/1.333)) ~= 0.6614 (~48.6 deg).
    // Soften across [0.34, 0.68] so shallow upward views transmit above-water trees and sky cleanly.
    let window_t = smoothstep(0.34, 0.68, ndotv);
    let f_window = mat_fresnel_schlick_scalar(clamp((ndotv - 0.34) / 0.66, 0.0, 1.0), 0.0204);

    // Calm underwater total internal reflection (TIR) outside Snell's window: matches the water body
    // and underwater fog tone with subtle directional ripple shading, avoiding sky-gradient stripes.
    let dist = length(input.position);
    let wave_fade = 1.0 - smoothstep(14.0, 64.0, dist);
    let ripple_shade = 1.0 + clamp((N.x * L.x + N.z * L.z) * 0.36, -0.11, 0.11) * wave_fade;
    let uw_active = frame.dimension == 0 && frame.blindness <= 0.0 && frame.darkness <= 0.0 && frame.night_vision <= 0.001;
    let uw_cal_fog = mat_underwater_fog_color(frame.fog_color, frame.sun_direction.y, input.light.y, uw_active);
    var tir_color: vec3<f32>;
    if frame.eye_in == 1u {
        let uw_fog = max(uw_cal_fog, vec3<f32>(0.0005, 0.001, 0.002));
        let grazing_t = smoothstep(0.52, 0.04, ndotv);
        let tir_base = uw_fog * mix(0.76, 0.96, grazing_t);
        let local_tint = mix(tir_base, min(max(water_body, uw_fog * 0.45), uw_fog * 1.15), 0.14 * wave_fade);
        tir_color = local_tint * ripple_shade;
    } else {
        tir_color = max(water_body, vec3<f32>(0.012, 0.036, 0.048)) * ripple_shade;
    }

    // Transmitted sky & sun glow inside Snell's window (scales cleanly with sky light & day/night).
    let sky_vis = smoothstep(0.05, 0.75, input.light.y);
    let sky_raw = mat_sky_reflection_color(vec3<f32>(0.0, 0.85, 0.0));
    let sky_lum = dot(sky_raw, vec3<f32>(0.2126, 0.7152, 0.0722));
    let sky_base = mix(vec3<f32>(sky_lum), sky_raw, 0.45) * vec3<f32>(0.68, 0.88, 0.96);
    let air_scale = select(0.45, select(0.30, 0.16, has_bg), frame.eye_in == 1u);
    let air_window = (sky_base * air_scale + sun_rad * sun_visibility * 0.025) * sky_vis;
    let window_body = select(water_body * 1.25, max(uw_cal_fog * 0.65, water_body), frame.eye_in == 1u);
    let window_color = mix(window_body + air_window, tir_color, f_window * 0.65);

    let lit = mix(tir_color, window_color, window_t);

    let depth_opacity = clamp(1.0 - dot(transmittance, vec3<f32>(0.24, 0.46, 0.30)), 0.18, 0.86);
    let final_alpha = mat_water_underside_alpha(ndotv, has_bg, water_depth, depth_opacity);

    return Surface(vec4<f32>(max(lit, vec3<f32>(0.0)), final_alpha));
}

fn mat_water_mirror_day_weight() -> f32 {
    // API 0.2's planar mirror renders vanilla's sky/sunrise and camera-dependent
    // fog_color with no depth/sky mask. Keep it off through dusk, dawn, and the
    // low-sun sunrise-fan band, fading smoothly into daylight reflections.
    return select(1.0, smoothstep(0.08, 0.24, frame.sun_direction.y), frame.dimension == 0);
}

override atmospheric_fog: f32 = 1.0;

// A water surface supplies its own height when the mirror is disabled or tracks another lake.
fn mat_water_surface_mist(input: MaterialInput, colour: vec4<f32>) -> vec4<f32> {
    if atmospheric_fog <= 0.001 || frame.dimension != 0 || frame.eye_in != 0u || input.normal.y < 0.6
        || frame.blindness > 0.0 || frame.darkness > 0.0 || frame.night_vision > 0.0 {
        return colour;
    }
    let water_y = frame.camera_position.y + input.position.y;
    let base_y = select(62.88, frame.water_plane, frame.has_reflection != 0u);
    if abs(water_y - base_y) < 1.50 { return colour; }
    let mist = zn_water_mist_strength(frame.day_time, frame.rain, frame.downfall, min(input.light.y, frame.eye_light_smooth.y));
    if mist <= 0.001 { return colour; }
    let distance = length(input.position);
    let near_fade = smoothstep(5.0, 16.0, distance);
    if near_fade <= 0.001 { return colour; }
    let depth_dims = vec2<i32>(textureDimensions(opaque_depth));
    let depth_coord = clamp(
        vec2<i32>(input.screen * vec2<f32>(depth_dims)),
        vec2<i32>(0),
        max(depth_dims - vec2<i32>(1), vec2<i32>(0)),
    );
    let bg_depth = textureLoad(opaque_depth, depth_coord, 0);
    var water_depth: f32 = 16.0;
    if bg_depth > 0.0001 {
        let bg_cam_pos = mat_world_from_depth(input.screen, bg_depth);
        water_depth = max(0.0, length(bg_cam_pos - input.position));
    }
    let shore_fade = smoothstep(0.15, 1.35, water_depth);
    if shore_fade <= 0.001 { return colour; }
    let direction = input.position / max(distance, 0.001);
    let eye_height = -input.position.y;
    let span = zn_water_mist_segment(eye_height, direction.y, distance);
    let middle = direction * (0.5 * (span.x + span.y));
    let drift = zn_water_mist_drift(frame.time);
    let mist_xz = frame.camera_position.xz + middle.xz;
    let warp = zn_fbm2(mist_xz * 0.07 + drift * 0.35, 2);
    let vapor = zn_fbm2(mist_xz * 0.11 + vec2<f32>(warp - 0.5, 0.5 - warp) * 1.4 + drift * 0.45, 2);
    let billow = smoothstep(0.22, 0.80, vapor);
    let h_env = 1.0 - smoothstep(0.12, ZN_WATER_MIST_TOP, eye_height + middle.y + (vapor - 0.5) * 0.75);
    let optical_len = h_env * (0.28 + 0.92 * billow) * (span.y - span.x) * near_fade * shore_fade;
    let rgb = zn_water_mist_composite(colour.rgb, optical_len, mist * min(atmospheric_fog, 1.3), direction, frame.sun_direction);
    return vec4<f32>(rgb, colour.a);
}

fn mat_shade_water(input: MaterialInput) -> Surface {
    let geom_n = mat_safe_normalize(input.normal);
    let is_underside = geom_n.y < -0.45;
    let dist = length(input.position);
    let world_pos = input.position + frame.camera_position;
    let N = mat_water_wave_normal(world_pos, geom_n, input.light.y);
    let V = mat_safe_normalize(-input.position);
    let L = mat_safe_normalize(frame.light_direction);

    // 1. Sample opaque depth behind water for Beer-Lambert depth absorption & shoreline foam.
    let depth_dims = vec2<i32>(textureDimensions(opaque_depth));
    let depth_coord = clamp(
        vec2<i32>(input.screen * vec2<f32>(depth_dims)),
        vec2<i32>(0),
        max(depth_dims - vec2<i32>(1), vec2<i32>(0))
    );
    let bg_depth = textureLoad(opaque_depth, depth_coord, 0);

    var water_depth: f32 = 16.0;
    var has_bg: bool = false;
    if bg_depth > 0.0001 {
        let bg_cam_pos = mat_world_from_depth(input.screen, bg_depth);
        water_depth = max(0.0, length(bg_cam_pos - input.position));
        has_bg = true;
    }

    // 2. Shadows & Lighting environment
    let shadow_n = select(geom_n, -geom_n, is_underside);
    let shadow = mat_engine_shadows(mat_sample_shadows(input.position, shadow_n, L, input.light.y, input.screen, true), input.position, shadow_n, L, input.light.y);
    let sun_rad = mat_sun_moon_radiance();
    let sky_amb = mat_sky_ambient_color(N, input.light.y);

    let bl = block_light_color(input.position);
    let block_tint = mat_resolve_block_light_tint(bl);
    let bl_light = block_tint * pow(clamp(input.light.x, 0.0, 1.0), 1.75) * block_light_strength;
    let dyn_light = mat_compress_dynamic_light(input.colored_light);

    let total_diffuse_light = sky_amb
        + sun_rad * shadow.sun_visibility * (0.35 + 0.65 * max(dot(N, L), 0.0)) * MAT_INV_PI
        + bl_light
        + dyn_light;

    // 3. Beer-Lambert spectral absorption & water body scattering
    let sigma = vec3<f32>(0.42, 0.14, 0.08) * water_absorption;
    let transmittance = exp(-sigma * min(water_depth, 24.0));
    // Vanilla biome water tint is a saturated blue; pull it towards grey and a teal body colour so the sea is not neon blue.
    // On the underside of the surface, omit the 16x16 vanilla water texels so looking up shows smooth waves instead of pixel blocks.
    let base_sample = select(input.albedo.rgb, vec3<f32>(0.42, 0.56, 0.62), is_underside);
    let biome_raw = max(input.shaded_tint.rgb * base_sample, vec3<f32>(0.02, 0.08, 0.14));
    let biome_luma = dot(biome_raw, vec3<f32>(0.2126, 0.7152, 0.0722));
    let biome_water = mix(vec3<f32>(biome_luma), biome_raw, 0.35);
    let deep_col = biome_water * vec3<f32>(0.30, 0.52, 0.50);
    let shallow_col = biome_water * vec3<f32>(0.55, 0.82, 0.78);
    let body_tint = mix(deep_col, shallow_col, transmittance.g);
    let water_body = body_tint * total_diffuse_light;

    if is_underside {
        return mat_shade_water_underside(
            input,
            N,
            V,
            L,
            water_body,
            transmittance,
            has_bg,
            water_depth,
            sun_rad,
            shadow.sun_visibility,
        );
    }

    // 4. Fresnel & Reflection (Horizon mirror reflection when available, else camera-invariant sky gradient)
    let ndotv = max(dot(N, V), 0.0);
    let fresnel = mat_fresnel_schlick_scalar(ndotv, 0.0204);

    let R = reflect(-V, N);
    let fallback_refl = mat_sky_reflection_color(R) * smoothstep(0.05, 0.75, input.light.y);

    var env_refl = fallback_refl;
    if water_reflections && frame.has_reflection == 1u && geom_n.y > 0.45 {
        let far_weight = smoothstep(24.0, 80.0, dist);
        let dist_atten = (1.0 - far_weight) / (1.0 + dist * 0.06);
        let broad = select(0.0, mat_water_swell_blend(dist), frame.eye_in == 0u && water_wave_strength > 0.001);
        let view_slope = (frame.view * vec4<f32>(N - geom_n, 0.0)).xyz;
        let shore_calm = smoothstep(0.10, 0.85, water_depth);
        let near_scale = mix(0.08, 0.24, shore_calm) * dist_atten;
        let near_offset = clamp(vec2<f32>(view_slope.x, -view_slope.y) * near_scale, vec2<f32>(-0.032), vec2<f32>(0.032));
        let distant_offset = clamp(vec2<f32>(view_slope.x, -view_slope.y) * 0.22, vec2<f32>(-0.024), vec2<f32>(0.024));
        let wave_off = mix(near_offset, distant_offset, broad);
        let texel = 1.0 / vec2<f32>(textureDimensions(reflection));
        let rain_wet = clamp(
            frame.wetness * smoothstep(0.55, 0.94, input.light.y) * smoothstep(0.15, 0.25, frame.temperature),
            0.0,
            1.0,
        );
        let radius = mix(mix(0.85, 2.2, rain_wet), mix(4.0, 2.4, broad), max(far_weight, rain_wet * 0.45));
        let margin = texel * (radius + 1.0);
        let refl_uv = clamp(input.screen + wave_off, margin, vec2<f32>(1.0) - margin);
        // Horizon's mirror has one mip. A separable 3x3 tent really filters it;
        // increasing textureSampleLevel's LOD alone would still read mip zero.
        // Clamp each tap BEFORE filtering so one HDR texel cannot seed a streak.
        let mirror_limit = mix(2.0, 1.0, far_weight);
        var mirror = vec3<f32>(0.0);
        for (var y = -1; y <= 1; y = y + 1) {
            for (var x = -1; x <= 1; x = x + 1) {
                let weight = select(1.0, 2.0, x == 0) * select(1.0, 2.0, y == 0);
                let uv = refl_uv + vec2<f32>(f32(x), f32(y)) * texel * radius;
                let tap = textureSampleLevel(reflection, reflection_sampler, uv, 0.0).rgb;
                mirror = mirror + clamp(tap, vec3<f32>(0.0), vec3<f32>(mirror_limit)) * (weight / 16.0);
            }
        }
        // Blend gracefully with sky reflection in dark caves or near screen borders.
        let edge_fade = smoothstep(0.0, 0.06, refl_uv.x)
                      * smoothstep(1.0, 0.94, refl_uv.x)
                      * smoothstep(0.0, 0.06, refl_uv.y)
                      * smoothstep(1.0, 0.94, refl_uv.y);
        // Fade the vanilla mirror out through dusk/dawn and low-sun sunrise-fan
        // elevations so neither vanilla's sunset nor camera-dependent fog_color
        // tints the water; daylight terrain reflections stay intact.
        let mirror_day = mat_water_mirror_day_weight();
        let mirror_weight = edge_fade * clamp(input.light.y * 1.25, 0.15, 1.0)
            * mix(1.0, mix(0.35, 0.58, broad), far_weight) * (1.0 - rain_wet * 0.22) * mirror_day;
        env_refl = mix(fallback_refl, mirror, mirror_weight);
    }

    // 5. Crisp GGX sun / moon specular glint on wave facets (widened & faded with distance to prevent far aliasing)
    var spec_glint = vec3<f32>(0.0);
    let ndotl = max(dot(N, L), 0.0);
    if ndotl > 0.0 {
        let H = mat_safe_normalize(V + L);
        let ndoth = max(dot(N, H), 0.0);
        let vdoth = max(dot(V, H), 0.0);
        let rough_t = smoothstep(8.0, 96.0, dist);
        let water_rough = mix(0.048, 0.28, rough_t);
        let spec_near = 1.0 - smoothstep(24.0, 108.0, dist);
        let spec_far = 0.34 * mat_water_swell_blend(dist) * (1.0 - smoothstep(120.0, 250.0, dist))
            * clamp(water_wave_strength, 0.0, 1.0);
        let spec_atten = max(spec_near, select(0.0, spec_far, frame.eye_in == 0u && geom_n.y > 0.45));
        let F_spec = mat_fresnel_schlick_scalar(vdoth, 0.0204);
        let D_spec = mat_d_ggx(ndoth, water_rough);
        let G_spec = mat_g_smith_ggx(ndotv, ndotl, water_rough);
        let brdf_s = (F_spec * D_spec * G_spec) / max(4.0 * max(ndotv, 1e-4) * ndotl, 1e-4);
        spec_glint = vec3<f32>(brdf_s) * sun_rad * shadow.sun_visibility * ndotl * spec_atten;
    }

    // 6. Soft animated shoreline foam where water meets solid geometry
    var foam: f32 = 0.0;
    if water_foam && has_bg && geom_n.y > 0.45 && water_depth < 0.60 {
        let foam_noise = zn_fbm2(world_pos.xz * 2.1 + vec2<f32>(frame.time * 0.22, -frame.time * 0.15), 4);
        let edge_mask = smoothstep(0.60, 0.03, water_depth);
        let foam_fade = 1.0 - smoothstep(16.0, 48.0, length(input.position));
        foam = edge_mask * smoothstep(0.34, 0.72, foam_noise) * 0.72 * foam_fade;
    }
    let foam_color = vec3<f32>(0.88, 0.94, 0.98) * total_diffuse_light;

    // 7. Combine absorption body, Fresnel reflection, specular glint, and shoreline foam
    let optical_opacity = clamp(1.0 - dot(transmittance, vec3<f32>(0.24, 0.46, 0.30)), 0.18, 0.90);
    let alpha_classic = clamp(max(optical_opacity, fresnel * 0.88) + foam * 0.55, 0.18, 0.97);

    var lit_classic = mix(water_body, env_refl, clamp(fresnel * 1.15, 0.02, 0.96)) + spec_glint;
    lit_classic = mix(lit_classic, foam_color, foam);

    // 8. True depth-aware Beer-Lambert refraction through opaque_color (fading cleanly to classic blend before fog horizon)
    let fog_t = vanilla_fog(input.position);
    if water_refraction && fog_t < 0.45 {
        let dist = length(input.position);
        let surf_z = mat_surface_ndc_z(input.position);
        let v_delta = (frame.view * vec4<f32>(N - geom_n, 0.0)).xyz;
        let depth_scale = smoothstep(0.0, 1.2, water_depth);
        let edge_guard = smoothstep(0.0, 0.04, input.screen.x)
                       * smoothstep(1.0, 0.96, input.screen.x)
                       * smoothstep(0.0, 0.04, input.screen.y)
                       * smoothstep(1.0, 0.96, input.screen.y);
        let refr_amp = (0.030 * clamp(water_wave_strength, 0.35, 1.8) * depth_scale * edge_guard) / (1.0 + dist * 0.075);
        let refr_uv = input.screen + vec2<f32>(v_delta.x, -v_delta.y) * refr_amp;
        let refr = mat_sample_opaque_refracted(refr_uv, input.screen, surf_z);
        if refr.valid {
            var refr_depth = water_depth;
            if refr.depth > 0.0001 {
                let refr_bg = mat_world_from_depth(clamp(refr_uv, vec2<f32>(0.0005), vec2<f32>(0.9995)), refr.depth);
                let raw_d = max(0.0, length(refr_bg - input.position));
                refr_depth = clamp(raw_d, water_depth * 0.65, water_depth * 1.35 + 0.25);
            }
            let refr_trans = exp(-sigma * min(refr_depth, 28.0));
            let transmitted = refr.color * refr_trans;
            let inscatter = water_body * (vec3<f32>(1.0) - refr_trans);
            var lit_refr = mix(transmitted + inscatter, env_refl, clamp(fresnel * 1.12, 0.02, 0.96)) + spec_glint;
            lit_refr = mix(lit_refr, foam_color, foam);

            let refract_w = 1.0 - smoothstep(0.05, 0.45, fog_t);
            let out_alpha = mix(alpha_classic, 1.0, refract_w);
            let out_rgb = mix(lit_classic * alpha_classic, lit_refr, refract_w) / max(out_alpha, 1e-4);
            return Surface(vec4<f32>(max(out_rgb, vec3<f32>(0.0)), out_alpha));
        }
    }

    return Surface(vec4<f32>(max(lit_classic, vec3<f32>(0.0)), alpha_classic));
}
