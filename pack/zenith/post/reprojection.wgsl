// src: Schied et al., HPG 2017 (temporal reprojection with depth rejection); Horizon Shader API 0.2 previous projection and camera motion.

fn zp_previous_uv(current_point: vec3<f32>) -> vec2<f32> {
    let prev_point = current_point + frame.camera_motion;
    let clip = frame.previous_view_projection * vec4<f32>(prev_point, 1.0);
    if frame.delta_time <= 0.0 || length(frame.camera_motion) > 2.0 || clip.w <= 0.0
        || clip.z <= 0.0 || clip.z > clip.w {
        return vec2<f32>(-1.0);
    }
    return clip.xy / clip.w * vec2<f32>(0.5, -0.5) + 0.5;
}

fn zp_history_rgb(prior: vec4<f32>, current: vec3<f32>, distance_blocks: f32, limit: f32, speed: f32) -> vec3<f32> {
    if prior.a <= 0.0 {
        return current;
    }
    let depth_error = abs(prior.a - distance_blocks);
    let confidence = 1.0 - smoothstep(0.05, 0.12 + distance_blocks * 0.008, depth_error);
    let bounded = clamp(prior.rgb, current - limit, current + limit);
    return mix(current, bounded, min(0.88, exp(-frame.delta_time * speed)) * confidence);
}
