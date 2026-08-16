#include <metal_stdlib>
using namespace metal;

/// Every number the effect is made of, handed over once a frame. Nothing about the look is decided
/// in this file: the constants are `AuroraField`'s and `StreamCascade`'s, the clock is the
/// display's, and the shader rasterises the frame and adds no motion, no colour and no state of
/// its own — the same contract the presence orb's shader keeps.
struct AuroraUniforms {
    float4 edge;
    float4 spark;
    float4 nib;
    float2 regionSize;
    float2 inkSize;
    float progress;
    float span;
    float phase;
    float time;
    float entry;
    float entryFloor;
    float shimmerWidth;
    float shimmerReach;
    float shimmerPeak;
    float landing;
    float riseHeight;
    float contraction;
    float tilt;
    float dispersionReach;
    float dispersionDepth;
    float bloomLevel;
    float bloomRadius;
    float bloomPeak;
    float emberReach;
    float emberDensity;
    float emberLife;
    float emberDrift;
    float nibGlow;
    float margin;
    float intensity;
    float motion;
};

/// One character of the answer as geometry: where it was laid out, how tall its line is, and which
/// character of the whole rendered string it is — which is all the wave needs, since distance
/// behind the leading edge is the only clock this effect has.
struct AuroraQuad {
    float4 rect;
    float2 facts;
};

struct AuroraVarying {
    float4 position [[position]];
    float2 source;
    float4 rect [[flat]];
    float distance [[flat]];
    float seed [[flat]];
    float height [[flat]];
};

struct AuroraNibVarying {
    float4 position [[position]];
    float2 local;
};

static float aurora_linear(float channel) {
    return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4);
}

static float aurora_encode(float channel) {
    return channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1.0 / 2.4) - 0.055;
}

/// OKLab, because lightness has to move without dragging the hue with it — the same reason and the
/// same coefficients as `Contrast.OKLab`, so the walk from prose colour to accent this shader makes
/// is the walk the settled renderer makes on the same two colours. A midpoint that goes grey on one
/// of them is a drift nobody notices until two screenshots sit side by side.
static float3 aurora_to_oklab(float3 rgb) {
    float3 lin = float3(aurora_linear(rgb.r), aurora_linear(rgb.g), aurora_linear(rgb.b));
    float3 lms = float3(
        dot(float3(0.4122214708, 0.5363325363, 0.0514459929), lin),
        dot(float3(0.2119034982, 0.6806995451, 0.1073969566), lin),
        dot(float3(0.0883024619, 0.2817188376, 0.6299787005), lin));
    lms = pow(max(lms, 0.0), 1.0 / 3.0);
    return float3(
        dot(float3(0.2104542553, 0.7936177850, -0.0040720468), lms),
        dot(float3(1.9779984951, -2.4285922050, 0.4505937099), lms),
        dot(float3(0.0259040371, 0.7827717662, -0.8086757660), lms));
}

static float3 aurora_from_oklab(float3 lab) {
    float3 lms = float3(
        lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z,
        lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z,
        lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z);
    lms = lms * lms * lms;
    float3 lin = clamp(
        float3(
            dot(float3(4.0767416621, -3.3077115913, 0.2309699292), lms),
            dot(float3(-1.2684380046, 2.6097574011, -0.3413193965), lms),
            dot(float3(-0.0041960863, -0.7034186147, 1.7076147010), lms)),
        0.0, 1.0);
    return float3(aurora_encode(lin.r), aurora_encode(lin.g), aurora_encode(lin.b));
}

static float3 aurora_blend(float3 one, float3 other, float amount) {
    if (amount <= 0.001) { return one; }
    return aurora_from_oklab(
        mix(aurora_to_oklab(one), aurora_to_oklab(other), clamp(amount, 0.0, 1.0)));
}

static float aurora_hash(float seed) {
    return fract(sin(seed * 12.9898) * 43758.5453);
}

/// The glyph's own character, from its position in the answer — `AuroraField.wobble`, so a row that
/// scrolls away and comes back lands exactly the way it was going to.
static float aurora_wobble(float index) {
    return fract(index * 0.6180339887 + 0.31) * 2.0 - 1.0;
}

/// Ease-out, shared with the transcript's entrances so the whole product lands on one curve.
static float aurora_ease(float t) {
    float inverse = 1.0 - clamp(t, 0.0, 1.0);
    return 1.0 - inverse * inverse * inverse;
}

/// `StreamCascade.sample`, glyph by glyph: heat toward the accent, the specular band travelling
/// back on its own clock, and the entry fade. The settled renderer computes exactly this on the
/// main thread twenty-six times a frame; here it is six lines of a stage that runs anyway.
///
/// The fractional tail below zero is the alpha renderer's own: the reveal is published
/// sub-character (`StreamCadence.progress`) because this hand moves the edge itself, and a
/// character that snapped from nothing to its entry floor would put a step back into the one effect
/// whose entire purpose is to not have one.
static float3 aurora_wave(float distance, constant AuroraUniforms &uniforms) {
    float far = max(distance, 0.0);
    float normalized = min(1.0, far / max(uniforms.span, 1.0));
    float heat = pow(1.0 - normalized, 2.2);
    float centre = uniforms.shimmerReach * uniforms.phase;
    float offset = (far - centre) / uniforms.shimmerWidth;
    float band = exp(-0.5 * offset * offset);
    float fade = 1.0 - min(1.0, far / uniforms.shimmerReach);
    float glow = band * fade * fade * uniforms.shimmerPeak;
    float entered = min(1.0, pow((far + 0.6) / uniforms.entry, 0.8));
    float alpha = uniforms.entryFloor + (1.0 - uniforms.entryFloor) * entered;
    if (distance < 0.0) { alpha *= max(0.0, 1.0 + distance); }
    return float3(heat, glow, alpha);
}

/// A character's quad, padded so the light it sheds has somewhere to land, and moved through the
/// last fraction of its own arrival.
///
/// The transform is affine and applied to the corners, so interpolating the *untransformed* corner
/// across the drawn quad is an exact inverse: the fragment stage reads the ink from where the glyph
/// was actually laid out, whatever the vertex stage did with it. And none of it touches layout —
/// the paragraph was measured when it arrived and is never measured again, which is the whole
/// reason a reveal this fine is affordable.
vertex AuroraVarying aurora_glyph_vertex(
    uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
    constant AuroraQuad *quads [[buffer(0)]], constant AuroraUniforms &uniforms [[buffer(1)]]) {
    AuroraQuad quad = quads[instanceID];
    float index = quad.facts.x;
    float height = max(quad.facts.y, 1.0);
    float distance = uniforms.progress - 1.0 - index;

    AuroraVarying out;
    out.rect = quad.rect;
    out.distance = distance;
    out.seed = index;
    out.height = height;

    if (distance < -1.0) {
        out.position = float4(0.0, 0.0, 2.0, 1.0);
        out.source = float2(-1.0, -1.0);
        return out;
    }

    float margin = uniforms.margin * height;
    float2 corner = float2(float(vertexID & 1), float((vertexID >> 1) & 1));
    float2 padded = float2(quad.rect.x - margin, quad.rect.y - margin)
        + corner * float2(quad.rect.z + margin * 2.0, quad.rect.w + margin * 2.0);
    out.source = padded;

    float2 moved = padded;
    if (uniforms.motion > 0.5) {
        float remaining = 1.0 - aurora_ease(min(1.0, max(distance, 0.0) / uniforms.landing));
        float2 pivot = float2(quad.rect.x + quad.rect.z * 0.5, quad.rect.y + quad.rect.w);
        float2 local = padded - pivot;
        float angle = remaining * uniforms.tilt * aurora_wobble(index);
        float sine = sin(angle);
        float cosine = cos(angle);
        local = float2(local.x * cosine - local.y * sine, local.x * sine + local.y * cosine);
        local *= 1.0 - remaining * uniforms.contraction;
        moved = local + pivot;
        moved.y -= remaining * uniforms.riseHeight * height;
    }

    float2 unit = moved / uniforms.regionSize;
    out.position = float4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
    return out;
}

/// How much light may land here, measured from the glyph's own box rather than from its quad.
///
/// This is what keeps a per-glyph effect from being a per-quad one. Every character carries a
/// padded rectangle so the light it throws has somewhere to go, and those rectangles tile the
/// line — so a glow that merely stopped at a quad's edge would draw the tiling: a faint grid of
/// boxes over the answer, one step of brightness per character, which is exactly what a reader
/// notices and cannot name. Reaching zero *inside* the padding instead means neighbouring quads
/// overlap and sum, and the seam has nothing to show.
static float aurora_falloff(float2 point, float4 rect, float reach) {
    float2 outside = max(max(rect.xy - point, point - (rect.xy + rect.zw)), 0.0);
    return 1.0 - smoothstep(0.0, max(reach, 0.001), length(outside));
}

/// Embers: light thrown off the hottest characters, computed from the clock and a hash rather than
/// simulated, so they cost nothing to keep and nothing to abandon. They die well inside the wave on
/// purpose — settled text is the one thing in this app that holds perfectly still, and an ember
/// still burning over a finished sentence would say the sentence was not finished.
static float aurora_embers(AuroraVarying in, float burn, constant AuroraUniforms &uniforms) {
    if (burn <= 0.004) { return 0.0; }
    float life = max(uniforms.emberLife, 0.05);
    float budget = burn * uniforms.emberDensity;
    float total = 0.0;
    for (int i = 0; i < 3; i++) {
        if (float(i) >= budget) { break; }
        float seed = in.seed * 7.13 + float(i) * 131.7;
        float age = fract((uniforms.time + aurora_hash(seed + 3.7) * life) / life);
        float sway = (aurora_hash(seed + 17.9) - 0.5) * 0.55 * in.height * age;
        float2 centre = float2(
            in.rect.x + aurora_hash(seed + 11.3) * in.rect.z + sway,
            in.rect.y + in.rect.w * (0.15 + aurora_hash(seed + 5.1) * 0.5)
                - uniforms.emberDrift * in.height * age);
        float radius = max(in.height * 0.05 * (1.0 - age * 0.6), 0.35);
        float2 delta = in.source - centre;
        float falloff = exp(-dot(delta, delta) / (radius * radius));
        float remaining = 1.0 - age;
        total += falloff * remaining * remaining * burn;
    }
    return min(total, 1.0);
}

/// One frame of one character.
///
/// The ink is sampled from where the glyph was laid out, walked toward the leading colour in OKLab
/// by exactly what `StreamCascade` said it was worth, split into its channels while it is still
/// near the edge, and given whatever light it is still throwing. The wave tints what is already
/// there rather than replacing it — a keyword in a code block, a link, an inline code span all keep
/// their own colour as the settled end of the blend — so a glyph leaving the wave lands on the
/// colour it would have had if it had never been in one. Output is premultiplied over a clear
/// ground, so the writing floats on whatever the bubble is made of.
fragment float4 aurora_glyph_fragment(
    AuroraVarying in [[stage_in]], constant AuroraUniforms &uniforms [[buffer(1)]],
    texture2d<float> ink [[texture(0)]], sampler flat [[sampler(0)]]) {
    float3 wave = aurora_wave(in.distance, uniforms);
    float heat = wave.x;
    float glow = wave.y;
    float alpha = wave.z;
    if (alpha <= 0.003) { return float4(0.0); }

    float2 uv = in.source / uniforms.regionSize * uniforms.inkSize;
    bool inside = all(in.source >= in.rect.xy) && all(in.source <= in.rect.xy + in.rect.zw);

    float3 accumulated = float3(0.0);
    float coverage = 0.0;

    if (inside) {
        /// The ink is always read at its own resolution. A sampler left to work the level out from
        /// the derivatives will not stay at zero here — the quads are padded, they overlap several
        /// deep, and the lanes at their edges are enough to push the level up — and the moment it
        /// does, the read stops being this glyph's ink and becomes a blurred average that reaches
        /// into the blank around it. What that draws is a faint bar at every character boundary:
        /// too quiet to name, exactly regular, and visible on any flat ground. Only the light,
        /// below, has any business reading a blurred level, and it asks for one by name.
        float4 sampled = ink.sample(flat, uv, level(0.0));
        if (uniforms.motion > 0.5) {
            float fringe = max(0.0, 1.0 - max(in.distance, 0.0) / uniforms.dispersionReach);
            float split = fringe * fringe * uniforms.dispersionDepth * in.height
                / max(uniforms.regionSize.x, 1.0) * uniforms.inkSize.x;
            if (split > 0.00002) {
                float4 low = ink.sample(flat, uv + float2(split, 0.0), level(0.0));
                float4 high = ink.sample(flat, uv - float2(split, 0.0), level(0.0));
                sampled = float4(
                    low.r, sampled.g, high.b, max(sampled.a, max(low.a, high.a) * 0.7));
            }
        }
        if (sampled.a > 0.008) {
            float3 settled = clamp(sampled.rgb / sampled.a, 0.0, 1.0);
            float3 warmed = aurora_blend(settled, uniforms.edge.rgb, heat * 0.86);
            float3 lit = aurora_blend(warmed, uniforms.spark.rgb, glow);
            coverage = min(1.0, sampled.a) * alpha;
            accumulated = lit * coverage;
        }
    }

    if (uniforms.motion > 0.5) {
        float reach = uniforms.bloomRadius * in.height;
        float halo = ink.sample(flat, uv, level(uniforms.bloomLevel)).a;
        float spill = halo * halo * heat * uniforms.bloomPeak
            * aurora_falloff(in.source, in.rect, reach);
        if (inside) { spill *= 0.4; }
        float burn = max(0.0, 1.0 - max(in.distance, 0.0) / uniforms.emberReach);
        float ember = aurora_embers(in, burn * burn * burn, uniforms);
        float lightAlpha = min(0.8, (spill + ember) * alpha * uniforms.intensity);
        if (lightAlpha > 0.003) {
            float3 tone = aurora_blend(
                uniforms.edge.rgb, uniforms.spark.rgb, min(1.0, glow * 2.0 + ember));
            float room = 1.0 - coverage;
            accumulated += tone * lightAlpha * room;
            coverage += lightAlpha * room;
        }
    }

    if (coverage <= 0.003) { return float4(0.0); }
    return float4(accumulated, coverage);
}

/// The nib: the lit point of contact, not a cursor. It sits on the character it has just written
/// rather than in the space after it, burns with the pacer's own rate, and rests rather than goes
/// out when a turn stops to run something — an answer paused on a tool call has not finished, and a
/// nib that vanished would say it had.
vertex AuroraNibVarying aurora_nib_vertex(
    uint vertexID [[vertex_id]], constant AuroraUniforms &uniforms [[buffer(1)]]) {
    float2 corner = float2(float(vertexID & 1), float((vertexID >> 1) & 1));
    float reach = max(uniforms.nib.z, 1.0) * uniforms.nibGlow;
    float2 origin = float2(uniforms.nib.x - reach, uniforms.nib.y - reach * 0.4);
    float2 size = float2(reach * 2.0, uniforms.nib.z + reach * 0.8);
    float2 point = origin + corner * size;

    AuroraNibVarying out;
    out.local = corner * 2.0 - 1.0;
    float2 unit = point / uniforms.regionSize;
    out.position = float4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
    return out;
}

fragment float4 aurora_nib_fragment(
    AuroraNibVarying in [[stage_in]], constant AuroraUniforms &uniforms [[buffer(1)]]) {
    float strength = uniforms.nib.w;
    if (strength <= 0.003) { return float4(0.0); }
    float radial = length(float2(in.local.x * 3.2, in.local.y));
    float core = 1.0 - smoothstep(0.0, 0.5, radial);
    float halo = exp(-radial * 2.4) * 0.45;
    float alpha = min(0.9, (core * 0.8 + halo) * strength);
    if (alpha <= 0.003) { return float4(0.0); }
    float3 tone = aurora_blend(uniforms.edge.rgb, uniforms.spark.rgb, core * 0.65);
    return float4(tone * alpha, alpha);
}
