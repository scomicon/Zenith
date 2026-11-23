// src: Horizon Shader API 0.2 (`[material] reads` of a kept resource's `_previous`, `frame.previous_view_projection`);
// M. Landis, "Production-Ready Global Illumination", SIGGRAPH 2002 course (ambient occlusion as the visible share of
// the sky dome); Tomasi and Manduchi, ICCV 1998 (depth-aware filtering).
//
// The share of the sky a surface sees, traced by compute/ray_bounce.wgsl at 480x270 and accumulated over frames, read
// here from last frame's map at the point's previous screen position. It scales the hemisphere ambient and the sky
// reflection only: the sun and block lights keep their own (traced) shadows. 1 where nothing was traced (past about
// 56 blocks, foliage, the first frame, without ray tracing).

const ZN_RT_SKY_BANDS: i32 = 3;   // rows of zp_rt_bounce: diffuse bounce, stained-glass light, sky visibility (+ probes)

fn mat_rt_sky_visibility(p: vec3<f32>) -> f32 {
    if frame.has_ray_tracing == 0u || rt_lighting < 1u || frame.eye_in != 0u || frame.dimension != 0 {
        return 1.0;
    }
    let distance = length(p);
    if distance >= 56.0 {
        return 1.0;
    }
    let size = vec2<i32>(textureDimensions(zp_rt_bounce_previous));
    let dims = vec2<i32>(size.x, (size.y - 1) / ZN_RT_SKY_BANDS);
    let clip = frame.previous_view_projection * vec4<f32>(p + frame.camera_motion, 1.0);
    if clip.w <= 1e-4 {
        return 1.0;
    }
    let uv = vec2<f32>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
    if any(uv < vec2<f32>(0.0)) || any(uv >= vec2<f32>(1.0)) {
        return 1.0;
    }
    let expected = length(p + frame.camera_motion);
    let pos = uv * vec2<f32>(dims) - 0.5;
    let base = vec2<i32>(floor(pos));
    let f = pos - floor(pos);
    let tolerance = max(0.35, expected * 0.035);
    var sum = 0.0;
    var weights = 0.0;
    for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
            let tap = clamp(base + vec2<i32>(x, y), vec2<i32>(0), dims - 1);
            let s = textureLoad(zp_rt_bounce_previous, tap + vec2<i32>(0, 2 * dims.y), 0);
            if s.a <= 0.0 { continue; }
            let w = select(1.0 - f.x, f.x, x == 1) * select(1.0 - f.y, f.y, y == 1)
                * (1.0 - smoothstep(tolerance * 0.4, tolerance, abs(s.a - expected)));
            sum += s.r * w;
            weights += w;
        }
    }
    if weights < 0.02 {
        return 1.0;
    }
    return clamp(sum / weights, 0.0, 1.0);
}
