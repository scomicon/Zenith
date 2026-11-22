// src: Turner Whitted, An Improved Illumination Model for Shaded Display, CACM 1980 (secondary reflection rays); Schlick, Eurographics 1994 (Fresnel); Horizon Shader API 0.2 (scene reach and surface metadata).

fn zp_rt_opaque_reflection(p: vec3<f32>, n: vec3<f32>, direction: vec3<f32>, smoothness: f32, data: f32) -> vec4<f32> {
    if frame.has_ray_tracing == 0u || dot(direction, n) < 0.025 || data > 0.50 {
        return vec4<f32>(0.0);
    }
    let metal_or_gem = data < -0.05 || (data > 0.12 && data < 0.40);
    let polish = select(smoothstep(0.80, 0.96, smoothness), smoothstep(0.54, 0.84, smoothness), metal_or_gem);
    let weight = polish * (1.0 - smoothstep(32.0, 68.0, length(p)));
    if weight <= 0.001 {
        return vec4<f32>(0.0);
    }
    let color = zn_rt_reflection(p + n * 0.075, direction, 86.0);
    return vec4<f32>(color.rgb, color.a * weight);
}

fn zp_resolve_reflection(base: vec3<f32>, hit_color: vec3<f32>, weight: f32, ndotv: f32, data: f32) -> vec3<f32> {
    let metallic = clamp(-data, 0.0, 1.0);
    let is_gem = data > 0.12 && data < 0.40;
    if metallic > 0.05 {
        let chroma_tint = clamp(base / max(zn_luma(base), 0.015), vec3<f32>(0.40), vec3<f32>(1.50));
        let metal_tint = mix(vec3<f32>(0.88), chroma_tint, 0.78);
        let f_metal = zn_fresnel_schlick(ndotv, metal_tint * 0.65);
        let blend = clamp(f_metal * weight * 0.52 * metallic, vec3<f32>(0.0), vec3<f32>(0.55));
        return mix(base, hit_color * metal_tint, blend) - base;
    }
    let f0 = select(vec3<f32>(0.04), vec3<f32>(0.16), is_gem);
    let fresnel = zn_fresnel_schlick(ndotv, f0);
    let blend = clamp(fresnel * weight * select(0.65, 0.85, is_gem), vec3<f32>(0.0), vec3<f32>(0.55));
    return (hit_color - base * 0.55) * blend;
}
