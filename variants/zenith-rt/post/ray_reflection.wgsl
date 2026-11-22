// src: Turner Whitted, An Improved Illumination Model for Shaded Display, CACM 1980 (secondary reflection rays); Schlick, Eurographics 1994 (Fresnel); Horizon Shader API 0.2 (scene reach and surface metadata).

fn zp_rt_opaque_reflection(p: vec3<f32>, n: vec3<f32>, direction: vec3<f32>, smoothness: f32, data: f32) -> vec4<f32> {
    if frame.has_ray_tracing == 0u || dot(direction, n) < 0.025 || data > 0.50 {
        return vec4<f32>(0.0);
    }
    let metal_or_gem = data < -0.05 || (data > 0.12 && data < 0.40);
    let polish = select(smoothstep(0.70, 0.94, smoothness), smoothstep(0.40, 0.80, smoothness), metal_or_gem);
    let weight = polish * (1.0 - smoothstep(32.0, 68.0, length(p)));
    if weight <= 0.001 {
        return vec4<f32>(0.0);
    }
    // Glossy cone: the ray is jittered inside a lobe that widens with roughness, with a minimum of about two pixels
    // so distant detail (tree crowns, fences) is antialiased by the temporal average instead of crawling.
    var ray = direction;
    {
        let rough = 1.0 - smoothness;
        // Per-pixel offset plus the R2 sequence over frames: stratified in time, so the average converges fast.
        let h = fract(zn_hash22(p.xz * 37.17 + vec2<f32>(p.y * 13.31, p.y * 5.77)) + f32(frame.frame_index % 997u) * vec2<f32>(0.7548776662, 0.5698402909));
        let up = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(direction.y) > 0.95);
        let t = normalize(cross(up, direction));
        let b = cross(direction, t);
        let cone = max(rough * rough * 0.9, 0.0030);
        let jittered = normalize(direction + (t * (h.x * 2.0 - 1.0) + b * (h.y * 2.0 - 1.0)) * cone);
        ray = select(direction, jittered, dot(jittered, n) > 0.04);
    }
    let color = zn_rt_reflection(p + n * 0.075, ray, 86.0);
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

// The traced glossy reflection jitters its ray every frame; averaging it over time (reprojected history, depth gated)
// turns that jitter into a rough-reflection blur instead of speckle (Schied et al., SVGF, HPG 2017).
fn zp_rt_out(p: vec3<f32>, delta: vec3<f32>, weight: f32) -> vec4<f32> {
    if weight <= 0.001 {
        return vec4<f32>(delta, 0.0);
    }
    var filtered = delta;
    let uv_prev = zp_previous_uv(p);
    if all(uv_prev >= vec2<f32>(0.0)) && all(uv_prev < vec2<f32>(1.0)) {
        let dims = vec2<i32>(textureDimensions(zp_reflection_previous));
        let prior = textureLoad(zp_reflection_previous, min(vec2<i32>(uv_prev * vec2<f32>(dims)), dims - 1), 0);
        let still = 1.0 - smoothstep(0.0, 0.06, length(frame.camera_motion));
        if prior.a > 0.0 {
            let expected = length(p + frame.camera_motion);
            let valid = 1.0 - smoothstep(0.05, 0.12 + expected * 0.008, abs(prior.a - expected));
            let keep = mix(0.78, 0.96, still) * valid;
            let limit = vec3<f32>(mix(0.30, 0.60, still));
            filtered = mix(delta, clamp(prior.rgb, delta - limit, delta + limit), keep);
        }
    }
    return vec4<f32>(filtered, length(p));
}
