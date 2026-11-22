// src: James Kajiya, The Rendering Equation, SIGGRAPH 1986 (cosine-distributed diffuse transport); Horizon Shader API 0.2 (camera-relative opaque depth, surface buffer, ray scene and kept textures).

// Stochastic one-bounce diffuse GI, accumulated over time (Kajiya 1986; Schied et al., SVGF, HPG 2017 for the
// reprojected history). The raster pass already adds a sky ambient term that assumes the whole hemisphere is open
// (`mat_sky_ambient_color`). What is stored here is the difference between the traced hemisphere and that
// assumption: light from lit nearby surfaces (colour bleeding, emissive blocks) and the shortfall where the sky is
// blocked (contact shadowing, rooms), with the sky share estimated from the rays that escaped.
override ambient_strength: f32 = 1.0;
override gi_strength: f32 = 1.0;

const ZP_GI_RAYS: u32 = 3u;
const ZP_GI_RANGE: f32 = 40.0;

fn zp_rt_hash(p: vec2<i32>) -> u32 {
    var h = u32(p.x) * 747796405u + u32(p.y) * 2891336453u + 2891336453u;
    h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
    return (h >> 22u) ^ h;
}

// Per-texel offset plus the R2 sequence over frames and rays: stratified in time, decorrelated in space.
fn zp_rt_rand2(texel: vec2<i32>, ray: u32) -> vec2<f32> {
    let h = zp_rt_hash(texel);
    let offset = vec2<f32>(f32(h & 0xffffu), f32(h >> 16u)) / 65536.0;
    let k = f32(frame.frame_index * ZP_GI_RAYS + ray);
    return fract(offset + k * vec2<f32>(0.7548776662, 0.5698402909));
}

fn zp_rt_cosine_direction(n: vec3<f32>, u: vec2<f32>) -> vec3<f32> {
    let reference = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(n.y) > 0.96);
    let t = normalize(cross(reference, n));
    let b = cross(n, t);
    let r = sqrt(u.x);
    let phi = 6.2831853 * u.y;
    return normalize(t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(0.0, 1.0 - u.x)));
}

// The Overworld hemisphere ambient of material/lighting.wgsl `mat_sky_ambient_color`, without its sky-light factor
// and climate LUT: the term the raster pass adds and this pass corrects.
fn zp_rt_ambient(n: vec3<f32>) -> vec3<f32> {
    let sun_elev = frame.sun_direction.y;
    let day_w = smoothstep(-0.08, 0.16, sun_elev);
    let hemi_t = clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
    let hemi_scale = mix(0.76, 1.08, hemi_t);
    let sky_tint = max(frame.sky_color, vec3<f32>(0.015, 0.022, 0.042));
    let storm = clamp(frame.rain * 0.72 + frame.thunder * 0.28, 0.0, 1.0);
    let sunset_f = exp(-pow(max(sun_elev, -0.04) * 5.2, 2.0));
    let bounce_day = smoothstep(-0.02, 0.22, sun_elev) * (1.0 - storm * 0.72);
    let warm = mix(vec3<f32>(0.135, 0.122, 0.095), vec3<f32>(0.175, 0.095, 0.042), sunset_f);
    let sun_dir = normalize(frame.sun_direction);
    let sun_az = 0.88 + 0.22 * clamp(dot(n, sun_dir) * 0.5 + 0.5, 0.0, 1.0);
    let luma = dot(sky_tint, vec3<f32>(0.2126, 0.7152, 0.0722));
    let ground = mix(vec3<f32>(luma), sky_tint, 0.50) * 0.34 + warm * bounce_day;
    let top = mix(vec3<f32>(luma), sky_tint, 0.72) * 0.68 + vec3<f32>(0.022, 0.029, 0.044);
    let dome = mix(ground, top, hemi_t) * hemi_scale * sun_az;
    let night = mix(vec3<f32>(0.032, 0.044, 0.072), vec3<f32>(0.0), day_w);
    return max(dome, night) * ambient_strength;
}

// A traced hit lit the way the raster pass would light it: hemisphere ambient by its sky light, block light, and
// the sun with a shadow ray of its own.
fn zp_rt_hit_lit(hit: RayHit) -> vec3<f32> {
    var visible = 0.0;
    let day = smoothstep(-0.04, 0.16, frame.sun_direction.y);
    let facing = dot(hit.normal, frame.sun_direction);
    if frame.sun_direction.y > 0.03 && facing > 0.02 {
        let o = hit.position + hit.normal * 0.04;
        let r = zn_rt_reach(o, frame.sun_direction, 48.0);
        visible = select(1.0, 0.0, r > 0.1 && trace_any(o, frame.sun_direction, r));
    }
    let weather = 1.0 - clamp(frame.rain * 0.65 + frame.thunder * 0.22, 0.0, 0.8);
    let sun_color = mix(vec3<f32>(1.0, 0.52, 0.25), vec3<f32>(1.0, 0.94, 0.84),
        smoothstep(0.04, 0.42, frame.sun_direction.y));
    let skylight = clamp(hit.light.y, 0.0, 1.0);
    let ambient = zp_rt_ambient(hit.normal) * pow(skylight, 1.35);
    let direct = sun_color * (max(facing, 0.0) * day * weather * pow(skylight, 1.6) * visible * 0.94);
    let local = vec3<f32>(1.0, 0.57, 0.25) * pow(clamp(hit.light.x, 0.0, 1.0), 2.2) * 0.57;
    let albedo = zn_rt_hit_albedo(hit);
    return albedo * (ambient + direct + local) + albedo * (zn_rt_hit_emission(hit) * 1.5);
}

fn zp_rt_gi(p: vec3<f32>, n: vec3<f32>, texel: vec2<i32>) -> vec3<f32> {
    if frame.dimension != 0 { return vec3<f32>(0.0); }
    let origin = p + n * 0.05;
    var bounce = vec3<f32>(0.0);
    var escaped = 0.0;
    for (var i = 0u; i < ZP_GI_RAYS; i++) {
        let dir = zp_rt_cosine_direction(n, zp_rt_rand2(texel, i));
        let reach = zn_rt_reach(origin, dir, ZP_GI_RANGE);
        if reach <= 0.4 { escaped += 1.0; continue; }
        let hit = trace(origin, dir, reach);
        if hit.distance < 0.0 { escaped += 1.0; continue; }
        // Falloff with the path length, so a far wall does not light a surface like a near one.
        bounce += min(zp_rt_hit_lit(hit) / (1.0 + 0.012 * hit.distance * hit.distance), vec3<f32>(3.0));
    }
    let count = f32(ZP_GI_RAYS);
    let sky_share = escaped / count;
    // The raster ambient assumed an open hemisphere (scaled by the vertex sky light); the traced share replaces it.
    let shortfall = zp_rt_ambient(n) * (sky_share - pow(sky_share, 1.35));
    return (bounce / count + shortfall) * gi_strength;
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
            let fade = 1.0 - smoothstep(30.0, 56.0, distance);
            if fade > 0.0 && max(abs(p.x), abs(p.z)) + 12.0 < frame.ray_distance {
                var light = zp_rt_gi(p, normalize(surface.normal), pixel) * fade;
                let prev_uv = zp_previous_uv(p);
                if all(prev_uv >= vec2<f32>(0.0)) && all(prev_uv < vec2<f32>(1.0)) {
                    let dims = vec2<i32>(diffuse_size);
                    let prior = textureLoad(zp_rt_bounce_previous, min(vec2<i32>(prev_uv * vec2<f32>(dims)), dims - 1), 0);
                    let motion = length(frame.camera_motion);
                    let keep = mix(0.95, 0.80, smoothstep(0.0, 0.08, motion));
                    if prior.a > 0.0 {
                        let expected = length(p + frame.camera_motion);
                        let valid = 1.0 - smoothstep(0.05, 0.12 + expected * 0.008, abs(prior.a - expected));
                        light = mix(light, clamp(prior.rgb, light - vec3<f32>(0.8), light + vec3<f32>(0.8)), keep * valid);
                    }
                }
                result = vec4<f32>(clamp(light, vec3<f32>(-1.5), vec3<f32>(3.0)), distance);
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

