// src: Morgan McGuire & Michael Mara, "Efficient GPU Screen-Space Ray Tracing", JCGT 3(4), 2014 (view-space ray march and binary-search refinement concept); Christophe Schlick, Eurographics 1994 (Fresnel); Jorge Jimenez, SIGGRAPH 2014 (IGN ray jitter); Horizon Shader API 0.2 (PostInput, surface_at, view_position, depth_at, previous).
// Pass 4: Screen-Space Reflections (SSR) on smooth metals, gems, polished blocks & rain puddles.

override ssr_enabled: bool = true;
override temporal_ssr: bool = false;
override ssr_glossy: bool = true;
override ssr_hiz: bool = true;
override quality_mode: u32 = 1u; // 0 = Performance, 1 = Balanced, 2 = Quality (manifest order)

const ZP_SSR_STEPS: vec3<i32> = vec3<i32>(24, 36, 48);

fn zp_ssr_sample_color(uv: vec2<f32>, smoothness: f32, hit_dist: f32) -> vec3<f32> {
    let dims = vec2<f32>(textureDimensions(previous));
    let px = 1.0 / max(dims, vec2<f32>(1.0));
    // Contact hardening: rough surfaces blur more the farther the reflected point is from them.
    let spread = select(1.0, 1.0 + (1.0 - smoothness) * clamp(hit_dist * 0.18, 0.0, 1.6), ssr_glossy);
    let blur = clamp((1.0 - smoothness) * 6.5 * spread + 0.5, 0.5, 5.5);
    let o1 = vec2<f32>(blur * px.x, blur * 0.5 * px.y);
    let o2 = vec2<f32>(-blur * 0.5 * px.x, blur * px.y);
    let c0 = textureSampleLevel(previous, linear_sampler, clamp(uv + o1, vec2<f32>(0.001), vec2<f32>(0.999)), 0.0).rgb;
    let c1 = textureSampleLevel(previous, linear_sampler, clamp(uv - o1, vec2<f32>(0.001), vec2<f32>(0.999)), 0.0).rgb;
    let c2 = textureSampleLevel(previous, linear_sampler, clamp(uv + o2, vec2<f32>(0.001), vec2<f32>(0.999)), 0.0).rgb;
    let c3 = textureSampleLevel(previous, linear_sampler, clamp(uv - o2, vec2<f32>(0.001), vec2<f32>(0.999)), 0.0).rgb;
    return clamp((c0 + c1 + c2 + c3) * 0.25, vec3<f32>(0.0), vec3<f32>(8.0));
}

// Hi-Z leap: true when the ray, sampled at four points spaced 2 * dt apart, stays in front of the nearest
// surface of the 12x12-pixel neighbourhood around each point (zp_hiz_quarter), with the points no more than
// 8 pixels apart. The skipped samples then cannot cross any surface, so the march advances 8 * dt at once.
fn zp_ssr_hiz_empty(Q0: vec3<f32>, Rm: vec3<f32>, t: f32, dt: f32) -> bool {
    let qdims = vec2<f32>(textureDimensions(zp_hiz_quarter));
    let fdims = vec2<f32>(textureDimensions(previous));
    var last_px = vec2<f32>(0.0);
    var have_last = false;
    for (var k = 0; k < 5; k = k + 1) {
        let Q = Q0 + Rm * (t + dt * f32(2 * k));
        let clip = frame.projection * (frame.view * vec4<f32>(Q, 1.0));
        if clip.w <= 0.05 {
            return false;
        }
        let ray_uv = vec2<f32>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
        if any(ray_uv <= vec2<f32>(0.02)) || any(ray_uv >= vec2<f32>(0.98)) {
            return false;
        }
        let px = ray_uv * fdims;
        if have_last && length(px - last_px) > 8.0 {
            return false;
        }
        last_px = px;
        have_last = true;
        let nearest = textureLoad(zp_hiz_quarter, vec2<i32>(ray_uv * qdims), 0).r;
        // Reversed depth: a larger value is nearer. Sky tiles (0) are left to the normal march.
        if nearest <= 0.0 || clip.z / clip.w <= nearest * 1.002 + 1e-5 {
            return false;
        }
    }
    return true;
}

fn post(input: PostInput) -> vec4<f32> {
    let base = max(input.color.rgb, vec3<f32>(0.0));
    if (!ssr_enabled || input.depth <= 0.0 || frame.eye_in != 0u) {
        return vec4<f32>(0.0);
    }

    let surf = surface_at(vec2<i32>(input.pixel));
    if (!surf.present || surf.smoothness < select(0.38, 0.30, ssr_glossy)) {
        return vec4<f32>(0.0);
    }

    let P = view_position(input.uv, input.depth);
    let dist = length(P);
    let dist_fade = 1.0 - smoothstep(42.0, 88.0, dist);
    if (dist_fade <= 0.001) {
        return vec4<f32>(0.0);
    }

    let V_dir = P / max(dist, 1e-4);
    let N = normalize(surf.normal);
    let R = reflect(V_dir, N);
    let angle_fade = smoothstep(-0.02, 0.14, dot(R, N));
    // Fade rays pointing back toward the camera: head-on walls reflect behind-camera space missing from depth.
    let cam_fade = 1.0 - smoothstep(-0.10, 0.42, dot(R, -V_dir));
    let dir_fade = angle_fade * cam_fade;
    if (dir_fade <= 0.001) {
        return vec4<f32>(0.0);
    }

    // Glossy cone: jitter the march direction inside a lobe that widens with roughness (stochastic GGX-like cone).
    var Rm = R;
    if ssr_glossy && surf.smoothness < 0.92 {
        let rough = 1.0 - surf.smoothness;
        let h = zn_hash22(input.pixel + vec2<f32>(f32(select(0u, frame.frame_index % 64u, temporal_ssr)) * 7.13, 3.7));
        let up = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(R.y) > 0.95);
        let T = normalize(cross(up, R));
        let B = cross(R, T);
        let cone = rough * rough * 0.85;
        let Rj = normalize(R + (T * (h.x * 2.0 - 1.0) + B * (h.y * 2.0 - 1.0)) * cone);
        Rm = select(R, Rj, dot(Rj, N) > 0.04);
    }
    let steps = ZP_SSR_STEPS[min(quality_mode, 2u)];
    let dims = vec2<f32>(textureDimensions(previous));
    let Q0 = P + N * 0.06;
    let jitter = zn_ign(input.pixel, select(0u, frame.frame_index % 64u, temporal_ssr));
    var t = 0.08 + jitter * 0.06;
    var t_prev = 0.0;
    var prev_behind = false;
    var hit = false;
    var hit_uv = input.uv;
    var has_sky = false;
    var sky_uv = input.uv;

    var empty_run = 0;
    for (var i = 0; i < steps; i = i + 1) {
        if ssr_hiz && empty_run >= 2 {
            let dt0 = clamp(0.06 + t * 0.065, 0.06, 1.25);
            if zp_ssr_hiz_empty(Q0, Rm, t, dt0) {
                t_prev = t + dt0 * 7.0;
                t = t + dt0 * 8.0;
                prev_behind = false;
                empty_run = 0;
                continue;
            }
            empty_run = 0;
        }
        let Q = Q0 + Rm * t;
        let clip = frame.projection * (frame.view * vec4<f32>(Q, 1.0));
        if (clip.w <= 0.05) {
            break;
        }
        let ndc_xy = clip.xy / clip.w;
        let ray_uv = vec2<f32>(ndc_xy.x * 0.5 + 0.5, 0.5 - ndc_xy.y * 0.5);
        if (any(ray_uv <= vec2<f32>(0.001)) || any(ray_uv >= vec2<f32>(0.999))) {
            break;
        }

        let dt = clamp(0.06 + t * 0.065, 0.06, 1.25);
        let ndc_z = clip.z / clip.w;
        let sd = depth_at(ray_uv);
        if (sd <= 0.0) {
            has_sky = true;
            sky_uv = ray_uv;
            prev_behind = false;
        } else {
            let is_behind = ndc_z < sd;
            if (is_behind) {
                let S = view_position(ray_uv, sd);
                let delta = length(Q) - length(S);
                let thickness = clamp(0.16 + dt * 0.85, 0.16, 0.72);
                if (delta > -0.02 && delta < thickness && (!prev_behind || delta < 0.25) && dot(S - P, N) > 0.05) {
                    let hit_surf = surface_at(vec2<i32>(ray_uv * dims));
                    let front_face = !hit_surf.present || dot(normalize(hit_surf.normal), Rm) <= 0.20;
                    if (front_face) {
                        hit = true;
                        hit_uv = ray_uv;
                        break;
                    }
                }
            }
            prev_behind = is_behind;
            empty_run = select(0, empty_run + 1, !is_behind);
        }

        t_prev = t;
        t = t + dt;
    }

    if (hit) {
        var lo = t_prev;
        var hi = t;
        for (var b = 0; b < 4; b = b + 1) {
            let mid = 0.5 * (lo + hi);
            let Qm = Q0 + Rm * mid;
            let clip_m = frame.projection * (frame.view * vec4<f32>(Qm, 1.0));
            if (clip_m.w <= 0.05) {
                hi = mid;
                continue;
            }
            let uv_m = vec2<f32>(clip_m.x / clip_m.w * 0.5 + 0.5, 0.5 - clip_m.y / clip_m.w * 0.5);
            if (any(uv_m <= vec2<f32>(0.001)) || any(uv_m >= vec2<f32>(0.999))) {
                hi = mid;
                continue;
            }
            let sd_m = depth_at(uv_m);
            let z_m = clip_m.z / clip_m.w;
            if (sd_m > 0.0 && z_m < sd_m) {
                let S_m = view_position(uv_m, sd_m);
                let d_m = length(Qm) - length(S_m);
                if (d_m < 0.72 && dot(S_m - P, N) > 0.05) {
                    hit_uv = uv_m;
                    hi = mid;
                } else {
                    lo = mid;
                }
            } else {
                lo = mid;
            }
        }
    }

    if (!hit && !(has_sky && surf.smoothness > 0.78 && R.y > -0.05)) {
        return vec4<f32>(0.0);
    }

    let sample_uv = select(sky_uv, hit_uv, hit);
    let edge_fade = smoothstep(0.0, 0.10, sample_uv.x)
                  * smoothstep(1.0, 0.90, sample_uv.x)
                  * smoothstep(0.0, 0.14, sample_uv.y)
                  * smoothstep(1.0, 0.82, sample_uv.y);
    let refl_w = smoothstep(select(0.42, 0.30, ssr_glossy), 0.90, surf.smoothness) * edge_fade * dist_fade * dir_fade * select(0.20, 1.0, hit);
    if (refl_w <= 0.001) {
        return vec4<f32>(0.0);
    }

    let hit_col = zp_ssr_sample_color(sample_uv, surf.smoothness, select(0.0, t, hit));
    let ndotv = max(dot(N, -V_dir), 0.0);
    let metallic = select(0.0, clamp(-surf.data, 0.0, 1.0), surf.data < -0.05);
    let is_gem = surf.data > 0.12 && surf.data < 0.40;

    var out_col: vec3<f32>;
    if (metallic > 0.05) {
        let base_lum = max(zn_luma(base), 0.015);
        let chroma_tint = clamp(base / base_lum, vec3<f32>(0.40), vec3<f32>(1.50));
        let metal_tint = mix(vec3<f32>(0.88), chroma_tint, 0.78);
        let f_metal = zn_fresnel_schlick(ndotv, metal_tint * 0.65);
        let k_metal = clamp(f_metal * refl_w * 0.52 * metallic, vec3<f32>(0.0), vec3<f32>(0.55));
        out_col = mix(base, hit_col * metal_tint, k_metal);
    } else {
        let f0 = select(vec3<f32>(0.04), vec3<f32>(0.16), is_gem);
        let F = zn_fresnel_schlick(ndotv, f0);
        let k_refl = clamp(F * refl_w * select(0.65, 0.85, is_gem), vec3<f32>(0.0), vec3<f32>(0.55));
        out_col = base * (vec3<f32>(1.0) - k_refl * 0.55) + hit_col * k_refl;
    }

    let reflection_delta = out_col - base;
    if !temporal_ssr || !hit || surf.data > 0.5 {
        return vec4<f32>(reflection_delta, 0.0);
    }
    let reflected_surface = surface_at(vec2<i32>(sample_uv * dims));
    if !reflected_surface.present || reflected_surface.data > 0.5 {
        return vec4<f32>(reflection_delta, 0.0);
    }
    let uv_prev = zp_previous_uv(P);
    var filtered = reflection_delta;
    if all(uv_prev >= vec2<f32>(0.0)) && all(uv_prev < vec2<f32>(1.0)) {
        let history_dims = vec2<i32>(textureDimensions(zp_reflection_previous));
        let prior = textureLoad(zp_reflection_previous, min(vec2<i32>(uv_prev * vec2<f32>(history_dims)), history_dims - 1), 0);
        let bounds = min(0.080, 0.012 + 0.55 * max(abs(reflection_delta.r), max(abs(reflection_delta.g), abs(reflection_delta.b))));
        filtered = zp_history_rgb(prior, reflection_delta, length(P + frame.camera_motion), bounds, 26.0);
    }
    return vec4<f32>(filtered, dist);
}
