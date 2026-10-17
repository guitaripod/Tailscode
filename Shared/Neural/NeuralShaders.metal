#include <metal_stdlib>
using namespace metal;

constant bool kSpill [[function_constant(0)]];
constant bool kRipple [[function_constant(1)]];
constant bool kSweep [[function_constant(2)]];
constant bool kCrunch [[function_constant(3)]];
constant bool kRainbow [[function_constant(4)]];

constant bool spillOn = is_function_constant_defined(kSpill) ? kSpill : false;
constant bool rippleOn = is_function_constant_defined(kRipple) ? kRipple : false;
constant bool sweepOn = is_function_constant_defined(kSweep) ? kSweep : false;
constant bool crunchOn = is_function_constant_defined(kCrunch) ? kCrunch : false;
constant bool rainbowOn = is_function_constant_defined(kRainbow) ? kRainbow : false;

constexpr sampler neuralSampler(
    coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);

/// What the interior pass reads, byte for byte `NeuralInteriorUniforms` in NeuralUniforms.swift.
/// Colours are linear RGB; every point is in texture space (0 to 1, y down).
struct NeuralInteriorUniforms {
    float4 tone[13];
    float4 intensity[4];
    float4 background;
    float4 sweepTone;
    float4 crunchZones[3];
    float2 act;
    float time;
    float ripple;
    float aspect;
    float sweep;
    float sweepAmount;
    float crunch;
};

/// What the front pass reads, byte for byte `NeuralFrontUniforms` in NeuralUniforms.swift.
struct NeuralFrontUniforms {
    float4 tone[13];
    float4 intensity[4];
    float2 center;
    float chassisScale;
    float glassScale;
    float fade;
    float time;
    float effort;
    float hollow;
    float ribs;
    float pad0;
    float pad1;
    float pad2;
};

/// What both vertex stages read, byte for byte `NeuralVertexUniforms` in NeuralUniforms.swift.
/// A point in the 640 by 420 design space becomes `point * clipScale + clipOffset`.
struct NeuralVertexUniforms {
    float4 rect;
    float2 clipScale;
    float2 clipOffset;
    float2 designSize;
    float2 pad;
};

struct NeuralDomeVertexIn {
    float2 position [[attribute(0)]];
};

struct NeuralVarying {
    float4 position [[position]];
    float2 uv;
};

/// A design-space point as the varying a fragment stage reads: clip position and texture uv.
static NeuralVarying neuralVarying(float2 point, constant NeuralVertexUniforms &v) {
    NeuralVarying out;
    out.position = float4(point * v.clipScale + v.clipOffset, 0.0, 1.0);
    out.uv = point / v.designSize;
    return out;
}

/// The dome's triangle list, one vertex per attribute-0 float2 in design space.
vertex NeuralVarying neuralDomeVertex(
    NeuralDomeVertexIn in [[stage_in]], constant NeuralVertexUniforms &v [[buffer(1)]]) {
    return neuralVarying(in.position, v);
}

/// A four-vertex triangle strip over `rect` (x, y, width, height in design space): the eye, ear
/// and rib region alone, a zone, or the whole design.
vertex NeuralVarying neuralQuadVertex(
    uint vertexID [[vertex_id]], constant NeuralVertexUniforms &v [[buffer(1)]]) {
    float2 corner = float2(float(vertexID & 1u), float(vertexID >> 1));
    return neuralVarying(v.rect.xy + corner * v.rect.zw, v);
}

/// Where the compaction pulls a point toward: the nearest of the six zone centres, so the
/// galaxies draw in while the rest of the head holds.
static float2 crunchUv(constant NeuralInteriorUniforms &u, float2 uv) {
    if (!crunchOn || u.crunch <= 0.0) return uv;
    float2 best = u.crunchZones[0].xy;
    float bestDistance = 1e9;
    for (int index = 0; index < 6; index++) {
        float4 pair = u.crunchZones[index >> 1];
        float2 zone = (index & 1) != 0 ? pair.zw : pair.xy;
        float2 delta = (uv - zone) * float2(u.aspect, 1.0);
        float distance = dot(delta, delta);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = zone;
        }
    }
    return best + (uv - best) * (1.0 + 0.7 * u.crunch);
}

/// The outward wave the fibres carry, one at rest when the ripple is compiled out.
static float rippleGain(constant NeuralInteriorUniforms &u, float2 uv) {
    if (!rippleOn) return 1.0;
    float distance = length((uv - u.act) * float2(u.aspect, 1.0));
    return 1.0 + u.ripple * 0.45 * sin(distance * 38.0 - u.time * 3.2);
}

/// The eight interior channels lit by their tone and intensity: `a` holds think, sense, act and
/// shell, `b` delegate, say, link and star; only the links ride the ripple.
static float3 interiorChannels(
    constant NeuralInteriorUniforms &u, float4 a, float4 b, float ripple) {
    return a.r * u.tone[0].rgb * u.intensity[0].x + a.g * u.tone[1].rgb * u.intensity[0].y
        + a.b * u.tone[2].rgb * u.intensity[0].z + a.a * u.tone[3].rgb * u.intensity[0].w
        + b.r * u.tone[4].rgb * u.intensity[1].x + b.g * u.tone[5].rgb * u.intensity[1].y
        + b.b * ripple * u.tone[6].rgb * u.intensity[1].z
        + b.a * u.tone[7].rgb * u.intensity[1].w;
}

/// The band of light that crosses the dome while the head retries, connects or compacts.
static float3 sweepLight(constant NeuralInteriorUniforms &u, float2 uv, float coverage, float luma) {
    if (!sweepOn) return float3(0.0);
    float x = (uv.x * 0.9 + (1.0 - uv.y) * 0.35 - u.sweep) * 7.0;
    float band = exp(-(x * x));
    return u.sweepTone.rgb * band * u.sweepAmount * (0.14 * coverage + min(luma * 1.2, 1.0));
}

/// The interior: the page under the glass, then the channels' light added on top by screen
/// blend. The dome is drawn from its mesh and the dive does not move it.
fragment float4 neuralInteriorFragment(
    NeuralVarying in [[stage_in]], constant NeuralInteriorUniforms &u [[buffer(0)]],
    texture2d<float> interior [[texture(0)]], texture2d<float> m0 [[texture(1)]],
    texture2d<float> m1 [[texture(2)]], texture2d<float> b0 [[texture(3)]],
    texture2d<float> b1 [[texture(4)]]) {
    float2 uv = in.uv;
    float4 color = interior.sample(neuralSampler, uv);
    float3 base = mix(u.background.rgb, color.rgb, color.a);
    float2 glowUv = crunchUv(u, uv);
    float ripple = rippleGain(u, uv);
    float3 glow = interiorChannels(
                      u, m0.sample(neuralSampler, glowUv), m1.sample(neuralSampler, glowUv), ripple)
            * 4.0
        + interiorChannels(
              u, b0.sample(neuralSampler, glowUv), b1.sample(neuralSampler, glowUv), ripple)
            * (6.0 / 3.0);
    float luma = dot(glow, float3(0.3, 0.5, 0.2));
    float3 add = glow + sweepLight(u, uv, color.a, luma);
    add = add / (1.0 + 0.2 * add);
    float3 result = 1.0 - (1.0 - base) * (1.0 - clamp(add, 0.0, 1.0));
    return float4(result, 1.0);
}

/// The sRGB transfer curve, to find how much alpha a stored colour needs: the surface holds the
/// encoded colour premultiplied, and a colour above its own alpha is not a valid premultiplied
/// pixel for the compositor.
static float srgbEncode(float value) {
    float clamped = clamp(value, 0.0, 1.0);
    return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055;
}

/// The dive's zoom about the centre: a point in the output is read from this one.
static float2 diveUv(float2 uv, float2 center, float scale) {
    return (uv - center) / scale + center;
}

/// A cosine rainbow along `x`, the ultracode eye.
static float3 rainbow(float x) {
    return 0.5 + 0.5 * cos(6.2831853 * (x + float3(0.0, 0.33, 0.67)));
}

/// The front's four channel groups lit at `uv`: `m` holds seam, eye, rib and ear. The eye's five
/// visor segments, the rainbow and the lit neck ribs are read off the position in design space.
static float3 frontChannels(constant NeuralFrontUniforms &u, float4 m, float2 uv) {
    float xDesign = uv.x * 640.0;
    float yDesign = uv.y * 420.0;
    float segment = clamp(floor((xDesign - 562.0) / 8.2), 0.0, 4.0);
    float lit = segment < u.effort ? 1.0 : (u.hollow > 0.5 ? 0.1 : 0.14);
    float3 eye = u.tone[9].rgb;
    if (rainbowOn) eye = rainbow(uv.x * 5.0 - u.time * 0.3);
    float rib = clamp(floor((yDesign - 381.0) / 6.0), 0.0, 5.0);
    float ribLit = clamp(u.ribs - (5.0 - rib), 0.0, 1.0);
    return m.r * u.tone[8].rgb * u.intensity[2].x * 2.0
        + m.g * eye * u.intensity[2].y * lit * 4.0
        + m.b * u.tone[10].rgb * u.intensity[2].z * ribLit * 3.0
        + m.a * u.tone[11].rgb * u.intensity[2].w * 3.0;
}

/// The front: the chassis, the eye, ear and rib glow over it, and the glass on top, written
/// premultiplied. Over a dark page the glow may spill past the chassis and lends it alpha, and
/// the alpha is never less than the encoded colour it carries, which is what the CPU compositor
/// writes too.
fragment float4 neuralFrontFragment(
    NeuralVarying in [[stage_in]], constant NeuralFrontUniforms &u [[buffer(0)]],
    texture2d<float> chassis [[texture(0)]], texture2d<float> glass [[texture(1)]],
    texture2d<float> m2 [[texture(2)]], texture2d<float> b2 [[texture(3)]]) {
    float2 chassisUv = diveUv(in.uv, u.center, u.chassisScale);
    float2 glassUv = diveUv(in.uv, u.center, u.glassScale);
    float4 ch = chassis.sample(neuralSampler, chassisUv);
    float3 glow = frontChannels(u, m2.sample(neuralSampler, chassisUv), chassisUv)
        + frontChannels(u, b2.sample(neuralSampler, chassisUv), chassisUv) * (4.0 / 3.0);
    if (!spillOn) glow *= ch.a;
    glow = glow / (1.0 + 0.2 * glow);
    float spillAlpha = 0.0;
    if (spillOn) spillAlpha = clamp(max(glow.r, max(glow.g, glow.b)), 0.0, 1.0);
    float3 color = (ch.rgb * ch.a + glow) * u.fade;
    float alpha = clamp(ch.a + spillAlpha, 0.0, 1.0) * u.fade;
    float4 gs = glass.sample(neuralSampler, glassUv);
    float glassAlpha = gs.a * (1.0 - 0.8 * (1.0 - u.fade));
    color = clamp(color * (1.0 - glassAlpha) + gs.rgb * glassAlpha, 0.0, 1.0);
    alpha = alpha * (1.0 - glassAlpha) + glassAlpha;
    float brightest = max(color.r, max(color.g, color.b));
    return float4(color, max(clamp(alpha, 0.0, 1.0), srgbEncode(brightest)));
}

/// The retained front copied into a drawable: one texel per pixel, the premultiplied colour and
/// its alpha carried across unchanged. Reading an sRGB texture linearises it and writing an sRGB
/// target encodes it again, which returns the same byte.
fragment float4 neuralCopyFragment(
    NeuralVarying in [[stage_in]], texture2d<float, access::read> source [[texture(0)]]) {
    uint2 pixel = uint2(in.position.xy);
    return source.read(pixel);
}
