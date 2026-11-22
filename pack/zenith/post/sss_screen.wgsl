// src: J. Jimenez, V. Sundstedt, D. Gutierrez, "Screen-Space Perceptual Rendering of Human Skin", ACM TAP 6(4), 2009 and Jimenez et al., "Separable Subsurface Scattering", CGF 2015 (screen-space diffusion with depth-aware weights); E. d'Eon, D. Luebke, "Advanced Techniques for Realistic Real-Time Skin Rendering", GPU Gems 3, 2007 (sum-of-Gaussians profile, red scatters farthest); Horizon Shader API 0.2 (surface_at, view_position, previous).
// Screen-space subsurface scattering for surfaces the material stage tagged with surface data 0.45 (skin, wax, snow, ice, honey).

override sss_screen: bool = true;
override quality_mode: u32 = 1u; // 0 = Performance, 1 = Balanced, 2 = Quality (manifest order)

const ZP_SSS_CLASS: f32 = 0.45;
const ZP_SSS_TAPS: vec3<i32> = vec3<i32>(8, 12, 16);
// Scatter width in blocks per channel (red travels farthest, blue least).
const ZP_SSS_WIDTH: vec3<f32> = vec3<f32>(0.10, 0.045, 0.025);

fn post(input: PostInput) -> vec4<f32> {
    let base = input.color;
    if !sss_screen || input.depth <= 0.0 || frame.eye_in != 0u {
        return base;
    }
    let here = surface_at(vec2<i32>(input.pixel));
    if !here.present || abs(here.data - ZP_SSS_CLASS) > 0.03 {
        return base;
    }

    let dims = vec2<f32>(textureDimensions(previous));
    let P = view_position(input.uv, input.depth);
    let dist = max(length(P), 0.2);
    // Blocks to pixels at this depth.
    let px_per_block = abs(frame.projection[1][1]) * 0.5 * dims.y / dist;
    let max_px = min(ZP_SSS_WIDTH.r * 2.2 * px_per_block, 14.0);
    if max_px < 1.2 {
        return base;
    }

    let taps = ZP_SSS_TAPS[min(quality_mode, 2u)];
    let rot = zn_ign(input.pixel, 0u) * 6.2831853;
    var sum = base.rgb;
    var wsum = vec3<f32>(1.0);
    for (var i = 0; i < taps; i = i + 1) {
        // Golden-angle spiral, denser near the centre.
        let fi = (f32(i) + 0.5) / f32(taps);
        let r = sqrt(fi) * max_px;
        let a = rot + f32(i) * 2.3999632;
        let off = vec2<f32>(cos(a), sin(a)) * r;
        let uv = input.uv + off / dims;
        if any(uv <= vec2<f32>(0.001)) || any(uv >= vec2<f32>(0.999)) {
            continue;
        }
        let s = surface_at(vec2<i32>(uv * dims));
        let d = depth_at(uv);
        if !s.present || abs(s.data - ZP_SSS_CLASS) > 0.03 || d <= 0.0 {
            continue;
        }
        let Q = view_position(uv, d);
        let dz = abs(length(Q) - dist);
        let r_blocks = r / px_per_block;
        // Depth gate: only the same surface, not a silhouette behind or in front of it.
        let gate = exp(-(dz * dz) / (0.012 + 0.5 * r_blocks * r_blocks));
        // Per-channel Gaussian in world distance.
        let kernel = exp(-(r_blocks * r_blocks) / (2.0 * ZP_SSS_WIDTH * ZP_SSS_WIDTH)) * gate;
        let c = min(textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb, vec3<f32>(6.0));
        sum += c * kernel;
        wsum += kernel;
    }
    let diffused = sum / wsum;
    // Keep part of the sharp image so texture detail and specular survive.
    let amount = select(0.50, 0.38, quality_mode == 0u);
    return vec4<f32>(mix(base.rgb, diffused, amount), base.a);
}
