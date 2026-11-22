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
            for (var i = 0; i < ZN_RT_PENUMBRA_RAYS; i++) {
                let r = sqrt((f32(i) + 0.5) / f32(ZN_RT_PENUMBRA_RAYS)) * ZN_RT_SUN_RADIUS;
                let a = spin + 0.7 + f32(i) * 2.39996323;
                let dir = normalize(light_dir + (t * cos(a) + b * sin(a)) * r);
                extra += select(0.0, 1.0, mat_rt_blocked(origin, dir, reach, normal));
            }
            visibility = 1.0 - (blocked + extra) / (5.0 + f32(ZN_RT_PENUMBRA_RAYS));
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
