// src: Christophe Schlick, "An Inexpensive BRDF Model for Physically-based Rendering", Eurographics 1994 (scalar Fresnel); Horizon Shader API 0.2 reversed-depth inverse projection unprojection and depth-aware opaque_color refraction.
// Zenith Shader Pack — Material Stage Constants, Overrides & Helpers
// Clean-room implementation for Horizon Shader API 0.2 (Linear Light).
// Relies on shared/common.wgsl (zn_luma, zn_hash21, zn_noise2, zn_fbm2,
// zn_ign, zn_fresnel_schlick, zn_pow5, zn_remap).

// --- Material & Shadow Pipeline Overrides (matching manifest-fragments/material.toml) ---
override shadows_enabled: bool = true;
override shadow_filter_quality: u32 = 1u;
override shadow_softness: f32 = 1.35;
override colored_shadows: bool = true;
override shadow_pcss: bool = true;
override cloud_shadows: bool = true;
override clouds: bool = true;
override cloud_coverage: f32 = 0.48;

override block_light_strength: f32 = 1.15;
override ambient_strength: f32 = 1.0;
override emissive_strength: f32 = 1.4;
override ore_glow: bool = true;

override pbr_specular: bool = true;
override procedural_pbr: bool = true;
override pbr_pom: bool = true;
override pom_depth: f32 = 0.06;
override pbr_displacement: bool = true;
override displacement_cells: u32 = 1u;
override rain_wetness: bool = true;
override foliage_sss: bool = true;
override snow_sand_sparkle: bool = true;

override water_reflections: bool = true;
override water_wave_strength: f32 = 1.0;
override water_absorption: f32 = 1.0;
override water_foam: bool = true;
override water_refraction: bool = true;
override glass_refraction: bool = true;

override end_rift: bool = true;
override end_rift_speed: f32 = 1.0;

const MAT_PI: f32 = 3.14159265359;
const MAT_INV_PI: f32 = 0.31830988618;

// Sprite tag bitmasks matching [[tags]] order in manifest-fragments/material.toml
const TAG_GLASS: u32          = 1u << 0u;
const TAG_ICE: u32            = 1u << 1u;
const TAG_FOLIAGE: u32        = 1u << 2u;
const TAG_PLANTS: u32         = 1u << 3u;
const TAG_METAL: u32          = 1u << 4u;
const TAG_POLISHED: u32       = 1u << 5u;
const TAG_EMISSIVE_ORE: u32   = 1u << 6u;
const TAG_EMISSIVE_BLOCK: u32 = 1u << 7u;
const TAG_SNOW_SAND: u32      = 1u << 8u;
const TAG_OBSIDIAN: u32       = 1u << 9u;
const TAG_MATTE_ORGANIC: u32  = 1u << 10u;
const TAG_GEM: u32            = 1u << 11u;
const TAG_BEACON: u32         = 1u << 12u;
const TAG_COPPER_FRESH: u32   = 1u << 13u;
const TAG_COPPER_EXPOSED: u32 = 1u << 14u;
const TAG_COPPER_WEATHERED: u32 = 1u << 15u;
const TAG_COPPER_OXIDIZED: u32 = 1u << 16u;
const TAG_AMETHYST: u32       = 1u << 17u;
const TAG_HONEY: u32          = 1u << 18u;
const TAG_SSS: u32            = 1u << 19u;
const TAG_COPPER_FINISH: u32  = TAG_COPPER_FRESH | TAG_COPPER_EXPOSED | TAG_COPPER_WEATHERED | TAG_COPPER_OXIDIZED;
const TAG_SOLID_SCATTER: u32  = TAG_ICE | TAG_HONEY;

// Material IDs matching [[materials]] in manifest-fragments/material.toml
const MAT_ID_LEAVES: u32      = 10u;
const MAT_ID_PLANTS: u32      = 11u;
const MAT_ID_VINES_KELP: u32  = 12u;
const MAT_ID_WATER: u32       = 20u;
const MAT_ID_LAVA: u32        = 21u;
const MAT_ID_METAL: u32       = 30u;
const MAT_ID_POLISHED: u32    = 31u;
const MAT_ID_GLASS_ICE: u32   = 32u;
const MAT_ID_ORE: u32         = 40u;
const MAT_ID_MAGMA_SCULK: u32 = 41u;
const MAT_ID_SNOW_SAND: u32   = 50u;

fn mat_fresnel_schlick_scalar(cos_theta: f32, f0: f32) -> f32 {
    let k = zn_pow5(1.0 - clamp(cos_theta, 0.0, 1.0));
    return f0 + (1.0 - f0) * k;
}

fn mat_safe_normalize(v: vec3<f32>) -> vec3<f32> {
    let len_sq = dot(v, v);
    if len_sq > 1e-12 {
        return v * inverseSqrt(len_sq);
    }
    return vec3<f32>(0.0, 1.0, 0.0);
}

// Converts a reversed-depth screen sample into camera-relative world position.
fn mat_world_from_depth(screen_uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let ndc_xy = vec2<f32>(screen_uv.x * 2.0 - 1.0, (1.0 - screen_uv.y) * 2.0 - 1.0);
    let clip = vec4<f32>(ndc_xy, depth, 1.0);
    let view_h = frame.projection_inverse * clip;
    let w_sign = select(-1.0, 1.0, view_h.w >= 0.0);
    let view_pos = view_h.xyz / (max(abs(view_h.w), 1e-6) * w_sign);
    return (frame.view_inverse * vec4<f32>(view_pos, 1.0)).xyz;
}

struct RefractSample {
    color: vec3<f32>,
    depth: f32,
    valid: bool,
};

fn mat_surface_ndc_z(cam_pos: vec3<f32>) -> f32 {
    let clip = frame.projection * (frame.view * vec4<f32>(cam_pos, 1.0));
    return clip.z / max(clip.w, 1e-4);
}

// Depth-aware manual 2x2 bilinear sample of non-filterable opaque_color (`textureLoad` only),
// rejecting any displaced tap that lies closer to the camera than the translucent surface itself.
fn mat_sample_opaque_refracted(refr_uv: vec2<f32>, center_uv: vec2<f32>, surf_z: f32) -> RefractSample {
    let oc_dims = vec2<i32>(textureDimensions(opaque_color));
    if oc_dims.x <= 1 || oc_dims.y <= 1 {
        return RefractSample(vec3<f32>(0.0), 0.0, false);
    }
    let od_dims = vec2<i32>(textureDimensions(opaque_depth));
    let max_oc = oc_dims - vec2<i32>(1);
    let max_od = max(od_dims - vec2<i32>(1), vec2<i32>(0));

    let c_uv = clamp(center_uv, vec2<f32>(0.0005), vec2<f32>(0.9995));
    let c_coord = clamp(vec2<i32>(c_uv * vec2<f32>(oc_dims)), vec2<i32>(0), max_oc);
    let c_dcoord = clamp(vec2<i32>(c_uv * vec2<f32>(od_dims)), vec2<i32>(0), max_od);
    let c_col = max(textureLoad(opaque_color, c_coord, 0).rgb, vec3<f32>(0.0));
    let c_dep = textureLoad(opaque_depth, c_dcoord, 0);

    let r_uv = clamp(refr_uv, vec2<f32>(0.0005), vec2<f32>(0.9995));
    let r_dcoord = clamp(vec2<i32>(r_uv * vec2<f32>(od_dims)), vec2<i32>(0), max_od);
    let r_dep = textureLoad(opaque_depth, r_dcoord, 0);
    if r_dep > surf_z + 1e-5 {
        return RefractSample(c_col, c_dep, true);
    }

    let p = r_uv * vec2<f32>(oc_dims) - vec2<f32>(0.5);
    let base = vec2<i32>(floor(p));
    let f = fract(p);

    var col_sum = vec3<f32>(0.0);
    for (var y: i32 = 0; y < 2; y = y + 1) {
        let wy = select(1.0 - f.y, f.y, y == 1);
        for (var x: i32 = 0; x < 2; x = x + 1) {
            let wx = select(1.0 - f.x, f.x, x == 1);
            let tc = clamp(base + vec2<i32>(x, y), vec2<i32>(0), max_oc);
            let td_uv = (vec2<f32>(tc) + vec2<f32>(0.5)) / vec2<f32>(oc_dims);
            let tdc = clamp(vec2<i32>(td_uv * vec2<f32>(od_dims)), vec2<i32>(0), max_od);
            let tap_d = textureLoad(opaque_depth, tdc, 0);
            let tap_c = select(max(textureLoad(opaque_color, tc, 0).rgb, vec3<f32>(0.0)), c_col, tap_d > surf_z + 1e-5);
            col_sum = col_sum + tap_c * (wx * wy);
        }
    }
    return RefractSample(col_sum, r_dep, true);
}
