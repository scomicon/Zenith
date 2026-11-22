// src: Jimenez 2014, Next Generation Post Processing in Call of Duty Advanced Warfare (13-tap bloom downsample, Karis-weighted)
// Pass 5: bloom, first downsample -> target `bloom_a` (1/2 size).
//
// In The End (`frame.dimension == 1`), samples `previous` (`compose` + `end_rift`) so the warp rift core
// and lightning arcs bloom naturally; Overworld/Nether keep sampling `scene_color` directly.
//
// Source: J. Jimenez, "Next Generation Post Processing in Call of Duty: Advanced Warfare", SIGGRAPH 2014:
// the 13-tap downsample (taps on a 5x5 texel footprint, read with bilinear filtering), and the weighting
// of each overlapping group of taps by 1 / (1 + luma) (the "Karis average" that the same slides credit to
// B. Karis) so a single very bright texel cannot make the bloom flicker.
//
// Extract HDR highlights before any downsample. Blurring and mixing the entire
// scene created pale duplicate contours around ordinary blocks and softened detail.
// Own choice: smooth luminance gate from scene white (1) to twice scene white (2).

fn zp_bloom_highlight(c: vec3<f32>) -> vec3<f32> {
    return c * smoothstep(1.0, 2.0, zn_luma(c));
}

override bloom: f32 = 1.0;

fn zp_tap(uv: vec2<f32>) -> vec3<f32> {
    var raw: vec3<f32>;
    if (frame.dimension == 1) {
        raw = textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb;
    } else {
        raw = textureSampleLevel(scene_color, linear_sampler, uv, 0.0).rgb;
    }
    // Guard against NaN / negative / absurd texels before they reach a blur.
    let c = min(max(raw, vec3<f32>(0.0)), vec3<f32>(256.0));
    return zp_bloom_highlight(c);
}

fn zp_karis(c: vec3<f32>) -> f32 {
    return 1.0 / (1.0 + zn_luma(c));
}

fn post(input: PostInput) -> vec4<f32> {
    if (bloom <= 0.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let uv = input.uv;
    let t = 1.0 / vec2<f32>(textureDimensions(scene_color));

    // Taps on a 5x5 grid of source texels (a..i), plus the four inner ones (j..m).
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

    // Five boxes: the centre box (j k l m) carries half the weight, the four corner boxes an eighth each.
    let g0 = (j + k + l + m) * 0.25;
    let g1 = (a + b + d + e) * 0.25;
    let g2 = (b + c + e + f) * 0.25;
    let g3 = (d + e + g + h) * 0.25;
    let g4 = (e + f + h + i) * 0.25;
    let w0 = 0.5 * zp_karis(g0);
    let w1 = 0.125 * zp_karis(g1);
    let w2 = 0.125 * zp_karis(g2);
    let w3 = 0.125 * zp_karis(g3);
    let w4 = 0.125 * zp_karis(g4);
    let rgb = (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4) / (w0 + w1 + w2 + w3 + w4);
    return vec4<f32>(rgb, 1.0);
}
