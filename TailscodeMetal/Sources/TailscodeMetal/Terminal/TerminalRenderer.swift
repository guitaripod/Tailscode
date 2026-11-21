import CoreGraphics
import CoreText
import Foundation
@preconcurrency import Metal
import TailscodeCore

/// Draws a terminal's frames with one instanced draw call.
///
/// Every row keeps the quads it was last drawn with, so a frame in which three rows changed
/// rebuilds three rows; the rest is a copy into the instance buffer. Fills go down first across
/// the whole screen, then everything inked, so a glyph that leans into its neighbour's cell is
/// never painted over by that neighbour's background.
final class TerminalRenderer {
    struct Quad {
        var rect: SIMD4<Float>
        var uv: SIMD4<Float> = .zero
        var color: SIMD4<Float>
        var kind: SIMD4<Float> = .zero
    }

    private struct FrameUniform {
        var size: SIMD2<Float>
        var origin: SIMD2<Float>
    }

    private struct Cursor: Equatable {
        var visible = false
        var blinking = false
        var style: UInt8 = 0
        var column = 0
        var row = 0
        var span = 1
        var text = ""
        var face = 0
        var color: UInt32 = 0xffffff
    }

    let atlas: TerminalGlyphAtlas
    var metrics: TerminalCellMetrics { atlas.metrics }
    private(set) var background = SIMD4<Float>(0, 0, 0, 1)
    private(set) var cursorBlinks = false

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var fills: [[Quad]] = []
    private var marks: [[Quad]] = []
    private var overlay: [Quad] = []
    private var columns = 0
    private var cursor = Cursor()
    private var backgroundRGB: UInt32 = 0
    private var scroll: (total: UInt64, offset: UInt64, length: UInt64) = (0, 0, 0)
    private var atlasGeneration = 0
    private var buffer: MTLBuffer?
    private var capacity = 0
    /// How many quads the last frame drew, for a check that has no eyes.
    private(set) var lastQuadCount = 0

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, font: CTFont) {
        guard let atlas = TerminalGlyphAtlas(device: device, font: font),
            let library = TerminalShaders.library(for: device)
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "terminal_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "terminal_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.atlas = atlas
        self.pipeline = pipeline
    }

    private static func color(_ rgb: UInt32, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float((rgb >> 16) & 0xff) / 255, Float((rgb >> 8) & 0xff) / 255, Float(rgb & 0xff) / 255, alpha)
    }

    private static func face(_ cell: TSCell) -> Int {
        (cell.flags & UInt16(TS_CELL_BOLD) != 0 ? 1 : 0) | (cell.flags & UInt16(TS_CELL_ITALIC) != 0 ? 2 : 0)
    }

    /// The colour behind the grid until a frame says its own.
    func setCanvas(_ rgb: UInt32) {
        backgroundRGB = rgb
        background = Self.color(rgb)
    }

    /// Takes a frame. True when what is on screen is now out of date.
    func update(_ frame: TerminalFrame, focused: Bool, blinkOn: Bool) -> Bool {
        guard !frame.isEmpty else { return false }
        var everything = frame.everythingChanged || fills.count != frame.rows || columns != frame.cols
        if fills.count != frame.rows {
            fills = Array(repeating: [], count: frame.rows)
            marks = Array(repeating: [], count: frame.rows)
        }
        columns = frame.cols
        var changed = everything
        for attempt in 0..<2 {
            atlasGeneration = atlas.generation
            for row in 0..<frame.rows where everything || frame.rowChanged(row) {
                build(row: row, frame: frame)
                changed = true
            }
            guard atlas.generation != atlasGeneration, attempt == 0 else { break }
            everything = true
        }
        if frame.raw.background != backgroundRGB {
            backgroundRGB = frame.raw.background
            background = Self.color(backgroundRGB)
            changed = true
        }
        var next = Cursor(
            visible: frame.raw.cursor_visible, blinking: frame.raw.cursor_blinking, style: frame.raw.cursor_style,
            column: Int(frame.raw.cursor_x), row: Int(frame.raw.cursor_y), span: 1, text: "", face: 0,
            color: frame.raw.cursor_color)
        if next.visible, next.row < frame.rows, next.column < frame.cols {
            let cell = frame.cells(row: next.row)[next.column]
            next.span = cell.width == 2 ? 2 : 1
            next.text = frame.text(of: cell, row: next.row)
            next.face = Self.face(cell)
        }
        let nextScroll = (frame.raw.scroll_total, frame.raw.scroll_offset, frame.raw.scroll_length)
        if next != cursor || nextScroll != scroll { changed = true }
        cursor = next
        scroll = nextScroll
        cursorBlinks = next.visible && next.blinking
        buildOverlay(focused: focused, blinkOn: blinkOn, rows: frame.rows)
        return changed
    }

    /// The cursor and the scroll mark again, for a blink or a change of focus with no new frame.
    func restyle(focused: Bool, blinkOn: Bool) {
        buildOverlay(focused: focused, blinkOn: blinkOn, rows: fills.count)
    }

    private func build(row: Int, frame: TerminalFrame) {
        let cells = frame.cells(row: row)
        let width = Float(metrics.width)
        let height = Float(metrics.height)
        let top = Float(row * metrics.height)
        var fill: [Quad] = []
        var mark: [Quad] = []
        var column = 0
        while column < cells.count {
            guard cells[column].flags & UInt16(TS_CELL_FILLED) != 0 else {
                column += 1
                continue
            }
            var end = column + 1
            while end < cells.count, cells[end].flags & UInt16(TS_CELL_FILLED) != 0, cells[end].bg == cells[column].bg {
                end += 1
            }
            fill.append(
                Quad(
                    rect: SIMD4(Float(column) * width, top, Float(end - column) * width, height),
                    color: Self.color(cells[column].bg)))
            column = end
        }
        for (column, cell) in cells.enumerated() where cell.width != 0 {
            let left = Float(column) * width
            let span = cell.width == 2 ? 2 : 1
            let ink = Self.color(cell.fg)
            if cell.codepoint != 0, cell.codepoint != 0x20 {
                if cell.extra == 0, (0x2500...0x259f).contains(cell.codepoint), box(cell, left: left, top: top, ink: ink, into: &mark) {
                } else {
                    let glyph =
                        cell.extra == 0 && span == 1
                        ? atlas.glyph(codepoint: cell.codepoint, face: Self.face(cell))
                        : atlas.glyph(text: frame.text(of: cell, row: row), face: Self.face(cell), span: span)
                    if let glyph, !glyph.isEmpty {
                        mark.append(
                            Quad(
                                rect: SIMD4(left, top, width * Float(span), height),
                                uv: SIMD4(glyph.u0, glyph.v0, glyph.u1, glyph.v1), color: ink,
                                kind: SIMD4(glyph.isColor ? 2 : 1, 0, 0, 0)))
                    }
                }
            }
            decorate(cell, left: left, top: top, width: width * Float(span), into: &mark)
        }
        fills[row] = fill
        marks[row] = mark
    }

    private func box(_ cell: TSCell, left: Float, top: Float, ink: SIMD4<Float>, into quads: inout [Quad]) -> Bool {
        let span: Float = cell.width == 2 ? 2 : 1
        return withUnsafeTemporaryAllocation(of: TSBoxRect.self, capacity: Int(TS_BOX_RECTS_MAX)) { rects in
            let count = ts_box_drawing(
                cell.codepoint, Float(metrics.width) * span, Float(metrics.height), 1, rects.baseAddress)
            for index in 0..<count {
                let rect = rects[index]
                var shade = ink
                shade.w *= rect.alpha
                quads.append(Quad(rect: SIMD4(left + rect.x, top + rect.y, rect.width, rect.height), color: shade))
            }
            return count > 0
        }
    }

    private func decorate(_ cell: TSCell, left: Float, top: Float, width: Float, into quads: inout [Quad]) {
        let marked = UInt16(TS_CELL_STRIKETHROUGH) | UInt16(TS_CELL_OVERLINE) | UInt16(TS_CELL_UNDERLINE_MASK)
        guard cell.flags & marked != 0 else { return }
        let thick = Float(metrics.lineThickness)
        let ink = Self.color(cell.fg)
        if cell.flags & UInt16(TS_CELL_STRIKETHROUGH) != 0 {
            quads.append(Quad(rect: SIMD4(left, top + Float(metrics.strikeOffset), width, thick), color: ink))
        }
        if cell.flags & UInt16(TS_CELL_OVERLINE) != 0 {
            quads.append(Quad(rect: SIMD4(left, top, width, thick), color: ink))
        }
        let underline = Int32(cell.flags & UInt16(TS_CELL_UNDERLINE_MASK)) >> Int32(TS_CELL_UNDERLINE_SHIFT)
        guard underline != TS_UNDERLINE_NONE else { return }
        let line = Self.color(cell.decoration)
        let y = top + Float(metrics.underlineOffset)
        switch underline {
        case Int32(TS_UNDERLINE_DOUBLE):
            quads.append(Quad(rect: SIMD4(left, y - thick - 1, width, thick), color: line))
            quads.append(Quad(rect: SIMD4(left, y, width, thick), color: line))
        case Int32(TS_UNDERLINE_CURLY):
            let step = max(thick * 2, 2)
            var at: Float = 0
            var index = 0
            while at < width {
                let lift: Float = index % 2 == 0 ? 0 : -thick
                quads.append(Quad(rect: SIMD4(left + at, y + lift, min(step, width - at), thick), color: line))
                at += step
                index += 1
            }
        case Int32(TS_UNDERLINE_DOTTED), Int32(TS_UNDERLINE_DASHED):
            let on = underline == Int32(TS_UNDERLINE_DOTTED) ? thick : thick * 3
            let period = on + thick * 2
            var at: Float = 0
            while at < width {
                quads.append(Quad(rect: SIMD4(left + at, y, min(on, width - at), thick), color: line))
                at += period
            }
        default:
            quads.append(Quad(rect: SIMD4(left, y, width, thick), color: line))
        }
    }

    /// The cursor as the program asked for it while the pane has the keyboard, a hollow box
    /// while it does not, and the mark that says how far back the screen is scrolled.
    private func buildOverlay(focused: Bool, blinkOn: Bool, rows: Int) {
        overlay.removeAll(keepingCapacity: true)
        let width = Float(metrics.width)
        let height = Float(metrics.height)
        if cursor.visible, cursor.row < rows, !(focused && cursor.blinking && !blinkOn) {
            let left = Float(cursor.column) * width
            let top = Float(cursor.row) * height
            let span = Float(cursor.span)
            let ink = Self.color(cursor.color)
            let line = max((width / 6).rounded(), 1)
            switch focused ? Int32(cursor.style) : Int32(TS_CURSOR_HOLLOW) {
            case Int32(TS_CURSOR_BAR):
                overlay.append(Quad(rect: SIMD4(left, top, line, height), color: ink))
            case Int32(TS_CURSOR_UNDERLINE):
                overlay.append(Quad(rect: SIMD4(left, top + height - line, width * span, line), color: ink))
            case Int32(TS_CURSOR_HOLLOW):
                overlay.append(Quad(rect: SIMD4(left, top, width * span, 1), color: ink))
                overlay.append(Quad(rect: SIMD4(left, top + height - 1, width * span, 1), color: ink))
                overlay.append(Quad(rect: SIMD4(left, top, 1, height), color: ink))
                overlay.append(Quad(rect: SIMD4(left + width * span - 1, top, 1, height), color: ink))
            default:
                overlay.append(Quad(rect: SIMD4(left, top, width * span, height), color: ink))
                if !cursor.text.isEmpty, cursor.text != " ",
                    let glyph = atlas.glyph(text: cursor.text, face: cursor.face, span: cursor.span), !glyph.isEmpty
                {
                    overlay.append(
                        Quad(
                            rect: SIMD4(left, top, width * span, height),
                            uv: SIMD4(glyph.u0, glyph.v0, glyph.u1, glyph.v1), color: background,
                            kind: SIMD4(glyph.isColor ? 2 : 1, 0, 0, 0)))
                }
            }
        }
    }

    private func scrollMark(size: SIMD2<Float>, padding: Float) -> Quad? {
        guard scroll.total > scroll.length, scroll.offset + scroll.length < scroll.total else { return nil }
        let track = size.y - 8
        let length = max(track * Float(scroll.length) / Float(scroll.total), 28)
        let top = 4 + (track - length) * Float(scroll.offset) / Float(scroll.total - scroll.length)
        var ink = Self.color(cursor.color)
        ink.w = 0.45
        return Quad(rect: SIMD4(size.x - padding - 10, top - padding, 5, length), color: ink)
    }

    /// Encodes the frame. `padding` is the margin around the grid, in pixels.
    func encode(commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, drawableSize: CGSize, padding: Float) {
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.x), green: Double(background.y), blue: Double(background.z), alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        let size = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        let mark = scrollMark(size: size, padding: padding)
        let count = fills.reduce(0) { $0 + $1.count } + marks.reduce(0) { $0 + $1.count } + overlay.count + (mark == nil ? 0 : 1)
        lastQuadCount = count
        guard count > 0 else { return }
        if count > capacity {
            capacity = max(count * 3 / 2, 4096)
            buffer = device.makeBuffer(length: capacity * MemoryLayout<Quad>.stride, options: .storageModeShared)
        }
        guard let buffer else { return }
        var cursor = buffer.contents().bindMemory(to: Quad.self, capacity: capacity)
        func copy(_ quads: [Quad]) {
            guard !quads.isEmpty else { return }
            quads.withUnsafeBufferPointer { cursor.update(from: $0.baseAddress!, count: $0.count) }
            cursor += quads.count
        }
        fills.forEach(copy)
        marks.forEach(copy)
        copy(overlay)
        if let mark { copy([mark]) }
        var uniform = FrameUniform(size: size, origin: SIMD2(padding, padding))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<FrameUniform>.stride, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }
}
