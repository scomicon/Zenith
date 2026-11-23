# Zenith

A shader pack for [Horizon](https://github.com/horizon-rust/horizon), shader API 0.2. MIT licensed, written clean-room (`PROVENANCE.md` at the repository root).

## Layout

| Path | What |
|---|---|
| `horizon-shaders.toml` | manifest, options, pages, post chain |
| `shared/common.wgsl` | `zn_*` helpers, included before every stage |
| `post/*.wgsl` | GTAO, volumetric light, compose, screen-space reflections (`ssr.wgsl`), End warp rift, bloom pyramid, anti-aliasing, grade |
| `sky/sky.wgsl`, `weather/weather.wgsl`, `tonemap/tonemap.wgsl` | physical sky, rain and snow, tone curve |
| `material/material.wgsl` (+ files named in the manifest), `entity/entity.wgsl`, `vertex/vertex.wgsl` | surfaces, entities, vertex motion, `[shadow]` extras, `[[materials]]` / `[[tags]]` / `[[lights]]` / `[[particle_lights]]` |

The manifest names those files; `horizon-shader check` fails until they all exist. A pack folder must hold only the
manifest, the WGSL files and textures it declares, `README.md`, `LICENSE` and `icon.png`.

## Requirements and installing

**Target build: Horizon `nightly-2026-11-21` (`8f83e5c`, final Shader API `0.2`) or a compatible newer build.** Pack-owned underwater fog uses
`[frame] fog = "pack"`, and terrain surfaces use zero-overhead `shaded_tint`. The pack uses final API `0.2` stage tables and fields:

- `[entity]` - the game draws entities through that stage since the 2026-11-13 build; a build that does not draw it
  refuses the whole pack ("the [entity] stage isn't drawn yet: leave it out").
- `[frame] fog = "pack"` lets Zenith retain more distant underwater detail. Material and entity stages apply
  the same fog; air, lava, powder snow and vision effects keep vanilla's fog behaviour.
- On the nightly `9f42064` the same pack is refused with "Shader pack zenith refused: entity/entity.wgsl is not used by
  any stage or in shared": that build skips the `[entity]` table, so its file looks unused. The cause is the old
  client, not the pack; start a `c07bfa7`-or-newer client.
- `[material] coverage` - the same build added the key (API 0.2 breaking change); older builds call it an unknown field.
- more than 4 post `output`s - the current API allows 16 outputs, 12 post passes and a total of 6 render-size
  `rgba16float` targets; the 2026-11-13 build stops at 4 outputs, so the 5-output post chain below needs a newer one.
- API 0.2 packs drew only behind an environment switch in builds before 2026-11-13. **No build from 2026-11-13 on
  needs one**: nothing has to be set in the environment or on the command line.

To install:

1. Copy the `pack/zenith` folder to `%APPDATA%\horizon\shaderpacks\zenith`, so that
   `%APPDATA%\horizon\shaderpacks\zenith\horizon-shaders.toml` is the manifest. Copy the folder as it is: the manifest
   names every file the folder holds, and a build that finds a WGSL the manifest does not name refuses the pack.
2. Start the game, open the shader pack screen and pick **Zenith**. `quality_mode` selects Performance, Balanced or
   Quality; every other option is described in its tooltip.
3. If the pack does not load, `%APPDATA%\horizon\logs\latest.log` reports the exact reason.

If the game is older than the target build, update it first: the pack cannot be made to load on it by editing files.
Hot reload keeps the last good pack when an edit fails to build, so the shader pack screen and log remain the authority.

## Names

- `zn_*` is the public API of `shared/common.wgsl`: `zn_luma`, `zn_saturate3`, `zn_hash21`, `zn_hash22`, `zn_noise2`,
  `zn_fbm2`, `zn_ign`, `zn_pow5`, `zn_fresnel_schlick`, `zn_remap`. Their signatures do not change.
- `zn_i_*` is internal to `common.wgsl`. Do not call it and do not define such a name.
- `zn_celestial_weights(sun_height, moon_height)` gives each body's direct-light weight; a body at or below the horizon contributes zero. Twilight colour belongs to sky/ambient, never to the opposite body's highlights.
- `common.wgsl` declares no constants, bindings or overrides. Define your own constants with a prefix of your
  own (`zp_` / `ZP_` is taken by `post/`; `zs_` for sky, `zw_` weather, `zt_` tonemap, `zm_` material,
  `ze_` entity, `zv_` vertex are suggested). Never start a name with `horizon_` and avoid WGSL's reserved words
  (`target`, `filter`, `shared`, `pass`, `common`, `type`, `set`, ...).
- `zn_luma` uses BT.709 weights. Where the primaries could differ, use `dot(c, frame.luminance)`.

## Options: who declares the `override`

Every option in the manifest must be an `override` of its type in some stage (the same name and type may be declared in
several stages). A `choice` is a `u32` holding the index of the value. `shadows_enabled`, `shadow_resolution` and
`shadow_distance` are read by the `[shadow]` table and need no `override`. `tools/manifest-check` checks option bindings against the manifest.

| Option | Type | Declared in |
|---|---|---|
| `quality_mode` | choice (Performance, Balanced, Quality) | `post/gtao.wgsl`, `post/volumetric.wgsl`, `post/compose.wgsl`, `post/ssr.wgsl`, `post/end_rift.wgsl` |
| `ssr_enabled` | bool | `post/ssr.wgsl` |
| `contact_shadows` | bool | `post/compose.wgsl` |
| `ao_strength` | f32 | `post/gtao.wgsl`, `post/compose.wgsl` |
| `volumetric_light` | f32 | `post/volumetric.wgsl`, `post/compose.wgsl` |
| `bloom` | f32 | `post/bloom_down_a.wgsl`, `post/bloom_wide.wgsl`, `post/grade.wgsl` |
| `fxaa` | bool | `post/fxaa.wgsl` |
| `morphological_aa` | bool | `post/smaa_edges.wgsl`, `post/smaa_weights.wgsl`, `post/fxaa.wgsl`; experimental alternative with Edge smoothing enabled |
| `color_mood`, `lens_flare`, `depth_of_field`, `focus_distance`, `camera_motion_blur` | choice, f32, f32, f32, f32 | Image options in `post/optics.wgsl`; `compute/optics_sources.wgsl` locates the flare sources |
| `temporal_ao`, `temporal_ssr`, `temporal_light` | bool | Corresponding AO, SSR, and volume passes; experimental, off by default |
| `saturation` | f32 | `post/grade.wgsl` |
| `clouds`, `cloud_coverage`, `cirrus_clouds`, `aurora`, `sky_saturation` | bool, f32, bool, bool, f32 | `sky/sky.wgsl`, `material/common_local.wgsl`, `entity/entity.wgsl` (`clouds`, `cloud_coverage`) |
| `quality_mode` | choice | Performance, Balanced (default), Quality, Ultra. Ultra raises every sample count (GTAO, SSR, SSS, contact shadows, sun shafts, clouds, End rift; in Zenith RT also the GI and penumbra rays) and bakes the clouds at full resolution, regardless of cost; pair it with Shadow Resolution 8192 and Shadow Distance 384-512. |
| `atmospheric_fog` | f32 | Sky settings, default 1.0; density of the shared haze medium (`shared/fog.wgsl`): aerial perspective over terrain, LODs and the horizon, valley fog (thickest at dawn, in rain and humid biomes), and biome-dependent outdoor light. `volumetric.wgsl` scatters sunlight through the same medium (shafts, glow around a low sun). `compute/climate.wgsl` smooths climate changes while walking. |
| `auto_exposure`, `histogram_exposure`, `exposure_bias` (EV), `tonemap_curve` | bool, bool, f32, choice (Soft, Neutral, Contrast, AgX) | Histogram and adaptation in `compute/`, adaptive gain in `post/grade.wgsl`, manual EV and optional legacy eye-light adaptation in `tonemap/tonemap.wgsl` |
| `underwater_clarity` | f32 | `shared/fog.wgsl`; Water settings, default 1.8 |
| `end_rift`, `end_rift_speed` | bool, f32 | `post/end_rift.wgsl`, `shared/rift_source.wgsl`, `material/lighting.wgsl`, `entity/entity.wgsl`; The End settings |
| `shadows_enabled`, `shadow_filter_quality`, `shadow_softness`, `shadow_pcss`, `cloud_shadows`, `colored_shadows`, lighting (`procedural_pbr`, `pbr_pom`, `pom_depth`, `pbr_displacement`, `displacement_cells`, etc.) and water options (`water_refraction`, `glass_refraction`, etc.) | | `material/common_local.wgsl`, `[displacement]`, `entity/entity.wgsl`, `post/volumetric.wgsl` (`colored_shadows`) |
| `waving_foliage`, `waving_water`, `wind_strength` | bool, bool, f32 | `vertex/vertex.wgsl` |

POM and its self-shadows use LabPBR height maps. Without a height map, Zenith keeps the engine's filtered
colour sample and uses procedural micro-normals and cavity shading for relief. At sprite borders the POM
shift fades out instead of wrapping to the opposite edge.

## Post chain

12 raster passes, three compute dispatches and six kept textures. Render-relative targets count as 4.375 of the
6 equivalents the API allows. The fixed-size AO and volumetric histories use 960×540, half of the 1080p target;
they keep this size when the player changes render resolution. Fixed kept textures total about 16 MiB, including
both history copies. `previous` advances at compose; SSR writes only its contribution to `zp_reflection`, which
`end_rift.wgsl` adds before drawing the End warp
portal when `frame.dimension == 1` before `bloom_down_a`.

| # | File | Writes | Reads |
|---|---|---|---|
| 1 | `gtao.wgsl` | `ao` (960×540): r visibility, g distance, b normal key, a validity and medium | depth, surface, `ao_previous` |
| 2 | `volumetric.wgsl` | `vlight` (960×540): rgb in-scattered light, a history depth | depth, shadow map, surface, `vlight_previous` |
| 3 | `compose.wgsl` | chain | `previous`, `ao`, `vlight`, `depth`, `scene_surface`, `shadow_map` |
| 4 | `ssr.wgsl` | `zp_reflection`: signed RGB contribution and history depth | `previous`, depth, surface, `zp_reflection_previous` |
| 5 | `end_rift.wgsl` | chain | `previous`, `zp_reflection`, depth |
| 6 | `compute/exposure_histogram.wgsl` | `zp_luma_tiles` | `previous` |
| 7 | `compute/exposure_resolve.wgsl` | `zp_shared[0]` (exposure) | `zp_luma_tiles`, last frame's `zp_shared[0]` |
| 8 | `bloom_down_a.wgsl` | `bloom_a` (1/2) | `scene_color` (`previous` in The End) |
| 9 | `bloom_down_b.wgsl` | `bloom_b` (1/4) | `bloom_a` |
| 10 | `bloom_wide.wgsl` | `bloom_wide` (1/4) | `bloom_b` |
| 11 | `smaa_edges.wgsl` | `zp_edges` | `previous` |
| 12 | `smaa_weights.wgsl` | `zp_edge_weights` | `zp_edges` |
| 13 | `fxaa.wgsl` | chain | `previous`, `zp_edge_weights` in morphological mode |
| 14 | `compute/optics_sources.wgsl` | `zp_shared[1..3]` (flare sources) | anti-aliased scene, depth, and surface metadata |
| 15 | `grade.wgsl` | window | `previous`, depth and surface, bloom pyramid, `zp_shared` (exposure, optical sources) |

The bloom chain is a pyramid: `bloom_a` (1/2) and `bloom_b` (1/4) are 13-tap downsamples, `bloom_wide` is a 3x3
binomial tent with its taps spread 3 texels over `bloom_b`, and `grade.wgsl` mixes the three levels into the picture
(0.35 / 0.35 / 0.30). The first pass extracts only HDR highlights (luminance gate 1..2); grade adds their glow to
the sharp scene, so ordinary block edges and dark details do not acquire a blurred duplicate. The wide level is a pass of its own: at a 1/4 size its
9 taps run 16 times fewer times than they did when the API's 4-target limit forced it into the grade pass, and the grade
pass then reads it with one bilinear tap.

The histogram meters the composed HDR scene. It downweights extreme highlights, adapts faster toward a brighter
scene, and applies one bounded linear gain before tonemapping. Switch off Meter Exposure from Image to restore
eye-light metering, or Auto Exposure to keep only manual EV. The End retains its authored exposure.

Temporal modes use camera reprojection without projection jitter. They keep current AO sample counts and reject
history on sky, unstable surfaces, or depth mismatch. The morphology prototype estimates edge coverage without
temporal accumulation. FXAA remains the default. Volumetric light runs only in the Overworld and retains its
depth-aware tent filter before composition.

Image → **Color Mood** offers Natural, Cinematic, Warm Film, Nordic Cold, and Fantasy. Natural keeps the original
color. **Lens Flare** adds a horizontal streak and soft reflections for the visible sun and entry rift; a beacon
needs a visible base and detectable beam contrast. **Depth of Field** focuses at the crosshair with Focus Distance
set to zero, or at a fixed distance in blocks. **Camera Motion Blur** follows camera movement on stable terrain;
without entity motion vectors it does not track independent mob motion. Flare and both blur effects start off.

## Validation

Validate the base pack and the generated Zenith RT variant with Horizon's shader checker:

```sh
horizon-shader check pack/zenith
node tools/build-zenith-rt.mjs outputs/zenith-rt/zenith_rt
horizon-shader check outputs/zenith-rt/zenith_rt
```

## Added options

| Option | Type | Used by |
|---|---|---|
| `ssr_glossy` | bool | `post/ssr.wgsl` (roughness cone and contact-hardening blur) |
| `body_sss` | bool | `material/lighting.wgsl` (skin, wax, snow, ice and other LabPBR subsurface materials; also gates the screen-space diffusion in `post/sss_screen.wgsl`) |
| `engine_shadows` | bool | `material/shadows.wgsl` (`mat_engine_shadows`, used by `material/lighting.wgsl` and `material/water.wgsl`), `entity/entity.wgsl`, `post/compose.wgsl` (turns contact shadows off) |

**Zenith Engine Shadows** (`engine_shadows`, off by default) hands the sun's shadows near the camera to the [Zenith Engine](https://github.com/scomicon/zenith-engine) mod, a native Horizon mod that traces them through its own voxel copy of the world and multiplies them into the picture. Within 96 blocks of the camera the pack lights sunward surfaces as unshadowed (only cloud shadows stay), from 96 to 120 blocks its own shadows fade back in, and contact shadows are off. Surfaces facing away from the sun and those with no sky light keep the pack's shading, since the mod skips both. The mod reads this option from the pack's saved values and turns its shadows on with it; without the mod, nearby terrain has no sun shadows. Zenith RT gets the same option: its traced shadows give way to the mod's in the same range.

Hi-Z depth (`post/hiz.wgsl`, a compute pass) is built whenever `ssr_enabled` is on. Each 8x8 workgroup reduces its 10x10 depth tiles once into workgroup memory and takes each cell's 3x3 from there (about 0.24 ms at 1080p on an RX 7600, was 1.2 ms). It has no option of its own because a pack may declare only 64 options.

The volumetric clouds (`sky/clouds.wgsl`) are marched once a frame by a `[[before_world]]` compute pass (`compute/cloud_bake.wgsl`) into `zp_clouds`, a half-resolution map of the view with an 8% margin, and the sky stage reads it with a bilinear lookup by direction. The map is indexed through the frame's own projection and view, so a sky pixel always finds the texel baked for its own ray, view bob included. With no sky light at the eye (caves) the bake is skipped, and a sky pixel seen from there marches its own ray as before. The two-tap sun march through the clouds is always on; it reads only the two coarse octaves of the cloud map. Exposure and the three lens-flare sources share one 64-byte buffer, `zp_shared`, which frees the resource slot the cloud map needs (a pack may declare 8).
