// src: Tomasi and Manduchi, Bilateral Filtering for Gray and Color Images, ICCV 1998 (cross-bilateral upsampling); Horizon Shader API 0.2 (surface buffer, kept resource).

override rt_lighting: u32 = 0u;

fn zp_rt_bounce_filtered(uv: vec2<f32>, distance: f32) -> vec3<f32> {
    if rt_lighting != 2u || frame.has_ray_tracing == 0u || frame.eye_in != 0u || distance >= 58.0 {
        return vec3<f32>(0.0);
    }
    let size = vec2<i32>(textureDimensions(zp_rt_bounce));
    let dims = vec2<i32>(size.x, (size.y - 1) / 2);
    return zp_rt_upsample_light(uv, distance, dims, 0);
}

fn zp_rt_glass_filtered(uv: vec2<f32>, distance: f32) -> vec3<f32> {
    if rt_lighting < 1u || frame.has_ray_tracing == 0u || frame.dimension != 0 || frame.eye_in != 0u || distance >= 33.0 {
        return vec3<f32>(0.0);
    }
    let row = i32(textureDimensions(zp_rt_bounce).y) - 1;
    if textureLoad(zp_rt_bounce, vec2<i32>(0, row), 0).w < 0.5 { return vec3<f32>(0.0); }
    let dims = vec2<i32>(i32(textureDimensions(zp_rt_bounce).x), row / 2);
    let visible = 1.0 - clamp(max(frame.blindness, frame.darkness), 0.0, 1.0);
    return zp_rt_upsample_light(uv, distance, dims, dims.y) * visible;
}

fn zp_rt_upsample_light(uv: vec2<f32>, distance: f32, dims: vec2<i32>, row_offset: i32) -> vec3<f32> {
    let receiver = surface_at(vec2<i32>(uv * frame.resolution));
    if !receiver.present || receiver.data >= 0.5 {
        return vec3<f32>(0.0);
    }
    let pos = uv * vec2<f32>(dims) - 0.5;
    let base = vec2<i32>(floor(pos));
    var sum = vec3<f32>(0.0);
    var weights = 0.0;
    for (var y = -1; y < 3; y++) {
        for (var x = -1; x < 3; x++) {
            let tap = clamp(base + vec2<i32>(x, y), vec2<i32>(0), dims - 1);
            let sample = textureLoad(zp_rt_bounce, tap + vec2<i32>(0, row_offset), 0);
            let distance_delta = abs(sample.a - distance);
            if sample.a <= 0.0 || distance_delta >= max(0.48, distance * 0.042) {
                continue;
            }
            let tap_uv = (vec2<f32>(tap) + 0.5) / vec2<f32>(dims);
            let tap_surface = surface_at(vec2<i32>(tap_uv * frame.resolution));
            if !tap_surface.present || dot(tap_surface.normal, receiver.normal) < 0.85 {
                continue;
            }
            let offset = vec2<f32>(f32(x), f32(y)) - fract(pos);
            let kernel = exp(-dot(offset, offset) * 0.45);
            let weight = kernel * (1.0 - smoothstep(0.06, max(0.48, distance * 0.042), distance_delta));
            sum += sample.rgb * weight;
            weights += weight;
        }
    }
    return sum / max(0.05, weights);
}
