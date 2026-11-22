// src: Lambert's cosine law, Whitted, CACM 1980 (shadow rays); Horizon Shader API 0.2 (surface depth, ray scene, texture resources).

fn zp_rt_window_surface(uv: vec2<f32>, row: i32) -> vec4<f32> {
    if textureLoad(zp_rt_bounce_previous, vec2<i32>(0, row), 0).w < 0.5 { return vec4<f32>(0.0); }
    let depth = depth_at(uv);
    let receiver = surface_at(vec2<i32>(uv * frame.resolution));
    if depth <= 0.0 || !receiver.present || receiver.data >= 0.5 { return vec4<f32>(0.0); }

    let p = view_position(uv, depth);
    let distance = length(p);
    if distance < 0.15 || distance > 33.0 || max(abs(p.x), abs(p.z)) + 1.0 >= frame.ray_distance {
        return vec4<f32>(0.0);
    }
    let origin = p + receiver.normal * 0.035;
    let count = i32(ZN_RT_WINDOW_SOURCES);
    var light = vec3<f32>(0.0);
    for (var i = 0; i < count; i++) {
        let previous = textureLoad(zp_rt_bounce_previous, vec2<i32>(i, row), 0);
        // The registry is compacted, so the first empty slot ends the list.
        if previous.w < 0.5 { break; }
        let source = vec4<f32>(zn_rt_window_centre(previous.xyz), previous.w);
        let from_source = origin - source.xyz;
        if dot(from_source, from_source) >= ZN_RT_WINDOW_SURFACE_REACH * ZN_RT_WINDOW_SURFACE_REACH { continue; }
        let state = textureLoad(zp_rt_bounce_previous, vec2<i32>(i + 2 * count, row), 0);
        let fade = zn_rt_window_fade(source, state.w);
        if fade <= 0.001 { continue; }
        let anchor = textureLoad(zp_rt_bounce_previous, vec2<i32>(i + count, row), 0);
        let pane = zn_rt_window_pane(source.xyz, previous.xyz, anchor.xyz, state.xyz);
        light += zn_rt_window_radiance(origin, source, pane, state.xyz, receiver.normal) * fade;
    }
    if max(max(light.r, light.g), light.b) <= 0.0002 { return vec4<f32>(0.0, 0.0, 0.0, distance); }

    // Sample receiver colour only once and only on lit pixels. Start just in
    // front of the raster hit instead of tracing the whole camera ray again.
    let view = p / distance;
    let hit = trace(p - view * 0.08, view, 0.20);
    if hit.distance < 0.0 || dot(hit.normal, receiver.normal) < 0.7 || zn_rt_hit_emission(hit) > 0.001 {
        return vec4<f32>(0.0, 0.0, 0.0, distance);
    }
    let diffuse = zn_rt_hit_albedo(hit) * (1.0 - clamp(-receiver.data, 0.0, 1.0));
    let radiance = min(light * (3.4 * diffuse), vec3<f32>(0.40));
    return vec4<f32>(radiance, distance);
}
