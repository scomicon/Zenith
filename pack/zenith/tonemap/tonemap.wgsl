// src: K. Narkowicz, ACES Filmic Tone Mapping Curve, 2016 (concept only); T. Sobotka, AgX look/highlight-desaturation concept (2023); Zenith own rational curve, peak-channel / AgX-inspired mapping, HDR extension and eye-light adaptation, 2026.
// Zenith original rational filmic & AgX-inspired tonemap family. Conceptual references:
// K. Narkowicz, ACES Filmic Tone Mapping Curve (2016),
// https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/
// and Troy Sobotka's AgX chromaticity-inset & smooth highlight-desaturation concept.
// Neither ACES coefficients nor external AgX matrices/LUTs are imported here:
// all curve parameters, inset weights, HDR extension and eye adaptation are original.
// Horizon 0.2 contract: linear in/out, 1 = paper white; engine encodes output
// and applies black_level. Do not gamma-encode or lift display blacks here.

const ZP_DITHER: f32 = 1.0; // dither amplitude in 8-bit steps (TPDF peak is +-1 step)
override exposure_bias: f32 = 0.0; // EV / stops
override auto_exposure: bool = true;
override histogram_exposure: bool = true;
override tonemap_curve: u32 = 3u; // 0 = Soft, 1 = Neutral, 2 = Contrast, 3 = AgX (manifest order)

fn sky_filmic(x: f32) -> f32 {
    // Original rational toe/shoulder: F(x)=x(x+a)/(x*x+b*x+c).
    // F(0)=0; F(infinity)=1. b>=a>0,c>0 make F monotone on x>=0,
    // since its derivative numerator is (b-a)x*x+2cx+ac >= 0.
    var a = 0.12;
    var b = 0.48;
    var c = 0.08;
    if (tonemap_curve == 0u) { a = 0.20; b = 0.65; c = 0.06; }
    if (tonemap_curve == 2u) { a = 0.06; b = 0.36; c = 0.11; }
    // Reciprocal evaluation above one avoids squaring large HDR input values.
    if (x > 1.0) {
        let r = 1.0 / x;
        return (1.0 + a * r) / (1.0 + b * r + c * r * r);
    }
    return x * (x + a) / (x * x + b * x + c);
}

fn sky_filmic_agx(x: f32) -> f32 {
    let a = 0.10;
    let b = 0.44;
    let c = 0.085;
    if (x > 1.0) {
        let r = 1.0 / x;
        return (1.0 + a * r) / (1.0 + b * r + c * r * r);
    }
    return x * (x + a) / (x * x + b * x + c);
}

fn zp_agx_channel(x: f32, headroom: f32) -> f32 {
    let s = max(0.0, (x - 1.0) / (x + headroom));
    return sky_filmic_agx(x) + (headroom - 1.0) * s * s;
}

// Smooth exposure adaptation using Horizon's 2s half-life eased `frame.eye_light_smooth`.
fn zp_eye_adaptation_ev() -> f32 {
    if (!auto_exposure || histogram_exposure || frame.dimension == 1) {
        return 0.0;
    }
    let vis = 1.0 - clamp(max(frame.blindness, frame.darkness), 0.0, 1.0);
    if (frame.dimension == -1) {
        let eye_lum = clamp(frame.eye_light_smooth.x, 0.0, 1.0);
        return mix(0.28, -0.04, smoothstep(0.10, 0.85, eye_lum)) * vis;
    }
    let day_sky = smoothstep(-0.14, 0.18, frame.sun_direction.y);
    let night_sky = mix(0.14, 1.0, day_sky);
    let eye_lum = clamp(max(frame.eye_light_smooth.y * night_sky, frame.eye_light_smooth.x * 0.72), 0.0, 1.0);
    let ev = mix(0.45, -0.06, smoothstep(0.05, 0.90, eye_lum));
    return ev * vis * select(1.0, 0.35, frame.eye_in == 1u);
}

// AgX-inspired curve: slight pre-curve chromaticity inset, per-channel monotone curve with HDR shoulder,
// highlight desaturation toward white and subtle midtone vibrancy recovery.
fn zp_tonemap_agx(color: vec3<f32>, headroom: f32) -> vec3<f32> {
    let lum_w = select(vec3<f32>(0.2126, 0.7152, 0.0722), frame.luminance, dot(frame.luminance, vec3<f32>(1.0)) > 0.1);
    let lum = max(dot(color, lum_w), 0.0);
    let inset = mix(color, vec3<f32>(lum), 0.14);
    let mapped = vec3<f32>(
        zp_agx_channel(inset.r, headroom),
        zp_agx_channel(inset.g, headroom),
        zp_agx_channel(inset.b, headroom)
    );
    let mapped_lum = zp_agx_channel(lum, headroom);
    let desat = smoothstep(0.65, 6.0, lum) * 0.62;
    var out_c = mix(mapped, vec3<f32>(mapped_lum), desat);
    let out_lum = dot(out_c, lum_w);
    let mid_punch = 1.0 + 0.14 * (1.0 - desat) * smoothstep(0.01, 0.22, out_lum);
    out_c = max(mix(vec3<f32>(out_lum), out_c, mid_punch), vec3<f32>(0.0));
    return clamp(out_c, vec3<f32>(0.0), vec3<f32>(headroom));
}

fn tonemap(input: TonemapInput) -> vec3<f32> {
    // Exposure is 2^EV by the photographic definition of a stop. Bound it to
    // the manifest range. Horizon promises nonnegative, non-NaN input.color;
    // cap infinities/overflow as well, keeping the mapper finite for any peak.
    let total_ev = clamp(exposure_bias + zp_eye_adaptation_ev(), -4.0, 4.0);
    let color = min(max(input.color, vec3<f32>(0.0)), vec3<f32>(1.0e30)) * exp2(total_ev);
    let peak = max(color.r, max(color.g, color.b));
    if (peak <= 0.0) { return vec3<f32>(0.0); }
    let headroom = max(frame.headroom, 1.0);
    var out_color: vec3<f32>;
    if (tonemap_curve == 3u) {
        out_color = zp_tonemap_agx(color, headroom);
    } else {
        // Original HDR extension: the added shoulder is zero below scene white,
        // rises monotonically above it, and asymptotes to headroom-1. Midtones
        // remain at the same paper-white-relative level when headroom changes.
        let shoulder = max(0.0, (peak - 1.0) / (peak + headroom));
        let mapped = sky_filmic(peak) + (headroom - 1.0) * shoulder * shoulder;
        // Scaling by the maximum channel preserves RGB ratios and ensures every
        // channel fits the output peak without an extra hue-changing hard clip.
        out_color = (color / peak) * mapped;
    }
    // Dither against banding of smooth dark gradients (sky, fog, water haze): triangular-PDF noise from two
    // interleaved-gradient-noise samples (Jimenez 2014), about one 8-bit step in size. The step is measured
    // in the encoded output: d(linear)/d(encoded) ~ 2.2 * linear^0.545 for the sRGB-like curve, so the noise
    // grows with the value and the black level stays clean. Varies per frame so it averages out.
    let n = zn_ign(input.pixel, frame.frame_index) + zn_ign(input.pixel + vec2<f32>(37.0, 91.0), frame.frame_index + 17u) - 1.0;
    let step_lin = (2.2 / 255.0) * pow(max(out_color, vec3<f32>(0.0005)), vec3<f32>(0.545)) * ZP_DITHER;
    return clamp(out_color + step_lin * n, vec3<f32>(0.0), vec3<f32>(headroom));
}
