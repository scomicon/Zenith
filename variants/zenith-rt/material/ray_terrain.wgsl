// src: Turner Whitted, An Improved Illumination Model for Shaded Display, CACM 1980 (secondary illumination and visibility); Horizon Shader API 0.2 (material ray calls, scene layers).

fn mat_rt_shadow_weight(p: vec3<f32>, light_dir: vec3<f32>) -> f32 {
    if frame.has_ray_tracing == 0u || rt_lighting < 1u || frame.eye_in != 0u || light_dir.y < 0.06 {
        return 0.0;
    }
    let reach = zn_rt_reach(p, light_dir, 100.0);
    return (1.0 - smoothstep(26.0, 52.0, length(p))) * smoothstep(46.0, 76.0, reach);
}

// Tangent of the light's angular radius for the soft shadow cone. The real sun is 0.0047; this is deliberately
// wider (about 1.5 degrees), the way a sky-lit scene looks: penumbrae grow with the distance to the occluder.
const ZN_RT_SUN_RADIUS: f32 = 0.026;
const ZN_RT_PENUMBRA_RAYS: i32 = 16;
override quality_mode: u32 = 1u; // Ultra (3) doubles the penumbra rays.

// True when a ray toward the light is stopped by solid terrain or an entity (or points into the surface).
fn mat_rt_blocked(origin: vec3<f32>, dir: vec3<f32>, reach: f32, normal: vec3<f32>) -> bool {
    if dot(dir, normal) <= 0.03 { return true; }
    return trace_any_layers(origin, dir, reach, RAY_SOLID | RAY_ENTITY);
}

// Soft sun and moon shadow: five rays across the light's disc (centre and four on its rim) find out whether the
// point is surely lit or surely shadowed; only the penumbra pays for sixteen more on a rotated Vogel disc
// (Fernando, PCSS, GDC 2005, with ray queries instead of shadow-map taps). The rotation comes from the world
// position, so the grain stays on the surface instead of crawling with the camera.
fn mat_rt_shadow(p: vec3<f32>, normal: vec3<f32>, light_dir: vec3<f32>) -> vec3<f32> {
    let origin = p + normal * 0.045 + light_dir * 0.014;
    let reach = zn_rt_reach(origin, light_dir, 100.0);
    var visibility = 1.0;
    if reach > 0.1 {
        let reference = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(light_dir.y) > 0.95);
        let t = normalize(cross(reference, light_dir));
        let b = cross(light_dir, t);
        let world = (p + frame.camera_position) * 11.0;
        let spin = fract(sin(dot(floor(world), vec3<f32>(12.9898, 78.233, 37.719))) * 43758.5453) * 6.2831853;
        var blocked = select(0.0, 1.0, mat_rt_blocked(origin, light_dir, reach, normal));
        for (var k = 0; k < 4; k++) {
            let a = spin + f32(k) * 1.5707963;
            let dir = normalize(light_dir + (t * cos(a) + b * sin(a)) * ZN_RT_SUN_RADIUS);
            blocked += select(0.0, 1.0, mat_rt_blocked(origin, dir, reach, normal));
        }
        if blocked > 0.5 && blocked < 4.5 {
            var extra = 0.0;
            let penumbra_rays = select(ZN_RT_PENUMBRA_RAYS, ZN_RT_PENUMBRA_RAYS * 2, quality_mode >= 3u);
            for (var i = 0; i < penumbra_rays; i++) {
                let r = sqrt((f32(i) + 0.5) / f32(penumbra_rays)) * ZN_RT_SUN_RADIUS;
                let a = spin + 0.7 + f32(i) * 2.39996323;
                let dir = normalize(light_dir + (t * cos(a) + b * sin(a)) * r);
                extra += select(0.0, 1.0, mat_rt_blocked(origin, dir, reach, normal));
            }
            visibility = 1.0 - (blocked + extra) / (5.0 + f32(penumbra_rays));
        } else {
            visibility = select(1.0, 0.0, blocked > 2.5);
        }
    }
    if visibility <= 0.0 {
        return vec3<f32>(0.0);
    }
    if colored_shadows {
        let blocker = trace_layers(origin, light_dir, max(reach, 0.1), RAY_TRANSLUCENT);
        if blocker.distance >= 0.0 {
            if blocker.fluid == 1u {
                let caustics = mat_water_caustic(p + frame.camera_position, p, light_dir, blocker.distance, frame.time);
                return visibility * zn_rt_transmission(blocker) * caustics * exp(-vec3<f32>(0.17, 0.06, 0.03) * min(blocker.distance, 18.0));
            }
            return visibility * zn_rt_transmission(blocker);
        }
    }
    return vec3<f32>(visibility);
}

fn mat_rt_water_reflection(p: vec3<f32>, geometric_normal: vec3<f32>, reflected: vec3<f32>) -> vec4<f32> {
    if frame.has_ray_tracing == 0u || frame.eye_in != 0u || dot(reflected, geometric_normal) < 0.02 {
        return vec4<f32>(0.0);
    }
    let fade = 1.0 - smoothstep(23.0, 42.0, length(p));
    if fade <= 0.0 {
        return vec4<f32>(0.0);
    }
    let hit = zn_rt_reflection(p + geometric_normal * 0.09, reflected, 62.0);
    return vec4<f32>(hit.rgb, hit.a * fade);
}

struct ZnRtRefraction {
    color: vec3<f32>,
    path: f32,
    weight: f32,
}

// What lies under the water along the refracted ray: the traced floor or object, lit with its own sun shadow ray
// and the water's caustics, with the path length in the water for the Beer-Lambert absorption. Weight 0 where the
// ray finds nothing in reach (deep water, the scene's edge), where the screen-space refraction stays in charge.
fn mat_rt_water_refraction(p: vec3<f32>, geometric_normal: vec3<f32>, wave_normal: vec3<f32>, view: vec3<f32>) -> ZnRtRefraction {
    var out: ZnRtRefraction;
    out.color = vec3<f32>(0.0);
    out.path = 0.0;
    out.weight = 0.0;
    if frame.has_ray_tracing == 0u || rt_lighting < 1u || frame.eye_in != 0u || geometric_normal.y < 0.45 {
        return out;
    }
    let fade = 1.0 - smoothstep(30.0, 56.0, length(p));
    if fade <= 0.0 { return out; }
    // Snell's law, air to water.
    let dir = refract(-view, wave_normal, 0.7519);
    if dot(dir, dir) < 0.5 || dir.y > -0.02 { return out; }
    let origin = p - geometric_normal * 0.03;
    let reach = zn_rt_reach(origin, dir, 26.0);
    if reach <= 0.3 { return out; }
    let hit = trace_layers(origin, dir, reach, RAY_SOLID | RAY_ENTITY);
    if hit.distance < 0.0 { return out; }
    let light = mat_safe_normalize(frame.light_direction);
    let visible = zn_rt_sun_visibility(hit);
    let caustic = mat_water_caustic(hit.position + frame.camera_position, hit.position, light, max(p.y - hit.position.y, 0.1), frame.time);
    var color = zn_rt_hit_radiance(hit, visible) * mix(vec3<f32>(1.0), caustic, clamp(visible * 0.8, 0.0, 1.0));
    color += zn_rt_hit_albedo(hit) * (zn_rt_hit_emission(hit) * 3.0);
    out.color = color;
    out.path = hit.distance;
    out.weight = fade;
    return out;
}

// Glass and ice: the traced scene in the pane, where the sky model alone would show only the sky. Alpha is the
// confidence of the trace; where it is 0 (a miss, or beyond the pane's reach) the sky reflection stays.
fn mat_rt_glass_reflection(p: vec3<f32>, view: vec3<f32>, geometric_normal: vec3<f32>, reflected: vec3<f32>) -> vec4<f32> {
    if frame.has_ray_tracing == 0u || frame.eye_in != 0u {
        return vec4<f32>(0.0);
    }
    let fade = 1.0 - smoothstep(26.0, 50.0, length(p));
    if fade <= 0.0 {
        return vec4<f32>(0.0);
    }
    let facing = select(-geometric_normal, geometric_normal, dot(geometric_normal, view) >= 0.0);
    if dot(reflected, facing) < 0.02 {
        return vec4<f32>(0.0);
    }
    let hit = zn_rt_reflection(p + facing * 0.02, reflected, 56.0);
    return vec4<f32>(hit.rgb, hit.a * fade);
}

// What lies behind glass along the bent ray, for the pixels where the screen-space tap lands on something nearer
// than the pane (the frame around a window) and falls back to the unbent colour.
fn mat_rt_glass_refraction(p: vec3<f32>, view: vec3<f32>, bend: vec3<f32>, refracted_uv: vec2<f32>, surface_z: f32) -> vec4<f32> {
    if frame.has_ray_tracing == 0u || frame.eye_in != 0u {
        return vec4<f32>(0.0);
    }
    let fade = 1.0 - smoothstep(24.0, 44.0, length(p));
    if fade <= 0.0 {
        return vec4<f32>(0.0);
    }
    let od_dims = vec2<i32>(textureDimensions(opaque_depth));
    let tap_uv = clamp(refracted_uv, vec2<f32>(0.0005), vec2<f32>(0.9995));
    let tap = clamp(vec2<i32>(tap_uv * vec2<f32>(od_dims)), vec2<i32>(0), max(od_dims - vec2<i32>(1), vec2<i32>(0)));
    if textureLoad(opaque_depth, tap, 0) <= surface_z + 1e-5 {
        return vec4<f32>(0.0);
    }
    let dir = normalize(-view + bend * 0.4);
    let origin = p + dir * 0.03;
    let reach = zn_rt_reach(origin, dir, 48.0);
    if reach <= 0.3 {
        return vec4<f32>(0.0);
    }
    let hit = trace_layers(origin, dir, reach, RAY_SOLID | RAY_ENTITY);
    if hit.distance < 0.0 {
        return vec4<f32>(0.0);
    }
    return vec4<f32>(zn_rt_reflected_radiance(hit, zn_rt_sun_visibility(hit)), fade);
}

// Looking up from under the surface: Snell's window shows what lies above along the refracted ray (shore, trees,
// the true sky gradient), and past the critical angle the surface mirrors the floor and walls under the water.
// Fresnel (unpolarised, water to air) blends the two. Alpha is the weight of the trace over the raster look.
fn mat_rt_water_underside(
    p: vec3<f32>, n: vec3<f32>, view: vec3<f32>, window_body: vec3<f32>, tir_body: vec3<f32>, sky_vis: f32,
) -> vec4<f32> {
    if frame.has_ray_tracing == 0u || frame.eye_in != 1u {
        return vec4<f32>(0.0);
    }
    let distance = length(p);
    let fade = 1.0 - smoothstep(34.0, 64.0, distance);
    if fade <= 0.0 {
        return vec4<f32>(0.0);
    }
    let travel = -view;
    let cos_i = clamp(dot(n, view), 0.0, 1.0);
    let refracted = refract(travel, n, 1.3333);
    let transmits = dot(refracted, refracted) > 0.5;
    var fresnel = 1.0;
    if transmits {
        let cos_t = clamp(-dot(n, refracted), 0.0, 1.0);
        let rs = (1.3333 * cos_i - cos_t) / (1.3333 * cos_i + cos_t);
        let rp = (cos_i - 1.3333 * cos_t) / (cos_i + 1.3333 * cos_t);
        fresnel = clamp(0.5 * (rs * rs + rp * rp), 0.0, 1.0);
    }
    let sigma_up = vec3<f32>(0.12, 0.045, 0.03);
    var through = tir_body;
    if transmits && fresnel < 0.995 {
        let origin = p - n * 0.03;
        let sky = mat_sky_reflection_color(refracted) * sky_vis;
        var air = sky;
        let reach = zn_rt_reach(origin, refracted, 90.0);
        if reach > 0.3 {
            let hit = trace_layers(origin, refracted, reach, RAY_SOLID | RAY_ENTITY);
            if hit.distance >= 0.0 {
                air = mix(zn_rt_reflected_radiance(hit, zn_rt_sun_visibility(hit)), sky, smoothstep(40.0, 110.0, hit.distance));
            }
        }
        let t_up = exp(-sigma_up * distance);
        through = air * vec3<f32>(1.45, 1.68, 1.78) * t_up + window_body * (vec3<f32>(1.0) - t_up);
    }
    var mirror = tir_body;
    if fresnel > 0.02 {
        let down = reflect(travel, n);
        let origin = p + n * 0.03;
        let reach = zn_rt_reach(origin, down, 48.0);
        if reach > 0.3 {
            let hit = trace_layers(origin, down, reach, RAY_SOLID | RAY_ENTITY);
            if hit.distance >= 0.0 {
                let t_down = exp(-vec3<f32>(0.25, 0.09, 0.05) * (distance + hit.distance));
                mirror = zn_rt_reflected_radiance(hit, zn_rt_sun_visibility(hit)) * t_down + tir_body * (vec3<f32>(1.0) - t_down);
            }
        }
    }
    return vec4<f32>(mix(through, mirror, fresnel), fade);
}
