import Foundation
@preconcurrency import Metal

/// The wall's Metal Shading Language, kept as one string and compiled at runtime once per device, so
/// the iPhone app and the Mac app never disagree about how a metallib is packaged.
enum WallShaders {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var libraries: [UInt64: MTLLibrary] = [:]

    static func library(for device: MTLDevice) -> MTLLibrary? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = libraries[device.registryID] { return cached }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        guard let library = try? device.makeLibrary(source: source, options: options) else { return nil }
        libraries[device.registryID] = library
        return library
    }

    static let source = #"""
        #include <metal_stdlib>
        using namespace metal;

        struct Frame {
            float2 canvas;
            float2 shift;
            float scale;
            float unit;
            float dim;
            float pad;
            float4 text;
            float4 dimInk;
        };

        struct Inst { float4 a; float4 b; float4 c; float4 d; };

        struct GroundU {
            float4 sizeScaleUnit;
            float4 ground;
            float4 deep;
            float4 text;
            float4 tint;
            float4 vig;
            float4 misc;
            int4 counts;
            float4 lr[8];
            float4 li[8];
            float4 rr[12];
            float4 ri[12];
            float4 rp[12];
        };

        static float sdr(float2 p, float2 c, float2 hs, float r) {
            float2 q = abs(p - c) - hs + r;
            return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        }

        static float h21(float2 p) {
            p = fract(p * float2(123.34, 456.21));
            p += dot(p, p + 45.32);
            return fract(p.x * p.y);
        }

        static float vn(float2 p) {
            float2 i = floor(p), f = fract(p);
            float2 w = f * f * (3.0 - 2.0 * f);
            return mix(mix(h21(i), h21(i + float2(1.0, 0.0)), w.x),
                       mix(h21(i + float2(0.0, 1.0)), h21(i + float2(1.0, 1.0)), w.x), w.y);
        }

        static float4 place(constant Frame &f, float2 p) {
            float2 px = (p + f.shift) * f.scale;
            return float4(px.x / f.canvas.x * 2.0 - 1.0, 1.0 - px.y / f.canvas.y * 2.0, 0.0, 1.0);
        }

        vertex float4 ground_vs(uint vid [[vertex_id]]) {
            const float2 P[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            return float4(P[vid], 0.0, 1.0);
        }

        fragment float4 ground_fs(float4 frag [[position]], constant GroundU &g [[buffer(0)]]) {
            float2 size = g.sizeScaleUnit.xy;
            float scale = g.sizeScaleUnit.z;
            float U = g.sizeScaleUnit.w;
            float2 p = frag.xy / scale - g.misc.xy;
            float2 uv = clamp(p / size, 0.0, 1.0);
            float3 col = mix(g.deep.rgb, g.ground.rgb, uv.y);
            float m = max(size.x, size.y);
            float bd = length(p - float2(0.5 * size.x, 0.42 * size.y)) / (0.7 * m);
            col = mix(col, g.tint.rgb, g.ground.a * max(0.0, 1.0 - bd));
            if (g.vig.a > 0.0) {
                float2 q = p / (U * 34.0);
                float time = g.tint.a;
                float n = vn(q + float2(time * 0.021, -time * 0.013)) * 0.62
                        + vn(q * 2.3 - float2(time * 0.034, time * 0.017)) * 0.38;
                float b = smoothstep(0.5, 0.72, n) * (1.0 - smoothstep(0.72, 0.92, n));
                col += g.tint.rgb * b * 0.06 * g.vig.a * (1.0 - uv.y * 0.45);
            }
            float gs = max(24.0, U * 6.0);
            float2 gd = abs(fract((p - gs * 0.5) / gs + 0.5) - 0.5) * gs * scale;
            float line = max(1.0 - smoothstep(0.0, 1.0, gd.x), 1.0 - smoothstep(0.0, 1.0, gd.y));
            col = mix(col, g.text.rgb, g.misc.z * line);
            int nl = g.counts.x;
            for (int i = 0; i < nl; i++) {
                float4 r = g.lr[i];
                float2 hs = r.zw * 0.5;
                float2 e = abs(p - (r.xy + hs)) - hs;
                if (max(e.x, e.y) > U * 40.0) continue;
                float d = sdr(p, r.xy + hs, hs, U * 1.6);
                if (d > 0.0 && d < U * 40.0) col += g.li[i].rgb * g.li[i].a * exp(-d / (U * 7.0));
            }
            int nr = g.counts.y;
            for (int i = 0; i < nr; i++) {
                float4 r = g.rr[i];
                float2 hs = r.zw * 0.5;
                float d = sdr(p, r.xy + hs, hs, g.rp[i].z);
                float b = (d - g.rp[i].x) / max(g.rp[i].y, 0.001);
                if (d >= 0.0 && abs(b) < 3.5) col += g.ri[i].rgb * g.ri[i].a * exp(-b * b);
            }
            float e = min(min(p.x, size.x - p.x), min(p.y, size.y - p.y));
            float v = clamp(1.0 - e / (0.13 * min(size.x, size.y)), 0.0, 1.0);
            col = mix(col, g.vig.rgb, g.deep.a * v * v);
            col *= g.text.a;
            col += (h21(frag.xy) - 0.5) / 255.0;
            return float4(col, 1.0);
        }

        struct PlateV {
            float4 pos [[position]];
            float2 p;
            float4 rect [[flat]];
            float4 ink [[flat]];
            float4 p1 [[flat]];
            float4 p2 [[flat]];
        };

        vertex PlateV plate_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                               constant Frame &f [[buffer(0)]], const device Inst *insts [[buffer(1)]]) {
            Inst s = insts[iid];
            float2 corner = float2(float(vid & 1u), float(vid >> 1));
            float m = 3.0;
            float2 p = s.a.xy - m + corner * (s.a.zw + 2.0 * m);
            PlateV o;
            o.pos = place(f, p);
            o.p = p;
            o.rect = s.a;
            o.ink = s.b;
            o.p1 = s.c;
            o.p2 = s.d;
            return o;
        }

        fragment float4 plate_fs(PlateV in [[stage_in]], constant Frame &f [[buffer(0)]]) {
            float2 vP = in.p;
            float4 vRect = in.rect;
            float4 vInk = in.ink;
            float4 vP1 = in.p1;
            float4 vP2 = in.p2;
            float U = f.unit;
            float scale = f.scale;
            float2 c = vRect.xy + vRect.zw * 0.5;
            float2 hs = vRect.zw * 0.5;
            float r = min(vP1.x, min(hs.x, hs.y));
            float d = sdr(vP, c, hs, r);
            float aa = 0.8 / scale;
            float inside = 1.0 - smoothstep(-aa, aa, d);
            float3 col = float3(0.0);
            float a = 0.0;
            if (vP2.w > 0.5) {
                col = vInk.rgb;
                a = 1.0;
                float op = vInk.a * f.dim;
                return float4(col * inside * op, a * inside * op);
            }
            float ty = clamp((vP.y - vRect.y) / max(vRect.w, 1.0), 0.0, 1.0);
            float g = mix(0.085, 0.03, ty);
            col += f.text.rgb * g;
            a += g;
            float wa = vP1.y * 1.6 * max(0.0, 1.0 - ty / 0.9);
            col += vInk.rgb * wa;
            a += wa * 0.45;
            col += vInk.rgb * vP2.y;
            a += vP2.y * 0.45;
            float sh = smoothstep(-1.8 * U, 0.0, d) * vP2.z;
            col += float3(1.0) * sh * 0.045;
            a += sh * 0.02;
            float rimY = abs(vP.y - (vRect.y + 1.2 / scale));
            float rim = (1.0 - smoothstep(0.0, 1.2 / scale, rimY)) * step(vRect.x + r, vP.x) * step(vP.x, vRect.x + vRect.z - r);
            col += float3(1.0) * rim * 0.1;
            a += rim * 0.05;
            if (vP2.x > 0.5) {
                float s = fract((vP.x + vP.y) / (1.3 * U));
                float ln = 1.0 - smoothstep(0.06, 0.12, abs(s - 0.5));
                col += f.dimInk.rgb * 0.2 * ln;
                a += 0.1 * ln;
            }
            col *= inside;
            a *= inside;
            float bw = max(vP1.w, 1.0 / scale);
            float bnd = 1.0 - smoothstep(bw * 0.5 - aa * 0.5, bw * 0.5 + aa * 0.5, abs(d + bw * 0.5));
            col += vInk.rgb * vP1.z * bnd;
            a += vP1.z * bnd;
            float op = vInk.a * f.dim;
            return float4(col * op, clamp(a, 0.0, 1.0) * op);
        }

        struct GlyphV {
            float4 pos [[position]];
            float2 q;
            float4 ink [[flat]];
            float4 k [[flat]];
            float4 x [[flat]];
            float s [[flat]];
        };

        vertex GlyphV glyph_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                               constant Frame &f [[buffer(0)]], const device Inst *insts [[buffer(1)]]) {
            Inst s = insts[iid];
            float2 corner = float2(float(vid & 1u), float(vid >> 1));
            float2 q = (corner * 2.0 - 1.0) * s.a.w;
            GlyphV o;
            o.pos = place(f, s.a.xy + q * s.a.z);
            o.q = q;
            o.ink = s.b;
            o.k = s.c;
            o.x = s.d;
            o.s = s.a.z;
            return o;
        }

        static float seg(float2 p, float2 a, float2 b) {
            float2 pa = p - a, ba = b - a;
            float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            return length(pa - ba * h);
        }

        static float band(float d, float w, float aa) { return 1.0 - smoothstep(w * 0.5 - aa, w * 0.5 + aa, abs(d)); }

        static float fillAA(float d, float aa) { return 1.0 - smoothstep(-aa, aa, d); }

        fragment float4 glyph_fs(GlyphV in [[stage_in]], constant Frame &f [[buffer(0)]]) {
            int k = int(in.k.x + 0.5);
            float2 q = in.q;
            float4 vK = in.k;
            float4 vX = in.x;
            float r = length(q);
            float aa = 1.0 / max(1.0, in.s * f.scale);
            float3 ink = in.ink.rgb;
            float3 c = float3(0.0);
            float a = 0.0;
            if (k == 0) {
                float R = vK.y;
                float core = fillAA(r - R, aa);
                float hl = clamp(1.0 - length(q - float2(-0.35 * R, -0.4 * R)) / (R * 1.1), 0.0, 1.0);
                float3 cc = mix(ink, float3(1.0), 0.3 * hl * hl);
                float halo = exp(-max(r - R, 0.0) / (R * 0.6)) * vK.z * (1.0 - core);
                c = cc * core + ink * halo * 0.55;
                a = core + halo * 0.3;
            } else if (k == 1) {
                float b = band(r - vK.y, vK.z, aa);
                float ang = atan2(q.x, -q.y);
                float t = (ang < 0.0 ? ang + 6.2831853 : ang) / 6.2831853;
                float on = 1.0 - smoothstep(vK.w - 0.003, vK.w + 0.003, t);
                c = ink * b * on + f.text.rgb * b * vX.x * (1.0 - on);
                a = b * on + b * vX.x * (1.0 - on);
            } else if (k == 2) {
                float b = band(r - vK.y, vK.z, aa);
                float fr = fract(atan2(q.y, q.x) / 6.2831853 * 14.0 + vK.w);
                float dsh = smoothstep(0.0, 0.06, fr) * (1.0 - smoothstep(0.56, 0.62, fr));
                c = ink * b * dsh;
                a = b * dsh;
            } else if (k == 3) {
                float b = band(r - vK.y, vK.z, aa) * 0.75;
                float2 dp = float2(sin(vK.w), -cos(vK.w)) * vK.y;
                float dt = fillAA(length(q - dp) - vX.x, aa);
                float v = max(b, dt);
                c = ink * v;
                a = v;
            } else if (k == 4) {
                float d = min(seg(q, float2(-0.26, 0.0), float2(-0.07, 0.19)), seg(q, float2(-0.07, 0.19), float2(0.27, -0.18)));
                float s = band(d, 0.1, aa);
                float ring = band(r - 0.43, 0.045, aa) * 0.4;
                float v = max(s, ring);
                c = ink * v;
                a = v;
            } else if (k == 5) {
                float d = min(seg(q, float2(-0.19, -0.19), float2(0.19, 0.19)), seg(q, float2(-0.19, 0.19), float2(0.19, -0.19)));
                float s = band(d, 0.1, aa);
                float ring = band(r - 0.43, 0.045, aa) * 0.4;
                float v = max(s, ring);
                c = ink * v;
                a = v;
            } else if (k == 6) {
                float2 dq = abs(q) - float2(0.17);
                float d = length(max(dq, 0.0)) + min(max(dq.x, dq.y), 0.0) - 0.03;
                float s = fillAA(d, aa) * 0.85;
                float ring = band(r - 0.43, 0.045, aa) * 0.35;
                float v = max(s, ring);
                c = ink * v;
                a = v;
            } else if (k == 7) {
                float b = (r - vK.y) / max(vK.z, 0.001);
                float g = exp(-b * b);
                c = ink * g;
                a = g;
            } else if (k == 8) {
                float g = exp(-(r * r) / max(vK.y * vK.y, 0.0001));
                c = ink * g;
                a = g;
            } else if (k == 9) {
                float dsk = fillAA(r - vK.y, aa);
                float s = fract((q.x + q.y) * 5.0);
                float h = smoothstep(0.0, 0.08, s) * (1.0 - smoothstep(0.42, 0.5, s));
                float e = band(r - vK.y, 0.05, aa);
                float v = max(dsk * h * 0.5, e * 0.8);
                c = ink * v;
                a = v;
            } else if (k == 10) {
                float dsk = fillAA(r - vK.y, aa) * 0.9;
                c = ink * dsk;
                a = dsk;
            }
            float op = in.ink.a * f.dim;
            return float4(c * op, a * op);
        }

        struct PointV {
            float4 pos [[position]];
            float size [[point_size]];
            float4 color [[flat]];
            float core [[flat]];
        };

        vertex PointV point_vs(uint vid [[vertex_id]], constant Frame &f [[buffer(0)]],
                               const device float4 *dots [[buffer(1)]]) {
            float4 a = dots[vid * 2];
            PointV o;
            o.pos = place(f, a.xy);
            o.size = max(1.0, a.z * f.scale);
            o.color = dots[vid * 2 + 1];
            o.core = a.w;
            return o;
        }

        fragment float4 point_fs(PointV in [[stage_in]], float2 pc [[point_coord]], constant Frame &f [[buffer(0)]]) {
            float d = length(pc - 0.5) * 2.0;
            float core = 1.0 - smoothstep(in.core * 0.75, in.core, d);
            float halo = (1.0 - smoothstep(in.core, 1.0, d)) * 0.22;
            float a = max(core, halo) * in.color.a * f.dim;
            if (a < 0.002) discard_fragment();
            return float4(in.color.rgb * a, a);
        }
        """#
}
