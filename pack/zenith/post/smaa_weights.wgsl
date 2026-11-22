// src: Jimenez et al., SMAA, Eurographics 2012 (edge patterns and coverage by re-vectorization); independent analytic area approximation.

override fxaa: bool = true;
override morphological_aa: bool = false;

fn zp_edge_at(cell: vec2<i32>, dims: vec2<i32>) -> vec2<f32> {
    if any(cell < vec2<i32>(0)) || any(cell >= dims) {
        return vec2<f32>(0.0);
    }
    return textureLoad(zp_edges, cell, 0).rg;
}

fn zp_edge_end(cell: vec2<i32>, along: vec2<i32>, across: vec2<i32>, axis: u32, dims: vec2<i32>) -> vec2<f32> {
    for (var distance_px = 1; distance_px <= 12; distance_px++) {
        let next = cell + along * distance_px;
        if zp_edge_at(next, dims)[axis] < 0.5 {
            let cross = next + select(-along, vec2<i32>(0), all(along >= vec2<i32>(0)));
            let near = zp_edge_at(cross, dims)[1u - axis] > 0.5;
            let far_side = zp_edge_at(cross - across, dims)[1u - axis] > 0.5;
            return vec2<f32>(f32(distance_px) - 0.5, select(0.0, select(-0.5, 0.5, near), near != far_side));
        }
    }
    return vec2<f32>(12.5, 0.0);
}

fn zp_edge_area(cell: vec2<i32>, axis: u32, dims: vec2<i32>) -> f32 {
    let across = select(vec2<i32>(1, 0), vec2<i32>(0, 1), axis == 1u);
    let along = across.yx;
    let neg = zp_edge_end(cell, -along, across, axis, dims);
    let pos = zp_edge_end(cell, along, across, axis, dims);
    let join = select(0.0, 1.0, neg.y * pos.y < 0.0);
    var offset = mix(neg.y, pos.y, neg.x / (neg.x + pos.x));
    if join == 0.0 {
        let end = select(pos, neg, abs(neg.y) > abs(pos.y));
        let other = select(neg, pos, abs(neg.y) > abs(pos.y));
        if other.y != 0.0 {
            return 0.0;
        }
        offset = end.y * max(0.0, 1.0 - 2.0 * end.x / (end.x + other.x)) * 0.60;
    }
    return offset;
}

fn post(input: PostInput) -> vec4<f32> {
    if !fxaa || !morphological_aa {
        return vec4<f32>(0.0);
    }
    let dims = vec2<i32>(textureDimensions(zp_edges));
    let cell = min(vec2<i32>(input.uv * vec2<f32>(dims)), dims - 1);
    let edges = zp_edge_at(cell, dims);
    var west = 0.0;
    var north = 0.0;
    if edges.x > 0.5 { west = zp_edge_area(cell, 0u, dims); }
    if edges.y > 0.5 { north = zp_edge_area(cell, 1u, dims); }
    if edges.x > 0.5 && edges.y > 0.5 {
        let east_south = vec2<f32>(zp_edge_at(cell + vec2<i32>(1, 0), dims).x,
            zp_edge_at(cell + vec2<i32>(0, 1), dims).y);
        let diagonal = zp_edge_at(cell + vec2<i32>(1, -1), dims).x > 0.5 &&
            zp_edge_at(cell + vec2<i32>(-1, 1), dims).y > 0.5;
        if diagonal && all(east_south < vec2<f32>(0.5)) {
            west = max(west, 0.22);
            north = max(north, 0.22);
        }
    }
    return vec4<f32>(vec2<f32>(west, north) + 0.5, 0.0, 1.0);
}
