// src: Horizon Shader API 0.2 (`[ray_tracing] lights`: ray_lights_near, ray_light_at, ray_light; trace_any); B. Karis,
// "Real Shading in Unreal Engine 4", SIGGRAPH 2013 (windowed inverse-square falloff of punctual lights, GGX);
// T. Whitted, CACM 1980 (shadow rays). Own choices: the falloff calibration against vanilla block light, the light
// sizes, the warm default colour and the vanilla residual.
//
// Light from torches, lanterns, glowstone and every other listed light block, each tested with a shadow ray, so
// walls and corners cast real shadows, light comes from the source's side (Lambert) and polished surfaces catch its
// highlight. Sources the list leaves out (lava) keep vanilla's block light through the residual below.

struct ZnRtBlockLight {
    diffuse: vec3<f32>,     // irradiance-like light, times the surface's diffuse albedo by the caller
    specular: vec3<f32>,    // GGX highlight, already weighted
    vanilla_scale: f32,     // what is left of vanilla's block light term (unlisted sources, the grid's edge)
}

const ZN_RT_LAMP_GAIN: f32 = 0.86;      // brightness one block from a level-14 source, as vanilla's curve gives it
const ZN_RT_LAMP_RADIUS: f32 = 5.0;     // blocks: the inverse-square knee (vanilla's linear falloff is matched to it)
const ZN_RT_LAMP_SIZE: f32 = 0.16;      // blocks: radius of a flame or lamp, for the shadow ray's soft edge
const ZN_RT_LAMP_CUBE: f32 = 0.42;      // ... of a full glowing cube (level 15)
const ZN_RT_LAMP_GRID: f32 = 64.0;      // blocks: half the side of the light grid around the camera
const ZN_RT_LAMP_FILL: f32 = 0.24;      // share of vanilla's block light kept as the light bounced off walls (own choice)
const ZN_RT_LAMP_TAPS: u32 = 4u;        // shadow rays across a near source's body, for a smooth penumbra

// How far along `direction` from `origin` the ray enters the block centred on `center`: a glowing cube is in the
// ray scene, so a shadow ray aimed at its centre would be stopped by the source itself.
fn zn_rt_lamp_entry(origin: vec3<f32>, direction: vec3<f32>, center: vec3<f32>) -> f32 {
    let tiny = vec3<f32>(1e-6);
    let inverse = 1.0 / select(direction, tiny, abs(direction) < tiny);
    let a = (center - 0.5 - origin) * inverse;
    let b = (center + 0.5 - origin) * inverse;
    let near = min(a, b);
    return max(max(near.x, near.y), near.z);
}

fn zn_rt_lamp_tint(color: vec3<f32>) -> vec3<f32> {
    // A block the pack gives no [[lights]] colour comes as white: use the warm flame colour vanilla torches have.
    let white = min(color.r, min(color.g, color.b)) > 0.97;
    return select(color, vec3<f32>(1.0, 0.56, 0.20), white);
}

fn mat_rt_block_light(
    p: vec3<f32>, geom_n: vec3<f32>, N: vec3<f32>, V: vec3<f32>, surf: PbrSurface, light_x: f32,
) -> ZnRtBlockLight {
    var out: ZnRtBlockLight;
    out.diffuse = vec3<f32>(0.0);
    out.specular = vec3<f32>(0.0);
    out.vanilla_scale = 1.0;
    if frame.has_ray_tracing == 0u || rt_lighting < 1u || frame.eye_in > 1u {
        return out;
    }
    let edge = max(max(abs(p.x), abs(p.y)), abs(p.z));
    let grid_weight = 1.0 - smoothstep(ZN_RT_LAMP_GRID - 16.0, ZN_RT_LAMP_GRID - 4.0, edge);
    if grid_weight <= 0.0 {
        return out;
    }
    let near = ray_lights_near(p);
    // The block of air in front of the face, where vanilla measures the light this face shows.
    let air = floor(p + frame.camera_position + geom_n * 0.5);
    let origin = p + geom_n * 0.03;
    // A stable per-surface rotation for the soft-edge offset (no crawl with the camera).
    let spin = fract(sin(dot(floor((p + frame.camera_position) * 16.0), vec3<f32>(12.9898, 78.233, 37.719))) * 43758.5453) * 6.2831853;
    var listed_level = 0.0;
    var diffuse = vec3<f32>(0.0);
    var specular = vec3<f32>(0.0);
    let rough = clamp(surf.roughness, 0.22, 0.9);
    let ndotv = max(dot(N, V), 1e-4);
    for (var i = 0u; i < near.y; i++) {
        let source = ray_light(ray_light_at(near.x + i));
        if source.level <= 0.0 { continue; }
        // Vanilla's level here from this source (level minus the block distance), for the residual below.
        let cell = floor(source.position + frame.camera_position);
        let steps = abs(cell - air);
        listed_level = max(listed_level, source.level - (steps.x + steps.y + steps.z));
        let to = source.position - origin;
        let distance = length(to);
        if distance >= source.level + 0.5 { continue; }
        let direction = to / max(distance, 1e-4);
        let ndotl = dot(N, direction);
        let facing = dot(geom_n, direction);
        if ndotl <= 0.0 || facing <= 0.0 { continue; }
        // Windowed inverse square (Karis 2013), its knee matched to vanilla's linear fall over the level's range.
        let range = source.level;
        let x = distance / range;
        let window = clamp(1.0 - x * x * x * x, 0.0, 1.0);
        let falloff = ZN_RT_LAMP_GAIN * window * window / (1.0 + (distance / ZN_RT_LAMP_RADIUS) * (distance / ZN_RT_LAMP_RADIUS));
        let radiance = zn_rt_lamp_tint(source.color) * (falloff * block_light_strength * (source.level / 14.0));
        // Light too faint to show is not worth its shadow rays.
        if zn_luma(radiance) * ndotl < 0.002 { continue; }
        // Aim at a point of the light's body, turned per surface, for a soft shadow edge.
        let size = select(ZN_RT_LAMP_SIZE, ZN_RT_LAMP_CUBE, source.level >= 15.0);
        let reference = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(direction.y) > 0.9);
        let t = normalize(cross(reference, direction));
        let b = cross(direction, t);
        // A few rays across the source's body (more for near sources, whose penumbra is wide on screen).
        let taps = select(select(1u, 2u, distance < 9.0), select(ZN_RT_LAMP_TAPS, ZN_RT_LAMP_TAPS * 2u, quality_mode >= 3u), distance < 5.0);
        var visible = 0.0;
        for (var k = 0u; k < taps; k++) {
            let a = spin + f32(k) * 2.39996323;
            let r = sqrt((f32(k) + 0.5) / f32(taps)) * size;
            let aim = source.position + (t * cos(a) + b * sin(a)) * r;
            let shadow_dir = normalize(aim - origin);
            let reach = zn_rt_lamp_entry(origin, shadow_dir, source.position) - 0.01;
            if reach <= 0.0 || !trace_any(origin, shadow_dir, reach) { visible += 1.0; }
        }
        if visible <= 0.0 { continue; }
        let shadow = visible / f32(taps);
        diffuse += radiance * (ndotl * shadow);
        let H = normalize(V + direction);
        let ndoth = max(dot(N, H), 0.0);
        let F = zn_fresnel_schlick(max(dot(V, H), 0.0), surf.f0);
        let spec = F * (mat_d_ggx(ndoth, rough) * mat_g_smith_ggx(ndotv, ndotl, rough)) / max(4.0 * ndotv * ndotl, 1e-4);
        specular += min(spec * radiance * (ndotl * shadow), vec3<f32>(1.6));
    }
    // Vanilla's light that no listed source explains (lava, a source past the grid) stays vanilla.
    let vanilla_level = clamp(light_x, 0.0, 1.0) * 15.0;
    let residual = max(vanilla_level - max(listed_level, 0.0) - 1.0, 0.0) / 15.0;
    let residual_scale = select(0.0, pow(residual / max(light_x, 1e-3), 1.75), light_x > 1e-3);
    out.diffuse = diffuse * grid_weight;
    out.specular = specular * grid_weight;
    // Light bounced off the room's walls, which the shadow rays leave out: a share of vanilla's smooth light stays.
    out.vanilla_scale = mix(1.0, max(clamp(residual_scale, 0.0, 1.0), ZN_RT_LAMP_FILL), grid_weight);
    return out;
}
