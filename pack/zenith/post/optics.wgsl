// src: Demers, GPU Gems 2004 and Hammon, GPU Gems 3 2007 (thin-lens depth of field); Guertin et al., HPG 2014 (feature-aware motion blur); Hullin et al., SIGGRAPH 2011 (flare ghosts); Horizon Shader API 0.2.

override lens_flare: f32 = 0.0;
override depth_of_field: f32 = 0.0;
override focus_distance: f32 = 0.0;
override camera_motion_blur: f32 = 0.0;
override color_mood: u32 = 0u;

fn zp_optics_distance(uv: vec2<f32>, depth: f32) -> f32 {
    if depth <= 0.0 { return 0.0; }
    let point = view_position(uv, depth);
    return max(0.05, -(frame.view * vec4<f32>(point, 1.0)).z);
}

fn zp_defocus_radius(distance_blocks: f32, focus: f32, strength: f32) -> f32 {
    let ratio = select(focus / max(distance_blocks, 0.05), 0.0, distance_blocks <= 0.0);
    let defocus = max(abs(1.0 - ratio) - 0.11, 0.0);
    return min(defocus * 8.0 * strength, 16.0);
}

fn zp_depth_agreement(center: f32, sample_distance: f32, tolerance: f32) -> f32 {
    if center == 0.0 || sample_distance == 0.0 {
        return select(0.0, 1.0, center == sample_distance);
    }
    return 1.0 - smoothstep(tolerance * 0.35, tolerance, abs(center - sample_distance));
}

fn zp_optics_sample(uv: vec2<f32>) -> vec3<f32> {
    let size = vec2<i32>(textureDimensions(previous));
    let pixel = clamp(vec2<i32>(uv * vec2<f32>(size)), vec2<i32>(0), size - 1);
    return max(textureLoad(previous, pixel, 0).rgb, vec3<f32>(0.0));
}

fn zp_dof(input: PostInput, base: vec3<f32>, distance_blocks: f32) -> vec3<f32> {
    let center_uv = vec2<f32>(0.5);
    let crosshair_depth = depth_at(center_uv);
    let auto_focus = select(96.0, clamp(zp_optics_distance(center_uv, crosshair_depth), 1.5, 128.0), crosshair_depth > 0.0);
    let focus = select(auto_focus, focus_distance, focus_distance > 0.0);
    let radius = zp_defocus_radius(distance_blocks, focus, depth_of_field);
    if radius < 0.4 { return base; }
    var sum = base;
    var weights = 1.0;
    for (var tap = 0u; tap < 12u; tap++) {
        let angle = f32(tap) * 2.399963;
        let spread = sqrt((f32(tap) + 0.5) / 12.0);
        let delta = vec2<f32>(cos(angle), sin(angle)) * radius * spread / max(frame.resolution, vec2<f32>(1.0));
        let uv = input.uv + delta;
        if any(uv <= vec2<f32>(0.0)) || any(uv >= vec2<f32>(1.0)) { continue; }
        let neighbor = zp_optics_distance(uv, depth_at(uv));
        let agreement = zp_depth_agreement(distance_blocks, neighbor, max(0.22, distance_blocks * 0.11));
        let defocus = zp_defocus_radius(neighbor, focus, depth_of_field);
        let weight = agreement * smoothstep(0.25, radius * 0.65 + 0.25, defocus);
        if weight > 0.001 {
            sum += zp_optics_sample(uv) * weight;
            weights += weight;
        }
    }
    return sum / weights;
}

fn zp_camera_shutter(uv: vec2<f32>, previous_uv: vec2<f32>, size: vec2<f32>, dt: f32, strength: f32) -> vec2<f32> {
    if dt <= 0.0 || dt > 0.15 || any(previous_uv < vec2<f32>(-0.10)) || any(previous_uv > vec2<f32>(1.10)) {
        return vec2<f32>(0.0);
    }
    let velocity = (previous_uv - uv) * size;
    let travel = length(velocity);
    if travel < 0.55 || travel > 0.16 * size.y { return vec2<f32>(0.0); }
    let pixels = min(14.0 * strength, travel * clamp((1.0 / 120.0) / dt, 0.06, 0.65) * strength);
    return velocity * pixels / max(travel, 1e-4) / size;
}

fn zp_motion(input: PostInput, base: vec3<f32>, distance_blocks: f32) -> vec3<f32> {
    if distance_blocks <= 0.0 || length(frame.camera_motion) > 1.75 { return base; }
    let surface = surface_at(vec2<i32>(input.uv * frame.resolution));
    if !surface.present || surface.data > 0.5 { return base; }
    let uv_previous = zp_previous_uv(view_position(input.uv, input.depth));
    let delta = zp_camera_shutter(input.uv, uv_previous, max(frame.resolution, vec2<f32>(1.0)),
        frame.delta_time, camera_motion_blur);
    if dot(delta, delta) <= 0.0 { return base; }
    var sum = base * 2.0;
    var weights = 2.0;
    for (var tap = 1u; tap <= 6u; tap++) {
        let fraction = (f32(tap) - 3.5) / 5.0;
        let uv = input.uv + delta * fraction;
        if any(uv <= vec2<f32>(0.0)) || any(uv >= vec2<f32>(1.0)) { continue; }
        let neighbor = zp_optics_distance(uv, depth_at(uv));
        let weight = zp_depth_agreement(distance_blocks, neighbor, max(0.12, distance_blocks * 0.065));
        if weight > 0.001 {
            sum += zp_optics_sample(uv) * weight;
            weights += weight;
        }
    }
    return sum / weights;
}

fn zp_optics_blur(input: PostInput, base: vec3<f32>) -> vec3<f32> {
    if (depth_of_field <= 0.0 && camera_motion_blur <= 0.0) || frame.eye_in != 0u
        || frame.blindness > 0.0 || frame.darkness > 0.0 {
        return base;
    }
    let distance_blocks = zp_optics_distance(input.uv, input.depth);
    var color = base;
    if depth_of_field > 0.0 { color = zp_dof(input, base, distance_blocks); }
    if camera_motion_blur > 0.0 { color = zp_motion(input, color, distance_blocks); }
    return color;
}

fn zp_glare_profile(uv: vec2<f32>, source: vec2<f32>, aspect: f32, kind: u32) -> f32 {
    let metric = vec2<f32>(aspect, 1.0);
    let offset = (uv - source) * metric;
    let radius = length(offset);
    let core = exp(-radius * 28.0) * 0.13;
    let streak = exp(-abs(offset.x) * 7.5 - abs(offset.y) * 240.0) * 0.22;
    if kind == 2u { return (0.60 * core + 0.68 * streak) * (1.0 - smoothstep(0.38, 0.72, radius)); }
    let axis = source - 0.5;
    let ghost1 = length((uv - (0.5 - axis * 0.48)) * metric);
    let ghost2 = length((uv - (0.5 - axis * 1.15)) * metric);
    let ghosts = exp(-ghost1 * ghost1 * 1050.0) * 0.014 + exp(-ghost2 * ghost2 * 390.0) * 0.010;
    let rings = exp(-abs(ghost2 - 0.072) * 125.0) * 0.008;
    return core + streak + ghosts + rings;
}

fn zp_lens_flare(uv: vec2<f32>) -> vec3<f32> {
    let vision = 1.0 - clamp(max(frame.blindness, frame.darkness), 0.0, 1.0);
    if lens_flare <= 0.0 || frame.eye_in != 0u || vision <= 0.0 { return vec3<f32>(0.0); }
    let aspect = frame.resolution.x / max(frame.resolution.y, 1.0);
    var total = vec3<f32>(0.0);
    for (var source_id = 0u; source_id < 3u; source_id++) {
        let source = textureLoad(zp_optics_sources, vec2<i32>(i32(source_id), 0), 0);
        if source.z <= 0.001 { continue; }
        let edge = min(min(source.x, source.y), 1.0 - max(source.x, source.y));
        let tint = select(select(vec3<f32>(1.0, 0.84, 0.61), vec3<f32>(0.62, 0.40, 1.0), source_id == 1u),
            vec3<f32>(0.57, 0.91, 1.0), source_id == 2u);
        total += tint * zp_glare_profile(uv, source.xy, aspect, source_id) * source.z * smoothstep(0.0, 0.09, edge);
    }
    return total * lens_flare * vision;
}

fn zp_apply_mood(color: vec3<f32>, mood: u32) -> vec3<f32> {
    if mood == 0u { return color; }
    let lum = max(dot(color, frame.luminance), 0.0);
    let bright = smoothstep(0.025, 0.44, lum);
    var shadow = vec3<f32>(0.86, 1.04, 1.12);
    var light = vec3<f32>(1.11, 1.00, 0.85);
    var chroma = 0.91;
    var contrast = 0.16;
    if mood == 2u {
        shadow = vec3<f32>(1.11, 0.99, 0.86);
        light = vec3<f32>(1.21, 1.04, 0.78);
        chroma = 0.94;
        contrast = -0.09;
    } else if mood == 3u {
        shadow = vec3<f32>(0.79, 1.03, 1.21);
        light = vec3<f32>(0.88, 1.02, 1.14);
        chroma = 0.79;
        contrast = 0.07;
    } else if mood == 4u {
        shadow = vec3<f32>(1.13, 0.88, 1.20);
        light = vec3<f32>(1.05, 0.98, 1.13);
        chroma = 1.23;
        contrast = 0.12;
    }
    let gain = mix(shadow, light, bright);
    let tint = gain / max(dot(gain, frame.luminance), 1e-3);
    let strength = 1.0 - smoothstep(0.9, 5.0, lum);
    let shaped = max(mix(vec3<f32>(lum), color, chroma), vec3<f32>(0.0)) * tint
        * exp2(contrast * clamp(log2(max(lum, 0.004) / 0.18), -2.8, 2.0));
    return mix(color, shaped, strength);
}
