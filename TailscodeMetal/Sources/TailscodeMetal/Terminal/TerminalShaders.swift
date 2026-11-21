import Foundation
@preconcurrency import Metal

/// The terminal's whole shading: one instanced quad, three kinds of fill. Compiled at run time
/// once per device, the way the wall's is, so no client packages a metallib.
enum TerminalShaders {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var libraries: [UInt64: MTLLibrary] = [:]

    static func library(for device: MTLDevice) -> MTLLibrary? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = libraries[device.registryID] { return cached }
        guard let library = try? device.makeLibrary(source: source, options: MTLCompileOptions()) else { return nil }
        libraries[device.registryID] = library
        return library
    }

    static let source = #"""
        #include <metal_stdlib>
        using namespace metal;

        struct Quad {
            float4 rect;
            float4 uv;
            float4 color;
            float4 kind;
        };

        struct Frame {
            float2 size;
            float2 origin;
        };

        struct Corner {
            float4 position [[position]];
            float2 uv;
            float4 color;
            float kind [[flat]];
        };

        vertex Corner terminal_vertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                      const device Quad* quads [[buffer(0)]],
                                      constant Frame& frame [[buffer(1)]]) {
            Quad quad = quads[instanceID];
            float2 corner = float2(float(vertexID & 1), float(vertexID >> 1));
            float2 pixel = quad.rect.xy + corner * quad.rect.zw + frame.origin;
            Corner out;
            out.position = float4(pixel.x / frame.size.x * 2.0 - 1.0, 1.0 - pixel.y / frame.size.y * 2.0, 0.0, 1.0);
            out.uv = mix(quad.uv.xy, quad.uv.zw, corner);
            out.color = quad.color;
            out.kind = quad.kind.x;
            return out;
        }

        fragment float4 terminal_fragment(Corner in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
            constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
            if (in.kind < 0.5) {
                return float4(in.color.rgb * in.color.a, in.color.a);
            }
            float4 texel = atlas.sample(nearest, in.uv);
            if (in.kind < 1.5) {
                return float4(in.color.rgb * texel.a, texel.a) * in.color.a;
            }
            return texel * in.color.a;
        }
        """#
}
