// src: Jimenez 2014, Next Generation Post Processing in Call of Duty Advanced Warfare (13-tap bloom downsample)
// Pass 3: bloom, second downsample, target `bloom_a` (1/2 size) -> target `bloom_b` (1/4 size).
//
// Source: J. Jimenez, "Next Generation Post Processing in Call of Duty: Advanced Warfare", SIGGRAPH 2014:
// the 13-tap downsample. Fixed weights (centre 0.125, outer corners 4 x 0.03125, edge midpoints
// 4 x 0.0625, inner taps 4 x 0.125; they sum to 1); the Karis average is only needed on the first level.

fn zp_tap(uv: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(bloom_a, linear_sampler, uv, 0.0).rgb;
}

fn post(input: PostInput) -> vec4<f32> {
    let uv = input.uv;
    let t = 1.0 / vec2<f32>(textureDimensions(bloom_a));

    let a = zp_tap(uv + t * vec2<f32>(-2.0, -2.0));
    let b = zp_tap(uv + t * vec2<f32>(0.0, -2.0));
    let c = zp_tap(uv + t * vec2<f32>(2.0, -2.0));
    let d = zp_tap(uv + t * vec2<f32>(-2.0, 0.0));
    let e = zp_tap(uv);
    let f = zp_tap(uv + t * vec2<f32>(2.0, 0.0));
    let g = zp_tap(uv + t * vec2<f32>(-2.0, 2.0));
    let h = zp_tap(uv + t * vec2<f32>(0.0, 2.0));
    let i = zp_tap(uv + t * vec2<f32>(2.0, 2.0));
    let j = zp_tap(uv + t * vec2<f32>(-1.0, -1.0));
    let k = zp_tap(uv + t * vec2<f32>(1.0, -1.0));
    let l = zp_tap(uv + t * vec2<f32>(-1.0, 1.0));
    let m = zp_tap(uv + t * vec2<f32>(1.0, 1.0));

    let rgb = e * 0.125
        + (a + c + g + i) * 0.03125
        + (b + d + f + h) * 0.0625
        + (j + k + l + m) * 0.125;
    return vec4<f32>(rgb, 1.0);
}
