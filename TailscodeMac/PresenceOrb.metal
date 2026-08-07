#include <metal_stdlib>
using namespace metal;

struct OrbUniforms {
    float2 size;
    int blobCount;
    int stopCount;
    float4 color;
    float4 params;
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

/// The field is a smooth-min union of the circles Core handed over — the shader rasterises the
/// frame and adds nothing: no motion, no colour choice, no state lives here. Output is
/// premultiplied over a clear background, so the orb floats on whatever canvas is behind it.
fragment float4 orb_fragment(
    OrbVarying in [[stage_in]], constant OrbUniforms &uniforms [[buffer(0)]]) {
    float2 p = in.unit;
    float energy = uniforms.params.x;
    float intensity = uniforms.params.y;
    float rainbow = uniforms.params.z;
    float d = 1000.0;
    for (int i = 0; i < 8; i++) {
        if (i >= uniforms.blobCount) break;
        float part = length(p - uniforms.blobs[i].xy) - uniforms.blobs[i].z;
        d = orb_smin(d, part, 0.19);
    }
    float body = 1.0 - smoothstep(-0.008, 0.012, d);
    float depth = smoothstep(0.0, -0.34, d);
    float3 ink = uniforms.color.rgb * mix(1.08, 0.72, depth) * (0.6 + 0.4 * intensity);
    float halo = exp(max(d, 0.0) * -5.5) * (1.0 - body);
    float haloAlpha = halo * 0.36 * energy * intensity;
    float3 accum = ink * body + uniforms.color.rgb * haloAlpha;
    float alpha = body + haloAlpha * 0.9;
    if (rainbow > 0.001) {
        float phase = uniforms.params.w;
        float glow = uniforms.color.a;
        float angle = fract(atan2(p.y, p.x) / 6.28318530718 + 0.5 + phase);
        float rim = 1.0 - smoothstep(0.0, 0.05, abs(d + 0.01));
        float rimAlpha = rim * rainbow * glow * 0.9;
        accum += orb_rainbow(uniforms, angle) * rimAlpha;
        alpha = min(1.0, alpha + rimAlpha);
    }
    return float4(accum, min(1.0, alpha));
}
