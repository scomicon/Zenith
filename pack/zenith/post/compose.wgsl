// src: Tomasi and Manduchi 1998, Bilateral Filtering for Gray and Color Images (range-weighted filter); Jimenez et al., SIGGRAPH 2016 (GTAO multi-bounce approximation); screen-space contact shadows; Wenzel, GDC 2006 and Hillaire, EGSR 2020 (height fog and aerial perspective); Perlin 2002 (3D quintic value noise and domain-warped volumetric fBm); Horizon Shader API 0.2 (kept biome weights).
// Pass 6: apply ambient occlusion, screen-space contact shadows, height fog / aerial perspective and volumetric light to the world's picture.
//
// First pass that advances `previous`: input.color is the world's picture.
//
// AO filter: the GTAO pass jitters its slice angles with a 4x4 ordered pattern (period 4 in its pixels), so a 4x4
// box over `ao` integrates the pattern exactly. Each tap is weighted by how close its stored camera
// distance (ao.g) is to this pixel's, so occlusion does not bleed over depth edges (a depth-aware /
// cross-bilateral filter, Tomasi & Manduchi, "Bilateral Filtering for Gray and Color Images", ICCV 1998).
//
// AO is applied to the final colour, since the material stage's light is already summed there: it is
// weakened where the pixel is bright (direct sunlight hides contact shadows less than ambient light does).
// That falloff, 1 / (1 + 0.35 luma), is an own heuristic.
//
// Light shafts: a continuous 4x4 tent smooths ray-march jitter, with a depth test
// per tap. Mixing sky haze across a block silhouette creates a shifted duplicate
// contour. Sky/terrain and discontinuous surface depths must stay separate.
//
// View bob: Horizon draws sky/sky.wgsl unbobbed, then draws the engine moon quad onto the sky
// with `globals.view_proj` (which already carries `frame.bob * frame.spin` — 1x bob). Reprojecting
// Overworld sky pixels again in post would apply a 2x bob to the moon and clip it at terrain edges.
// Therefore Overworld view-bob sky matching (`bob_sky_match`) runs inside `sky/sky.wgsl` via
// `sky_bob_direction`. End and Nether skies (`dimension == 1 / -1`) are rendered here directly via
// `zp_sky_ray`, which already reads the bobbed projection. Numerical regression: `tools/tests/sky-bob.test.mjs`.

override ao_strength: f32 = 1.0;
override volumetric_light: f32 = 0.6;
override contact_shadows: bool = true;
override quality_mode: u32 = 1u;
override atmospheric_fog: f32 = 1.0;

const ZP_AO_POWER: f32 = 1.6;
const ZP_CONTACT_STEPS: vec3<i32> = vec3<i32>(8, 12, 16);

// J. Jimenez, X. Wu, A. Pesce, A. Jarosz, SIGGRAPH 2016: Multi-bounce GTAO approximation.
fn zp_gtao_multibounce(visibility: f32, albedo: vec3<f32>) -> vec3<f32> {
    let x = clamp(visibility, 0.0, 1.0);
    let alb = clamp(albedo, vec3<f32>(0.0), vec3<f32>(0.95));
    let a =  2.0404 * alb - vec3<f32>(0.3324);
    let b = -4.7951 * alb + vec3<f32>(0.6417);
    let c =  2.7552 * alb + vec3<f32>(0.6903);
    return clamp(max(vec3<f32>(x), ((x * a + b) * x + c) * x), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn zp_estimate_albedo(colour: vec3<f32>) -> vec3<f32> {
    let luma = zn_luma(colour);
    let max_c = max(max(colour.r, colour.g), max(colour.b, 1e-4));
    let chroma = colour / max_c;
    let refl_mag = clamp(pow(luma / (luma + 0.35), 0.45) * 0.78, 0.16, 0.78);
    return clamp(chroma * refl_mag, vec3<f32>(0.02), vec3<f32>(0.88));
}

fn zp_contact_shadow(input: PostInput, P: vec3<f32>, dist: f32, colour: vec3<f32>) -> f32 {
    if (!contact_shadows || frame.dimension != 0 || frame.has_shadow == 0u || frame.eye_in != 0u) {
        return 0.0;
    }
    let dist_fade = smoothstep(0.25, 0.65, dist) * (1.0 - smoothstep(26.0, 44.0, dist));
    if (dist_fade <= 0.001) {
        return 0.0;
    }
    let L = frame.light_direction;
    let body_w = zn_celestial_weights(frame.sun_direction.y, frame.moon_direction.y);
    let light_elev = max(body_w.x, body_w.y * 0.35);
    let storm = clamp(frame.rain * 0.72 + frame.thunder * 0.28, 0.0, 1.0);
    let weather_w = 1.0 - storm * 0.75;
    if (light_elev * weather_w <= 0.01 || L.y <= 0.04) {
        return 0.0;
    }
    let surf = surface_at(vec2<i32>(input.pixel));
    if (!surf.present || (surf.data > 0.5 && surf.data < 1.5)) {
        return 0.0;
    }
    let N = normalize(surf.normal);
    if (dot(N, L) <= 0.06) {
        return 0.0;
    }

    // Gate on macro shadow map so caves, deep interiors, and already-shadowed walls stay untouched.
    let sp = shadow_position(P + N * 0.06 + L * 0.04);
    if (sp.x <= 0.001 || sp.x >= 0.999 || sp.y <= 0.001 || sp.y >= 0.999 || sp.z <= 0.0 || sp.z >= 1.0) {
        return 0.0;
    }
    let sm_vis = textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy, sp.z);
    let sm_gate = smoothstep(0.12, 0.75, sm_vis);
    if (sm_gate <= 0.001) {
        return 0.0;
    }

    let steps = ZP_CONTACT_STEPS[min(quality_mode, 2u)];
    let max_len = mix(0.55, 0.95, clamp(dist / 24.0, 0.0, 1.0));
    let Q0 = P + N * (0.025 + 0.0018 * dist);
    let dt = max_len / f32(steps);
    let jitter = zn_ign(input.pixel, 0u);
    let thickness = clamp(0.10 + 0.008 * dist, 0.10, 0.28);

    var occ = 0.0;
    for (var i = 0; i < 16; i = i + 1) {
        if (i >= steps) {
            break;
        }
        let t = dt * (f32(i) + 0.5 + jitter);
        let Q = Q0 + L * t;
        let clip = frame.projection * (frame.view * vec4<f32>(Q, 1.0));
        if (clip.w <= 0.05) {
            break;
        }
        let ray_uv = vec2<f32>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
        if (any(ray_uv <= vec2<f32>(0.001)) || any(ray_uv >= vec2<f32>(0.999))) {
            break;
        }
        if (length((ray_uv - input.uv) * frame.resolution) < 1.25) {
            continue;
        }
        let sd = depth_at(ray_uv);
        if (sd <= 0.0) {
            continue;
        }
        let ndc_z = clip.z / clip.w;
        if (ndc_z < sd) {
            let S = view_position(ray_uv, sd);
            let delta = length(Q) - length(S);
            if (delta > 0.015 && delta < thickness && dot(S - P, N) > 0.02) {
                let edge = min(min(ray_uv.x, 1.0 - ray_uv.x), min(ray_uv.y, 1.0 - ray_uv.y));
                let edge_fade = smoothstep(0.0, 0.04, edge);
                let ray_fade = 1.0 - smoothstep(0.65, 1.0, t / max_len);
                occ = max(occ, edge_fade * ray_fade);
                break;
            }
        }
    }

    let foliage_scale = select(1.0, 0.55, surf.data > 0.5);
    let emissive_guard = 1.0 / (1.0 + zn_luma(colour) * 0.45);
    return clamp(0.48 * occ * dist_fade * light_elev * weather_w * sm_gate * foliage_scale * emissive_guard, 0.0, 0.52);
}

// Reuse the existing fog control for outdoor biome lighting.
fn zp_outdoor_climate() -> vec3<f32> {
    if atmospheric_fog <= 0.001 || frame.dimension != 0 || frame.eye_in != 0u
        || frame.blindness > 0.0 || frame.darkness > 0.0 || frame.night_vision > 0.0 {
        return vec3<f32>(0.0);
    }
    return textureLoad(zp_climate, vec2<i32>(0, 32), 0).rgb * min(atmospheric_fog, 1.0);
}

fn zp_climate_irradiance(colour: vec3<f32>, climate: vec3<f32>, strength: f32) -> vec3<f32> {
    let gain = vec3<f32>(1.0) + climate.x * vec3<f32>(0.14, 0.035, -0.19)
        + climate.y * vec3<f32>(-0.09, 0.07, -0.045) + climate.z * vec3<f32>(-0.11, 0.025, 0.19);
    let neutral_gain = gain / max(0.01, dot(gain, vec3<f32>(0.2126, 0.7152, 0.0722)));
    return mix(colour, colour * neutral_gain, strength * (1.0 - smoothstep(0.85, 2.0, zn_luma(colour))));
}

fn zp_climate_haze(day_haze: vec3<f32>, climate: vec3<f32>) -> vec3<f32> {
    let weight = clamp(dot(climate, vec3<f32>(0.63, 0.79, 0.61)), 0.0, 1.0);
    let tint = climate.x * vec3<f32>(0.53, 0.36, 0.19) * 0.63
        + climate.y * vec3<f32>(0.21, 0.30, 0.25) * 0.79
        + climate.z * vec3<f32>(0.34, 0.49, 0.69) * 0.61;
    return day_haze * (1.0 - weight) + tint;
}

// Clean-room 3D value noise (Perlin 2002 quintic fade) & 2-octave volumetric fBm for swirling fog/mist wisps.
fn zp_hash31(p: vec3<f32>) -> f32 {
    let q = fract(p * vec3<f32>(0.1031, 0.1030, 0.0973));
    let r = q + dot(q, q.yxz + vec3<f32>(33.33));
    return fract((r.x + r.y) * r.z);
}

fn zp_vnoise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let n000 = zp_hash31(i);
    let n100 = zp_hash31(i + vec3<f32>(1.0, 0.0, 0.0));
    let n010 = zp_hash31(i + vec3<f32>(0.0, 1.0, 0.0));
    let n110 = zp_hash31(i + vec3<f32>(1.0, 1.0, 0.0));
    let n001 = zp_hash31(i + vec3<f32>(0.0, 0.0, 1.0));
    let n101 = zp_hash31(i + vec3<f32>(1.0, 0.0, 1.0));
    let n011 = zp_hash31(i + vec3<f32>(0.0, 1.0, 1.0));
    let n111 = zp_hash31(i + vec3<f32>(1.0, 1.0, 1.0));
    let nx00 = mix(n000, n100, u.x);
    let nx10 = mix(n010, n110, u.x);
    let nx01 = mix(n001, n101, u.x);
    let nx11 = mix(n011, n111, u.x);
    return mix(mix(nx00, nx10, u.y), mix(nx01, nx11, u.y), u.z);
}

fn zp_fbm3(p: vec3<f32>) -> f32 {
    let v0 = zp_vnoise3(p);
    let v1 = zp_vnoise3(p * 2.09 + vec3<f32>(13.7, 7.3, 19.1));
    return v0 * 0.64 + v1 * 0.36;
}

// Analytical exponential height fog (Wenzel, GDC 2006) & aerial perspective with 3D domain-warped volumetric wisps.
// Leaves caves (low eye sky-light), underwater, vision effects, render boundary, and The End untouched.
fn zp_atmospheric_fog(P: vec3<f32>, dist: f32, colour: vec3<f32>, climate: vec3<f32>) -> vec3<f32> {
    if (atmospheric_fog <= 0.001 || frame.eye_in != 0u || frame.blindness > 0.0 || frame.darkness > 0.0 || dist < 14.0) {
        return colour;
    }
    if (frame.dimension == 1) {
        return colour;
    }
    let vf = vanilla_fog(P);
    let edge_guard = 1.0 - smoothstep(0.15, 0.85, vf);
    if (edge_guard <= 0.001) {
        return colour;
    }

    let ray_dir = P / max(dist, 1e-3);
    let drift_xz = zn_water_mist_drift(frame.time) * 0.45;

    if (frame.dimension == -1) {
        var n_t = array<f32, 2>(28.0, 64.0);
        var n_w = array<f32, 2>(smoothstep(16.0, 38.0, dist), smoothstep(38.0, 80.0, dist));
        var ash_sum = 0.0;
        var ash_w = 0.0;
        for (var k = 0; k < 2; k = k + 1) {
            let bw = n_w[k];
            if bw <= 0.001 { continue; }
            let wp = ray_dir * n_t[k] + frame.camera_position;
            let q = vec3<f32>(wp.x * 0.036 + drift_xz.x, wp.y * 0.048 - frame.time * 0.028, wp.z * 0.036 + drift_xz.y);
            let w = zp_vnoise3(q * 0.85);
            let v = zp_fbm3(q + vec3<f32>(w - 0.5, (w - 0.5) * 0.45, 0.5 - w) * 1.25);
            ash_sum = ash_sum + v * bw;
            ash_w = ash_w + bw;
        }
        let ash_raw = select(0.5, ash_sum / max(ash_w, 1e-4), ash_w > 0.001);
        let ash_wisp = mix(0.5, smoothstep(0.24, 0.78, ash_raw), clamp(ash_w, 0.0, 1.0));
        let n_fog = clamp((1.0 - exp(-max(dist - 16.0, 0.0) * 0.0042 * atmospheric_fog)) * 0.24 * edge_guard * mix(0.78, 1.26, ash_wisp), 0.0, 0.35);
        let n_base = max(frame.fog_color, vec3<f32>(0.03, 0.01, 0.005)) * (1.0 + smoothstep(0.1, -0.3, ray_dir.y) * 0.35);
        let n_col = n_base * mix(0.88, 1.14, ash_wisp);
        return mix(colour, n_col, n_fog);
    }

    let world_y1 = frame.camera_position.y + P.y;
    let outdoor_w = max(smoothstep(0.12, 0.65, frame.eye_light_smooth.y), smoothstep(42.0, 96.0, dist) * smoothstep(52.0, 66.0, world_y1));
    if (outdoor_w <= 0.001) {
        return colour;
    }

    let sun_elev = frame.sun_direction.y;
    let daylight = smoothstep(-0.04, 0.20, sun_elev);
    let twilight_vis = smoothstep(-0.045, 0.06, sun_elev);
    let sunset = exp(-pow(max(sun_elev, -0.04) * 6.5, 2.0)) * twilight_vis;
    let storm = clamp(frame.rain * 0.72 + frame.thunder * 0.28, 0.0, 1.0);

    let y_ref = 64.0;
    let b = 0.045;
    let h0 = clamp((frame.camera_position.y - y_ref) * b, -1.5, 6.0);
    let dh = P.y * b;
    let height_factor = clamp(select(exp(-h0) * (1.0 - exp(-dh)) / dh, exp(-h0), abs(dh) < 1e-3), 0.0, 2.2);

    let climate_density = climate * mix(0.42, 1.0, daylight) * (1.0 - storm * 0.4);
    let sigma_h = mix(0.0018, 0.0050, storm) * (1.0 + 0.45 * sunset)
        * (1.0 + dot(climate_density, vec3<f32>(0.34, 1.00, 0.04)));
    let sigma_a = mix(0.0010, 0.0026, storm) * (1.0 + dot(climate_density, vec3<f32>(0.25, -0.08, -0.25)));
    let d_eff = max(dist - 20.0, 0.0);
    let optical = (sigma_h * height_factor + sigma_a) * d_eff * atmospheric_fog;
    let max_cap = mix(mix(0.14, 0.38 + 0.12 * climate.y, daylight), 0.56, storm);
    var fog_amount = clamp((1.0 - exp(-optical)) * outdoor_w * edge_guard, 0.0, max_cap);

    let sun_fwd = pow(max(dot(ray_dir, normalize(frame.sun_direction)), 0.0), 3.0) * smoothstep(-0.03, 0.10, sun_elev);
    let neutral_haze = mix(vec3<f32>(0.22, 0.36, 0.60), max(frame.sky_color, vec3<f32>(0.10, 0.18, 0.34)) * 1.10, 0.45);
    let day_haze = zp_climate_haze(neutral_haze, climate);
    let night_haze = vec3<f32>(0.005, 0.009, 0.019);
    let sunset_haze = vec3<f32>(0.58, 0.28, 0.13) * mix(0.20, 1.0, twilight_vis);
    let overcast_haze = mix(vec3<f32>(0.009, 0.013, 0.022), vec3<f32>(0.18, 0.22, 0.27), daylight);

    var haze_col = mix(night_haze, day_haze, daylight);
    haze_col = mix(haze_col, sunset_haze, clamp(sunset * (0.12 + 0.68 * sun_fwd), 0.0, 0.72));
    haze_col = haze_col + vec3<f32>(0.38, 0.26, 0.14) * sun_fwd * daylight * 0.26;
    haze_col = mix(haze_col, overcast_haze, storm * 0.78);

    if frame.dimension == 0 {
        let lut_uv = zn_sky_lut_uv(vec3<f32>(ray_dir.x, clamp(ray_dir.y, 0.0, 1.0), ray_dir.z));
        let lut_sky = textureSampleLevel(zp_climate, linear_sampler, lut_uv, 0.0);
        if lut_sky.a > 0.5 {
            let lut_haze = zp_climate_haze(lut_sky.rgb * mix(0.68, 1.05, max(daylight, twilight_vis)), climate);
            haze_col = mix(haze_col, lut_haze, mix(0.32, 0.68, max(daylight, sunset)));
        }
    }

    if fog_amount > 0.008 && dist > 20.0 {
        var band_t = array<f32, 3>(30.0, 60.0, 96.0);
        var band_w = array<f32, 3>(
            smoothstep(18.0, 36.0, dist),
            smoothstep(34.0, 68.0, dist),
            smoothstep(64.0, 108.0, dist),
        );
        var wisp_sum = 0.0;
        var valley_sum = 0.0;
        var weight_sum = 0.0;
        for (var s = 0; s < 3; s = s + 1) {
            let bw = band_w[s];
            if bw <= 0.001 { continue; }
            let wp = ray_dir * band_t[s] + frame.camera_position;
            let valley = smoothstep(104.0, 56.0, wp.y);
            let q = vec3<f32>(wp.x * 0.024 + drift_xz.x, wp.y * 0.062 - frame.time * 0.014, wp.z * 0.024 + drift_xz.y);
            let warp = zp_vnoise3(q * 0.85);
            let swirl = zp_fbm3(q + vec3<f32>(warp - 0.5, (warp - 0.5) * 0.35, 0.5 - warp) * 1.25);
            wisp_sum = wisp_sum + swirl * valley * bw;
            valley_sum = valley_sum + valley * bw;
            weight_sum = weight_sum + bw;
        }
        if valley_sum > 0.01 {
            let valley_w = valley_sum / max(weight_sum, 1e-4);
            let wisp_avg = smoothstep(0.24, 0.78, wisp_sum / max(valley_sum, 1e-4));
            let wisp_amp = valley_w * clamp(weight_sum, 0.0, 1.0)
                * clamp(0.42 + 0.35 * storm + 0.35 * sunset + 0.35 * climate.y, 0.38, 1.0);
            fog_amount = clamp(fog_amount * mix(1.0, mix(0.76, 1.28, wisp_avg), wisp_amp), 0.0, max_cap);
            let sunlit_wisp = haze_col * 1.14 + vec3<f32>(0.10, 0.07, 0.04) * sun_fwd * daylight;
            haze_col = mix(haze_col, mix(haze_col * 0.86, sunlit_wisp, wisp_avg), wisp_amp * 0.82);
        }
    }

    return mix(colour, haze_col, fog_amount);
}

fn zp_ao_filtered(uv: vec2<f32>, dist: f32) -> f32 {
    let dims = vec2<f32>(textureDimensions(ao));
    let base = vec2<i32>(floor(uv * dims)) - vec2<i32>(2, 2);
    let max_texel = vec2<i32>(dims) - vec2<i32>(1, 1);
    var sum = 0.0;
    var weight = 0.0;
    for (var y = 0; y < 4; y = y + 1) {
        for (var x = 0; x < 4; x = x + 1) {
            let texel = clamp(base + vec2<i32>(x, y), vec2<i32>(0, 0), max_texel);
            let s = textureLoad(ao, texel, 0);
            let w = 1.0 - clamp(abs(s.g - dist) / (0.08 * dist + 0.25), 0.0, 1.0);
            sum = sum + s.r * w;
            weight = weight + w;
        }
    }
    if (weight < 1e-3) {
        let c = textureLoad(ao, clamp(vec2<i32>(floor(uv * dims)), vec2<i32>(0, 0), max_texel), 0);
        return c.r;
    }
    return sum / weight;
}

fn zp_light_filtered(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let dims = vec2<i32>(textureDimensions(vlight));
    let p = uv * vec2<f32>(dims) - vec2<f32>(0.5);
    let base = vec2<i32>(floor(p)) - vec2<i32>(1);
    let f = fract(p);
    var sum = vec3<f32>(0.0);
    var total = 0.0;
    for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
            let texel = clamp(base + vec2<i32>(x, y), vec2<i32>(0), dims - vec2<i32>(1));
            let tap_uv = (vec2<f32>(texel) + vec2<f32>(0.5)) / vec2<f32>(dims);
            let tap_depth = depth_at(tap_uv);
            if ((depth > 0.0) != (tap_depth > 0.0)) { continue; }
            var range_weight = 1.0;
            if (depth > 0.0) {
                // Own choice: relative reversed-depth tolerance; no view-space
                // reconstruction needed for the 16 filter taps.
                let difference = abs(tap_depth - depth) / max(depth, 1e-6);
                range_weight = 1.0 - smoothstep(0.05, 0.15, difference);
            }
            let offset = vec2<f32>(f32(x - 1), f32(y - 1));
            let tent = max(vec2<f32>(0.0), vec2<f32>(1.0) - abs(offset - f) * 0.5);
            let weight = tent.x * tent.y * range_weight;
            sum += textureLoad(vlight, texel, 0).rgb * weight;
            total += weight;
        }
    }
    // Subpixel geometry can have no matching half-resolution sample. Zero haze
    // there is safer than copying a background sample over the foreground.
    return sum / max(total, 1e-6);
}

// World-axes unit direction of the sky at `uv` for the bobbed projection (matching volumetric.wgsl).
fn zp_sky_ray(uv: vec2<f32>) -> vec3<f32> {
    let clip_xy = vec2<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let near = frame.projection_inverse * vec4<f32>(clip_xy, 1.0, 1.0);
    let far = frame.projection_inverse * vec4<f32>(clip_xy, 0.0, 1.0);
    let ray_view = far.xyz * near.w - near.xyz * far.w;
    let ray_world = (frame.view_inverse * vec4<f32>(ray_view, 0.0)).xyz;
    let reference = view_position(uv, 0.5);
    let len = length(ray_world);
    if (len < 1e-6) {
        return normalize(reference);
    }
    return select(-ray_world, ray_world, dot(ray_world, reference) >= 0.0) / len;
}

fn zp_snowstorm_weight() -> f32 {
    if frame.dimension != 0 || frame.eye_in != 0u || frame.precipitation != 2u
        || frame.blindness > 0.0 || frame.darkness > 0.0 {
        return 0.0;
    }
    let open_air = smoothstep(0.54, 0.94, frame.eye_light_smooth.y);
    let snow = smoothstep(0.18, 0.96, frame.rain);
    return min(atmospheric_fog, 1.0) * open_air * snow * mix(0.74, 1.0, frame.thunder);
}

fn zp_snowstorm_haze(colour: vec3<f32>, distance: f32, snow: f32) -> vec3<f32> {
    let day = smoothstep(-0.12, 0.20, frame.sun_direction.y);
    let snowlight = mix(vec3<f32>(0.012, 0.019, 0.035), vec3<f32>(0.34, 0.42, 0.52), day);
    let opacity = (1.0 - exp2(-max(distance - 4.0, 0.0) * 0.050)) * snow * 0.94;
    return mix(colour, snowlight, opacity);
}

// Pure 3D world-space volumetric dawn mist integrated strictly along each pixel's unobstructed ray.
// Uses deterministic front-loaded steps with Nyquist-attenuated 3D domain-warped fBm (no screen-space
// footprint projection and no unfiltered per-pixel jitter), preventing object halos and motion shimmer.
fn zp_dawn_mist(
    colour: vec3<f32>,
    direction: vec3<f32>,
    limit: f32,
    strength: f32,
    base_y: f32,
) -> vec3<f32> {
    let eye_height = frame.camera_position.y - base_y;
    let segment = zn_water_mist_segment(eye_height, direction.y, min(limit, 92.0));
    let t_start = max(segment.x, 8.5);
    let t_end = segment.y;
    let span = t_end - t_start;
    if span <= 0.15 { return colour; }

    let n_steps = select(select(8u, 10u, quality_mode >= 2u), 6u, quality_mode == 0u);
    let inv_n = 1.0 / f32(n_steps);

    let drift = zn_water_mist_drift(frame.time);
    let dawn_light = smoothstep(-0.16, 0.11, frame.sun_direction.y);
    let core_col = mix(vec3<f32>(0.068, 0.098, 0.150), vec3<f32>(0.25, 0.32, 0.40), dawn_light);
    let crest_col = mix(vec3<f32>(0.125, 0.168, 0.235), vec3<f32>(0.46, 0.53, 0.60), dawn_light);
    let forward = pow(max(dot(direction, frame.sun_direction), 0.0), 4.0)
        * smoothstep(-0.075, 0.10, frame.sun_direction.y);

    var accum = vec3<f32>(0.0);
    var trans = 1.0;
    for (var i = 0u; i < 10u; i = i + 1u) {
        if i >= n_steps || trans < 0.38 { break; }
        let u0 = f32(i) * inv_n;
        let u1 = f32(i + 1u) * inv_n;
        let f0 = mix(u0, u0 * u0, 0.45);
        let f1 = mix(u1, u1 * u1, 0.45);
        let t0 = t_start + span * f0;
        let t1 = t_start + span * f1;
        let dt = t1 - t0;
        let t = 0.5 * (t0 + t1);
        let near_fade = smoothstep(8.5, 22.0, t);
        if near_fade <= 0.001 { continue; }

        let p = direction * t;
        let wp = p + frame.camera_position;
        let h = eye_height + p.y;
        let h_norm = clamp(h / ZN_WATER_MIST_TOP, 0.0, 1.0);

        let q = vec3<f32>(
            wp.x * 0.052 + drift.x * 0.36,
            h * 0.38 - frame.time * 0.024,
            wp.z * 0.052 + drift.y * 0.36,
        );
        let w1 = zp_vnoise3(q * 0.88);
        let w2 = zp_vnoise3(q * 0.88 + vec3<f32>(5.2, 1.3, -3.7));
        let warped = q + vec3<f32>(w1 - 0.5, (w2 - 0.5) * 0.35, w2 - 0.5) * 1.55;
        let v0 = zp_vnoise3(warped * 1.15);
        let detail_w = 1.0 - smoothstep(4.5, 11.5, dt);
        let v1 = select(0.5, zp_vnoise3(warped * 2.38 + vec3<f32>(13.7, 7.3, 19.1)), detail_w > 0.01);
        let vapor = mix(v0, v0 * 0.68 + v1 * 0.32, detail_w);

        // Dense valley core right over water (h = 0..1.1), wispy swirling plumes rising where vapor is thick.
        let ragged_h = h_norm - (vapor - 0.5) * 0.42;
        let base_env = 1.0 - smoothstep(0.06, 0.94, ragged_h);
        let height_env = base_env * base_env;
        let billow = smoothstep(0.24, 0.82, vapor);
        let density = near_fade * height_env * (0.14 + 0.96 * billow);
        if density <= 0.001 { continue; }

        let sun_rim = vec3<f32>(0.76, 0.50, 0.34) * (forward * (0.42 + 0.58 * billow));
        let top_lit = clamp(h_norm * 0.65 + billow * 0.55, 0.0, 1.0);
        let step_col = mix(core_col, crest_col, top_lit) + sun_rim * 0.60;
        let step_alpha = 1.0 - exp(-density * dt * 0.095 * strength);
        accum += trans * step_col * step_alpha;
        trans *= (1.0 - step_alpha);
    }

    trans = max(trans, 0.44);
    return colour * trans + accum;
}

fn post(input: PostInput) -> vec4<f32> {
    var colour = max(input.color.rgb, vec3<f32>(0.0));
    let climate = zp_outdoor_climate();
    let air_light = smoothstep(0.20, 0.70, frame.eye_light_smooth.y)
        * smoothstep(-0.02, 0.16, frame.sun_direction.y) * (1.0 - frame.thunder * 0.45);
    var scene_distance = 160.0;
    var scene_point = vec3<f32>(0.0);

    if (input.depth <= 0.0 && frame.eye_in == 0u) {
        if (frame.dimension == 1) {
            let vis = 1.0 - clamp(max(frame.blindness, frame.darkness), 0.0, 1.0);
            if (vis > 0.001) {
                let d = zp_sky_ray(input.uv);
                let end_sky = zn_sky_end(d, frame.fog_color, frame.resolution.y);
                let fg_excess = max(colour - vec3<f32>(0.025, 0.016, 0.032), vec3<f32>(0.0));
                colour = mix(colour, end_sky + fg_excess, vis);
            }
        } else if frame.dimension == 0 && dot(climate, climate) > 0.001 && air_light > 0.001 {
            let direction = zp_sky_ray(input.uv);
            let horizon = 1.0 - smoothstep(0.025, 0.32, abs(direction.y));
            colour = zp_climate_irradiance(colour, climate, air_light * horizon);
        } else if (frame.dimension == -1) {
            let vis = 1.0 - clamp(max(frame.blindness, frame.darkness), 0.0, 1.0);
            if (vis > 0.001) {
                let d = zp_sky_ray(input.uv);
                let nether_sky = zn_sky_nether(d, colour, frame.fog_color, frame.time);
                let fg_excess = max(colour - max(frame.fog_color, vec3<f32>(0.025, 0.008, 0.004)) * 1.15, vec3<f32>(0.0));
                colour = mix(colour, nether_sky + fg_excess, vis);
            }
        }
    }

    if (input.depth > 0.0 && (ao_strength > 0.0 || contact_shadows || atmospheric_fog > 0.001)) {
        let P = view_position(input.uv, input.depth);
        scene_point = P;
        let dist = length(P);
        scene_distance = dist;

        if (ao_strength > 0.0) {
            let visibility = pow(zp_ao_filtered(input.uv, dist), ZP_AO_POWER);
            // Own choice: retain gentle underwater contact shadows without the
            // heavy black halos that obscure the seabed and kelp texture detail.
            let water_ao = mix(1.0, 0.35, select(0.0, 1.0, frame.eye_in == 1u));
            let k = ao_strength * water_ao / (1.0 + 0.35 * zn_luma(colour));
            let est_albedo = zp_estimate_albedo(colour);
            let ao_rgb = zp_gtao_multibounce(visibility, est_albedo);
            colour = colour * mix(vec3<f32>(1.0), ao_rgb, clamp(k, 0.0, 1.0));
        }

        let c_shadow = zp_contact_shadow(input, P, dist, colour);
        colour = colour * (1.0 - c_shadow);

        if dot(climate, climate) > 0.001 && air_light > 0.001 {
            colour = zp_climate_irradiance(colour, climate, air_light);
        }
        colour = zp_atmospheric_fog(P, dist, colour, climate);
    }

    if (volumetric_light > 0.0) {
        colour = colour + zp_light_filtered(input.uv, input.depth);
    }
    if atmospheric_fog > 0.001 && frame.dimension == 0 && frame.eye_in == 0u
        && frame.blindness <= 0.0 && frame.darkness <= 0.0 && frame.night_vision <= 0.0 {
        let cam_sky = min(frame.eye_light.y, frame.eye_light_smooth.y);
        let mist = zn_water_mist_strength(frame.day_time, frame.rain, frame.downfall, cam_sky)
            * smoothstep(0.60, 0.94, cam_sky);
        if mist > 0.001 {
            var direction = scene_point / max(scene_distance, 0.001);
            if input.depth <= 0.0 {
                direction = zp_sky_ray(input.uv);
            }
            let base_y = select(62.88, frame.water_plane, frame.has_reflection != 0u);
            colour = zp_dawn_mist(colour, direction, scene_distance, mist * min(atmospheric_fog, 1.3), base_y);
        }
    }
    let snow = zp_snowstorm_weight();
    if snow > 0.001 {
        colour = zp_snowstorm_haze(colour, scene_distance, snow);
    }
    return vec4<f32>(colour, 1.0);
}
