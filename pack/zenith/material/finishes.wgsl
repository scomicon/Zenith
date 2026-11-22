// src: Karis, Real Shading in Unreal Engine 4, SIGGRAPH 2013 (metal/dielectric roughness and specular color); Jensen et al., Practical Model for Subsurface Light Transport, SIGGRAPH 2001 (concept of attenuated transmission); Beer-Lambert absorption; Zenith's own crystal lobes and finishes.

// Smoothness, metallic fraction and porosity. The increasing patina covers the conductor.
fn mat_copper_finish(tags: u32) -> vec3<f32> {
    if (tags & TAG_COPPER_OXIDIZED) != 0u {
        return vec3<f32>(0.22, 0.04, 0.38);
    }
    if (tags & TAG_COPPER_WEATHERED) != 0u {
        return vec3<f32>(0.40, 0.34, 0.26);
    }
    if (tags & TAG_COPPER_EXPOSED) != 0u {
        return vec3<f32>(0.65, 0.68, 0.13);
    }
    return vec3<f32>(0.88, 0.94, 0.04);
}

fn mat_amethyst_scatter(
    albedo: vec3<f32>, sprite: vec3<f32>, N: vec3<f32>, V: vec3<f32>, L: vec3<f32>,
    uv: vec2<f32>,
) -> vec3<f32> {
    let H = mat_safe_normalize(V + L);
    let facet = clamp(dot(H, N), 0.0, 1.0);
    let color_shift = 0.5 + 0.5 * cos(10.5 * facet + dot(uv, vec2<f32>(4.1, -2.7)));
    let tint = mix(vec3<f32>(0.80, 0.33, 0.91), vec3<f32>(0.42, 0.57, 1.0), color_shift);
    let fleck = smoothstep(0.05, 0.42, zn_luma(sprite));
    let highlight = smoothstep(-0.22, 0.75, dot(N, L)) * mix(0.32, 1.0, facet * facet);
    return mix(albedo, tint * sqrt(max(0.0, zn_luma(albedo))), 0.55)
        * (fleck * highlight * mix(0.11, 0.27, color_shift));
}

fn mat_volume_scatter(N: vec3<f32>, V: vec3<f32>, L: vec3<f32>, honey: bool) -> vec3<f32> {
    let incidence = dot(N, L);
    let rim = 1.0 - max(dot(N, V), 0.0);
    let path = mix(0.24, 0.95, smoothstep(-0.55, 0.75, incidence)) * (1.0 - 0.32 * rim);
    let absorption = select(vec3<f32>(1.45, 0.54, 0.24), vec3<f32>(0.37, 1.55, 3.65), honey);
    let transmission = exp(-absorption * path);
    let scatter = 0.075 + 0.18 * smoothstep(0.62, -0.76, incidence) + rim * rim * 0.095;
    let gain = select(vec3<f32>(0.66, 0.87, 1.0), vec3<f32>(0.97, 0.68, 0.33), honey);
    return gain * transmission * scatter;
}

fn mat_finish_scattered_light(input: MaterialInput, surface_albedo: vec3<f32>, N: vec3<f32>,
    V: vec3<f32>, L: vec3<f32>, radiance: vec3<f32>) -> vec3<f32> {
    let span = 1.0 - smoothstep(17.0, 44.0, length(input.position));
    if (input.tags & TAG_AMETHYST) != 0u {
        return mat_amethyst_scatter(surface_albedo, input.albedo.rgb, N, V, L, input.uv) * radiance * span;
    }
    let tint = mat_volume_scatter(N, V, L, (input.tags & TAG_HONEY) != 0u);
    // Keep the texture's internal variations when adding diffuse transmission.
    let texture_weight = mix(0.56, 1.0, sqrt(clamp(zn_luma(input.albedo.rgb), 0.0, 1.0)));
    return tint * radiance * (texture_weight * span);
}
