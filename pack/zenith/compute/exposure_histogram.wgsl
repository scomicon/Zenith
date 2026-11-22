// src: Epic Games, Auto Exposure in Unreal Engine (log luminance histogram and metering mask); Horizon Shader API 0.2 (ComputeInput, kept resources).

override auto_exposure: bool = true;
override histogram_exposure: bool = true;

var<workgroup> zp_bins: array<atomic<u32>, 64>;

fn compute(input: ComputeInput) {
    if !auto_exposure || !histogram_exposure || frame.dimension == 1 {
        return;
    }
    let tile = vec2<u32>(input.cell.x / 64u, input.cell.y);
    atomicStore(&zp_bins[input.local], 0u);
    workgroupBarrier();

    let size = textureDimensions(previous);
    for (var quadrant = 0u; quadrant < 4u; quadrant++) {
        let sample_cell = tile * 16u + vec2<u32>(input.local % 8u, input.local / 8u)
            + 8u * vec2<u32>(quadrant % 2u, quadrant / 2u);
        let uv = (vec2<f32>(sample_cell) + 0.5) / vec2<f32>(192.0, 128.0);
        let pixel = min(vec2<u32>(uv * vec2<f32>(size)), size - 1u);
        let rgb = max(textureLoad(previous, vec2<i32>(pixel), 0).rgb, vec3<f32>(0.0));
        let log_lum = log2(clamp(dot(rgb, frame.luminance), exp2(-12.0), exp2(8.0)));
        let bin = u32(clamp((log_lum + 12.0) * 3.2, 0.0, 63.0));
        let center = all(abs(uv - 0.5) < vec2<f32>(0.25));
        atomicAdd(&zp_bins[bin], select(1u, 3u, center));
    }
    workgroupBarrier();
    textureStore(zp_luma_tiles, vec2<i32>(i32(input.local), i32(tile.y * 12u + tile.x)),
        vec4<u32>(atomicLoad(&zp_bins[input.local]), 0u, 0u, 0u));
}
