// src: Hullin et al., Physically-Based Real-Time Lens Flare Rendering, SIGGRAPH 2011 (visible bright sources); Horizon Shader API 0.2 (projection, depth and surface data).

override lens_flare: f32 = 0.0;

var<workgroup> zp_beacon_candidates: array<vec4<f32>, 64>;

fn zp_beacon_energy(beam: vec3<f32>, left: vec3<f32>, right: vec3<f32>) -> f32 {
    let left_delta = beam - left;
    let right_delta = beam - right;
    let contrast = min(length(left_delta), length(right_delta));
    let beam_pattern = smoothstep(0.0, 0.02, dot(left_delta, right_delta));
    return smoothstep(0.12, 0.62, contrast) * beam_pattern;
}

fn zp_source_in_frame(uv: vec2<f32>) -> bool {
    return all(uv > vec2<f32>(0.0)) && all(uv < vec2<f32>(1.0));
}

fn zp_source_luminance(uv: vec2<f32>) -> f32 {
    let rgb = max(textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb, vec3<f32>(0.0));
    return dot(rgb, frame.luminance);
}

fn zp_project_light(position: vec4<f32>) -> vec4<f32> {
    let clip = frame.projection * (frame.view * position);
    if clip.w <= 1e-4 {
        return vec4<f32>(-1.0);
    }
    return vec4<f32>(clip.xy / clip.w * vec2<f32>(0.5, -0.5) + 0.5, clip.z / clip.w, clip.w);
}

fn zp_sun_source() -> vec4<f32> {
    if frame.dimension != 0 || frame.sun_direction.y <= 0.01 {
        return vec4<f32>(0.0);
    }
    let projected = zp_project_light(vec4<f32>(frame.sun_direction, 0.0));
    if projected.w <= 0.0 || !zp_source_in_frame(projected.xy) {
        return vec4<f32>(0.0);
    }
    var visible = 0.0;
    let offset = 2.5 / vec2<f32>(textureDimensions(previous));
    for (var index = 0u; index < 5u; index++) {
        let angle = f32(index) * 1.5707963;
        let uv = projected.xy + select(vec2<f32>(cos(angle), sin(angle)) * offset, vec2<f32>(0.0), index == 4u);
        if depth_at(uv) == 0.0 {
            visible += smoothstep(0.85, 3.4, zp_source_luminance(uv));
        }
    }
    return vec4<f32>(projected.xy, visible * 0.20 * (1.0 - 0.8 * frame.rain), 0.0);
}

fn zp_portal_source() -> vec4<f32> {
    if frame.dimension != 1 || !end_rift {
        return vec4<f32>(0.0);
    }
    let aperture = zn_rift_aperture(zn_rift_phase());
    let projected = zp_project_light(vec4<f32>(zn_rift_center(), 1.0));
    if aperture <= 0.03 || projected.w <= 0.0 || !zp_source_in_frame(projected.xy) {
        return vec4<f32>(0.0);
    }
    var energy = 0.0;
    let spread = clamp(5.0 / projected.w, 0.006, 0.04) * aperture;
    let offset = vec2<f32>(frame.resolution.y / max(1.0, frame.resolution.x), 1.0) * spread;
    for (var index = 0u; index < 5u; index++) {
        let angle = f32(index) * 1.5707963;
        let uv = projected.xy + select(vec2<f32>(cos(angle), sin(angle)) * offset, vec2<f32>(0.0), index == 4u);
        if depth_at(uv) <= projected.z * 1.15 {
            energy += smoothstep(0.12, 0.75, zp_source_luminance(uv));
        }
    }
    return vec4<f32>(projected.xy, 0.20 * energy * aperture, 0.0);
}

fn zp_beacon_source(cell: vec2<i32>, size: vec2<i32>) -> vec4<f32> {
    let surface = surface_at(cell);
    if !surface.present || surface.data < 1.9 {
        return vec4<f32>(0.0);
    }
    let base_uv = (vec2<f32>(cell) + 0.5) / vec2<f32>(size);
    let point = view_position(base_uv, depth_at(base_uv));
    let block = floor(point + frame.camera_position - 0.04 * surface.normal);
    let beam_origin = block + vec3<f32>(0.5, 1.65, 0.5) - frame.camera_position;
    let projected = zp_project_light(vec4<f32>(beam_origin, 1.0));
    if projected.w <= 0.0 || !zp_source_in_frame(projected.xy) {
        return vec4<f32>(0.0);
    }
    let beam_depth = depth_at(projected.xy);
    if beam_depth > projected.z * 1.10 {
        return vec4<f32>(0.0);
    }
    let dx = abs(frame.projection[0][0]) * 0.38 / projected.w;
    let offset = vec2<f32>(max(3.0 / f32(size.x), dx), 0.0);
    let beam = textureSampleLevel(previous, linear_sampler, projected.xy, 0.0).rgb;
    let left = textureSampleLevel(previous, linear_sampler, projected.xy - offset, 0.0).rgb;
    let right = textureSampleLevel(previous, linear_sampler, projected.xy + offset, 0.0).rgb;
    return vec4<f32>(projected.xy, zp_beacon_energy(beam, left, right), 0.0);
}

fn compute(input: ComputeInput) {
    if lens_flare <= 0.0 || frame.eye_in != 0u || frame.blindness >= 0.99 || frame.darkness >= 0.99 {
        if input.local < 3u { textureStore(zp_optics_sources, vec2<i32>(i32(input.local), 0), vec4<f32>(0.0)); }
        return;
    }
    let size = vec2<i32>(frame.resolution);
    var winner = vec4<f32>(0.0);
    for (var sample_index = input.local; sample_index < 23040u; sample_index += 64u) {
        let uv = (vec2<f32>(f32(sample_index % 192u), f32(sample_index / 192u)) + 0.5) / vec2<f32>(192.0, 120.0);
        let probe = zp_beacon_source(min(vec2<i32>(uv * vec2<f32>(size)), size - 1), size);
        if probe.z > winner.z { winner = probe; }
    }
    zp_beacon_candidates[input.local] = winner;
    workgroupBarrier();
    if input.local == 0u {
        for (var index = 1u; index < 64u; index++) {
            if zp_beacon_candidates[index].z > winner.z { winner = zp_beacon_candidates[index]; }
        }
        textureStore(zp_optics_sources, vec2<i32>(0, 0), zp_sun_source());
        textureStore(zp_optics_sources, vec2<i32>(1, 0), zp_portal_source());
        textureStore(zp_optics_sources, vec2<i32>(2, 0), winner);
    }
}
