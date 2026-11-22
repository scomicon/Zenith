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
    if (frame.dimension == 0 && frame.eye_in == 0u && frame.blindness <= 0.0 && frame.darkness <= 0.0 && frame.night_vision <= 0.001) {
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
        fog_rgb = sky_fog_rgb;
    } else if (frame.eye_in == 1u) {
        let uw_active = frame.dimension == 0 && frame.blindness <= 0.0 && frame.darkness <= 0.0 && frame.night_vision <= 0.001;
        fog_rgb = zn_underwater_fog_color(fog_rgb, frame.sun_direction.y, max(frame.eye_light_smooth.y, frame.eye_light.y), uw_active);
    }
    let gamma_colour = pow(max(colour.rgb, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
    let gamma_fog = pow(fog_rgb, vec3<f32>(1.0 / 2.2));
    return vec4<f32>(pow(mix(gamma_colour, gamma_fog, clamp(fog, 0.0, 1.0)), vec3<f32>(2.2)), colour.a);
}
