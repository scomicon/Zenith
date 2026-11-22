// src: S. Hillaire, A Scalable and Production Ready Sky and Atmosphere Rendering Technique, EGSR 2020 (scattering and Beer-Lambert extinction); Zenith own precipitation calibration, 2026.
// Zenith independent precipitation lighting. Horizon shader API 0.2:
// https://github.com/horizon-rust/horizon/blob/90e97a1fc2fa4aac23766e418f55cbce94e97618/docs/api/shaders-reference-0.2.md
// WeatherInput contains color/light/position/snow, not UV or a surface normal.
// Rain/snow geometry and texture coverage are the engine's. RGB is linear;
// alpha is straight coverage, never premultiplied radiance.

fn weather(input: WeatherInput) -> vec4<f32> {
    let block = clamp(input.light.x, 0.0, 1.0);
    let sky_light = clamp(input.light.y, 0.0, 1.0);
    let distance = length(input.position);
    let view = input.position / max(distance, 0.001);
    let sun = normalize(frame.sun_direction);
    let day = smoothstep(-0.10, 0.12, sun.y);
    // Zenith calibration of block/sky irradiance: squared light levels suppress
    // bright unlit streaks underground; warm lamps and cool night illumination.
    let ambient = mix(vec3<f32>(0.014, 0.022, 0.045), vec3<f32>(0.48, 0.56, 0.68), day);
    let lamps = vec3<f32>(1.0, 0.52, 0.20) * block * block;
    let storm = 1.0 - 0.60 * clamp(frame.thunder, 0.0, 1.0);
    let irradiance = ambient * sky_light * sky_light * storm + lamps + vec3<f32>(0.002);
    // Henyey-Greenstein single-particle phase, normalized so an isotropic
    // particle has factor 1. Hillaire 2020 section 2 (standard scattering law):
    // https://sebh.github.io/publications/egsr2020.pdf
    // Rain is more forward scattering than snow; this is an artistic effective
    // phase, not a complete droplet Mie or ice-crystal simulation.
    let g = select(0.68, 0.20, input.snow);
    let mu = clamp(dot(view, sun), -1.0, 1.0);
    let phase = (1.0 - g * g) / pow(max(1.0 + g * g - 2.0 * g * mu, 0.001), 1.5);
    let sun_color = mix(vec3<f32>(1.0, 0.34, 0.13), vec3<f32>(1.0, 0.96, 0.88), smoothstep(0.0, 0.3, sun.y));
    let direct = sun_color * min(phase, 6.0) * day * sky_light * sky_light * storm * 0.18;
    let tint = select(vec3<f32>(0.72, 0.83, 1.0), vec3<f32>(0.94, 0.97, 1.0), input.snow);
    let lit = max(input.color.rgb, vec3<f32>(0.0)) * tint * (irradiance + direct);
    // Beer-Lambert aerial fog, as Hillaire's homogeneous-medium limit.
    // Density and snow/rain opacity are original Zenith scene calibrations.
    var density = mix(0.007, 0.025, clamp(frame.rain, 0.0, 1.0));
    var opacity = 0.60;
    if input.snow {
        // Modulate the native falling flakes with broad moving gusts in world space.
        let world = frame.camera_position.xz + input.position.xz;
        let gust_phase = frame.time * (6.2831853 / 3600.0);
        let a = sin(dot(world, vec2<f32>(0.17, -0.11)) - 790.0 * gust_phase);
        let b = sin(dot(world, vec2<f32>(0.09, 0.20)) - 570.0 * gust_phase);
        let gust = smoothstep(-0.65, 0.85, a * 0.65 + b * 0.35);
        let snowstorm = clamp(frame.rain * mix(0.78, 1.0, frame.thunder), 0.0, 1.0);
        density += snowstorm * (0.008 + gust * 0.011);
        opacity = mix(0.90, mix(0.72, 1.32, gust), snowstorm);
    }
    let transmission = exp(-distance * density);
    let fog = max(frame.fog_color, vec3<f32>(0.0)) * (0.12 + 0.58 * day);
    let color = mix(fog, lit, transmission);
    // A Hermite fade at the fog range avoids a visible weather-cylinder wall;
    // preserve texture/vertex alpha, which already includes engine rain fading.
    let far = max(min(frame.fog_environment.y, frame.fog_render.y), 8.0);
    let fade = 1.0 - smoothstep(far * 0.65, far, distance);
    return vec4<f32>(color, clamp(input.color.a * opacity * fade, 0.0, 1.0));
}
