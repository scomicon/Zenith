// src: Turner Whitted, An Improved Illumination Model for Shaded Display, CACM 1980 (visibility and reflection rays); James Kajiya, The Rendering Equation, SIGGRAPH 1986 (diffuse light transport); Horizon Shader API 0.2 (scene reach, layers, hit material).

override rt_lighting: u32 = 0u; // Reflections, Reflections + Shadows, Full RT.

const ZN_RT_WINDOW_SOURCES: u32 = 8u;
const ZN_RT_WINDOW_VOLUME_REACH: f32 = 7.0;
const ZN_RT_WINDOW_SURFACE_REACH: f32 = 11.0;

// Coloured glass only, by saturation (spread over the brightest channel): vanilla's clear glass
// streaks reach 0.11-0.33, the palest coloured glass (pink) 0.48, white, light grey, grey and
// black stained glass 0. Clear glass passing as a coloured window projected its frame texture
// into the air as large ghost copies of the pane around a lamp behind it.
fn zn_rt_stained_glass(hit: RayHit) -> bool {
    let rgb = hit.albedo.rgb;
    let peak = max(max(rgb.r, rgb.g), rgb.b);
    let spread = peak - min(min(rgb.r, rgb.g), rgb.b);
    return hit.distance >= 0.0 && hit.translucent && (hit.tags & 1u) != 0u && spread >= 0.035
        && spread >= 0.40 * peak;
}

// The scene is guaranteed inside a square around the camera in world XZ.
fn zn_rt_reach(origin: vec3<f32>, direction: vec3<f32>, limit: f32) -> f32 {
    let edge = max(0.0, frame.ray_distance - 2.0);
    if max(abs(origin.x), abs(origin.z)) >= edge {
        return 0.0;
    }
    let dx = (edge - origin.x * sign(direction.x)) / max(abs(direction.x), 1e-4);
    let dz = (edge - origin.z * sign(direction.z)) / max(abs(direction.z), 1e-4);
    return min(limit, min(dx, dz));
}

fn zn_rt_window_fade(source: vec4<f32>, state: f32) -> f32 {
    return smoothstep(0.0, 1.0, state) * (1.0 - smoothstep(14.0, 22.0, length(source.xyz)));
}

fn zn_rt_window_history_valid() -> bool {
    return frame.delta_time > 0.0 && frame.delta_time < 0.5 && length(frame.camera_motion) < 2.0;
}

fn zn_rt_window_centre(previous: vec3<f32>) -> vec3<f32> {
    return floor(frame.camera_position + previous - frame.camera_motion) + 0.5 - frame.camera_position;
}

fn zn_rt_window_pane(centre: vec3<f32>, previous: vec3<f32>, anchor: vec3<f32>, normal: vec3<f32>) -> vec4<f32> {
    // Glass is axis-aligned and uses integer, half-block or pane grid coordinates.
    let offset = round(dot(anchor - previous, normal) * 16.0) / 16.0;
    let point = centre + normal * offset;
    return vec4<f32>(point, dot(point, normal));
}

// A zero receiver normal denotes an air sample. Surface receivers add Lambert's cosine.
fn zn_rt_window_radiance(
    pos: vec3<f32>, source: vec4<f32>, pane: vec4<f32>, pane_normal: vec3<f32>, receiver_normal: vec3<f32>,
) -> vec3<f32> {
    let from_source = pos - source.xyz;
    let distance = length(from_source);
    let surface = dot(receiver_normal, receiver_normal) > 0.5;
    let radius = select(ZN_RT_WINDOW_VOLUME_REACH, ZN_RT_WINDOW_SURFACE_REACH, surface);
    if distance < 0.95 || distance >= radius { return vec3<f32>(0.0); }
    let direction = -from_source / distance;
    let incidence = select(1.0, max(dot(receiver_normal, direction), 0.0), surface);
    if incidence <= 0.001 { return vec3<f32>(0.0); }
    let depth_to_pane = pane.w - dot(source.xyz, pane_normal);
    let normal_gap = dot(from_source, pane_normal);
    if normal_gap <= depth_to_pane || depth_to_pane <= 0.015 { return vec3<f32>(0.0); }
    let aperture_offset = source.xyz + from_source * (depth_to_pane / normal_gap) - pane.xyz;
    // Let a tall window reach the floor. The actual pane and walls still clip the path.
    let vertical_scale = select(1.0, 0.40, surface && abs(pane_normal.y) < 0.5);
    let aperture = 1.0 - smoothstep(1.40, 2.35, length(aperture_offset * vec3<f32>(1.0, vertical_scale, 1.0)));
    if aperture <= 0.001 { return vec3<f32>(0.0); }

    // End at the near face of the source voxel. The retained probe validates the emitter itself.
    let axes = abs(direction);
    let entry = distance - 0.5 / max(max(axes.x, axes.y), axes.z);
    if entry <= 0.02 || zn_rt_reach(pos, direction, entry) < entry { return vec3<f32>(0.0); }
    let glass = trace_layers(pos, direction, entry, RAY_TRANSLUCENT);
    if !zn_rt_stained_glass(glass) || trace_any_layers(pos, direction, entry - 0.012, RAY_SOLID | RAY_ENTITY) {
        return vec3<f32>(0.0);
    }
    let rgb = glass.albedo.rgb;
    let peak = max(max(rgb.r, rgb.g), rgb.b);
    let tint = mix(vec3<f32>(0.10), rgb / max(peak, 0.05), 0.90);
    let falloff = 1.0 - smoothstep(select(2.5, 5.5, surface), radius, distance);
    return tint * (source.w * aperture * incidence * falloff / (1.0 + 0.22 * distance * distance));
}

fn zn_rt_hit_albedo(hit: RayHit) -> vec3<f32> {
    return clamp(hit.albedo.rgb * hit.shaded_tint.rgb, vec3<f32>(0.0), vec3<f32>(1.0));
}

fn zn_rt_hit_emission(hit: RayHit) -> f32 {
    return max(hit.emission, select(0.0, 0.9, hit.fluid == 2u));
}

fn zn_rt_hit_radiance(hit: RayHit, visible: f32) -> vec3<f32> {
    let albedo = zn_rt_hit_albedo(hit);
    let skylight = pow(clamp(hit.light.y, 0.0, 1.0), 1.6);
    let blocklight = pow(clamp(hit.light.x, 0.0, 1.0), 2.2);
    let day = smoothstep(-0.04, 0.16, frame.sun_direction.y);
    let weather = 1.0 - clamp(frame.rain * 0.65 + frame.thunder * 0.22, 0.0, 0.8);
    let sun_color = mix(vec3<f32>(1.0, 0.52, 0.25), vec3<f32>(1.0, 0.94, 0.84),
        smoothstep(0.04, 0.42, frame.sun_direction.y));
    let sun = max(dot(hit.normal, frame.sun_direction), 0.0) * day * weather * skylight * visible;
    let sky = max(frame.sky_color, vec3<f32>(0.23, 0.31, 0.42));
    var ambient = sky * skylight * mix(0.08, 0.44, day * weather) + vec3<f32>(0.018, 0.022, 0.035);
    var direct = sun_color * (sun * 0.94);
    if frame.dimension != 0 {
        ambient = select(vec3<f32>(0.09, 0.055, 0.045), vec3<f32>(0.13, 0.12, 0.19), frame.dimension == 1);
        direct = vec3<f32>(0.0);
    }
    let local = vec3<f32>(1.0, 0.57, 0.25) * blocklight * 0.57;
    return albedo * (ambient + direct + local);
}

fn zn_rt_reflected_radiance(hit: RayHit, visible: f32) -> vec3<f32> {
    return zn_rt_hit_radiance(hit, visible) + zn_rt_hit_albedo(hit) * (zn_rt_hit_emission(hit) * 3.0);
}

fn zn_rt_sun_visibility(hit: RayHit) -> f32 {
    if frame.dimension != 0 || frame.sun_direction.y <= 0.03 || dot(hit.normal, frame.sun_direction) <= 0.02 {
        return 1.0;
    }
    let origin = hit.position + hit.normal * 0.035;
    let reach = zn_rt_reach(origin, frame.sun_direction, 56.0);
    return select(1.0, 0.0, reach > 0.1 && trace_any(origin, frame.sun_direction, reach));
}

fn zn_rt_transmission(hit: RayHit) -> vec3<f32> {
    let tint = clamp(hit.albedo.rgb, vec3<f32>(0.08), vec3<f32>(1.0));
    let glass = mix(vec3<f32>(1.0), tint, clamp(hit.albedo.a * 1.35, 0.0, 0.90));
    return select(glass, vec3<f32>(0.60, 0.82, 0.92), hit.fluid == 1u);
}

// Alpha is the geometry contribution, which fades to the existing reflection at the scene bounds.
fn zn_rt_reflection(origin: vec3<f32>, direction: vec3<f32>, limit: f32) -> vec4<f32> {
    let range = zn_rt_reach(origin, direction, limit);
    if range <= 0.1 {
        return vec4<f32>(0.0);
    }
    let opaque_layers = RAY_SOLID | RAY_ENTITY;
    let front = trace_layers(origin, direction, range, opaque_layers | RAY_TRANSLUCENT);
    if front.distance < 0.0 {
        return vec4<f32>(0.0);
    }
    let confidence = 1.0 - smoothstep(0.80, 1.0, front.distance / range);
    if !front.translucent {
        return vec4<f32>(zn_rt_reflected_radiance(front, zn_rt_sun_visibility(front)), confidence);
    }
    // Ignore further panes in this bounded ray. Keep the first pane's color on the background.
    let rest = range - front.distance - 0.025;
    let opacity = clamp(front.albedo.a * 0.7, 0.08, 0.7);
    let surface = zn_rt_hit_radiance(front, 1.0);
    if rest > 0.05 {
        let behind = trace_layers(front.position + direction * 0.025, direction, rest, opaque_layers);
        if behind.distance >= 0.0 {
            let background = zn_rt_reflected_radiance(behind, zn_rt_sun_visibility(behind));
            return vec4<f32>(mix(background * zn_rt_transmission(front), surface, opacity), confidence);
        }
    }
    return vec4<f32>(surface, confidence * opacity);
}
