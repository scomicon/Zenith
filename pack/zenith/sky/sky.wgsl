// src: S. Hillaire, A Scalable and Production Ready Sky and Atmosphere Rendering Technique, EGSR 2020; A. Schneider / N. Vos, The Real-time Volumetric Cloudscapes of Horizon: Zero Dawn, SIGGRAPH 2015 (multi-scattering powder approximation & high cirrus concept); L. Henyey & J. Greenstein, 1941 (dual-lobe cloud silver-lining phase); Procedural cosmic End nebula, Nether ash sky, Milky Way band & height-sliced aurora curtains.
// Zenith: clean-room physical sky, cloud, and starfield stage.
// API: horizon-rust/horizon@90e97a1fc2fa4aac23766e418f55cbce94e97618,
// docs/api/shaders-reference-0.2.md. Linear BT.709 throughout.
// Atmosphere reference: S. Hillaire, EGSR 2020, sections 2-3:
// https://sebh.github.io/publications/egsr2020.pdf
// Clouds reference (principles only; original density and lighting below):
// Schneider/Vos 2015, https://www.guerrilla-games.com/read/the-real-time-volumetric-cloudscapes-of-horizon-zero-dawn
// No LUTs, textures, code or assets from either presentation are included.

override sky_saturation: f32 = 1.0;
override cirrus_clouds: bool = true;
override aurora: bool = true;
override atmospheric_fog: f32 = 1.0;

const SKY_GROUND: f32 = 6360.0;
const SKY_TOP: f32 = 6460.0;
// Hillaire 2020: wavelength-dependent molecular scattering, aerosol extinction,
// in inverse kilometres. Aerosol strength is Zenith's calibrated parameter.
const SKY_R: vec3<f32> = vec3<f32>(0.005802, 0.013558, 0.033100);
const SKY_M: vec3<f32> = vec3<f32>(0.0036);

// Shared zn_* helpers are supplied by shared/common.wgsl.

// Positive far intersection of a unit ray and sphere: quadratic equation.
fn sky_exit(p: vec3<f32>, d: vec3<f32>, radius: f32) -> f32 {
    let b = dot(p, d);
    return max(0.0, -b + sqrt(max(0.0, b * b - dot(p, p) + radius * radius)));
}

fn sky_hits_ground(p: vec3<f32>, d: vec3<f32>) -> bool {
    let b = dot(p, d);
    return b < 0.0 && b * b - dot(p, p) + SKY_GROUND * SKY_GROUND > 0.0;
}

fn sky_density(p: vec3<f32>) -> vec2<f32> {
    // Hillaire: exponential vertical density profiles, scale heights 8 / 1.2 km.
    let height = max(length(p) - SKY_GROUND, 0.0);
    return exp(-height / vec2<f32>(8.0, 1.2));
}

fn sky_sun_transmittance(p: vec3<f32>, sun: vec3<f32>) -> vec3<f32> {
    if (sky_hits_ground(p, sun)) { return vec3<f32>(0.0); }
    let distance = sky_exit(p, sun, SKY_TOP);
    var depth = vec2<f32>(0.0);
    // Zenith quadratic sampling concentrates four samples in the dense lower air.
    for (var j = 0u; j < 4u; j++) {
        let a = f32(j) / 4.0;
        let b = f32(j + 1u) / 4.0;
        let segment = (b * b - a * a) * distance;
        depth += sky_density(p + sun * ((a * a + b * b) * 0.5 * distance)) * segment;
    }
    // Beer-Lambert extinction (Hillaire 2020); Mie single-scattering albedo 0.9.
    return exp(-(SKY_R * depth.x + SKY_M * depth.y));
}

struct SkyAtmosphere {
    radiance: vec3<f32>,
    transmittance: vec3<f32>,
}

fn sky_atmosphere(d: vec3<f32>, sun: vec3<f32>) -> SkyAtmosphere {
    let p = vec3<f32>(0.0, SKY_GROUND + clamp((frame.camera_position.y - 64.0) * 0.001, 0.03, 8.0), 0.0);
    var distance = sky_exit(p, d, SKY_TOP);
    if (sky_hits_ground(p, d)) {
        let b = dot(p, d);
        distance = max(0.0, -b - sqrt(max(0.0, b * b - dot(p, p) + SKY_GROUND * SKY_GROUND)));
    }
    let mu = clamp(dot(d, sun), -1.0, 1.0);
    // Normalized Rayleigh phase and Henyey-Greenstein aerosol phase;
    // standard single-scattering models discussed by Hillaire 2020.
    let rayleigh = 3.0 * (1.0 + mu * mu) / (16.0 * SKY_PI);
    let g = 0.76;
    let mie = (1.0 - g * g) / (4.0 * SKY_PI * pow(max(1.0 + g * g - 2.0 * g * mu, 0.001), 1.5));
    var transmittance = vec3<f32>(1.0);
    var radiance = vec3<f32>(0.0);
    for (var i = 0u; i < 8u; i++) {
        let a = f32(i) / 8.0;
        let b = f32(i + 1u) / 8.0;
        let segment = (b * b - a * a) * distance;
        let sample_p = p + d * ((a * a + b * b) * 0.5 * distance);
        let density = sky_density(sample_p);
        let extinction = SKY_R * density.x + SKY_M * density.y;
        let step_t = exp(-extinction * segment);
        let source = SKY_R * density.x * rayleigh + SKY_M * (0.9 * density.y * mie);
        // Analytic constant-source segment integration of the radiative transfer
        // equation, Hillaire 2020. 14 is Zenith's scene-light calibration.
        radiance += transmittance * sky_sun_transmittance(sample_p, sun) * source
                  * ((vec3<f32>(1.0) - step_t) / max(extinction, vec3<f32>(0.000001))) * 14.0;
        transmittance *= step_t;
    }
    return SkyAtmosphere(radiance, transmittance);
}

fn sky_stars(direction: vec3<f32>) -> vec3<f32> {
    // Original cube-face star catalogue. Rotate with the daily sky, without
    // frame.time's hourly wrap. No star texture or catalogue is imported.
    let angle = frame.day_time * 2.0 * SKY_PI;
    let d = vec3<f32>(direction.x, direction.y * cos(angle) - direction.z * sin(angle),
                     direction.y * sin(angle) + direction.z * cos(angle));
    return zn_star_layer(d, frame.resolution.y, 160.0, 0.978, 0.0);
}

// Tilted Galactic Milky Way band with central dust lane rotated with daily sky.
fn sky_milky_way(direction: vec3<f32>) -> vec3<f32> {
    let angle = frame.day_time * 2.0 * SKY_PI;
    let dr = vec3<f32>(direction.x, direction.y * cos(angle) - direction.z * sin(angle),
                      direction.y * sin(angle) + direction.z * cos(angle));
    let gal_n = normalize(vec3<f32>(0.42, 0.78, -0.46));
    let lat = dot(dr, gal_n);
    let band = exp(-lat * lat * 15.0);
    let p_u = vec2<f32>(dot(dr, vec3<f32>(0.85, -0.32, 0.42)), dot(dr, vec3(-0.32, 0.54, 0.78))) * 3.4;
    let cloud = zn_fbm2(p_u, 4);
    let dust = zn_fbm2(p_u * 2.1 + vec2<f32>(lat * 2.4, 5.1), 3);
    let rift = 1.0 - smoothstep(0.45, 0.68, dust) * 0.68 * exp(-lat * lat * 45.0);
    let neb_col = mix(vec3<f32>(0.012, 0.018, 0.036), vec3<f32>(0.032, 0.038, 0.056), smoothstep(0.35, 0.75, cloud));
    return neb_col * band * smoothstep(0.28, 0.78, cloud) * rift * 0.72;
}

// Height-sliced undulating aurora curtains above northern night horizon.
fn sky_aurora(d: vec3<f32>) -> vec3<f32> {
    if (d.y <= 0.04) {
        return vec3<f32>(0.0);
    }
    let sky_fade = smoothstep(0.05, 0.24, d.y) * (1.0 - smoothstep(0.58, 0.92, d.y));
    let north_bias = smoothstep(-0.45, 0.55, -d.z);
    if (sky_fade * north_bias <= 0.001) {
        return vec3<f32>(0.0);
    }
    let t = frame.time * 0.022;
    var accum = vec3<f32>(0.0);
    for (var s: i32 = 0; s < 3; s = s + 1) {
        let sf = f32(s);
        let h = 420.0 + sf * 95.0;
        let p = d.xz * (h / max(d.y, 0.08)) * 0.0014;
        let warp = zn_fbm2(p * 1.15 + vec2<f32>(t, -t * 0.6), 3);
        let ribbon = sin(p.x * 2.6 + warp * 4.4 + p.y * 0.85 + sf * 0.28);
        let intensity = pow(clamp(1.0 - abs(ribbon) * 2.2, 0.0, 1.0), 2.8);
        let slice_col = mix(vec3<f32>(0.06, 0.58, 0.34), vec3<f32>(0.34, 0.12, 0.55), sf * 0.45);
        accum = accum + slice_col * (intensity * mix(0.45, 0.28, sf * 0.4));
    }
    return accum * (sky_fade * north_bias * 0.14);
}

// High-altitude wispy cirrus streaks above the main cumulus layer.
fn sky_cirrus_layer(d: vec3<f32>, background: vec3<f32>, sun: vec3<f32>, daylight: f32) -> vec3<f32> {
    if (!cirrus_clouds || d.y <= 0.03) {
        return background;
    }
    let t = clamp((620.0 - frame.camera_position.y) / max(d.y, 0.03), 0.0, 16000.0);
    let p_xz = frame.camera_position.xz + d.xz * t;
    let angle = frame.time * (2.0 * SKY_PI / 3600.0);
    let wind = vec2<f32>(sin(angle), 1.0 - cos(angle)) * 2.2;
    let uv = p_xz * vec2<f32>(0.00055, 0.00145) + wind;
    let warp = zn_fbm2(uv * 1.4, 2);
    let wisp = zn_fbm2(uv * vec2<f32>(2.4, 0.9) + vec2<f32>(warp * 0.85, -warp * 0.55), 3);
    let density = smoothstep(0.55, 0.86, wisp) * smoothstep(0.03, 0.22, d.y) * (1.0 - smoothstep(5000.0, 15500.0, t)) * (1.0 - frame.rain * 0.65);
    if (density <= 0.001) {
        return background;
    }
    let mu = dot(d, sun);
    let fwd = clamp(sky_hg(mu, 0.62) * 4.0 * SKY_PI, 0.5, 2.2);
    let direct = mix(vec3<f32>(1.0, 0.34, 0.14), vec3<f32>(1.0, 0.97, 0.92), smoothstep(-0.02, 0.28, sun.y));
    let night_fill = vec3<f32>(0.012, 0.018, 0.034);
    let cloud_sun = smoothstep(-0.04, 0.14, sun.y);
    let cirrus_col = night_fill + direct * cloud_sun * (0.42 + 0.36 * fwd) * (1.0 - 0.55 * frame.thunder);
    return mix(background, cirrus_col, clamp(density * 0.36, 0.0, 0.36));
}

fn sky_cloud_lookup(d: vec3<f32>) -> vec4<f32> {
    let dims = vec2<i32>(textureDimensions(zp_clouds));
    let p = clamp(sky_cloud_map_uv(d), vec2<f32>(0.0), vec2<f32>(1.0)) * vec2<f32>(dims) - vec2<f32>(0.5);
    let base = vec2<i32>(floor(p));
    let f = p - floor(p);
    let top = max(dims - vec2<i32>(1), vec2<i32>(0));
    let c00 = textureLoad(zp_clouds, clamp(base, vec2<i32>(0), top), 0);
    let c10 = textureLoad(zp_clouds, clamp(base + vec2<i32>(1, 0), vec2<i32>(0), top), 0);
    let c01 = textureLoad(zp_clouds, clamp(base + vec2<i32>(0, 1), vec2<i32>(0), top), 0);
    let c11 = textureLoad(zp_clouds, clamp(base + vec2<i32>(1, 1), vec2<i32>(0), top), 0);
    return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

fn sky_cloud_layer(d: vec3<f32>, background: vec3<f32>, sun: vec3<f32>, daylight: f32) -> vec3<f32> {
    // Below this the ray is nearly parallel to the layer; the blend below is 0 there.
    if !clouds || abs(d.y) < 0.02 { return background; }
    var c: vec4<f32>;
    if sky_cloud_baked() {
        c = sky_cloud_lookup(d);
    } else {
        c = sky_cloud_march(d, sun, daylight);
    }
    // Wide fade toward the horizon: grazing rays are the least stable part of the
    // layer, so they blend into the sky colour well before the horizon line.
    return mix(background, c.rgb + c.a * background, smoothstep(0.02, 0.14, abs(d.y)));
}

fn sky_underwater_fog_color(raw_fog: vec3<f32>, sun_y: f32, sky_light: f32, calibrate: bool) -> vec3<f32> {
    let clean = max(raw_fog, vec3<f32>(0.0));
    if (!calibrate) {
        return clean;
    }
    let peak = max(clean.r, max(clean.g, clean.b));
    if (peak <= 1e-5) {
        return vec3<f32>(0.0);
    }
    let norm = clean / peak;
    let base_peak = min(peak, 0.20 + 0.04 * clamp(peak, 0.0, 1.0)) * 0.30;
    let uw_day = mix(0.18, 1.0, smoothstep(-0.10, 0.16, sun_y));
    let uw_sky = mix(0.08, 1.0, smoothstep(0.02, 0.55, sky_light));
    let calm_tint = mix(norm, vec3<f32>(0.38, 0.64, 0.76), 0.68);
    return calm_tint * (base_peak * uw_day * uw_sky);
}

fn sky(input: SkyInput) -> vec4<f32> {
    // The engine draws the sky along the ray through the bobbed projection (measured: the horizon line of this
    // direction stays within 1 px of terrain while walking), so no pack-side bob correction is applied.
    let d = normalize(input.direction);
    if (frame.eye_in == 1u) {
        let uw_active = frame.dimension == 0 && frame.blindness <= 0.0 && frame.darkness <= 0.0 && frame.night_vision <= 0.001;
        let uw_fog = sky_underwater_fog_color(frame.fog_color, frame.sun_direction.y, max(frame.eye_light_smooth.y, frame.eye_light.y), uw_active);
        if (d.y <= 0.46) {
            return vec4<f32>(uw_fog, 1.0);
        }
        if (frame.dimension != 0) {
            let vis_mask = 1.0 - clamp(max(frame.blindness, frame.darkness), 0.0, 1.0);
            let snell_t = smoothstep(0.46, 0.74, d.y) * vis_mask;
            let transmitted = min(max(input.color.rgb, vec3<f32>(0.0)), vec3<f32>(3.0)) * vec3<f32>(0.36, 0.62, 0.78);
            return vec4<f32>(mix(uw_fog, max(transmitted, uw_fog * 0.85), snell_t * 0.70), 1.0);
        }
    }
    // Dimension skies: custom cosmic End nebula & starfield, volcanic Nether ash/glow, Overworld sky below.
    if (frame.dimension == 1) { return vec4<f32>(zn_sky_end(d, frame.fog_color, frame.resolution.y), 1.0); }
    if (frame.dimension == -1) { return vec4<f32>(zn_sky_nether(d, max(input.color.rgb, vec3<f32>(0.0)), frame.fog_color, frame.time), 1.0); }
    let sun = normalize(frame.sun_direction);
    let moon = normalize(frame.moon_direction);
    let daylight = smoothstep(-0.10, 0.12, sun.y);
    let night = 1.0 - smoothstep(-0.16, -0.02, sun.y);
    let horizon = smoothstep(-0.025, 0.04, d.y);
    // From any sample inside the atmosphere visible above the camera's horizon,
    // twice acos(GROUND/TOP) bounds the solar depression at the last sunlit point.
    // sin of that angle is below 0.35, so the single-scatter term is zero deeper at night.
    var atmosphere = SkyAtmosphere(vec3<f32>(0.0), vec3<f32>(1.0));
    // With the pack's haze on, the sky below the horizon (seen past the loaded terrain) continues the horizon's
    // colour: compose.wgsl lays the same haze over it as over the terrain beside it.
    let haze_below = atmospheric_fog > 0.001;
    if (horizon > 0.0 || haze_below) && sun.y > -0.35 {
        atmosphere = sky_atmosphere(normalize(vec3<f32>(d.x, max(d.y, 0.0), d.z) + vec3<f32>(0.0, 1e-4, 0.0)), sun);
    }
    // Original airglow/indirect-night floor; deliberately not a multiple-
    // scattering solver. day_time rotates the stars; solar elevation sets dusk.
    var color = atmosphere.radiance + vec3<f32>(0.0012, 0.0020, 0.0040) * night;
    let star_vis = night * horizon * (1.0 - frame.rain);
    if star_vis > 0.0 {
        color += sky_stars(d) * star_vis;
        if aurora && star_vis > 0.001 {
            color += (sky_milky_way(d) + sky_aurora(d)) * star_vis;
        }
    }
    // Dot-product angular discs: cos(radius) threshold, original artistic sizes
    // 0.27 degrees sun, 0.30 degrees moon. Smooth boundaries avoid hard aliasing.
    // Disc, corona and halo are all functions of the same ray `d` (this stage's `input.direction`) and of the
    // same sun colour, so they move as one object; the view bob is applied to the whole sky picture afterwards
    // (compose.wgsl). Disc radius is about 0.4-0.5 degrees (the real sun is 0.27, but a 5 px disc at 18x
    // brightness shimmers under that resampling). The corona bridges the disc and the wide halo, and the colour
    // is pulled a third of the way to neutral so a low sun is not a lone orange dot inside a blue glow.
    let sun_mu = dot(d, sun);
    let sun_x = max(0.0, 1.0 - sun_mu);
    let sun_disk = smoothstep(0.999962, 0.999975, sun_mu);
    let sun_corona = exp(-sun_x * 9000.0) * 0.70;
    let sun_halo = exp(-sun_x * 650.0) * 0.038;
    let sun_colour = mix(atmosphere.transmittance, vec3<f32>(zn_luma(atmosphere.transmittance)), 0.35);
    color += sun_colour * (sun_disk * 10.5 + sun_corona + sun_halo) * horizon * daylight;
    let moon_mu = dot(d, moon);
    let moon_halo = exp(-max(0.0, 1.0 - moon_mu) * 180.0) * 0.016;
    // API 0.2 has no moon=false: engine moon (including its phases) draws cleanly over this subtle halo without a round disc artifact.
    color += vec3<f32>(0.58, 0.72, 1.0) * moon_halo * night * horizon;
    let fog_raw = max(frame.fog_color, vec3<f32>(0.0));
    let fog_lum = zn_luma(fog_raw);
    let cool_fog = vec3<f32>(0.55, 0.74, 1.20) * fog_lum;
    let tinted_fog = mix(cool_fog, fog_raw, smoothstep(-0.04, 0.10, sun.y));
    let air_fog = tinted_fog * (0.12 + 0.45 * smoothstep(-0.08, 0.14, sun.y));
    color = mix(air_fog, color, select(horizon, 1.0, haze_below));
    // Original overcast extinction/art direction, always in linear light.
    let overcast = mix(vec3<f32>(0.008, 0.012, 0.022), vec3<f32>(0.20, 0.24, 0.29), daylight);
    color = mix(color, overcast, clamp(frame.rain * 0.68 + frame.thunder * 0.22, 0.0, 0.9));
    // The clouds are not visible from under the surface: skip their march once submerged.
    if (frame.eye_in != 1u) {
        color = sky_cirrus_layer(d, color, sun, daylight);
        color = sky_cloud_layer(d, color, sun, daylight);
    }
    let luma = zn_luma(color); // Pack primaries are BT.709.
    color = max(mix(vec3<f32>(luma), color, clamp(sky_saturation, 0.0, 1.6)), vec3<f32>(0.0));
    if (frame.eye_in == 1u) {
        let sky_l = max(frame.eye_light_smooth.y, frame.eye_light.y);
        let uw_active = frame.dimension == 0 && frame.blindness <= 0.0 && frame.darkness <= 0.0 && frame.night_vision <= 0.001;
        let uw_fog = sky_underwater_fog_color(frame.fog_color, frame.sun_direction.y, sky_l, uw_active);
        let uw_sky_dim = select(1.0, mix(0.08, 1.0, smoothstep(0.02, 0.55, sky_l)), uw_active);
        let vis_mask = 1.0 - clamp(max(frame.blindness, frame.darkness), 0.0, 1.0);
        let snell_t = smoothstep(0.46, 0.72, d.y) * vis_mask;
        let sky_soft = mix(vec3<f32>(luma), color, 0.38);
        let sky_tamed = sky_soft / (1.0 + luma * 2.2);
        let transmitted_sky = sky_tamed * vec3<f32>(0.56, 0.76, 0.82) * uw_sky_dim;
        color = mix(uw_fog, max(transmitted_sky, uw_fog * 0.85), snell_t * 0.75);
    }
    return vec4<f32>(color, 1.0);
}
