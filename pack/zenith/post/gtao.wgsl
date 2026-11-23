// src: Jimenez, Wu, Pesce, Jarosz 2016 (GTAO); Schied et al., HPG 2017 (temporal reprojection and rejection); Horizon Shader API 0.2 kept textures.
// Pass 1: ground-truth ambient occlusion at half of 1080p -> kept target `ao`.
//
// Algorithm: J. Jimenez, X. Wu, A. Pesce, A. Jarosz, "Practical Realtime Strategies for Accurate Indirect
// Occlusion", SIGGRAPH 2016 course notes (GTAO): per screen-space slice, find the two horizon angles
// around the view vector, clamp them to the normal's hemisphere and integrate the cosine-weighted
// visible arc analytically:  a(h, n) = 1/4 * (-cos(2h - n) + cos(n) + 2 h sin(n)).
// The slice plane is built from the view vector and the 3D direction of the slice's screen direction,
// so no view-space handedness is assumed. Distance falloff of a sample's weight toward the radius is
// a linear ramp (own choice). Noise: a 4x4 ordered pattern for the slice angles (Bayer, 1973) plus IGN
// for the step offsets (zn_ign), removed by the 4x4 bilateral box in compose.wgsl.
//
// Output: r = visibility 0..1, g = distance of the point from the camera in blocks (60000 for the sky),
// which compose.wgsl uses as the bilateral weight.

override ao_strength: f32 = 1.0;
override temporal_ao: bool = false;

override quality_mode: u32 = 1u;     // 0 = Performance, 1 = Balanced, 2 = Quality (manifest order)

// Slices and steps per slice by mode (own choices): 2x4, 3x6, 4x8.
const ZP_SLICES_BY_MODE: vec4<i32> = vec4<i32>(2, 3, 4, 8);
const ZP_STEPS_BY_MODE: vec4<i32> = vec4<i32>(4, 6, 8, 12);
const ZP_RADIUS: f32 = 1.5;          // world-space radius, blocks
const ZP_FALLOFF_FROM: f32 = 0.6;    // samples nearer than this fraction of the radius count fully
const ZP_MAX_RADIUS_PX: f32 = 96.0;  // cap of the screen-space radius, in pixels of the world's picture
const ZP_MIN_RADIUS_PX: f32 = 2.0;
const ZP_PI: f32 = 3.14159265;
const ZP_HALF_PI: f32 = 1.57079633;
const ZP_SKY_DISTANCE: f32 = 60000.0;

// 4x4 ordered-dither index (Bayer 1973, by bit interleaving), mapped to [0, 1).
fn zp_bayer4(p: vec2<u32>) -> f32 {
    let x = p.x & 3u;
    let y = p.y & 3u;
    let a = x ^ y;
    let v = ((a & 1u) << 3u) | ((y & 1u) << 2u) | (a & 2u) | ((y >> 1u) & 1u);
    return (f32(v) + 0.5) / 16.0;
}

// The surface normal facing the camera: the material stage's own (set_surface) where it left one,
// else rebuilt from the depth buffer with the smaller one-sided difference on each axis.
fn zp_normal(uv: vec2<f32>, d: f32, p: vec3<f32>, v: vec3<f32>) -> vec3<f32> {
    let texel = vec2<i32>(uv * frame.resolution);
    let s = surface_at(texel);
    if (s.present && dot(s.normal, s.normal) > 0.5) {
        var n = normalize(s.normal);
        // keep it in the visible hemisphere
        n = normalize(n + v * max(0.0, 0.05 - dot(n, v)));
        return n;
    }
    let px = 1.0 / frame.resolution;
    let uv_l = uv - vec2<f32>(px.x, 0.0);
    let uv_r = uv + vec2<f32>(px.x, 0.0);
    let uv_u = uv - vec2<f32>(0.0, px.y);
    let uv_d = uv + vec2<f32>(0.0, px.y);
    let dl = depth_at(uv_l);
    let dr = depth_at(uv_r);
    let du = depth_at(uv_u);
    let dd = depth_at(uv_d);
    if (dl <= 0.0 || dr <= 0.0 || du <= 0.0 || dd <= 0.0) {
        return v;
    }
    let pl = view_position(uv_l, dl) - p;
    let pr = view_position(uv_r, dr) - p;
    let pu = view_position(uv_u, du) - p;
    let pd = view_position(uv_d, dd) - p;
    let ex = select(pr, -pl, dot(pl, pl) < dot(pr, pr));
    let ey = select(pd, -pu, dot(pu, pu) < dot(pd, pd));
    let c = cross(ex, ey);
    let len2 = dot(c, c);
    if (len2 < 1e-12) {
        return v;
    }
    var n = c * inverseSqrt(len2);
    if (dot(n, v) < 0.0) {
        n = -n;
    }
    return n;
}

fn zp_ao_history(visibility: f32, point: vec3<f32>, normal: vec3<f32>, medium: f32) -> f32 {
    if frame.delta_time <= 0.0 || length(frame.camera_motion) > 2.0 {
        return visibility;
    }
    let prev_point = point + frame.camera_motion;
    let clip = frame.previous_view_projection * vec4<f32>(prev_point, 1.0);
    if clip.w <= 0.0 || clip.z <= 0.0 || clip.z > clip.w {
        return visibility;
    }
    let uv = clip.xy / clip.w * vec2<f32>(0.5, -0.5) + 0.5;
    if any(uv < vec2<f32>(0.0)) || any(uv >= vec2<f32>(1.0)) {
        return visibility;
    }
    let size = vec2<i32>(textureDimensions(ao_previous));
    let pixel = min(vec2<i32>(uv * vec2<f32>(size)), size - 1);
    let prior = textureLoad(ao_previous, pixel, 0);
    if prior.a != medium {
        return visibility;
    }
    let expected = length(prev_point);
    let depth_error = abs(prior.g - expected);
    let depth_weight = 1.0 - smoothstep(0.04, 0.08 + expected * 0.008, depth_error);
    let normal_weight = select(0.0, 1.0, prior.b == zp_ao_normal_key(normal));
    let bounded = clamp(prior.r, visibility - 0.18, visibility + 0.18);
    let history_weight = exp(-frame.delta_time * 12.0) * depth_weight * normal_weight;
    return mix(visibility, bounded, history_weight);
}

fn zp_ao_normal_key(normal: vec3<f32>) -> f32 {
    let q = vec3<u32>(round(clamp(normal * 0.5 + 0.5, vec3<f32>(0.0), vec3<f32>(1.0)) * 7.0));
    return f32(q.x + q.y * 8u + q.z * 64u);
}

fn post(input: PostInput) -> vec4<f32> {
    let uv = input.uv;
    let d = depth_at(uv);
    if (d <= 0.0) {
        return vec4<f32>(1.0, ZP_SKY_DISTANCE, 0.0, 0.0);
    }
    let p = view_position(uv, d);
    let dist = max(length(p), 1e-3);
    if (ao_strength <= 0.0) {
        return vec4<f32>(1.0, dist, 0.0, 0.0);
    }
    // Water, glass, entities and particles leave no `set_surface` record: their depth-derived normal is
    // quantised and, on a flat plane seen at a grazing angle, breaks into horizontal AO bands. Leave them unoccluded.
    let surf_here = surface_at(vec2<i32>(uv * frame.resolution));
    // Thin animated kelp/seagrass/foliage quads have no solid local hemisphere: treating their
    // two-sided quads like blocks paints dark halos underwater and black squares in air.
    let water = select(0.0, 1.0, frame.eye_in == 1u);
    let is_foliage = surf_here.data > 0.5 && surf_here.data < 1.5;
    if (!surf_here.present || (water > 0.5 && is_foliage)) {
        return vec4<f32>(1.0, dist, 0.0, 0.0);
    }
    let v = -p / dist;
    let n = zp_normal(uv, d, p, v);

    // Screen-space radius: the world radius seen from this distance (focal length in pixels = P11 * H / 2).
    let focal_px = frame.projection[1][1] * 0.5 * frame.resolution.y;
    // Own choice: local contact occlusion in water, rather than a 1.5-block
    // dark cloud around each plant/step. Optical haze already supplies depth.
    let radius = ZP_RADIUS * mix(1.0, 0.4, water);
    let radius_px = min(radius * focal_px / dist, ZP_MAX_RADIUS_PX);
    if (radius_px < ZP_MIN_RADIUS_PX) {
        return vec4<f32>(1.0, dist, 0.0, 0.0);
    }

    let noise_pixel = input.uv * frame.resolution * 0.5;
    let pix = vec2<u32>(noise_pixel);
    let accumulate = temporal_ao && surf_here.data <= 0.5;
    let phase = select(0u, frame.frame_index % 64u, accumulate);
    let slice_noise = fract(zp_bayer4(pix) + f32(phase) * 0.618034);
    let step_noise = zn_ign(noise_pixel, phase);
    let res = frame.resolution;
    let falloff_range = radius * (1.0 - ZP_FALLOFF_FROM);

    let mode_idx = min(quality_mode, 3u);
    let zp_slices = ZP_SLICES_BY_MODE[mode_idx];
    let zp_steps = ZP_STEPS_BY_MODE[mode_idx];

    var visibility = 0.0;
    for (var k = 0; k < zp_slices; k = k + 1) {
        let phi = (f32(k) + slice_noise) * (ZP_PI / f32(zp_slices));
        let dir = vec2<f32>(cos(phi), sin(phi));   // in uv space (y grows downward)

        // The 3D direction this screen direction has on the surface's depth, made orthogonal to the view vector.
        let p_side = view_position(uv + dir * (4.0 / res), d);
        var axis_dir = p_side - p;
        axis_dir = axis_dir - v * dot(axis_dir, v);
        let axis_len2 = dot(axis_dir, axis_dir);
        if (axis_len2 < 1e-12) {
            visibility = visibility + 1.0;
            continue;
        }
        axis_dir = axis_dir * inverseSqrt(axis_len2);
        let slice_normal = cross(axis_dir, v);

        // The normal projected into the slice plane and its signed angle to the view vector.
        let proj_n = n - slice_normal * dot(n, slice_normal);
        let proj_len = max(length(proj_n), 1e-4);
        let cos_n = clamp(dot(proj_n, v) / proj_len, -1.0, 1.0);
        let sign_n = select(-1.0, 1.0, dot(axis_dir, proj_n) >= 0.0);
        let ang_n = sign_n * acos(cos_n);

        // Start from the tangent plane's horizon on each side, raise it with every sample in front of it.
        var hc_pos = cos(ang_n + ZP_HALF_PI);
        var hc_neg = cos(ang_n - ZP_HALF_PI);

        for (var s = 0; s < zp_steps; s = s + 1) {
            let t = (f32(s) + step_noise) / f32(zp_steps);
            let off_px = max(t * t * radius_px, 1.5 + f32(s));
            let o = dir * off_px;

            let uv_a = (floor(uv * res + o) + vec2<f32>(0.5)) / res;
            if (all(uv_a > vec2<f32>(0.0)) && all(uv_a < vec2<f32>(1.0))) {
                let da = depth_at(uv_a);
                if (da > 0.0) {
                    let delta = view_position(uv_a, da) - p;
                    let len = max(length(delta), 1e-4);
                    let w = clamp((radius - len) / falloff_range, 0.0, 1.0);
                    hc_pos = max(hc_pos, mix(cos(ang_n + ZP_HALF_PI), dot(delta, v) / len, w));
                }
            }
            let uv_b = (floor(uv * res - o) + vec2<f32>(0.5)) / res;
            if (all(uv_b > vec2<f32>(0.0)) && all(uv_b < vec2<f32>(1.0))) {
                let db = depth_at(uv_b);
                if (db > 0.0) {
                    let delta = view_position(uv_b, db) - p;
                    let len = max(length(delta), 1e-4);
                    let w = clamp((radius - len) / falloff_range, 0.0, 1.0);
                    hc_neg = max(hc_neg, mix(cos(ang_n - ZP_HALF_PI), dot(delta, v) / len, w));
                }
            }
        }

        // Horizon angles, kept inside the normal's hemisphere, then the analytic arc integral.
        var h_neg = -acos(clamp(hc_neg, -1.0, 1.0));
        var h_pos = acos(clamp(hc_pos, -1.0, 1.0));
        h_neg = ang_n + clamp(h_neg - ang_n, -ZP_HALF_PI, ZP_HALF_PI);
        h_pos = ang_n + clamp(h_pos - ang_n, -ZP_HALF_PI, ZP_HALF_PI);
        let sin_n = sin(ang_n);
        let arc_neg = (cos_n + 2.0 * h_neg * sin_n - cos(2.0 * h_neg - ang_n)) * 0.25;
        let arc_pos = (cos_n + 2.0 * h_pos * sin_n - cos(2.0 * h_pos - ang_n)) * 0.25;
        visibility = visibility + proj_len * (arc_neg + arc_pos);
    }
    visibility = clamp(visibility / f32(zp_slices), 0.0, 1.0);
    if (is_foliage) {
        visibility = mix(1.0, visibility, 0.22);
    }
    if accumulate {
        let medium = f32(frame.eye_in) + 1.0;
        return vec4<f32>(zp_ao_history(visibility, p, n, medium), dist, zp_ao_normal_key(n), medium);
    }
    return vec4<f32>(visibility, dist, 0.0, 0.0);
}
