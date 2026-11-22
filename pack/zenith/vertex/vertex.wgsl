// src: Tiago Sousa, "Crysis 2" vegetation animation concepts, SIGGRAPH 2011 (UV-anchored & world-phase sinusoidal wind sway); Horizon Shader API 0.2 (VertexInput).
// Zenith Shader Pack — Vertex Stage (Wind Sway for Foliage, Plants & Water Surface)
// Note: Shares the [material] shader module; uses vtx_ prefix to avoid symbol collisions
// and never calls fragment-only or ray-tracing functions.

override waving_foliage: bool = true;
override waving_water: bool = true;
override wind_strength: f32 = 1.0;

const VTX_MAT_LEAVES: u32     = 10u;
const VTX_MAT_PLANTS: u32     = 11u;
const VTX_MAT_VINES_KELP: u32 = 12u;
const VTX_MAT_WATER: u32      = 20u;
const VTX_MAT_LAVA: u32       = 21u;

fn vtx_gust_envelope(world_pos: vec3<f32>, t: f32) -> f32 {
    // Broad traveling wind gusts across world XZ so vegetation sways in natural waves.
    let gust_phase = world_pos.x * 0.14 + world_pos.z * 0.11 - t * 1.15;
    let secondary = world_pos.x * 0.07 - world_pos.z * 0.16 - t * 0.72;
    return 0.65 + 0.35 * sin(gust_phase) * cos(secondary);
}

fn vertex(input: VertexInput) -> vec3<f32> {
    if wind_strength <= 0.001 {
        return input.position;
    }

    let world_pos = input.position + frame.camera_position;
    let t = frame.time;
    let storm = 1.0 + 0.55 * frame.rain + 0.85 * frame.thunder;
    let sky_exposure = smoothstep(0.12, 0.88, input.light.y);
    let env_wind = wind_strength * storm * mix(0.22, 1.0, sky_exposure);

    var pos = input.position;
    let vtx_dist = length(input.position);

    // 1. Water surface vertical wave displacement (top faces only, excluding lava)
    // Primary directional swells synced with material/water.wgsl wave vectors.
    if waving_water && input.fluid == 1u && input.material != VTX_MAT_LAVA && input.face == 1u {
        let wave_fade = 1.0 - smoothstep(48.0, 110.0, vtx_dist);
        let wave_t = t * (1.35 + 0.55 * clamp(frame.rain * 0.7 + frame.thunder * 0.3, 0.0, 1.0));
        let w1 = sin(dot(world_pos.xz, vec2<f32>(0.86, 0.51)) * 1.35 + wave_t * 1.45);
        let w2 = sin(dot(world_pos.xz, vec2<f32>(-0.54, 0.84)) * 1.85 - wave_t * 1.20);
        // Slightly downward-biased displacement keeps water from clipping thin slabs above.
        let disp_y = (w1 * 0.56 + w2 * 0.44 - 0.65) * 0.034 * clamp(wind_strength, 0.0, 1.8) * wave_fade;
        pos.y = pos.y + disp_y;
        return pos;
    }

    if !waving_foliage {
        return pos;
    }

    let wind_fade = 1.0 - smoothstep(32.0, 68.0, vtx_dist);
    if wind_fade <= 0.001 {
        return pos;
    }

    let gust = vtx_gust_envelope(world_pos, t);
    let env_foliage = env_wind * wind_fade;

    // 2. Ground plants, tall grass, flowers, crops (anchored at root where uv.y == 1.0)
    if input.material == VTX_MAT_PLANTS {
        let top_weight = pow(clamp(1.0 - input.uv.y, 0.0, 1.0), 1.35);
        let phase = world_pos.x * 1.7 + world_pos.z * 1.3 + world_pos.y * 0.9;
        let sway_x = sin(t * 2.45 + phase) * 0.065 + sin(t * 4.8 + phase * 1.7) * 0.018;
        let sway_z = cos(t * 2.05 + phase * 0.85) * 0.055;
        let amp = top_weight * env_foliage * gust;
        pos.x = pos.x + sway_x * amp;
        pos.z = pos.z + sway_z * amp;
        return pos;
    }

    // 3. Tree leaves (continuous 3D world-space sway keeps cube corners stitched together)
    if input.material == VTX_MAT_LEAVES {
        let phase = world_pos.x * 0.95 + world_pos.y * 0.75 + world_pos.z * 0.85;
        let sway_x = sin(t * 1.85 + phase) * 0.028;
        let sway_y = sin(t * 2.25 + phase * 1.3) * 0.014;
        let sway_z = cos(t * 1.65 + phase * 0.9) * 0.026;
        let amp = env_foliage * gust;
        pos = pos + vec3<f32>(sway_x, sway_y, sway_z) * amp;
        return pos;
    }

    // 4. Vines, seagrass & kelp (gentle continuous sway so multi-block stems stay joined)
    if input.material == VTX_MAT_VINES_KELP {
        let phase = world_pos.x * 1.3 + world_pos.y * 1.15 + world_pos.z * 1.25;
        let sway_x = sin(t * 1.9 + phase) * 0.030;
        let sway_z = cos(t * 1.7 + phase * 0.9) * 0.030;
        let amp = wind_strength * (0.65 + 0.35 * gust) * wind_fade;
        pos.x = pos.x + sway_x * amp;
        pos.z = pos.z + sway_z * amp;
        return pos;
    }

    return pos;
}
