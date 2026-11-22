// src: James Kajiya, The Rendering Equation, SIGGRAPH 1986 (cosine-distributed diffuse transport); Horizon Shader API 0.2 (camera-relative opaque depth, surface buffer, ray scene and kept textures).

// A fixed quadrature avoids temporal noise. Rotate the second stratum relative to the first.
fn zp_rt_diffuse_direction(n: vec3<f32>, index: u32, second: bool) -> vec3<f32> {
    let reference = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(n.y) > 0.96);
    let t = normalize(cross(reference, n));
    let b = cross(n, t);
    let phi = f32(index) * 2.39996323 + select(0.31, 1.48, second);
    let radius = sqrt((f32(index) + 0.72) / 3.0);
    return n * sqrt(max(0.0, 1.0 - radius * radius)) + (t * cos(phi) + b * sin(phi)) * radius;
}

fn zp_rt_diffuse_bounce(p: vec3<f32>, n: vec3<f32>) -> vec3<f32> {
    let origin = p + n * 0.055;
    var radiance = vec3<f32>(0.0);
    for (var i = 0u; i < 3u; i++) {
        let direction = zp_rt_diffuse_direction(n, i, false);
        let first = trace(origin, direction, zn_rt_reach(origin, direction, 6.0));
        // Zenith's block light already accounts for direct light from these emitters.
        // Sparse fixed directions would paint their full-resolution texture on diffuse surfaces.
        if first.distance < 0.0 || zn_rt_hit_emission(first) > 0.001 {
            continue;
        }
        var outgoing = zn_rt_hit_radiance(first, 1.0);
        let next = zp_rt_diffuse_direction(first.normal, (i + 1u) % 3u, true);
        let next_origin = first.position + first.normal * 0.045;
        let second = trace(next_origin, next, zn_rt_reach(next_origin, next, 4.0));
        if second.distance >= 0.0 && zn_rt_hit_emission(second) <= 0.001 {
            let attenuation = 0.45 / (1.0 + 0.22 * second.distance * second.distance);
            outgoing += zn_rt_hit_albedo(first) * zn_rt_hit_radiance(second, 1.0) * attenuation;
        }
        radiance += outgoing / (1.0 + 0.16 * first.distance * first.distance);
    }
    return radiance * 0.26; // Artistic weight for filling the raster ambient term.
}

struct ZpRtWindowProbe {
    source: vec4<f32>,
    pane: vec4<f32>,
    normal: vec4<f32>,
    emitter_offset: vec4<f32>,
    emitter_normal: vec4<f32>,
}

const ZP_RT_DISCOVERY_STRIPES: u32 = 6u;
const ZP_RT_DISCOVERY_BASE: i32 = 5 * i32(ZN_RT_WINDOW_SOURCES);

fn zp_rt_probe_normal(encoded: u32) -> vec3<f32> {
    let e = unpack2x16snorm(encoded);
    var n = vec3<f32>(e.x, 1.0 - abs(e.x) - abs(e.y), e.y);
    if n.y < 0.0 {
        n = vec3<f32>((1.0 - abs(n.z)) * sign(n.x), n.y, (1.0 - abs(n.x)) * sign(n.z));
    }
    return normalize(n);
}

fn zp_rt_probe_tint_key(colour: vec3<f32>) -> f32 {
    let peak = max(max(colour.r, colour.g), max(colour.b, 0.05));
    let bins = round(colour * (3.0 / peak));
    return dot(bins, vec3<f32>(1.0, 4.0, 16.0));
}

fn zp_rt_probe_window(stripe: u32) -> ZpRtWindowProbe {
    let scene_size = vec2<f32>(textureDimensions(scene_surface));
    var probe: ZpRtWindowProbe;
    var nearest = 22.0;
    for (var y = 0u; y < 36u; y++) {
        for (var x = 0u; x < 8u; x++) {
            let grid = vec2<f32>(vec2<u32>(stripe * 8u + x, y)) + 0.5;
            let uv = grid / vec2<f32>(48.0, 36.0);
            // Horizon 0.2 stores the pack code in z and the original solid depth in w.
            // surface_at discards that record where translucent glass writes a nearer depth.
            let cell = vec2<i32>(uv * scene_size);
            let solid = bitcast<vec4<f32>>(textureLoad(scene_surface, cell, 0));
            if solid.w <= 0.0 || solid.z < 2.9 { continue; }
            let sample_uv = (vec2<f32>(cell) + 0.5) / scene_size;
            if depth_at(sample_uv) <= solid.w * 1.0001 { continue; }
            let pos = view_position(sample_uv, solid.w);
            let distance = length(pos);
            if distance < nearest {
                let direction = pos / max(distance, 1e-4);
                let glass = trace_layers(vec3<f32>(0.0), direction, distance, RAY_SOLID | RAY_TRANSLUCENT | RAY_ENTITY);
                if zn_rt_stained_glass(glass) {
                    let emitter_normal = zp_rt_probe_normal(bitcast<u32>(solid.x));
                    let block = floor(frame.camera_position + pos - emitter_normal * 0.04);
                    let centre = block + 0.5 - frame.camera_position;
                    let plane = dot(glass.normal, glass.position);
                    // Project the lamp centre onto the pane. Moving the discovery pixel along
                    // a face no longer translates the aperture or changes its integration interval.
                    let anchor = centre + glass.normal * (plane - dot(centre, glass.normal));
                    probe.source = vec4<f32>(centre, solid.z - 3.0);
                    probe.pane = vec4<f32>(anchor, plane);
                    probe.normal = vec4<f32>(glass.normal, 0.0);
                    probe.emitter_offset = vec4<f32>(pos - centre, zp_rt_probe_tint_key(glass.albedo.rgb));
                    probe.emitter_normal = vec4<f32>(emitter_normal, 0.0);
                    nearest = distance;
                }
            }
        }
    }
    return probe;
}

fn zp_rt_restore_window(texel: vec2<i32>) -> ZpRtWindowProbe {
    let stride = vec2<i32>(i32(ZN_RT_WINDOW_SOURCES), 0);
    let previous = textureLoad(zp_rt_bounce_previous, texel, 0);
    var probe: ZpRtWindowProbe;
    if previous.w < 0.5 { return probe; }

    let centre = zn_rt_window_centre(previous.xyz);
    let in_range = length(centre) < 22.0
        && max(abs(centre.x), abs(centre.z)) + 1.0 < frame.ray_distance;
    if !in_range { return probe; }

    let offset = textureLoad(zp_rt_bounce_previous, texel + 3 * stride, 0);
    let outward = textureLoad(zp_rt_bounce_previous, texel + 4 * stride, 0);
    let surface = centre + offset.xyz;
    let hit = trace(surface + outward.xyz * 0.12, -outward.xyz, 0.24);
    if hit.distance < 0.0 || hit.emission < 0.66 || any(abs(hit.position - centre) > vec3<f32>(0.515)) {
        return probe;
    }

    let previous_pane = textureLoad(zp_rt_bounce_previous, texel + stride, 0);
    let previous_normal = textureLoad(zp_rt_bounce_previous, texel + 2 * stride, 0);
    // Rebase the offset from the voxel rather than accumulating half-float camera-motion errors.
    probe.source = vec4<f32>(centre, hit.emission);
    probe.pane = zn_rt_window_pane(centre, previous.xyz, previous_pane.xyz, previous_normal.xyz);
    probe.normal = vec4<f32>(previous_normal.xyz, min(previous_normal.w + 7.0 * frame.delta_time, 1.0));
    probe.emitter_offset = offset;
    probe.emitter_normal = outward;
    return probe;
}

fn zp_rt_same_window_light(a: ZpRtWindowProbe, b: ZpRtWindowProbe) -> bool {
    let same_plane = dot(a.normal.xyz, b.normal.xyz) > 0.98 && abs(a.pane.w - b.pane.w) < 0.16;
    let distance = length(a.source.xyz - b.source.xyz);
    let shared_colour = abs(a.emitter_offset.w - b.emitter_offset.w) < 0.5;
    return same_plane && (distance < 0.20 || (distance < 1.15 && shared_colour));
}

fn zp_rt_store_window(pixel: vec2<i32>, light: ZpRtWindowProbe) {
    let stride = vec2<i32>(i32(ZN_RT_WINDOW_SOURCES), 0);
    textureStore(zp_rt_bounce, pixel, light.source);
    textureStore(zp_rt_bounce, pixel + stride, light.pane);
    textureStore(zp_rt_bounce, pixel + 2 * stride, light.normal);
    textureStore(zp_rt_bounce, pixel + 3 * stride, light.emitter_offset);
    textureStore(zp_rt_bounce, pixel + 4 * stride, light.emitter_normal);
}

fn zp_rt_update_windows(row: i32, enabled: bool) {
    var lights: array<ZpRtWindowProbe, ZN_RT_WINDOW_SOURCES>;
    var count = 0u;
    if enabled && zn_rt_window_history_valid() {
        for (var i = 0u; i < ZN_RT_WINDOW_SOURCES; i++) {
            let light = zp_rt_restore_window(vec2<i32>(i32(i), row));
            if light.source.w >= 0.5 {
                lights[count] = light;
                count++;
            }
        }

        // Screen probes run in parallel and are merged on the following frame. The
        // retained list is independent of which screen stripe observed each lamp.
        for (var stripe = 0u; stripe < ZP_RT_DISCOVERY_STRIPES; stripe++) {
            let candidate = zp_rt_restore_window(vec2<i32>(ZP_RT_DISCOVERY_BASE + i32(stripe), row));
            if candidate.source.w < 0.5 { continue; }
            let distance = length(candidate.source.xyz);
            var duplicate = false;
            var farthest = max(distance + 3.0, 17.0);
            var replace_slot = ZN_RT_WINDOW_SOURCES;
            for (var i = 0u; i < count; i++) {
                duplicate = duplicate || zp_rt_same_window_light(candidate, lights[i]);
                let old_distance = length(lights[i].source.xyz);
                if old_distance > farthest {
                    farthest = old_distance;
                    replace_slot = i;
                }
            }
            if duplicate { continue; }
            if count < ZN_RT_WINDOW_SOURCES {
                lights[count] = candidate;
                count++;
            } else if replace_slot < ZN_RT_WINDOW_SOURCES {
                lights[replace_slot] = candidate;
            }
        }
    }

    for (var i = 0u; i < ZN_RT_WINDOW_SOURCES; i++) {
        var light: ZpRtWindowProbe;
        if i < count { light = lights[i]; }
        zp_rt_store_window(vec2<i32>(i32(i), row), light);
    }
}

fn compute(input: ComputeInput) {
    if !input.in_bounds {
        return;
    }
    let pixel = vec2<i32>(input.cell.xy);
    let has_rt = frame.has_ray_tracing != 0u && frame.eye_in == 0u;
    let diffuse_size = input.size.xy - vec2<u32>(0u, 1u);
    let rows = i32(diffuse_size.y);
    let windows = has_rt && rt_lighting >= 1u && frame.dimension == 0;
    if input.cell.y == diffuse_size.y {
        if input.cell.x < ZP_RT_DISCOVERY_STRIPES {
            var probe: ZpRtWindowProbe;
            if windows { probe = zp_rt_probe_window(input.cell.x); }
            zp_rt_store_window(pixel + vec2<i32>(ZP_RT_DISCOVERY_BASE, rows), probe);
        } else if input.cell.x == ZP_RT_DISCOVERY_STRIPES {
            zp_rt_update_windows(2 * rows, windows);
        }
        return;
    }
    let uv = (vec2<f32>(pixel) + 0.5) / vec2<f32>(diffuse_size);
    var result = vec4<f32>(0.0);
    if rt_lighting == 2u && has_rt {
        let depth = depth_at(uv);
        let surface = surface_at(vec2<i32>(uv * frame.resolution));
        if depth > 0.0 && surface.present && surface.data < 0.5 {
            let p = view_position(uv, depth);
            let distance = length(p);
            let fade = 1.0 - smoothstep(16.0, 28.0, distance);
            if fade > 0.0 && max(abs(p.x), abs(p.z)) + 12.0 < frame.ray_distance {
                let light = zp_rt_diffuse_bounce(p, normalize(surface.normal));
                result = vec4<f32>(min(light * fade, vec3<f32>(0.85)), distance);
            }
        }
    }
    textureStore(zp_rt_bounce, pixel, result);
    var direct = vec4<f32>(0.0);
    if windows && zn_rt_window_history_valid() {
        direct = zp_rt_window_surface(uv, 2 * rows);
    }
    textureStore(zp_rt_bounce, pixel + vec2<i32>(0, rows), direct);
}

