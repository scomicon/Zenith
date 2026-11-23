// src: A. Schneider / N. Vos, The Real-time Volumetric Cloudscapes of Horizon: Zero Dawn, SIGGRAPH 2015 (shape/detail split, Beer-powder, light march); L. Henyey & J. Greenstein, 1941 (phase); Horizon Shader API 0.2 (`[[before_world]]`, `[sky] reads`).
// Zenith cumulus layer, shared by the sky stage and the `[[before_world]]` pass that bakes it at half resolution.
// No code or assets from the presentation are included.

override clouds: bool = true;
override quality_mode: u32 = 1u; // 0 = Performance, 1 = Balanced, 2 = Quality (manifest order)
override cloud_coverage: f32 = 0.48;

const SKY_PI: f32 = 3.14159265359;

fn sky_hg(mu: f32, g: f32) -> f32 {
    let g2 = g * g;
    return (1.0 - g2) / (4.0 * SKY_PI * pow(max(1.0 + g2 - 2.0 * g * mu, 0.001), 1.5));
}

// Cloud slab, in blocks. The march uses fixed height planes inside it, so where a
// sample lands depends only on the ray and the camera height, never on a
// per-ray segment length. That removes the ray-dependent sample jitter.
const SKY_CLOUD_BASE: f32 = 150.0;
const SKY_CLOUD_TOP: f32 = 290.0;
const SKY_CLOUD_STEPS: vec4<u32> = vec4<u32>(24u, 36u, 48u, 96u); // by quality_mode
const SKY_CLOUD_RANGE: f32 = 12000.0;
// Footprint, in blocks, of the light-march taps: the macro map past its second octave is filtered out.
const SKY_CLOUD_LIGHT_FOOTPRINT: f32 = 90.0;

// Band-limited fBm of value noise (same octave layout as zn_fbm2, 4 octaves).
// `footprint` is the pixel footprint in noise-lattice units of the first octave.
// An octave whose cell is smaller than the footprint is blended continuously to
// the noise mean (0.5) instead of aliasing, so distant clouds stay stable.
fn sky_cloud_fbm(p: vec2<f32>, footprint: f32) -> f32 {
    var q = p;
    var fp = footprint;
    var amp = 0.5;
    var sum = 0.0;
    var norm = 0.0;
    for (var i = 0; i < 4; i = i + 1) {
        if fp >= 1.0 {
            // Every remaining octave is fully filtered to its mean.
            return (sum + 0.5 * (0.9375 - norm)) / 0.9375;
        }
        let w = 1.0 - smoothstep(0.35, 1.0, fp);
        sum = sum + amp * mix(0.5, zn_noise2(q), w);
        norm = norm + amp;
        q = vec2<f32>(0.87758 * q.x - 0.47943 * q.y, 0.47943 * q.x + 0.87758 * q.y) * 2.0 + vec2<f32>(17.3, 9.1);
        fp = fp * 2.0;
        amp = amp * 0.5;
    }
    return sum / norm;
}

// 3D value noise: two lattice layers of zn_noise2, blended along y.
fn sky_noise3(p: vec3<f32>) -> f32 {
    let iy = floor(p.y);
    let fy = p.y - iy;
    let u = fy * fy * (3.0 - 2.0 * fy);
    let o0 = vec2<f32>(fract(iy * 0.7548776662) * 97.0, fract(iy * 0.5698402909) * 89.0);
    let o1 = vec2<f32>(fract((iy + 1.0) * 0.7548776662) * 97.0, fract((iy + 1.0) * 0.5698402909) * 89.0);
    return mix(zn_noise2(p.xz + o0), zn_noise2(p.xz + o1), u);
}

// Cumulus field (Schneider/Vos 2015 shape / detail split): a 2D macro map decides where clouds stand and how tall
// they grow (thick cores tower, thin edges stay low); 3D billow noise erodes it into rounded puffs. The macro map
// is the one `zn_cloud_shadow` samples, so terrain shadows follow the clouds. `detail` is off for light-march taps.
fn sky_cloud_density(p: vec3<f32>, coverage: f32, footprint_blocks: f32, wind: vec2<f32>, detail: bool) -> f32 {
    let height = zn_remap(p.y, SKY_CLOUD_BASE, SKY_CLOUD_TOP, 0.0, 1.0);
    if height <= 0.0 || height >= 1.0 { return 0.0; }
    let uv = p.xz * 0.003 + wind + vec2<f32>(height * 0.61, -height * 0.37);
    let fp = footprint_blocks * 0.003;
    let macro_shape = sky_cloud_fbm(uv, fp);
    let threshold = mix(1.0, 0.13, coverage);
    let cover = smoothstep(0.0, 0.45, macro_shape - threshold);
    if cover <= 0.0 { return 0.0; }
    let top = mix(0.30, 1.0, cover);
    let envelope = smoothstep(0.0, 0.10, height) * (1.0 - smoothstep(top * 0.55, top, height));
    var d = cover * envelope;
    var n = 0.5;
    let fp3 = footprint_blocks * 0.012;
    if detail && fp3 < 1.0 {
        let q = vec3<f32>(p.x * 0.012 + wind.x * 4.0, p.y * 0.016, p.z * 0.012 + wind.y * 4.0);
        let w = 1.0 - smoothstep(0.35, 1.0, fp3);
        let n1 = sky_noise3(q);
        let n2 = sky_noise3(q * 2.3 + vec3<f32>(7.1, 3.3, 1.7));
        n = mix(0.5, n1 * 0.65 + n2 * 0.35, w);
    }
    d = d - (1.0 - n) * 0.45 * (1.0 - 0.5 * d);
    return smoothstep(0.0, 0.38, d);
}

// The cloud layer along `d` without the sky behind it: rgb is the light the clouds add, alpha what is left of the
// background (the transmission plus the share the distance haze blends toward it). The caller takes
// `rgb + alpha * background` and the horizon fade.
fn sky_cloud_march(d: vec3<f32>, sun: vec3<f32>, daylight: f32) -> vec4<f32> {
    // Below this the ray is nearly parallel to the layer; the blend below is 0 there.
    if (!clouds || abs(d.y) < 0.02) { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
    let coverage = clamp(cloud_coverage + frame.rain * 0.35, 0.0, 1.0);
    // Coverage zero truly removes clouds, including their march cost.
    if (coverage <= 0.0) { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
    let origin = frame.camera_position;
    // A ray that leaves the layer behind (down from below it, up from above it) never meets a cloud.
    if (d.y < 0.0 && origin.y <= SKY_CLOUD_BASE) || (d.y > 0.0 && origin.y >= SKY_CLOUD_TOP) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let inv_dy = 1.0 / d.y;
    // Approximate angular size of one pixel (about 1.5 / height radians).
    let pixel = 1.5 / max(frame.resolution.y, 1.0);
    let footprint_scale = pixel / max(abs(d.y), 0.02);
    var transmission = 1.0;
    var color = vec3<f32>(0.0);
    var haze_share = 0.0;
    let mu = dot(d, sun);
    let cloud_phase = clamp(mix(sky_hg(mu, 0.68), sky_hg(mu, -0.22), 0.30) * 4.0 * SKY_PI, 0.55, 2.8);
    let direct = mix(vec3<f32>(1.0, 0.28, 0.08), vec3<f32>(1.0, 0.96, 0.88), smoothstep(0.0, 0.3, sun.y));
    let cloud_sun = smoothstep(-0.04, 0.14, sun.y);
    let ambient = mix(vec3<f32>(0.008, 0.012, 0.025), vec3<f32>(0.22, 0.29, 0.40), daylight);
    // A closed wind orbit avoids a discontinuity when frame.time wraps at 3600s.
    let angle = frame.time * (2.0 * SKY_PI / 3600.0);
    let wind = vec2<f32>(sin(angle), 1.0 - cos(angle)) * 3.5;
    // March through the cloud volume in horizontal slices of constant height (Schneider/Vos 2015). The sample
    // positions depend only on the ray's elevation, so they move continuously when the view bobs or turns: no
    // stepping along the ray, no per-pixel jitter, nothing that can pop or swim between frames. Each slice is
    // sampled once at the middle of the ray's path through it, front to back.
    // Empty-space skipping: the macro map is smooth, so if no cloud stands at six heights along the ray the full
    // slice march finds none either, and clear sky costs six lookups instead of dozens.
    var occupied = false;
    let cover_threshold = mix(1.0, 0.13, coverage) - 0.10;
    for (var j = 0u; j < 6u; j++) {
        let level = (f32(j) + 0.5) / 6.0;
        let t = clamp((SKY_CLOUD_BASE + level * (SKY_CLOUD_TOP - SKY_CLOUD_BASE) - origin.y) * inv_dy, 0.0, SKY_CLOUD_RANGE);
        let q = origin + d * t;
        let uv = q.xz * 0.003 + wind + vec2<f32>(level * 0.61, -level * 0.37);
        if sky_cloud_fbm(uv, t * footprint_scale * 0.003) > cover_threshold {
            occupied = true;
            break;
        }
    }
    if !occupied { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
    // A steep ray crosses the layer in a short path, so it needs fewer slices than a grazing one.
    var steps = SKY_CLOUD_STEPS[min(quality_mode, 3u)];
    let slope = abs(d.y);
    if slope > 0.55 {
        steps = max(steps / 3u, 8u);
    } else if slope > 0.30 {
        steps = max(steps / 2u, 12u);
    }
    let slab_h = (SKY_CLOUD_TOP - SKY_CLOUD_BASE) / f32(steps);
    for (var k = 0u; k < steps; k++) {
        if transmission < 0.02 { break; }
        // Ascending heights when looking up, descending when looking down.
        let i = select(steps - 1u - k, k, d.y > 0.0);
        let h0 = SKY_CLOUD_BASE + f32(i) * slab_h;
        let ta = (h0 - origin.y) * inv_dy;
        let tb = (h0 + slab_h - origin.y) * inv_dy;
        // Part of the slice in front of the camera, capped at the cloud range. Clamping, not skipping, keeps this
        // continuous while the camera moves through the layer.
        let t0 = min(max(min(ta, tb), 0.0), SKY_CLOUD_RANGE);
        let t1 = min(max(max(ta, tb), 0.0), SKY_CLOUD_RANGE);
        let length_in_slab = t1 - t0;
        if length_in_slab <= 0.0 { continue; }
        let distance = 0.5 * (t0 + t1);
        let p = origin + d * distance;
        let footprint = distance * footprint_scale;
        let density = sky_cloud_density(p, coverage, footprint, wind, true);
        if density <= 0.002 { continue; }
        let height = zn_remap(p.y, SKY_CLOUD_BASE, SKY_CLOUD_TOP, 0.0, 1.0);
        // Beer-powder multi-scattering & silver-lining HG phase; Schneider/Vos 2015.
        let alpha = 1.0 - exp(-density * length_in_slab * 0.035);
        if alpha < 0.003 { continue; }
        let h_amb = ambient * mix(0.40, 1.25, height);
        var illumination = h_amb;
        if cloud_sun > 0.0 && density > 0.04 {
            // Two light-march taps at growing distances (cone-sampled light march): the whole depth self-shadows.
            // The tap offsets are fixed per slice, so they do not depend on the view.
            let tap = fract(f32(i) * 0.618034);
            // Self-shadowing is broad: the taps read only the two coarse octaves of the macro map.
            // Ultra keeps every octave in the light march too.
            let light_footprint = select(max(footprint, SKY_CLOUD_LIGHT_FOOTPRINT), footprint, quality_mode >= 3u);
            let sun_tau = (sky_cloud_density(p + sun * (30.0 + 12.0 * tap), coverage, light_footprint, wind, false) * 1.35
                + sky_cloud_density(p + sun * (100.0 + 30.0 * tap), coverage, light_footprint, wind, false) * 1.5);
            let multi = max(exp(-sun_tau), exp(-sun_tau * 0.28) * 0.48);
            let powder = 1.0 - exp(-density * 3.8);
            let scatter = multi * mix(1.0, 0.55 + 0.75 * powder, smoothstep(-0.15, 0.55, mu));
            illumination += direct * cloud_sun * scatter * (0.65 + 0.55 * cloud_phase);
        }
        let light = illumination * (1.0 - 0.65 * frame.thunder);
        // Distance haze: original calibrated aerial-perspective approximation.
        let haze = 1.0 - exp(-distance * 0.00008);
        color += transmission * alpha * (1.0 - haze) * light;
        haze_share += transmission * alpha * haze;
        transmission *= 1.0 - alpha;
    }
    return vec4<f32>(color, haze_share + transmission);
}

// The baked map is the screen at half resolution, a little wider than the view so the view bob and edge pixels
// stay inside it. It is indexed by direction through the frame's own matrices: `sky_cloud_map_uv` and
// `sky_cloud_map_direction` are exact inverses, so a sky pixel finds the texel baked for its own ray whatever the
// bob or field of view does.
const SKY_CLOUD_MAP_MARGIN: f32 = 1.08;

fn sky_cloud_map_uv(d: vec3<f32>) -> vec2<f32> {
    let clip = frame.projection * (frame.view * vec4<f32>(d, 0.0));
    let ndc = clip.xy / max(clip.w, 1e-6) / SKY_CLOUD_MAP_MARGIN;
    return vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
}

fn sky_cloud_map_direction(uv: vec2<f32>) -> vec3<f32> {
    let ndc = vec2<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0) * SKY_CLOUD_MAP_MARGIN;
    let m = frame.projection;
    let r0 = vec3<f32>(m[0].x, m[1].x, m[2].x);
    let r1 = vec3<f32>(m[0].y, m[1].y, m[2].y);
    let r3 = vec3<f32>(m[0].w, m[1].w, m[2].w);
    // The view-space direction on both planes `clip.x = ndc.x * clip.w` and `clip.y = ndc.y * clip.w`.
    var v = cross(r0 - ndc.x * r3, r1 - ndc.y * r3);
    if dot(r3, v) < 0.0 { v = -v; }
    return normalize((frame.view_inverse * vec4<f32>(v, 0.0)).xyz);
}

// Whether this frame's map holds the clouds. Caves (no sky light at the eye) skip the bake; a sky pixel seen from
// there marches its own ray instead.
fn sky_cloud_baked() -> bool {
    return clouds && frame.dimension == 0 && frame.eye_in != 1u && frame.eye_light_smooth.y > 0.02
        && clamp(cloud_coverage + frame.rain * 0.35, 0.0, 1.0) > 0.0;
}

// The map packs a texel into 32 bits (a render-size rgba16float map would not fit the pack's post-target budget):
// alpha 8 bits, log2 luminance 12 bits over [-16, 8] (0.6% steps), and the r and g shares of r + g + b in
// 6 bits each. Clouds are pale, so the chroma steps do not show; the luminance steps sit below one 8-bit step.
fn sky_cloud_pack(c: vec4<f32>) -> u32 {
    let rgb = max(c.rgb, vec3<f32>(0.0));
    let sum = rgb.r + rgb.g + rgb.b;
    let share = select(vec2<f32>(1.0 / 3.0), rgb.rg / max(sum, 1e-8), sum > 1e-8);
    let lum = dot(rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
    let log_l = select(0.0, clamp((log2(max(lum, 1e-8)) + 16.0) / 24.0, 0.0, 1.0), lum > 1.6e-5);
    let a = u32(round(clamp(c.a, 0.0, 1.0) * 255.0));
    let l = u32(round(log_l * 4095.0));
    let r = u32(round(clamp(share.x, 0.0, 1.0) * 63.0));
    let g = u32(round(clamp(share.y, 0.0, 1.0) * 63.0));
    return a | (l << 8u) | (r << 20u) | (g << 26u);
}

fn sky_cloud_unpack(v: u32) -> vec4<f32> {
    let a = f32(v & 0xffu) / 255.0;
    let l_code = (v >> 8u) & 0xfffu;
    let r = f32((v >> 20u) & 0x3fu) / 63.0;
    let g = f32((v >> 26u) & 0x3fu) / 63.0;
    let share = vec3<f32>(r, g, max(1.0 - r - g, 0.0));
    let lum = select(0.0, exp2(f32(l_code) / 4095.0 * 24.0 - 16.0), l_code > 0u);
    let per_sum = dot(share, vec3<f32>(0.2126, 0.7152, 0.0722));
    return vec4<f32>(share * (lum / max(per_sum, 1e-6)), a);
}
