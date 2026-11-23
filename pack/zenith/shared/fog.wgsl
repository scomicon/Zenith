// src: Horizon Shader API 0.2, 3a6bea5 reference, [frame] fog and vanilla_fog contract; Beer-Lambert/visibility concepts. Independently tuned smooth underwater distance ramp.
// Pack-owned surface fog: preserve vanilla outside water and under vision effects.
// Own choices: water clarity range multiplier 1.8, clear near range up to 6 blocks,
// smoothstep profile. This preserves contrast before it is lost to opaque fog;
// no sharpening, deconvolution or screen-space blur is used.
override underwater_clarity: f32 = 1.8;

fn zn_underwater_fog_color(raw_fog: vec3<f32>, sun_y: f32, sky_light: f32, calibrate: bool) -> vec3<f32> {
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

// Overworld clear air: the render-distance fog colour, calibrated to the pack's sky. compose.wgsl swaps it for the
// aerial perspective's own colour afterwards, so both must come from here.
fn zn_overworld_air_fog() -> bool {
    return frame.dimension == 0 && frame.eye_in == 0u && frame.blindness <= 0.0 && frame.darkness <= 0.0 && frame.night_vision <= 0.001;
}

fn zn_overworld_fog_rgb() -> vec3<f32> {
    let fog_rgb = max(frame.fog_color, vec3<f32>(0.0));
    let daylight = smoothstep(-0.08, 0.14, frame.sun_direction.y);
    let storm = clamp(frame.rain * 0.68 + frame.thunder * 0.22, 0.0, 0.9);
    let fog_lum = dot(fog_rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
    let cool_fog = vec3<f32>(0.55, 0.74, 1.20) * fog_lum;
    let tinted = mix(cool_fog, fog_rgb, smoothstep(-0.04, 0.10, frame.sun_direction.y));
    var sky_fog_rgb = tinted * (0.12 + 0.45 * daylight);
    if (storm > 0.001) {
        let overcast = mix(vec3<f32>(0.008, 0.012, 0.022), vec3<f32>(0.20, 0.24, 0.29), daylight);
        sky_fog_rgb = mix(sky_fog_rgb, overcast, storm);
    }
    return sky_fog_rgb;
}

fn zn_fog_surface(colour: vec4<f32>, position: vec3<f32>) -> vec4<f32> {
    var fog = vanilla_fog(position);
    if (frame.eye_in == 1u && frame.blindness <= 0.0 && frame.darkness <= 0.0) {
        let original_end = max(frame.fog_environment.y, 48.0);
        let near = max(frame.fog_environment.x, 0.0) + min(original_end * 0.08, 6.0);
        let far = max(original_end * clamp(underwater_clarity, 1.0, 3.0), near + 1.0);
        let dist = length(position);
        let up_air = smoothstep(0.15, 3.5, position.y) * smoothstep(0.02, 0.22, position.y / max(dist, 1.0));
        let environment = smoothstep(near, far, dist * mix(1.0, 0.22, up_air));
        let render_dist = max(length(position.xz), abs(position.y));
        let render_span = max(frame.fog_render.y - frame.fog_render.x, 1e-4);
        let render_fog = clamp((render_dist - frame.fog_render.x) / render_span, 0.0, 1.0);
        let water_fog = max(environment, render_fog);
        fog = water_fog;
    } else if (frame.eye_in == 3u && frame.fog_environment.x >= 0.0 && frame.blindness <= 0.0 && frame.darkness <= 0.0) {
        // Keep close shapes legible in powder snow and close the view by the engine's fog limit.
        fog = smoothstep(0.18, max(frame.fog_environment.y, 0.30), length(position));
    } else if (frame.dimension == 1 && frame.eye_in == 0u && frame.blindness <= 0.0 && frame.darkness <= 0.0) {
        // Bypass vanilla's Ender Dragon boss_world_fog clamp so the End island remains crisp from any altitude
        // while retaining subtle depth haze and render-distance fade.
        let render_dist = max(length(position.xz), abs(position.y));
        let render_span = max(frame.fog_render.y - frame.fog_render.x, 1e-4);
        let render_fog = clamp((render_dist - frame.fog_render.x) / render_span, 0.0, 1.0);
        let end_haze = smoothstep(115.0, max(frame.fog_render.y * 1.10, 320.0), length(position)) * 0.34;
        fog = max(end_haze, render_fog);
    }
    // Match Horizon's documented gamma-domain fog, including alpha preservation.
    // Calibrate Overworld clear-air horizon fog to match sky/sky.wgsl (taming vanilla's
    // bright brownish dusk fog_color so distant hills melt naturally into the night sky).
    var fog_rgb = max(frame.fog_color, vec3<f32>(0.0));
    if (zn_overworld_air_fog()) {
        fog_rgb = zn_overworld_fog_rgb();
    } else if (frame.eye_in == 1u) {
        let uw_active = frame.dimension == 0 && frame.blindness <= 0.0 && frame.darkness <= 0.0 && frame.night_vision <= 0.001;
        fog_rgb = zn_underwater_fog_color(fog_rgb, frame.sun_direction.y, max(frame.eye_light_smooth.y, frame.eye_light.y), uw_active);
    }
    let gamma_colour = pow(max(colour.rgb, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
    let gamma_fog = pow(fog_rgb, vec3<f32>(1.0 / 2.2));
    return vec4<f32>(pow(mix(gamma_colour, gamma_fog, clamp(fog, 0.0, 1.0)), vec3<f32>(2.2)), colour.a);
}

// ---- Participating medium shared by the aerial perspective (compose.wgsl) and the sun shafts (volumetric.wgsl) ----
// src: S. Hillaire, "A Scalable and Production Ready Sky and Atmosphere Rendering Technique", EGSR 2020 (Rayleigh and
// Mie media with exponential height profiles, single scattering); E. Wenzel, "Real-time atmospheric effects in games",
// GDC 2006 (closed-form optical depth of exponential height fog). Own choices: the scale of the media for a world in
// blocks (haze about 6x real, air 10x, so a vista of a few hundred blocks reads as one), the ground-fog layer, the
// weather and time-of-day factors and every constant.
//
// Three media, each with density exp(-(y - sea) / H) (clamped 40 blocks under the sea):
//   air      Rayleigh, H = 1200 blocks, blue extinction: far terrain turns toward the sky's blue;
//   haze     Mie aerosol, H = 90 blocks: the golden glow toward the sun and the grey-blue veil away from it;
//   ground   Mie fog lying in the valleys, H = 14 blocks: thick at dawn, in rain and in humid biomes.

const ZN_ATMO_SEA: f32 = 63.0;
const ZN_ATMO_AIR_H: f32 = 1200.0;
const ZN_ATMO_HAZE_H: f32 = 90.0;
const ZN_ATMO_GROUND_H: f32 = 14.0;
const ZN_ATMO_AIR: vec3<f32> = vec3<f32>(5.8e-5, 13.6e-5, 33.1e-5);   // Rayleigh scattering per block (10x sea level)
const ZN_ATMO_MIE_ALBEDO: f32 = 0.9;

struct ZnMedium {
    haze: f32,     // Mie scattering per block at sea level
    ground: f32,   // ground-fog scattering per block at sea level
    air: f32,      // multiplier of the Rayleigh coefficients
}

// Morning (around sunrise) weight, 0..1: the hours when valley fog forms.
fn zn_atmo_morning() -> f32 {
    let t = fract(frame.day_time + 0.10) - 0.10;   // 0 at day_time 0 (sunrise), negative before it
    return smoothstep(-0.07, -0.015, t) * (1.0 - smoothstep(0.035, 0.12, t));
}

fn zn_atmo_medium(strength: f32) -> ZnMedium {
    let rain = clamp(frame.rain, 0.0, 1.0);
    let humid = smoothstep(0.30, 0.90, frame.downfall);
    let morning = zn_atmo_morning();
    let dusk = smoothstep(0.18, 0.0, abs(frame.sun_direction.y)) * smoothstep(-0.08, 0.02, frame.sun_direction.y);
    // Midday air is the clearest: convection lifts and thins the haze while the sun stands high.
    let midday = smoothstep(0.30, 0.85, frame.sun_direction.y);
    var m: ZnMedium;
    m.haze = 4.2e-4 * mix(1.0, 0.62, midday) * (1.0 + 1.6 * rain + 0.55 * morning + 0.35 * dusk + 0.45 * humid) * strength;
    m.ground = 2.6e-3 * (0.05 + 0.95 * morning + 0.55 * rain + 0.20 * humid) * strength;
    m.air = strength;
    return m;
}

fn zn_atmo_profile(y: f32, scale_height: f32) -> f32 {
    return exp(-max(y - ZN_ATMO_SEA, -40.0) / scale_height);
}

// Integral of exp(-(y0 + dy * s - sea) / H) over s in [0, t] (Wenzel 2006), with the endpoints' clamp applied.
fn zn_atmo_column(y0: f32, dy: f32, t: f32, scale_height: f32) -> f32 {
    let e0 = zn_atmo_profile(y0, scale_height);
    if abs(dy) < 1e-4 {
        return e0 * t;
    }
    let e1 = zn_atmo_profile(y0 + dy * t, scale_height);
    return max((e0 - e1) * scale_height / dy, 0.0);
}

// RGB optical depth from height y0 along a ray with vertical component dy, over t blocks.
fn zn_atmo_optical_depth(y0: f32, dy: f32, t: f32, m: ZnMedium) -> vec3<f32> {
    let air = ZN_ATMO_AIR * (m.air * zn_atmo_column(y0, dy, t, ZN_ATMO_AIR_H));
    let mie = (m.haze * zn_atmo_column(y0, dy, t, ZN_ATMO_HAZE_H) + m.ground * zn_atmo_column(y0, dy, t, ZN_ATMO_GROUND_H))
        / ZN_ATMO_MIE_ALBEDO;
    return air + vec3<f32>(mie);
}

// Optical depth of the haze and ground fog alone (the Mie media): what the sky stage's own Rayleigh sky lacks.
fn zn_atmo_optical_depth_mie(y0: f32, dy: f32, t: f32, m: ZnMedium) -> f32 {
    return (m.haze * zn_atmo_column(y0, dy, t, ZN_ATMO_HAZE_H) + m.ground * zn_atmo_column(y0, dy, t, ZN_ATMO_GROUND_H))
        / ZN_ATMO_MIE_ALBEDO;
}

// How far a sky pixel's ray runs through the medium: to the sea plane below the horizon, 6000 blocks above it.
fn zn_atmo_sky_distance(dir: vec3<f32>) -> f32 {
    let void_dist = zn_atmo_void_distance(dir);
    return select(6000.0, void_dist, void_dist > 0.0);
}

// Henyey-Greenstein, normalised so isotropic scattering is 1.
fn zn_atmo_hg(cos_t: f32, g: f32) -> f32 {
    let g2 = g * g;
    return (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * cos_t, 1e-4), 1.5);
}

// Mie phase of the haze: a strong forward lobe (the glow around a low sun) and a faint back lobe.
fn zn_atmo_mie_phase(cos_t: f32) -> f32 {
    return mix(zn_atmo_hg(cos_t, 0.72), zn_atmo_hg(cos_t, -0.25), 0.18);
}

// Below the horizon, past the loaded terrain, the sky shows the void: it is taken as the sea plane (y 63) the
// ray would meet, at most 6000 blocks away, so the medium in front of it matches the terrain beside it.
// -1 for rays at or above the horizon.
fn zn_atmo_void_distance(dir: vec3<f32>) -> f32 {
    if dir.y >= -1e-5 {
        return -1.0;
    }
    let drop = max(frame.camera_position.y - ZN_ATMO_SEA, 1.0);
    return min(drop / -dir.y, 6000.0);
}

fn zn_atmo_rayleigh_phase(cos_t: f32) -> f32 {
    return 0.75 * (1.0 + cos_t * cos_t);
}
