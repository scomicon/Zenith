// src: Turner Whitted, An Improved Illumination Model for Shaded Display, CACM 1980 (secondary illumination and visibility); Horizon Shader API 0.2 (material ray calls, scene layers).

fn mat_rt_shadow_weight(p: vec3<f32>, light_dir: vec3<f32>) -> f32 {
    if frame.has_ray_tracing == 0u || rt_lighting < 1u || frame.eye_in != 0u || light_dir.y < 0.06 {
        return 0.0;
    }
    let reach = zn_rt_reach(p, light_dir, 100.0);
    return (1.0 - smoothstep(18.0, 34.0, length(p))) * smoothstep(46.0, 76.0, reach);
}

fn mat_rt_shadow(p: vec3<f32>, normal: vec3<f32>, light_dir: vec3<f32>) -> vec3<f32> {
    let origin = p + normal * 0.045 + light_dir * 0.014;
    let reach = zn_rt_reach(origin, light_dir, 100.0);
    if trace_any_layers(origin, light_dir, reach, RAY_SOLID | RAY_ENTITY) {
        return vec3<f32>(0.0);
    }
    if colored_shadows {
        let blocker = trace_layers(origin, light_dir, reach, RAY_TRANSLUCENT);
        if blocker.distance >= 0.0 {
            if blocker.fluid == 1u {
                let caustics = mat_water_caustic(p + frame.camera_position, p, light_dir, blocker.distance, frame.time);
                return zn_rt_transmission(blocker) * caustics * exp(-vec3<f32>(0.17, 0.06, 0.03) * min(blocker.distance, 18.0));
            }
            return zn_rt_transmission(blocker);
        }
    }
    return vec3<f32>(1.0);
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
