// src: Jimenez 2014, Next Generation Post Processing in Call of Duty Advanced Warfare (tent upsample, wide bloom lobe); Burt and Adelson 1983 (binomial kernel)
// Pass 4: bloom, the wide level: target `bloom_b` (1/4 size) -> target `bloom_wide` (1/4 size).
//
// The 3x3 binomial tent (4-2-1 over 16: P. J. Burt, E. H. Adelson, "The Laplacian Pyramid as a Compact Image
// Code", IEEE Transactions on Communications 31(4), 1983) with its taps spread 3 texels apart over the
// 1/4-size level and read with bilinear filtering, so the lobe reaches ~12 pixels of the window out from a
// texel: the widest level of the chain (J. Jimenez, "Next Generation Post Processing in Call of Duty: Advanced
// Warfare", SIGGRAPH 2014, tent upsample). Own pick: the 3-texel spread.
//
// A level of its own: shader API 0.2 allows 16 post `output`s (it was 4 when this lobe had to be folded into
// post/grade.wgsl as a spread tent evaluated per pixel of the window). The split is cheaper and clearer: the 9
// taps now run once per texel of a 1/4-size target, 16 times fewer, and grade.wgsl reads the level back with
// one bilinear tap. The lobe is low-frequency by construction, so writing it at 1/4 size costs nothing the
// folded version kept.
//
// Bloom is not thresholded: grade.wgsl mixes the blur into the picture, which conserves energy.

override bloom: f32 = 1.0;

fn zp_wide_tap(uv: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(bloom_b, linear_sampler, uv, 0.0).rgb;
}

fn post(input: PostInput) -> vec4<f32> {
    if (bloom <= 0.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let uv = input.uv;
    let r = 3.0 / vec2<f32>(textureDimensions(bloom_b));

    let rgb = zp_wide_tap(uv) * 0.25
        + (zp_wide_tap(uv + vec2<f32>(r.x, 0.0))
            + zp_wide_tap(uv - vec2<f32>(r.x, 0.0))
            + zp_wide_tap(uv + vec2<f32>(0.0, r.y))
            + zp_wide_tap(uv - vec2<f32>(0.0, r.y))) * 0.125
        + (zp_wide_tap(uv + r)
            + zp_wide_tap(uv - r)
            + zp_wide_tap(uv + vec2<f32>(r.x, -r.y))
            + zp_wide_tap(uv + vec2<f32>(-r.x, r.y))) * 0.0625;
    return vec4<f32>(rgb, 1.0);
}
