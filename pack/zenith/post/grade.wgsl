// src: Jimenez 2014, Next Generation Post Processing in Call of Duty Advanced Warfare (tent upsample, energy-conserving bloom mix); Burt and Adelson 1983 (binomial kernel)
// Pass 8 (last): bloom composite and colour grade. Draws at the window's size; the tonemap stage follows.
//
// Bloom: three levels, bloom_a (1/2) and bloom_b (1/4) written by bloom_down_a / bloom_down_b, and the widest
// one, bloom_wide (1/4), written by bloom_wide.wgsl from bloom_b, spread the HDR highlights extracted by
// bloom_down_a. They are added to the sharp scene; ordinary blocks below scene white never enter the blur
// (the approach of Jimenez 2014, "Next Generation Post Processing in Call of Duty: Advanced Warfare",
// SIGGRAPH). bloom_b is read with the 3x3 tent upsample of the same slides, evaluated here with 9 bilinear taps;
// bloom_a and bloom_wide are whole levels already, so one bilinear tap each. Level weights and mix factor are
// own picks.
//
// Saturation: blend between the luminance and the colour, luminance from the frame's own weights
// (`frame.luminance`) so it is right in any primaries.
//
// Histogram adaptation multiplies the linear image here. Manual EV stays in the tonemap stage.

override bloom: f32 = 1.0;
override saturation: f32 = 1.05;
override auto_exposure: bool = true;
override histogram_exposure: bool = true;

// Underwater grade (switched immediately on frame.eye_in == 1u to match Horizon's instant water fog/environment switch). Vanilla fogs the world with the biome's
// water fog colour, default #050533: a saturated deep blue that turns the whole picture violet-blue, while sky/vlight
// underwater haze leans greenish. The grade (own art choices): (1) tames extreme blue excess into cyan-green without
// crushing chroma, (2) keeps desaturation light so terrain stays readable, (3) applies a turquoise-blue colour balance,
// (4) adds a gentle midtone contrast lift, a world-space vertical light gradient (brighter toward the surface), and a
// subtle depth vignette at screen edges.
const ZP_UW_BLUE_CUT: f32 = 0.28;       // gentle softening of pure primary-blue excess
const ZP_UW_DESAT: f32 = 0.16;          // calm natural desaturation at full submersion
const ZP_UW_TEAL: vec3<f32> = vec3<f32>(0.84, 0.98, 1.06); // restrained deep-water colour balance
const ZP_UW_TEAL_MIX: f32 = 0.22;
const ZP_UW_CONTRAST: f32 = 1.04;       // subtle midtone contrast underwater
const ZP_UW_CONTRAST_PIVOT: f32 = 0.032;
const ZP_UW_VERT_LOW: f32 = 0.96;
const ZP_UW_VERT_HIGH_NIGHT: f32 = 0.88;
const ZP_UW_VERT_HIGH_DAY: f32 = 1.02;
const ZP_UW_VERT_DEEP_TINT: vec3<f32> = vec3<f32>(0.88, 0.96, 1.06);
const ZP_UW_VERT_SURFACE_TINT: vec3<f32> = vec3<f32>(0.96, 1.04, 1.02);
const ZP_UW_VIGNETTE: f32 = 0.06; // own choice: subtle edge depth, without blackening the seabed
const ZP_UW_VIGNETTE_TINT: vec3<f32> = vec3<f32>(0.82, 0.94, 1.04);

const ZP_BLOOM_MIX: f32 = 0.08;   // additive highlight gain at bloom = 1 (own choice)

fn zp_tent_b(uv: vec2<f32>) -> vec3<f32> {
    let t = 1.0 / vec2<f32>(textureDimensions(bloom_b));
    return textureSampleLevel(bloom_b, linear_sampler, uv, 0.0).rgb * 0.25
        + (textureSampleLevel(bloom_b, linear_sampler, uv + vec2<f32>(t.x, 0.0), 0.0).rgb
            + textureSampleLevel(bloom_b, linear_sampler, uv - vec2<f32>(t.x, 0.0), 0.0).rgb
            + textureSampleLevel(bloom_b, linear_sampler, uv + vec2<f32>(0.0, t.y), 0.0).rgb
            + textureSampleLevel(bloom_b, linear_sampler, uv - vec2<f32>(0.0, t.y), 0.0).rgb) * 0.125
        + (textureSampleLevel(bloom_b, linear_sampler, uv + t, 0.0).rgb
            + textureSampleLevel(bloom_b, linear_sampler, uv - t, 0.0).rgb
            + textureSampleLevel(bloom_b, linear_sampler, uv + vec2<f32>(t.x, -t.y), 0.0).rgb
            + textureSampleLevel(bloom_b, linear_sampler, uv + vec2<f32>(-t.x, t.y), 0.0).rgb) * 0.0625;
}

// Wide level: written by post/bloom_wide.wgsl as a spread tent over bloom_b, at 1/4 size. It used to be
// evaluated here with 9 taps per pixel of the window, while shader API 0.2 allowed only four post `output`s;
// with 16 allowed, the level has a pass of its own and is read back with one bilinear tap.
fn zp_tent_wide(uv: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(bloom_wide, linear_sampler, uv, 0.0).rgb;
}

fn zp_uw_ray_y(uv: vec2<f32>, depth: f32) -> f32 {
    if (depth > 0.0) {
        let p = view_position(uv, depth);
        let len = length(p);
        if (len > 1e-4) {
            return p.y / len;
        }
    }
    let clip_xy = vec2<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let near = frame.projection_inverse * vec4<f32>(clip_xy, 1.0, 1.0);
    let far = frame.projection_inverse * vec4<f32>(clip_xy, 0.0, 1.0);
    let ray_view = far.xyz * near.w - near.xyz * far.w;
    let ray_world = (frame.view_inverse * vec4<f32>(ray_view, 0.0)).xyz;
    let len = length(ray_world);
    if (len < 1e-6) {
        return 0.0;
    }
    let ref_p = view_position(uv, 0.5);
    let oriented = select(-ray_world, ray_world, dot(ray_world, ref_p) >= 0.0);
    return oriented.y / len;
}

fn zp_underwater(colour: vec3<f32>, uv: vec2<f32>, depth: f32, water: f32) -> vec3<f32> {
    // Blue beyond the brighter of red/green is the fog's cast: pull part of it out of blue into
    // green/cyan so #050533 reads rich deep slate-blue instead of neon violet or glowing baby-cyan.
    let excess = max(colour.b - max(colour.r, colour.g) * 1.1, 0.0) * ZP_UW_BLUE_CUT * water;
    var c = max(colour + vec3<f32>(0.02 * excess, 0.12 * excess, -excess), vec3<f32>(0.0));
    var lum = dot(c, frame.luminance);
    c = mix(c, vec3<f32>(lum), ZP_UW_DESAT * water);

    let gain = mix(vec3<f32>(1.0), ZP_UW_TEAL / max(dot(ZP_UW_TEAL, frame.luminance), 1e-3), ZP_UW_TEAL_MIX * water);
    c = c * gain;

    // Gentle hue-preserving midtone contrast lift so underwater terrain and kelp keep depth.
    lum = dot(c, frame.luminance);
    let contrast_scale = mix(1.0, pow(clamp(lum / ZP_UW_CONTRAST_PIVOT, 0.25, 2.2), ZP_UW_CONTRAST - 1.0), water);
    c = c * contrast_scale;

    // World-space vertical light gradient: brighter and crisper aqua toward the water surface.
    let ray_y = zp_uw_ray_y(uv, depth);
    let up_t = smoothstep(-0.45, 0.55, ray_y);
    let day_k = smoothstep(-0.12, 0.16, frame.sun_direction.y);
    let vert_bright = mix(ZP_UW_VERT_LOW, mix(ZP_UW_VERT_HIGH_NIGHT, ZP_UW_VERT_HIGH_DAY, day_k), up_t);
    let vert_tint = mix(ZP_UW_VERT_DEEP_TINT, ZP_UW_VERT_SURFACE_TINT, up_t);
    c = c * mix(vec3<f32>(1.0), vert_tint * vert_bright, water);

    // Subtle depth vignette around screen edges.
    let aspect = frame.resolution.x / max(frame.resolution.y, 1.0);
    let vig_r = length((uv - vec2<f32>(0.5)) * vec2<f32>(aspect / 1.6, 1.0));
    let vig_t = smoothstep(0.28, 0.82, vig_r);
    let vig = mix(vec3<f32>(1.0), ZP_UW_VIGNETTE_TINT * (1.0 - ZP_UW_VIGNETTE), vig_t * water);
    return c * vig;
}

fn zp_powder_snow(colour: vec3<f32>, uv: vec2<f32>) -> vec3<f32> {
    let p = (uv - 0.5) * vec2<f32>(1.36, 1.64);
    let radius = length(p);
    let crystals = zn_noise2(p * 128.0) * 0.66 + zn_noise2(p * 29.0) * 0.34;
    let frost = smoothstep(0.40, 0.98, radius + (crystals - 0.5) * 0.21);
    let haze = max(frame.fog_color, vec3<f32>(0.0)) * vec3<f32>(0.80, 0.95, 1.15);
    let ice = clamp((crystals - 0.60) * 0.55, 0.0, 0.20);
    return mix(colour * vec3<f32>(0.86, 0.94, 1.03), haze * (0.81 + ice), 0.10 + frost * 0.54);
}

fn post(input: PostInput) -> vec4<f32> {
    var colour = max(input.color.rgb, vec3<f32>(0.0));
    colour = zp_optics_blur(input, colour);

    if (bloom > 0.0) {
        let a = textureSampleLevel(bloom_a, linear_sampler, input.uv, 0.0).rgb;
        let glow = a * 0.35 + zp_tent_b(input.uv) * 0.35 + zp_tent_wide(input.uv) * 0.30;
        colour = colour + glow * clamp(ZP_BLOOM_MIX * bloom, 0.0, 0.5);
    }

    let water = select(0.0, 1.0, frame.eye_in == 1u);
    if (water > 0.0) {
        colour = zp_underwater(colour, input.uv, input.depth, water);
    } else if frame.eye_in == 3u && frame.fog_environment.x >= 0.0 && frame.blindness <= 0.0 && frame.darkness <= 0.0 {
        colour = zp_powder_snow(colour, input.uv);
    }

    colour += zp_lens_flare(input.uv);
    let lum = dot(colour, frame.luminance);
    colour = max(mix(vec3<f32>(lum), colour, saturation), vec3<f32>(0.0));
    if auto_exposure && histogram_exposure && frame.dimension != 1 {
        let exposure = zp_shared[0];
        let vision = 1.0 - clamp(max(frame.night_vision, max(frame.blindness, frame.darkness)), 0.0, 1.0);
        let medium = select(0.0, select(0.18, 1.0, frame.eye_in == 0u), frame.eye_in <= 1u);
        let adapted_ev = select(clamp(exposure.r, -1.75, 1.15), clamp(exposure.r, -1.75, 0.20), frame.eye_in == 1u);
        colour *= exp2(adapted_ev * vision * medium);
    }
    return vec4<f32>(zp_apply_mood(colour, color_mood), 1.0);
}
