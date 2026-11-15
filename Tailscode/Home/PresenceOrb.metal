#include <metal_stdlib>
using namespace metal;

struct OrbUniforms {
    float2 size;
    int blobCount;
    int stopCount;
    float4 color;
    float4 params;
    float4 look;
    float4 blobs[8];
    float4 stops[8];
};

struct OrbVarying {
    float4 position [[position]];
    float2 unit;
};

static float orb_smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

static float orb_field(constant OrbUniforms &uniforms, float2 p) {
    float d = 1000.0;
    for (int i = 0; i < 8; i++) {
        if (i >= uniforms.blobCount) break;
        float part = length(p - uniforms.blobs[i].xy) - uniforms.blobs[i].z;
        d = orb_smin(d, part, 0.19);
    }
    return d;
}

static float3 orb_rainbow(constant OrbUniforms &uniforms, float t) {
    float span = t * float(uniforms.stopCount - 1);
    int low = int(floor(span));
    int high = low + 1 < uniforms.stopCount ? low + 1 : uniforms.stopCount - 1;
    return mix(uniforms.stops[low].rgb, uniforms.stops[high].rgb, fract(span));
}

vertex OrbVarying orb_vertex(uint id [[vertex_id]], constant OrbUniforms &uniforms [[buffer(0)]]) {
    float2 corner = float2(float((id & 1) << 2) - 1.0, float((id & 2) << 1) - 1.0);
    OrbVarying out;
    out.position = float4(corner, 0.0, 1.0);
    out.unit = corner * uniforms.size / min(uniforms.size.x, uniforms.size.y);
    return out;
}

/// The field is a smooth-min union of the circles Core handed over, lit as one glass bead: the
/// distance field's own slope is the surface normal, so the core and every satellite catch the
/// same key light from the upper left, a specular glint and a rim that brightens toward the edge,
/// with the ink glowing from inside as the body breathes. The shader adds light and nothing else:
/// no motion, no colour choice, no state lives here. `look.x` is the zoom, how much of the unit
/// space the view shows, so a small view can wear a larger body, and the glow fades out inside the
/// view's inscribed circle so a square view never shows a square edge. Output is premultiplied
/// over a clear background, so the bead floats on whatever is behind it.
fragment float4 orb_fragment(
    OrbVarying in [[stage_in]], constant OrbUniforms &uniforms [[buffer(0)]]) {
    float zoom = uniforms.look.x;
    float2 p = in.unit * zoom;
    float pixel = 2.0 * zoom / min(uniforms.size.x, uniforms.size.y);
    float energy = uniforms.params.x;
    float intensity = uniforms.params.y;
    float rainbow = uniforms.params.z;
    float d = orb_field(uniforms, p);
    float body = 1.0 - smoothstep(-0.75 * pixel, 0.75 * pixel, d);
    float3 base = uniforms.color.rgb;
    float3 accum = float3(0.0);
    float alpha = 0.0;
    if (d < pixel) {
        float e = 0.012;
        float2 slope = float2(
            orb_field(uniforms, p + float2(e, 0.0)) - orb_field(uniforms, p - float2(e, 0.0)),
            orb_field(uniforms, p + float2(0.0, e)) - orb_field(uniforms, p - float2(0.0, e)));
        float2 outward = length(slope) > 1e-5 ? normalize(slope) : float2(0.0);
        float rise = clamp(-d / 0.22, 0.0, 1.0);
        float height = sqrt(1.0 - (1.0 - rise) * (1.0 - rise));
        float3 normal = normalize(float3(outward * sqrt(max(0.0, 1.0 - height * height)), height));
        float3 light = normalize(float3(-0.48, 0.6, 0.64));
        float diffuse = max(dot(normal, light), 0.0);
        float glint = pow(max(dot(normal, normalize(light + float3(0.0, 0.0, 1.0))), 0.0), 38.0);
        float rim = pow(1.0 - normal.z, 2.4);
        float glow = smoothstep(0.0, -0.3, d) * energy * (0.55 + 0.45 * intensity);
        float3 ink = base * (0.34 + 0.62 * diffuse) * (0.72 + 0.28 * intensity);
        ink += base * glow * 0.42;
        ink += mix(base, float3(1.0), 0.35) * rim * 0.5;
        ink += float3(1.0) * glint * (0.45 + 0.35 * energy);
        accum = ink * body;
        alpha = body;
    }
    float reach = 1.0 - smoothstep(0.6, 0.98, length(in.unit));
    float halo = exp(max(d, 0.0) * -5.0) * (1.0 - body) * reach;
    float haloAlpha = halo * 0.4 * energy * intensity;
    accum += base * haloAlpha;
    alpha += haloAlpha * 0.9;
    if (rainbow > 0.001) {
        float phase = uniforms.params.w;
        float glow = uniforms.color.a;
        float angle = fract(atan2(p.y, p.x) / 6.28318530718 + 0.5 + phase);
        float ring = 1.0 - smoothstep(0.0, 0.05, abs(d + 0.01));
        float ringAlpha = ring * rainbow * glow * 0.9;
        accum += orb_rainbow(uniforms, angle) * ringAlpha;
        alpha = min(1.0, alpha + ringAlpha);
    }
    alpha = min(1.0, alpha);
    return float4(min(accum, float3(alpha)), alpha);
}
