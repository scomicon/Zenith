// src: Bart Wronski, Volumetric Fog, SIGGRAPH 2014 (single-scattering integration); Horizon Shader API 0.2 (trace_layers, RayHit, surface buffers and kept textures).

fn zp_rt_window_light(view_dir: vec3<f32>, view_range: f32) -> vec3<f32> {
    if rt_lighting < 1u || frame.has_ray_tracing == 0u || frame.eye_in != 0u {
        return vec3<f32>(0.0);
    }
    let row = i32(textureDimensions(zp_rt_bounce).y) - 1;
    let count = i32(ZN_RT_WINDOW_SOURCES);
    var light = vec3<f32>(0.0);
    for (var i = 0; i < count; i++) {
        let source = textureLoad(zp_rt_bounce, vec2<i32>(i, row), 0);
        if source.w < 0.5 { continue; }
        let t = dot(source.xyz, view_dir);
        let side = source.xyz - t * view_dir;
        let chord_sq = ZN_RT_WINDOW_VOLUME_REACH * ZN_RT_WINDOW_VOLUME_REACH - dot(side, side);
        if chord_sq <= 0.0 { continue; }
        let chord = sqrt(chord_sq);
        let start = max(t - chord, 0.08);
        let pane = textureLoad(zp_rt_bounce, vec2<i32>(i + count, row), 0);
        let normal_state = textureLoad(zp_rt_bounce, vec2<i32>(i + 2 * count, row), 0);
        let normal = normal_state.xyz;
        let fade = zn_rt_window_fade(source, normal_state.w);
        if fade <= 0.001 { continue; }
        let direction_to_plane = dot(view_dir, normal);
        let before_pane = select(24.0, pane.w / min(direction_to_plane, -1e-4), direction_to_plane < -1e-4);
        let end = min(t + chord, min(view_range, before_pane));
        if end <= start { continue; }
        // Fixed integration points avoid temporal noise and the registered volume ends at opaque depth.
        var segment = vec3<f32>(0.0);
        for (var j = 0u; j < 3u; j++) {
            let position = view_dir * mix(start, end, 0.20 + 0.30 * f32(j));
            segment += zn_rt_window_radiance(position, source, pane, normal, vec3<f32>(0.0));
        }
        light += segment * ((end - start) * fade / 3.0);
    }
    return min(light * 0.13, vec3<f32>(0.28));
}
