// src: Jimenez, Echevarria, Sousa and Gutierrez, SMAA, Eurographics 2012 (local contrast adaptation); Horizon Shader API 0.2.

override fxaa: bool = true;
override morphological_aa: bool = false;

fn zp_edge_luma(uv: vec2<f32>) -> f32 {
    let lum = zn_luma(max(textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb, vec3<f32>(0.0)));
    return sqrt(lum / (1.0 + lum));
}

fn post(input: PostInput) -> vec4<f32> {
    if !fxaa || !morphological_aa {
        return vec4<f32>(0.0);
    }
    let px = 1.0 / vec2<f32>(textureDimensions(previous));
    let west = vec2<f32>(px.x, 0.0);
    let north = vec2<f32>(0.0, px.y);
    let center = zp_edge_luma(input.uv);
    let delta = abs(center - vec2<f32>(zp_edge_luma(input.uv - west), zp_edge_luma(input.uv - north)));
    if max(delta.x, delta.y) < 0.028 {
        return vec4<f32>(0.0);
    }
    let forward = abs(center - vec2<f32>(zp_edge_luma(input.uv + west), zp_edge_luma(input.uv + north)));
    let local_peak = max(max(delta.x, delta.y), max(forward.x, forward.y));
    let edges = delta >= vec2<f32>(max(0.028, 0.55 * local_peak));
    return vec4<f32>(select(vec2<f32>(0.0), vec2<f32>(1.0), edges), 0.0, 1.0);
}
