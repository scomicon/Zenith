// src: Morgan McGuire & Michael Mara, "Efficient GPU Screen-Space Ray Tracing", JCGT 3(4), 2014 (view-space ray march and binary-search refinement concept); Christophe Schlick, Eurographics 1994 (Fresnel); Jorge Jimenez, SIGGRAPH 2014 (IGN ray jitter); Horizon Shader API 0.2 (PostInput, surface_at, view_position, depth_at, previous).
// Pass 4: Screen-Space Reflections (SSR) on smooth metals, gems, polished blocks & rain puddles.

override ssr_enabled: bool = true;
override temporal_ssr: bool = false;
override quality_mode: u32 = 1u; // 0 = Performance, 1 = Balanced, 2 = Quality (manifest order)

const ZP_SSR_STEPS: vec3<i32> = vec3<i32>(40, 64, 96); // DDA samples per ray by quality_mode
const ZP_SSR_STEPS_MAX: i32 = 96;
const ZP_SSR_MIN_STRIDE: f32 = 1.5; // pixels
const ZP_SSR_MAX_RAY: f32 = 96.0;

struct ZpSsrRay {
    p0: vec2<f32>,
    p1: vec2<f32>,
    k0: f32,
    k1: f32,
    z0: f32,
    z1: f32,
    q0: vec3<f32>,
    q1: vec3<f32>,
}

struct ZpSsrPoint {
    uv: vec2<f32>,
    ndc_z: f32,
    q: vec3<f32>,
}

fn zp_ssr_point(ray: ZpSsrRay, s: f32) -> ZpSsrPoint {
    let k = mix(ray.k0, ray.k1, s);
    var pt: ZpSsrPoint;
    pt.uv = mix(ray.p0, ray.p1, s);
    pt.ndc_z = mix(ray.z0, ray.z1, s);
    pt.q = mix(ray.q0, ray.q1, s) / max(k, 1e-5);
    return pt;
}

fn zp_ssr_sample_color(uv: vec2<f32>, smoothness: f32) -> vec3<f32> {
    let dims = vec2<f32>(textureDimensions(previous));
    let px = 1.0 / max(dims, vec2<f32>(1.0));
    let blur = clamp((1.0 - smoothness) * 6.5 + 0.5, 0.5, 4.0);
    let o1 = vec2<f32>(blur * px.x, blur * 0.5 * px.y);
    let o2 = vec2<f32>(-blur * 0.5 * px.x, blur * px.y);
    let c0 = textureSampleLevel(previous, linear_sampler, clamp(uv + o1, vec2<f32>(0.001), vec2<f32>(0.999)), 0.0).rgb;
    let c1 = textureSampleLevel(previous, linear_sampler, clamp(uv - o1, vec2<f32>(0.001), vec2<f32>(0.999)), 0.0).rgb;
    let c2 = textureSampleLevel(previous, linear_sampler, clamp(uv + o2, vec2<f32>(0.001), vec2<f32>(0.999)), 0.0).rgb;
    let c3 = textureSampleLevel(previous, linear_sampler, clamp(uv - o2, vec2<f32>(0.001), vec2<f32>(0.999)), 0.0).rgb;
    return clamp((c0 + c1 + c2 + c3) * 0.25, vec3<f32>(0.0), vec3<f32>(8.0));
}

fn post(input: PostInput) -> vec4<f32> {
    let base = max(input.color.rgb, vec3<f32>(0.0));
    if (!ssr_enabled || input.depth <= 0.0 || frame.eye_in != 0u) {
        return vec4<f32>(0.0);
    }

    let surf = surface_at(vec2<i32>(input.pixel));
    if (!surf.present || surf.smoothness < 0.38) {
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

    let max_samples = ZP_SSR_STEPS[min(quality_mode, 2u)];
    let dims = vec2<f32>(textureDimensions(previous));
    let Q0 = P + N * 0.06;
    let jitter = zn_ign(input.pixel, select(0u, frame.frame_index % 64u, temporal_ssr));
    var hit = false;
    var hit_uv = input.uv;
    var has_sky = false;
    var sky_uv = input.uv;

    // Screen-space DDA: the ray is projected once, then walked in near-uniform pixel strides with
    // perspective-correct interpolation of 1/w, z/w and Q/w (McGuire & Mara 2014).
    let clip0 = frame.projection * (frame.view * vec4<f32>(Q0, 1.0));
    let dir_w = (frame.projection * (frame.view * vec4<f32>(R, 0.0))).w;
    var ray_len = clamp(dist + 24.0, 24.0, ZP_SSR_MAX_RAY);
    if (dir_w < 0.0) {
        ray_len = max(min(ray_len, (clip0.w - 0.12) / -dir_w), 0.0);
    }
    var n_samples = 0;
    let Q1 = Q0 + R * ray_len;
    let clip1 = frame.projection * (frame.view * vec4<f32>(Q1, 1.0));
    var ray: ZpSsrRay;
    ray.k0 = 1.0 / clip0.w;
    ray.k1 = 1.0 / max(clip1.w, 0.05);
    ray.p0 = vec2<f32>(clip0.x * ray.k0 * 0.5 + 0.5, 0.5 - clip0.y * ray.k0 * 0.5);
    ray.p1 = vec2<f32>(clip1.x * ray.k1 * 0.5 + 0.5, 0.5 - clip1.y * ray.k1 * 0.5);
    ray.z0 = clip0.z * ray.k0;
    ray.z1 = clip1.z * ray.k1;
    ray.q0 = Q0 * ray.k0;
    ray.q1 = Q1 * ray.k1;

    // Stop at the screen border instead of spending samples off-screen.
    let dp = ray.p1 - ray.p0;
    var s_end = 1.0;
    if (abs(dp.x) > 1e-6) {
        s_end = min(s_end, (select(0.998, 0.002, dp.x < 0.0) - ray.p0.x) / dp.x);
    }
    if (abs(dp.y) > 1e-6) {
        s_end = min(s_end, (select(0.998, 0.002, dp.y < 0.0) - ray.p0.y) / dp.y);
    }
    s_end = clamp(s_end, 0.0, 1.0);
    let px_len = length(dp * s_end * dims);
    if (clip0.w > 0.12 && ray_len > 0.1 && px_len >= 1.5) {
        n_samples = min(max_samples, i32(ceil(px_len / ZP_SSR_MIN_STRIDE)));
    }

    var s_prev = 0.0;
    var s_hit = 0.0;
    var prev_behind = false;
    var q_prev = Q0;
    for (var i = 0; i < ZP_SSR_STEPS_MAX; i = i + 1) {
        if (i >= n_samples) {
            break;
        }
        let s = s_end * (f32(i) + 0.15 + jitter * 0.85) / f32(n_samples);
        let pt = zp_ssr_point(ray, s);
        let sd = depth_at(pt.uv);
        if (sd <= 0.0) {
            has_sky = true;
            sky_uv = pt.uv;
            prev_behind = false;
        } else {
            let is_behind = pt.ndc_z < sd;
            if (is_behind) {
                let S = view_position(pt.uv, sd);
                let delta = length(pt.q) - length(S);
                let thickness = clamp(0.16 + length(pt.q - q_prev) * 0.85, 0.16, 0.72);
                if (delta > -0.02 && delta < thickness && (!prev_behind || delta < 0.25) && dot(S - P, N) > 0.05) {
                    let hit_surf = surface_at(vec2<i32>(pt.uv * dims));
                    let front_face = !hit_surf.present || dot(normalize(hit_surf.normal), R) <= 0.20;
                    if (front_face) {
                        hit = true;
                        hit_uv = pt.uv;
                        s_hit = s;
                        break;
                    }
                }
            }
            prev_behind = is_behind;
        }
        s_prev = s;
        q_prev = pt.q;
    }

    if (hit) {
        var lo = s_prev;
        var hi = s_hit;
        for (var b = 0; b < 5; b = b + 1) {
            let mid = 0.5 * (lo + hi);
            let pm = zp_ssr_point(ray, mid);
            let sd_m = depth_at(pm.uv);
            if (sd_m > 0.0 && pm.ndc_z < sd_m) {
                let S_m = view_position(pm.uv, sd_m);
                let d_m = length(pm.q) - length(S_m);
                if (d_m < 0.72 && dot(S_m - P, N) > 0.05) {
                    hit_uv = pm.uv;
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
    let refl_w = smoothstep(0.42, 0.90, surf.smoothness) * edge_fade * dist_fade * dir_fade * select(0.20, 1.0, hit);
    if (refl_w <= 0.001) {
        return vec4<f32>(0.0);
    }

    let hit_col = zp_ssr_sample_color(sample_uv, surf.smoothness);
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
