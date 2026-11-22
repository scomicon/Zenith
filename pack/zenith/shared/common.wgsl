// src: Jarzynski and Olano 2020 (PCG hash), Perlin 2002 (quintic fade), Jimenez 2014 (interleaved gradient noise), Schlick 1994 (Fresnel), Schneider and Vos SIGGRAPH 2015 (cloud shadow optical projection), domain-warped wave-interference optical caustics with chromatic dispersion; Hillaire EGSR 2020 (Beer-Lambert fog); Horizon shader API 0.2 (sun/moon directions and local time).
// Zenith shared helpers. Put before every stage's file (manifest `shared`).
//
// Public API (other authors rely on exactly these signatures):
//   zn_luma, zn_saturate3, zn_hash21, zn_hash22, zn_noise2, zn_fbm2,
//   zn_ign, zn_pow5, zn_fresnel_schlick, zn_remap, zn_celestial_weights,
//   zn_cloud_shadow, zn_water_caustic_rgb, zn_water_mist_*, zn_sky_lut_uv
// Everything starting with `zn_i_` is internal: do not call it, do not define a name with that prefix.
// This file declares no bindings, no overrides and does not read `frame`, so every stage can include it.

const ZN_WATER_MIST_TOP: f32 = 2.6;

fn zn_water_mist_strength(day_time: f32, rain: f32, downfall: f32, skylight: f32) -> f32 {
    let dawn = fract(day_time + 0.12) - 0.12;
    let time_gate = smoothstep(-0.055, -0.012, dawn) * (1.0 - smoothstep(0.010, 0.085, dawn));
    let humidity = mix(0.55, 1.0, smoothstep(0.10, 0.65, downfall));
    return time_gate * humidity * (1.0 - smoothstep(0.15, 0.80, rain)) * smoothstep(0.30, 0.85, skylight);
}

// Clip a camera ray to the shallow layer between the water and its upper edge.
fn zn_water_mist_segment(eye_height: f32, vertical: f32, limit: f32) -> vec2<f32> {
    let end = clamp(limit, 0.0, 116.0);
    if abs(vertical) <= 1e-4 {
        return vec2<f32>(0.0, select(0.0, end, eye_height >= -0.15 && eye_height <= ZN_WATER_MIST_TOP));
    }
    let water_t = (-0.15 - eye_height) / vertical;
    let top_t = (ZN_WATER_MIST_TOP - eye_height) / vertical;
    return clamp(vec2<f32>(min(water_t, top_t), max(water_t, top_t)), vec2<f32>(0.0), vec2<f32>(end));
}

fn zn_water_mist_density(height: f32, world_xz: vec2<f32>, drift: vec2<f32>) -> f32 {
    let profile = 1.0 - smoothstep(0.12, ZN_WATER_MIST_TOP, height);
    let patches = mix(0.63, 1.0, smoothstep(0.20, 0.80, zn_noise2(world_xz * 0.12 + drift)));
    return profile * patches;
}

fn zn_water_mist_drift(seconds: f32) -> vec2<f32> {
    let angle = seconds * (6.2831853 / 3600.0);
    return vec2<f32>(sin(angle), 1.0 - cos(angle)) * 5.0;
}

fn zn_water_mist_composite(colour: vec3<f32>, optical_length: f32, strength: f32, ray: vec3<f32>, sun: vec3<f32>) -> vec3<f32> {
    let dawn_light = smoothstep(-0.16, 0.11, sun.y);
    let silver = mix(vec3<f32>(0.092, 0.128, 0.185), vec3<f32>(0.38, 0.45, 0.52), dawn_light);
    let forward = pow(max(dot(ray, sun), 0.0), 4.0) * smoothstep(-0.075, 0.10, sun.y);
    let mist = mix(silver, vec3<f32>(0.64, 0.44, 0.32), forward * 0.64);
    let amount = min(1.0 - exp(-optical_length * 0.085 * strength), 0.58);
    return mix(colour, mist, amount);
}

// Maps a world-space direction to the 64x32 Overworld sky LUT inside the 64x33 zp_climate target.
// Column 0 and column 63 both sit at azimuth +-PI so bilinear ClampToEdge filtering is seam-free;
// row 31 center is 31.5/33.0, staying separated from texel (0, 32) biome climate weights.
fn zn_sky_lut_uv(dir: vec3<f32>) -> vec2<f32> {
    let d = normalize(dir + vec3<f32>(0.0, 1e-6, 0.0));
    let phi = select(atan2(d.z, d.x), 0.0, abs(d.x) + abs(d.z) < 1e-5);
    let u_norm = phi * (1.0 / 6.283185307) + 0.5;
    let v_norm = sqrt(clamp(d.y, 0.0, 1.0));
    return vec2<f32>(
        (0.5 + clamp(u_norm, 0.0, 1.0) * 63.0) / 64.0,
        (0.5 + clamp(v_norm, 0.0, 1.0) * 31.0) / 33.0,
    );
}

// ---- integer hashing --------------------------------------------------------------------------
// PCG2D: M. Jarzynski, M. Olano, "Hash Functions for GPU Rendering", JCGT 9(3), 2020
// (a PCG output permutation applied to a 2D integer vector, with cross-coupling of the lanes).
fn zn_i_pcg2d(p: vec2<u32>) -> vec2<u32> {
    var v = p * 1664525u + vec2<u32>(1013904223u);
    v.x = v.x + v.y * 1664525u;
    v.y = v.y + v.x * 1664525u;
    v = v ^ (v >> vec2<u32>(16u));
    v.x = v.x + v.y * 1664525u;
    v.y = v.y + v.x * 1664525u;
    v = v ^ (v >> vec2<u32>(16u));
    return v;
}

// The top 24 bits of a hash as a float in [0, 1): every value is exactly representable.
fn zn_i_unit(x: u32) -> f32 {
    return f32(x >> 8u) * (1.0 / 16777216.0);
}

// ---- public: colour -------------------------------------------------------------------------

// Relative luminance with the BT.709 / sRGB weights (ITU-R BT.709-6). `frame.luminance` holds the
// weights of the pack's primaries; this file cannot read `frame`, so it fixes BT.709, the pack default.
fn zn_luma(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn zn_saturate3(c: vec3<f32>) -> vec3<f32> {
    return clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
}

// ---- public: hashes and noise -----------------------------------------------------------------

// White noise in [0, 1) from the bit pattern of `p`: any float input, no structure at integer inputs.
fn zn_hash21(p: vec2<f32>) -> f32 {
    // `+ 0.0` turns -0.0 into +0.0, so both zeros hash alike.
    let h = zn_i_pcg2d(bitcast<vec2<u32>>(p + vec2<f32>(0.0)));
    return zn_i_unit(h.x);
}

// Two independent white-noise values in [0, 1).
fn zn_hash22(p: vec2<f32>) -> vec2<f32> {
    let h = zn_i_pcg2d(bitcast<vec2<u32>>(p + vec2<f32>(0.0)));
    return vec2<f32>(zn_i_unit(h.x), zn_i_unit(h.y));
}

fn zn_i_lattice(cell: vec2<i32>) -> f32 {
    let h = zn_i_pcg2d(bitcast<vec2<u32>>(cell));
    return zn_i_unit(h.x);
}

// Value noise in [0, 1]: hashed lattice values blended with the quintic fade 6t^5 - 15t^4 + 10t^3
// (K. Perlin, "Improving Noise", SIGGRAPH 2002), which has zero first and second derivative at the cells' edges.
fn zn_noise2(p: vec2<f32>) -> f32 {
    let base = floor(p);
    let f = p - base;
    let cell = vec2<i32>(base);
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let a = zn_i_lattice(cell);
    let b = zn_i_lattice(cell + vec2<i32>(1, 0));
    let c = zn_i_lattice(cell + vec2<i32>(0, 1));
    let d = zn_i_lattice(cell + vec2<i32>(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fractal Brownian motion of value noise (gain 0.5, lacunarity 2), normalised to [0, 1].
// `octaves` is clamped to 1..12. Each octave is rotated by 0.5 rad and offset so the lattice axes
// do not line up between octaves (rotation of the domain between octaves: standard fbm practice).
fn zn_fbm2(p: vec2<f32>, octaves: i32) -> f32 {
    let n = clamp(octaves, 1, 12);
    var q = p;
    var amp = 0.5;
    var sum = 0.0;
    var norm = 0.0;
    for (var i = 0; i < n; i = i + 1) {
        sum = sum + amp * zn_noise2(q);
        norm = norm + amp;
        q = vec2<f32>(0.87758 * q.x - 0.47943 * q.y, 0.47943 * q.x + 0.87758 * q.y) * 2.0 + vec2<f32>(17.3, 9.1);
        amp = amp * 0.5;
    }
    return sum / norm;
}

// Interleaved gradient noise in [0, 1): J. Jimenez, "Next Generation Post Processing in Call of Duty:
// Advanced Warfare", SIGGRAPH 2014. `pixel` is the pixel position, `frame` the frame counter; the pattern
// repeats every 64 frames, where it is shifted along the diagonal by 5.588238 pixels per frame.
fn zn_ign(pixel: vec2<f32>, frame: u32) -> f32 {
    let p = pixel + vec2<f32>(5.588238 * f32(frame % 64u));
    return fract(52.9829189 * fract(dot(p, vec2<f32>(0.06711056, 0.00583715))));
}

// ---- public: shading helpers ----------------------------------------------------------------------

fn zn_pow5(x: f32) -> f32 {
    let x2 = x * x;
    return x2 * x2 * x;
}

// Schlick's approximation of the Fresnel reflectance (C. Schlick, "An Inexpensive BRDF Model for
// Physically-based Rendering", Eurographics 1994): F0 + (1 - F0) (1 - cos)^5.
fn zn_fresnel_schlick(cos_t: f32, f0: vec3<f32>) -> vec3<f32> {
    let k = zn_pow5(1.0 - clamp(cos_t, 0.0, 1.0));
    return f0 + (vec3<f32>(1.0) - f0) * k;
}

// Linear map of x from [a, b] to [c, d], not clamped. Returns c when a == b.
fn zn_remap(x: f32, a: f32, b: f32, c: f32, d: f32) -> f32 {
    if (a == b) {
        return c;
    }
    return c + (x - a) * (d - c) / (b - a);
}

// Horizon API 0.2: light_direction changes from sun to moon at the horizon.
// Direct light must follow that body, rather than mixing sunset red into the
// moon's BRDF/shaft direction. Twilight stays in the sky and ambient lighting.
// Own choice: fade each body's direct light over 0..0.14 elevation, reaching
// exactly zero at/below the horizon so both handoffs are continuous.
fn zn_celestial_weights(sun_height: f32, moon_height: f32) -> vec2<f32> {
    return smoothstep(vec2<f32>(0.0), vec2<f32>(0.14), vec2<f32>(sun_height, moon_height));
}

// Synced with sky/sky.wgsl cloud slab (SKY_CLOUD_BASE=150, SKY_CLOUD_TOP=240, 3600s closed wind orbit).
// Returns direct-light transmission in [0.46, 1.0]; 1.0 when clouds are off, light is near/below horizon,
// or receiver is above the cloud deck.
fn zn_cloud_shadow(world_pos: vec3<f32>, light_dir: vec3<f32>, time: f32, coverage: f32) -> f32 {
    let cov = clamp(coverage, 0.0, 1.0);
    if (cov <= 0.001 || light_dir.y <= 0.03) {
        return 1.0;
    }
    let below_fade = 1.0 - smoothstep(150.0, 220.0, world_pos.y);
    if (below_fade <= 0.001) {
        return 1.0;
    }
    let elev_fade = smoothstep(0.04, 0.22, light_dir.y);
    let t = clamp((185.0 - world_pos.y) / max(light_dir.y, 0.08), 0.0, 2500.0);
    let p_xz = world_pos.xz + light_dir.xz * t;
    let angle = time * (6.2831853 / 3600.0);
    let wind = vec2<f32>(sin(angle), 1.0 - cos(angle)) * 3.5;
    // Matches sky_cloud_density mid-plane height = (185 - 150) / (240 - 150) = 0.38889
    let uv = p_xz * 0.003 + wind + vec2<f32>(0.38889 * 0.61, -0.38889 * 0.37);
    let shape = zn_fbm2(uv, 3);
    let threshold = mix(1.0, 0.13, cov);
    let density = smoothstep(0.0, 0.42, shape - threshold - 0.06);
    let cloud_alpha = 1.0 - exp(-density * 2.8);
    return mix(1.0, 0.46, cloud_alpha * elev_fade * below_fade);
}

fn zn_i_caustic_layer(p: vec2<f32>, t: f32) -> f32 {
    let p1 = p * 1.15 + vec2<f32>(t * 0.26, -t * 0.19);
    let p2 = p * 1.85 + vec2<f32>(-t * 0.22, t * 0.29);
    // Domain warp for organic optical wave-focusing webs
    let w1 = zn_noise2(p1 * 0.65 + vec2<f32>(t * 0.12, t * 0.09)) * 0.55;
    let n1 = abs(zn_noise2(p1 + vec2<f32>(w1, -w1)) * 2.0 - 1.0);
    let n2 = abs(zn_noise2(p2 - vec2<f32>(w1 * 0.7, w1 * 0.5)) * 2.0 - 1.0);
    let web = 1.0 - min(n1, n2);
    let cross_web = (1.0 - n1) * (1.0 - n2);
    return pow(clamp(web, 0.0, 1.0), 3.6) * 0.78 + pow(clamp(cross_web, 0.0, 1.0), 2.2) * 0.45;
}

// Refracted sunlight-projected optical water caustics with subtle R/G/B refractive dispersion.
fn zn_water_caustic_rgb(world_pos: vec3<f32>, light_dir: vec3<f32>, time: f32) -> vec3<f32> {
    let inv_ly = 1.0 / max(light_dir.y, 0.35);
    let proj = world_pos.xz - light_dir.xz * (world_pos.y * inv_ly);
    let l_xz_len = length(light_dir.xz);
    let disp_dir = select(vec2<f32>(0.7071, 0.7071), light_dir.xz / max(l_xz_len, 1e-4), l_xz_len > 1e-3);
    let disp = disp_dir * 0.038;
    let r = zn_i_caustic_layer(proj + disp, time);
    let g = zn_i_caustic_layer(proj, time);
    let b = zn_i_caustic_layer(proj - disp, time);
    return vec3<f32>(0.70) + vec3<f32>(r, g, b) * 0.92;
}

// Pure cube-face procedural starfield layer used by Overworld (at night) and The End.
fn zn_star_layer(d: vec3<f32>, res_y: f32, grid_scale: f32, density_thresh: f32, cool_bias: f32) -> vec3<f32> {
    let a = abs(d);
    var uv = d.xy / max(a.z, 0.0001);
    var face = select(4.0, 5.0, d.z > 0.0);
    if (a.x >= a.y && a.x >= a.z) {
        uv = d.yz / max(a.x, 0.0001);
        face = select(0.0, 1.0, d.x > 0.0);
    } else if (a.y >= a.z) {
        uv = d.xz / max(a.y, 0.0001);
        face = select(2.0, 3.0, d.y > 0.0);
    }
    let grid = (uv * 0.5 + 0.5) * grid_scale;
    let cell = floor(grid);
    let seed = cell + vec2<f32>(face * 317.0, face * 173.0);
    let random = zn_hash22(seed);
    let offset = fract(grid) - (0.25 + random * 0.5);
    let width = clamp(grid_scale / max(res_y, 1.0), 0.015, 1.0);
    let radius = 0.055 + 0.07 * random.x;
    let core = 1.0 - smoothstep(max(0.0, radius - width), radius + width, length(offset));
    let coverage = min(1.0, radius * radius / max(width * width, 0.0001));
    let exists = select(0.0, 1.0, zn_hash21(seed + vec2<f32>(41.0, 91.0)) > density_thresh);
    let color = mix(vec3<f32>(0.55, 0.72, 1.0), vec3<f32>(1.0, 0.72, 0.45), random.y * (1.0 - cool_bias));
    return color * core * coverage * exists * (0.7 + random.x * 1.8);
}

// Custom cosmic nebula & dual-scale starfield sky for The End (seamless 3D projection).
fn zn_sky_end(d: vec3<f32>, fog_color: vec3<f32>, res_y: f32) -> vec3<f32> {
    let sky_hor_col = mix(vec3<f32>(0.020, 0.010, 0.038), max(fog_color, vec3<f32>(0.008, 0.004, 0.018)), 0.30);
    let zenith_col = vec3<f32>(0.004, 0.002, 0.011);
    var color = mix(sky_hor_col, zenith_col, smoothstep(0.0, 0.72, abs(d.y)));

    let p3 = d * 2.6;
    let neb_u = vec2<f32>(p3.x + p3.z * 0.61, p3.y * 1.35 - p3.z * 0.47);
    let n_warp = zn_fbm2(neb_u * 0.75 + vec2<f32>(3.1, 7.4), 2);
    let n_shape = zn_fbm2(neb_u + vec2<f32>(n_warp * 1.15, -n_warp * 0.85), 3);
    let n_detail = zn_noise2(neb_u * 3.4 - vec2<f32>(n_warp, 0.0));
    let gal_tilt = d.y * 0.72 - d.x * 0.52 + d.z * 0.28;
    let band = exp(-gal_tilt * gal_tilt * 5.2);

    let violet = vec3<f32>(0.095, 0.032, 0.165);
    let cyan_dust = vec3<f32>(0.026, 0.078, 0.145);
    let magenta_core = vec3<f32>(0.14, 0.042, 0.13);
    let neb_base = mix(violet, cyan_dust, smoothstep(0.32, 0.76, n_detail));
    let neb_col = mix(neb_base, magenta_core, smoothstep(0.55, 0.90, band) * smoothstep(0.45, 0.82, n_shape));
    let dust_carve = smoothstep(0.28, 0.78, n_shape) * (0.45 + 0.55 * n_detail);
    color = color + neb_col * (dust_carve * (0.30 + 0.70 * band));

    let stars_hi = zn_star_layer(d, res_y, 115.0, 0.986, 0.45) * 1.15;
    let stars_lo = zn_star_layer(d, res_y, 210.0, 0.968, 0.65) * 0.55;
    color = color + (stars_hi + stars_lo) * (0.55 + 0.45 * band) * (1.0 - smoothstep(0.05, -0.45, d.y) * 0.50);
    return max(color, vec3<f32>(0.0));
}

// Custom volcanic ash & magma-underglow sky for The Nether, anchored to biome fog_color.
fn zn_sky_nether(d: vec3<f32>, engine_col: vec3<f32>, fog_color: vec3<f32>, time: f32) -> vec3<f32> {
    let biome_fog = max(max(engine_col, fog_color), vec3<f32>(0.030, 0.009, 0.004));
    let p3 = d * 2.4;
    let ash_u = vec2<f32>(p3.x - p3.z * 0.52, p3.z + p3.x * 0.52) * 1.2 + vec2<f32>(time * 0.02, -time * 0.015);
    let ash = zn_fbm2(ash_u + vec2<f32>(0.0, d.y * 1.8), 3);
    let up_fade = smoothstep(-0.15, 0.75, d.y);
    let upper_ash = biome_fog * mix(0.68, 1.25, ash) * mix(1.0, 0.55, up_fade);
    let lava_underglow = smoothstep(0.26, -0.45, d.y) * vec3<f32>(0.24, 0.058, 0.015) * mix(0.65, 1.2, zn_noise2(ash_u * 2.2));
    let ember_band = exp(-pow((d.y - 0.02) * 5.0, 2.0)) * smoothstep(0.58, 0.88, zn_noise2(ash_u * 3.8 + vec2<f32>(time * 0.05, 0.0))) * vec3<f32>(0.16, 0.045, 0.008);
    return max(upper_ash + lava_underglow + ember_band, vec3<f32>(0.0));
}
