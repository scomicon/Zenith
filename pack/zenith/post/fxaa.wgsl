// src: Lottes 2009, FXAA white paper; Jimenez et al., SMAA, Eurographics 2012 (neighbourhood resolve); Horizon Shader API 0.2.
// Pass 7: spatial anti-aliasing of the composed picture (an FXAA-style filter).
//
// Concept: T. Lottes, "FXAA", NVIDIA white paper, 2009: find edges by local luma contrast, classify them
// as horizontal or vertical from second differences, search along the edge in both directions for its
// ends, and shift the sample position across the edge in proportion to where the pixel sits along the
// span; a separate sub-pixel term blends isolated high-contrast pixels. Written here from that
// description; the constants (contrast thresholds, sub-pixel strength, search length) are own picks.
//
// HDR: the picture is scene-referred linear light, so contrast is measured on perceptual luma
// sqrt(L / (1 + L)) (a Reinhard-compressed square root), which keeps a 100x brighter sun disc from
// swamping every other edge.
//
// The world is drawn without jitter and without the engine's own anti-aliasing while a pack's post chain
// runs (Horizon docs, "Anti-aliasing"), so this pass is what smooths edges.

override fxaa: bool = true;
override morphological_aa: bool = false;

const ZP_EDGE_MIN: f32 = 0.025;   // contrast below this is never an edge
const ZP_EDGE_REL: f32 = 0.10;    // ... nor below this fraction of the local maximum
const ZP_SUBPIX: f32 = 0.78;      // subpixel stabilization for distant foliage and thin geometry
const ZP_SEARCH: i32 = 10;        // smooth variable-stride steps along the edge (up to 14 px)
const ZP_STRIDES: array<f32, 10> = array<f32, 10>(1.0, 1.0, 1.0, 1.0, 1.0, 1.5, 1.5, 2.0, 2.0, 2.0);

fn zp_lp(uv: vec2<f32>) -> f32 {
    let c = max(textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb, vec3<f32>(0.0));
    let l = zn_luma(c);
    return sqrt(l / (1.0 + l));
}

fn zp_hdr_mix(c0: vec3<f32>, c1: vec3<f32>, t: f32) -> vec3<f32> {
    let r0 = c0 / (1.0 + min(zn_luma(c0), 1.0e4));
    let r1 = c1 / (1.0 + min(zn_luma(c1), 1.0e4));
    let r = mix(r0, r1, t);
    let lr = min(zn_luma(r), 0.9999);
    return max(r / (1.0 - lr), vec3<f32>(0.0));
}

fn zp_morphological(uv: vec2<f32>, color: vec3<f32>) -> vec3<f32> {
    let dims = vec2<i32>(textureDimensions(zp_edge_weights));
    let cell = min(vec2<i32>(uv * vec2<f32>(dims)), dims - 1);
    let east_cell = min(cell + vec2<i32>(1, 0), dims - 1);
    let south_cell = min(cell + vec2<i32>(0, 1), dims - 1);
    let here = textureLoad(zp_edge_weights, cell, 0).rg - 0.5;
    let east = select(0.0, 0.5 - textureLoad(zp_edge_weights, east_cell, 0).r, east_cell.x > cell.x);
    let south = select(0.0, 0.5 - textureLoad(zp_edge_weights, south_cell, 0).g, south_cell.y > cell.y);
    let weights = max(vec4<f32>(here.r, east, here.g, south), vec4<f32>(0.0));
    let sum = dot(weights, vec4<f32>(1.0));
    if sum <= 0.0 {
        return color;
    }
    let west_cell = max(cell - vec2<i32>(1, 0), vec2<i32>(0));
    let north_cell = max(cell - vec2<i32>(0, 1), vec2<i32>(0));
    let adjacent = textureLoad(previous, west_cell, 0).rgb * weights.x
        + textureLoad(previous, east_cell, 0).rgb * weights.y
        + textureLoad(previous, north_cell, 0).rgb * weights.z
        + textureLoad(previous, south_cell, 0).rgb * weights.w;
    return zp_hdr_mix(color, max(adjacent / sum, vec3<f32>(0.0)), min(sum, 0.55));
}

fn post(input: PostInput) -> vec4<f32> {
    let c = max(input.color.rgb, vec3<f32>(0.0));
    if (!fxaa) {
        return vec4<f32>(c, 1.0);
    }
    if morphological_aa {
        return vec4<f32>(zp_morphological(input.uv, c), 1.0);
    }
    let uv = input.uv;
    let px = 1.0 / vec2<f32>(textureDimensions(previous));

    let lc = zn_luma(c);
    let lm = sqrt(lc / (1.0 + lc));
    let ln = zp_lp(uv + vec2<f32>(0.0, -px.y));
    let ls = zp_lp(uv + vec2<f32>(0.0, px.y));
    let lw = zp_lp(uv + vec2<f32>(-px.x, 0.0));
    let le = zp_lp(uv + vec2<f32>(px.x, 0.0));

    let l_max = max(lm, max(max(ln, ls), max(lw, le)));
    let l_min = min(lm, min(min(ln, ls), min(lw, le)));
    let range = l_max - l_min;
    if (range < max(ZP_EDGE_MIN, l_max * ZP_EDGE_REL)) {
        return vec4<f32>(c, 1.0);
    }

    let lnw = zp_lp(uv + vec2<f32>(-px.x, -px.y));
    let lne = zp_lp(uv + vec2<f32>(px.x, -px.y));
    let lsw = zp_lp(uv + vec2<f32>(-px.x, px.y));
    let lse = zp_lp(uv + vec2<f32>(px.x, px.y));

    // Sub-pixel term: how far the pixel is from the average of its 3x3 neighbourhood.
    let avg = (2.0 * (ln + ls + lw + le) + (lnw + lne + lsw + lse)) / 12.0;
    var subpix = clamp(abs(avg - lm) / range, 0.0, 1.0);
    subpix = smoothstep(0.0, 1.0, subpix);
    // The End: weaker isolated-pixel blend so fine starfield and warp-rift detail stay sharp (own pick).
    subpix = subpix * subpix * select(ZP_SUBPIX, 0.28, frame.dimension == 1);

    // Edge direction: vertical second differences dominate on a horizontal edge, horizontal ones on a vertical edge.
    let edge_h = abs(lnw + lsw - 2.0 * lw) + 2.0 * abs(ln + ls - 2.0 * lm) + abs(lne + lse - 2.0 * le);
    let edge_v = abs(lnw + lne - 2.0 * ln) + 2.0 * abs(lw + le - 2.0 * lm) + abs(lsw + lse - 2.0 * ls);
    let horizontal = edge_h >= edge_v;

    // The neighbour across the edge with the steeper step is the one the edge lies against.
    let l_neg = select(lw, ln, horizontal);
    let l_pos = select(le, ls, horizontal);
    let g_neg = abs(l_neg - lm);
    let g_pos = abs(l_pos - lm);
    let neg_steeper = g_neg >= g_pos;
    let stop_at = 0.25 * max(g_neg, g_pos);
    let l_local = 0.5 * (select(l_pos, l_neg, neg_steeper) + lm);

    var step_len = select(px.x, px.y, horizontal);
    if (neg_steeper) {
        step_len = -step_len;
    }
    var start = uv;
    if (horizontal) {
        start.y = start.y + 0.5 * step_len;
    } else {
        start.x = start.x + 0.5 * step_len;
    }
    let along = select(vec2<f32>(0.0, px.y), vec2<f32>(px.x, 0.0), horizontal);

    // Walk along the edge both ways until the luma leaves the local average by `stop_at`.
    var p_neg = start - along;
    var p_pos = start + along;
    var d_neg = zp_lp(p_neg) - l_local;
    var d_pos = zp_lp(p_pos) - l_local;
    var done_neg = abs(d_neg) >= stop_at;
    var done_pos = abs(d_pos) >= stop_at;
    for (var i = 0; i < ZP_SEARCH; i = i + 1) {
        if (done_neg && done_pos) {
            break;
        }
        let step_along = along * ZP_STRIDES[i];
        if (!done_neg) {
            p_neg = p_neg - step_along;
            d_neg = zp_lp(p_neg) - l_local;
            done_neg = abs(d_neg) >= stop_at;
        }
        if (!done_pos) {
            p_pos = p_pos + step_along;
            d_pos = zp_lp(p_pos) - l_local;
            done_pos = abs(d_pos) >= stop_at;
        }
    }

    let dist_neg = select(uv.y - p_neg.y, uv.x - p_neg.x, horizontal);
    let dist_pos = select(p_pos.y - uv.y, p_pos.x - uv.x, horizontal);
    let neg_closer = dist_neg < dist_pos;
    let dist_min = min(dist_neg, dist_pos);
    let span = max(dist_neg + dist_pos, 1e-6);
    let end_delta = select(d_pos, d_neg, neg_closer);
    // Only shift if the nearer end of the edge steps the right way for this pixel; otherwise the pixel already is the edge.
    let correct_side = (end_delta < 0.0) != (lm < l_local);
    let edge_offset = select(0.0, 0.5 - dist_min / span, correct_side);

    let shift = max(edge_offset, subpix);
    var target_uv = uv;
    if (horizontal) {
        target_uv.y = target_uv.y + shift * step_len;
    } else {
        target_uv.x = target_uv.x + shift * step_len;
    }
    let rgb_sdr = max(textureSampleLevel(previous, linear_sampler, target_uv, 0.0).rgb, vec3<f32>(0.0));
    let hdr_w = smoothstep(0.78, 0.90, l_max);
    if (hdr_w > 0.001) {
        let step_vec = select(vec2<f32>(step_len, 0.0), vec2<f32>(0.0, step_len), horizontal);
        let c_step = max(textureSampleLevel(previous, linear_sampler, uv + step_vec, 0.0).rgb, vec3<f32>(0.0));
        return vec4<f32>(mix(rgb_sdr, zp_hdr_mix(c, c_step, shift), hdr_w), 1.0);
    }
    return vec4<f32>(rgb_sdr, 1.0);
}
