// src: Perlin 2002 / domain-warped fBm, Jimenez 2014 IGN, Horizon Shader API 0.2
// Pass 4 (after compose, before bloom): animated 3D volumetric warp rift portal in The End.
//
// Composite the separate reflection contribution before evaluating the End warp rift.

override quality_mode: u32 = 1u;          // 0 = Performance, 1 = Balanced, 2 = Quality

const ZP_ER_PORTAL_RAD: f32 = 54.0;       // Inner-mid vortex throat radius in blocks
const ZP_ER_PORTAL_FWD: vec3<f32> = vec3<f32>(0.621462, -0.050118, 0.781839);

// World-axes unit ray for the bobbed projection (matching volumetric.wgsl / compose.wgsl).
fn zp_er_sky_ray(uv: vec2<f32>) -> vec3<f32> {
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

fn zp_er_hash31(p: vec3<f32>) -> f32 {
    let q = fract(p * vec3<f32>(0.1031, 0.1030, 0.0973));
    let r = q + dot(q, q.yxz + vec3<f32>(33.33));
    return fract((r.x + r.y) * r.z);
}

fn zp_er_vnoise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (vec3<f32>(3.0) - 2.0 * f);
    let n000 = zp_er_hash31(i + vec3<f32>(0.0, 0.0, 0.0));
    let n100 = zp_er_hash31(i + vec3<f32>(1.0, 0.0, 0.0));
    let n010 = zp_er_hash31(i + vec3<f32>(0.0, 1.0, 0.0));
    let n110 = zp_er_hash31(i + vec3<f32>(1.0, 1.0, 0.0));
    let n001 = zp_er_hash31(i + vec3<f32>(0.0, 0.0, 1.0));
    let n101 = zp_er_hash31(i + vec3<f32>(1.0, 0.0, 1.0));
    let n011 = zp_er_hash31(i + vec3<f32>(0.0, 1.0, 1.0));
    let n111 = zp_er_hash31(i + vec3<f32>(1.0, 1.0, 1.0));
    let nx00 = mix(n000, n100, u.x);
    let nx10 = mix(n010, n110, u.x);
    let nx01 = mix(n001, n101, u.x);
    let nx11 = mix(n011, n111, u.x);
    return mix(mix(nx00, nx10, u.y), mix(nx01, nx11, u.y), u.z);
}

fn zp_er_fbm3(p: vec3<f32>) -> f32 {
    var sum = 0.0;
    var amp = 0.52;
    var q = p;
    for (var i = 0; i < 3; i = i + 1) {
        sum = sum + amp * zp_er_vnoise3(q);
        q = q * 2.07 + vec3<f32>(13.7, 7.3, 19.1);
        amp = amp * 0.48;
    }
    return sum;
}

fn zp_er_sphere_hit(ro: vec3<f32>, rd: vec3<f32>, center: vec3<f32>, rad: f32) -> vec2<f32> {
    let oc = ro - center;
    let b = dot(oc, rd);
    let c = dot(oc, oc) - rad * rad;
    let h = b * b - c;
    if (h < 0.0) {
        return vec2<f32>(1.0, -1.0);
    }
    let sq = sqrt(h);
    return vec2<f32>(max(-b - sq, 0.0), -b + sq);
}

// Volumetric 3D swirling purple warp nebula + blazing lavender-white core + crackling rim lightning.
fn zp_er_eval_portal(
    rd: vec3<f32>,
    p_pos: vec3<f32>,
    p_fwd: vec3<f32>,
    open_frac: f32,
    flash: f32,
    t_limit: f32,
    jitter: f32,
    phase_time: f32,
    out_transmittance: ptr<function, f32>,
) -> vec3<f32> {
    if (open_frac <= 0.005 && flash <= 0.01) {
        return vec3<f32>(0.0);
    }
    let rad_eff = max(ZP_ER_PORTAL_RAD * mix(0.25, 1.0, open_frac), 14.0);
    let sph = zp_er_sphere_hit(vec3<f32>(0.0), rd, p_pos, rad_eff * 2.15);
    let t_start = sph.x;
    let t_end = min(sph.y, t_limit);
    if (t_start >= t_end) {
        return vec3<f32>(0.0);
    }

    let p_right = normalize(cross(p_fwd, vec3<f32>(0.0, 1.0, 0.0)));
    let p_up = cross(p_right, p_fwd);

    var n_steps = 12;
    if (quality_mode == 0u) {
        n_steps = 8;
    } else if (quality_mode == 2u) {
        n_steps = 16;
    }

    let dt = (t_end - t_start) / f32(n_steps);
    var accum = vec3<f32>(0.0);
    var trans = 1.0;

    for (var i = 0; i < 16; i = i + 1) {
        if (i >= n_steps || trans < 0.02) {
            break;
        }
        let t = t_start + (f32(i) + jitter) * dt;
        let pw = rd * t;
        let rel = pw - p_pos;
        let z_loc = dot(rel, p_fwd);
        let x_loc = dot(rel, p_right);
        let y_loc = dot(rel, p_up);

        // Conical swirling vortex throat
        let cone_r = rad_eff * (0.90 + clamp(z_loc / (rad_eff * 2.2), -0.40, 0.35));
        let r = length(vec2<f32>(x_loc, y_loc));
        let rn = r / max(cone_r, 1.0);

        // Domain-warped spiral cloud coordinates
        let base_ang = atan2(y_loc, x_loc);
        let swirl_ang = base_ang + phase_time * 0.36 - rn * 2.6 + z_loc * 0.026;
        let cs = cos(swirl_ang);
        let sn = sin(swirl_ang);
        let turb_coord = vec3<f32>(cs * (rn * 3.4), sn * (rn * 3.4), z_loc * 0.06 - phase_time * 0.28);
        let warp = zp_er_fbm3(turb_coord * 1.15);
        let p_warped = turb_coord + vec3<f32>(warp * 1.5, -warp * 1.2, warp * 0.85);
        let cloud_n = zp_er_fbm3(p_warped * 1.65);

        // Strong angular cloud lobes so the outer edge dissolves into dark cosmic wisps (zero round boundary!)
        let lobe = zp_er_fbm3(vec3<f32>(cos(base_ang - rn * 1.2) * 2.1, sin(base_ang - rn * 1.2) * 2.1, phase_time * 0.08));
        let outer_limit = 0.85 + 0.85 * lobe;
        let rn_torn = rn + (cloud_n - 0.5) * 0.55;
        let inner_clear = smoothstep(0.30, 0.68, rn_torn);
        let outer_fade = 1.0 - smoothstep(outer_limit * 0.48, outer_limit, rn);
        let z_off = (z_loc + rad_eff * 0.14) / (rad_eff * 1.25);
        let z_fade = exp(-z_off * z_off * 1.15) * (1.0 - smoothstep(0.65, 1.35, abs(z_off)));
        let sph_fade = 1.0 - smoothstep(rad_eff * 1.40, rad_eff * 2.12, length(rel));
        let cam_fade = smoothstep(8.0, 28.0, t);
        let billow = smoothstep(0.28, 0.82, cloud_n);
        let density = (inner_clear * outer_fade * z_fade * sph_fade * cam_fade) * billow * smoothstep(0.0, 0.22, open_frac);

        if (density > 0.008) {
            // Very dark abyssal violet outer clouds melting into End sky -> rich purple -> hot magenta throat folds
            let throat_lit = exp(-pow(max(rn_torn - 0.38, 0.0) / 0.22, 2.0)) * smoothstep(0.35, 0.80, cloud_n);
            let outer_dark = vec3<f32>(0.007, 0.001, 0.018);
            let mid_purple = vec3<f32>(0.19, 0.022, 0.42);
            let edge_dim = 1.0 - smoothstep(outer_limit * 0.35, outer_limit * 0.92, rn);
            let cloud_col = mix(outer_dark, mid_purple, billow * edge_dim)
                + vec3<f32>(1.15, 0.22, 1.55) * (throat_lit * edge_dim);

            let step_alpha = 1.0 - exp(-density * dt * 0.068 * mix(0.28, 1.0, edge_dim));
            accum = accum + trans * cloud_col * step_alpha;
            trans = trans * (1.0 - step_alpha);
        }
    }
    if (t_limit < 1e5) {
        // Keep foreground terrain behind the outer warp wisps legible instead of blacked out by portal absorption.
        trans = max(trans, 0.48);
    }

    // Dazzling irregular white-lavender central warp throat + razor-crisp crackling rim lightning (jitter-free plane!)
    let denom = dot(rd, p_fwd);
    if (abs(denom) > 1e-4) {
        let t_core = dot(p_pos - p_fwd * 8.0, p_fwd) / denom;
        if (t_core > 0.0 && t_core < t_limit) {
            let rel_c = rd * t_core - p_pos;
            let rx_c = dot(rel_c, p_right);
            let ry_c = dot(rel_c, p_up);
            let r_c = length(vec2<f32>(rx_c, ry_c)) / max(rad_eff, 1.0);
            let ang_c = atan2(ry_c, rx_c);
            let edge_wobble = 0.20 * (zp_er_vnoise3(vec3<f32>(cos(ang_c) * 4.5, sin(ang_c) * 4.5, phase_time * 0.55)) - 0.5);
            let core_mask = 1.0 - smoothstep(0.22 + edge_wobble, 0.50 + edge_wobble, r_c);
            let flare_halo = exp(-r_c * r_c * 6.5) * (0.18 + flash * 1.2);
            let core_hdr = vec3<f32>(3.4, 2.6, 4.6) * (core_mask * (0.88 + 0.32 * open_frac) + flare_halo) * clamp(open_frac + flash * 0.7, 0.0, 1.3);
            let core_cov = clamp(core_mask * open_frac * 0.96, 0.0, 1.0);
            accum = accum + trans * core_hdr;
            trans = trans * (1.0 - core_cov);

            // Clean jitter-free crackling pink-white lightning arcs branching in 3 discrete sectors around the vortex rim
            let t_tick = floor(phase_time * 6.0);
            let arc_w = abs(sin(ang_c * 3.0 + t_tick * 1.9 + zp_er_fbm3(vec3<f32>(rx_c, ry_c, t_tick * 3.7) * 0.08) * 6.5));
            let arc_rad_dist = abs(r_c - (0.78 + 0.25 * (zp_er_vnoise3(vec3<f32>(cos(ang_c) * 3.0, sin(ang_c) * 3.0, t_tick * 2.3)) - 0.5)));
            let arc_gate = smoothstep(0.58, 0.85, zp_er_vnoise3(vec3<f32>(cos(ang_c) * 2.2, sin(ang_c) * 2.2, t_tick * 1.7)));
            let arc_thin = exp(-arc_w * 28.0) * exp(-arc_rad_dist * 18.0) * arc_gate * smoothstep(0.05, 0.35, open_frac);
            accum = accum + (0.25 + 0.75 * trans) * vec3<f32>(5.5, 1.6, 4.8) * arc_thin;
        }
    }

    *out_transmittance = trans;
    return accum;
}

fn zp_er_post(input: PostInput) -> vec4<f32> {
    let reflection = textureLoad(zp_reflection, vec2<i32>(input.pixel), 0).rgb;
    let base = max(input.color.rgb + reflection, vec3<f32>(0.0));
    if (frame.dimension != 1 || !end_rift) {
        return vec4<f32>(base, 1.0);
    }

    let phase = zn_rift_phase();
    let phase_time = frame.time * max(end_rift_speed, 0.05);
    let portal_pos = zn_rift_center();
    let portal_open = zn_rift_aperture(phase);
    let pulse = 0.5 + 0.5 * sin(phase_time * 0.35);
    let portal_flash = 0.08 + 0.14 * pow(pulse, 4.0);
    let rd = zp_er_sky_ray(input.uv);

    let h_in = zp_er_sphere_hit(vec3<f32>(0.0), rd, portal_pos, ZP_ER_PORTAL_RAD * 2.20);
    if (h_in.y < 0.0) {
        return vec4<f32>(base, 1.0);
    }

    let t_scene = select(1e6, length(view_position(input.uv, input.depth)), input.depth > 0.0);
    let jitter = zn_ign(input.pixel, frame.frame_index);

    var trans = 1.0;
    let hdr = zp_er_eval_portal(
        rd, portal_pos, ZP_ER_PORTAL_FWD,
        portal_open, portal_flash, t_scene, jitter, phase_time, &trans
    );
    return vec4<f32>(base * trans + hdr, 1.0);
}

// Screen-space subsurface scattering diffuses the lit picture before the reflection contribution is added.
fn post(input: PostInput) -> vec4<f32> {
    var lit = input;
    lit.color = zp_sss_apply(input);
    return zp_er_post(lit);
}
