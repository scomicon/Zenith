// src: S. Hillaire, "A Scalable and Production Ready Sky and Atmosphere Rendering Technique", EGSR 2020 (64x32 sky-view LUT physical scattering parameters); Horizon Shader API 0.2 ([[before_world]], ComputeInput, kept rgba16float resources, camera-local climate inputs).

override sky_saturation: f32 = 1.0;

const ZP_LUT_PI: f32 = 3.141592654;
const ZP_SKY_GROUND: f32 = 6360.0;
const ZP_SKY_TOP: f32 = 6460.0;
const ZP_RAYLEIGH: vec3<f32> = vec3<f32>(5.802e-3, 13.558e-3, 33.100e-3);
const ZP_MIE_SCAT: vec3<f32> = vec3<f32>(3.996e-3);
const ZP_MIE_EXT: vec3<f32> = vec3<f32>(4.440e-3);
const ZP_OZONE: vec3<f32> = vec3<f32>(0.36e-3, 0.68e-3, 0.05e-3);

fn zp_lut_atmosphere_exit(r: f32, mu: f32) -> f32 {
    let b = r * mu;
    let c = r * r - ZP_SKY_TOP * ZP_SKY_TOP;
    return max(-b + sqrt(max(b * b - c, 0.0)), 0.0);
}

fn zp_lut_sun_transmittance(pos: vec3<f32>, sun_dir: vec3<f32>) -> vec3<f32> {
    let r = length(pos);
    let up = pos / max(r, 1e-4);
    let mu = dot(up, sun_dir);
    let sin_h = ZP_SKY_GROUND / max(r, ZP_SKY_GROUND);
    let tan_mu = -sqrt(max(1.0 - sin_h * sin_h, 0.0));
    let earth_vis = smoothstep(tan_mu - 0.032, tan_mu + 0.018, mu);
    if earth_vis <= 0.001 {
        return vec3<f32>(0.0);
    }

    let seg_len = zp_lut_atmosphere_exit(r, mu);
    var od_r = 0.0;
    var od_m = 0.0;
    var od_o3 = 0.0;
    for (var i = 0; i < 4; i = i + 1) {
        let u = (f32(i) + 0.5) * 0.25;
        let t = seg_len * u * u;
        let dt = seg_len * (0.125 * (2.0 * f32(i) + 1.0));
        let alt = max(length(pos + sun_dir * t) - ZP_SKY_GROUND, 0.0);
        od_r = od_r + exp(-alt / 8.0) * dt;
        od_m = od_m + exp(-alt / 1.2) * dt;
        od_o3 = od_o3 + max(0.0, 1.0 - abs(alt - 25.0) / 15.0) * dt;
    }
    let od = ZP_RAYLEIGH * od_r + ZP_MIE_EXT * od_m + ZP_OZONE * od_o3;
    return exp(-od) * earth_vis;
}

fn zp_lut_eval_overworld_sky(dir: vec3<f32>) -> vec3<f32> {
    let sun_len = length(frame.sun_direction);
    let sun = select(vec3<f32>(0.0, 1.0, 0.0), frame.sun_direction / sun_len, sun_len > 1e-5);
    let r0 = ZP_SKY_GROUND + max(frame.camera_position.y - 62.0, 1.0) * 0.001 + 0.012;
    let pos0 = vec3<f32>(0.0, r0, 0.0);
    let ray_len = zp_lut_atmosphere_exit(r0, dir.y);

    let day_w = zn_celestial_weights(sun.y, frame.moon_direction.y).x;
    let twilight_w = smoothstep(-0.14, 0.10, sun.y);

    var scatter_r = vec3<f32>(0.0);
    var scatter_m = vec3<f32>(0.0);
    var od_view = vec3<f32>(0.0);

    if twilight_w > 0.001 && ray_len > 0.0 {
        for (var i = 0; i < 8; i = i + 1) {
            let u0 = f32(i) * 0.125;
            let u1 = u0 + 0.125;
            let u = 0.5 * (u0 + u1);
            let t = ray_len * u * u;
            let dt = ray_len * (u1 * u1 - u0 * u0);
            let sample_pos = pos0 + dir * t;
            let alt = max(length(sample_pos) - ZP_SKY_GROUND, 0.0);

            let rho_r = exp(-alt / 8.0);
            let rho_m = exp(-alt / 1.2);
            let rho_o3 = max(0.0, 1.0 - abs(alt - 25.0) / 15.0);
            let step_ext = ZP_RAYLEIGH * rho_r + ZP_MIE_EXT * rho_m + ZP_OZONE * rho_o3;
            let step_trans = exp(-step_ext * dt);

            let sun_trans = zp_lut_sun_transmittance(sample_pos, sun);
            let mid_trans = exp(-od_view) * sqrt(step_trans);

            scatter_r = scatter_r + ZP_RAYLEIGH * (rho_r * dt) * sun_trans * mid_trans;
            scatter_m = scatter_m + ZP_MIE_SCAT * (rho_m * dt) * sun_trans * mid_trans;
            od_view = od_view + step_ext * dt;
        }
    }

    let cos_t = dot(dir, sun);
    let phase_r = (3.0 / (16.0 * ZP_LUT_PI)) * (1.0 + cos_t * cos_t);
    let g = 0.78;
    let g2 = g * g;
    let phase_m = (3.0 / (8.0 * ZP_LUT_PI))
        * ((1.0 - g2) * (1.0 + cos_t * cos_t))
        / ((2.0 + g2) * pow(max(1.0 + g2 - 2.0 * g * cos_t, 1e-4), 1.5));

    let sun_scatter = (scatter_r * phase_r + scatter_m * phase_m) * (14.0 * twilight_w);

    // Horizon-to-zenith night airglow and cool moonlit scatter matching Zenith night sky contrast.
    let horiz = pow(1.0 - clamp(dir.y, 0.0, 1.0), 3.0);
    let night_base = mix(vec3<f32>(0.0040, 0.0072, 0.0155), vec3<f32>(0.0090, 0.0145, 0.0270), horiz);
    let night_col = night_base * mix(1.0, 0.35, day_w);

    var col = sun_scatter + night_col;

    // Preserve monotonic green channel during twilight transitions (avoid ozone magenta cast on water).
    col.g = max(col.g, min(col.r, col.b) * 0.96);

    let storm = clamp(frame.rain * 0.74 + frame.thunder * 0.26, 0.0, 1.0);
    let overcast = mix(vec3<f32>(0.008, 0.012, 0.022), vec3<f32>(0.20, 0.24, 0.29), day_w);
    col = mix(col, overcast, storm * 0.86);

    let luma = zn_luma(col);
    return max(mix(vec3<f32>(luma), col, clamp(sky_saturation, 0.0, 1.6)), vec3<f32>(0.0));
}

fn zp_climate_target() -> vec3<f32> {
    let cold = smoothstep(0.32, 0.05, frame.temperature);
    let warm = smoothstep(0.62, 1.15, frame.temperature);
    let dry = 1.0 - smoothstep(0.18, 0.55, frame.downfall);
    let wet = smoothstep(0.42, 0.85, frame.downfall);

    let arid = warm * dry;
    let lush = wet * (1.0 - cold);
    return clamp(vec3<f32>(arid, lush, cold), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn zp_climate_blend() -> f32 {
    if frame.delta_time <= 0.0 || frame.delta_time > 0.5 || length(frame.camera_motion) > 8.0 {
        return 1.0;
    }
    return 1.0 - exp(-2.1 * frame.delta_time);
}

fn compute(input: ComputeInput) {
    if !input.in_bounds || input.cell.x >= 64u || input.cell.y >= 33u {
        return;
    }

    if frame.dimension != 0 {
        textureStore(zp_climate, vec2<i32>(input.cell.xy), vec4<f32>(0.0));
        return;
    }

    if input.cell.y == 32u {
        if input.cell.x == 0u {
            let climate_target = zp_climate_target();
            let prev = textureLoad(zp_climate_previous, vec2<i32>(0, 32), 0);
            let alpha = select(zp_climate_blend(), 1.0, prev.a < 0.5);
            let smoothed = mix(prev.rgb, climate_target, alpha);
            textureStore(zp_climate, vec2<i32>(0, 32), vec4<f32>(smoothed, 1.0));
        } else {
            textureStore(zp_climate, vec2<i32>(input.cell.xy), vec4<f32>(0.0));
        }
        return;
    }

    let phi = select(
        (f32(input.cell.x) / 63.0 - 0.5) * (2.0 * ZP_LUT_PI),
        -ZP_LUT_PI,
        input.cell.x == 0u || input.cell.x == 63u,
    );
    let v_norm = f32(input.cell.y) / 31.0;
    let sin_e = v_norm * v_norm;
    let cos_e = sqrt(max(1.0 - sin_e * sin_e, 0.0));
    let dir = vec3<f32>(cos(phi) * cos_e, sin_e, sin(phi) * cos_e);

    let sky_rgb = zp_lut_eval_overworld_sky(dir);
    textureStore(zp_climate, vec2<i32>(input.cell.xy), vec4<f32>(sky_rgb, 1.0));
}
