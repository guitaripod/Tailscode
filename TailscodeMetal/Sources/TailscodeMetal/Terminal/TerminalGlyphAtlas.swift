import CoreGraphics
import CoreText
import Foundation
@preconcurrency import Metal

/// The size of a cell and where its text sits, in device pixels.
public struct TerminalCellMetrics: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var ascent: Int
    public var underlineOffset: Int
    public var strikeOffset: Int
    public var lineThickness: Int

    public init(width: Int, height: Int, ascent: Int, underlineOffset: Int, strikeOffset: Int, lineThickness: Int) {
        self.width = width
        self.height = height
        self.ascent = ascent
        self.underlineOffset = underlineOffset
        self.strikeOffset = strikeOffset
        self.lineThickness = lineThickness
    }
}

/// Every character the terminal has drawn, rasterised once into one texture.
///
/// A glyph is drawn by CoreText into a slot exactly as large as the cells it covers, with the
/// baseline where every other glyph has it, so placing it is placing a cell: no bearings, no
/// per-glyph origin. CoreText finds a face for whatever the terminal's own face lacks, so an emoji,
/// a CJK character and an accent joined to its letter all come through the one path. Text in one
/// colour is kept as coverage and tinted when drawn; an emoji is kept as the picture it is.
final class TerminalGlyphAtlas {
    struct Glyph {
        var u0: Float
        var v0: Float
        var u1: Float
        var v1: Float
        var isColor: Bool
        var isEmpty: Bool
    }

    private struct Key: Hashable {
        var text: String
        var face: UInt8
        var span: UInt8
    }

    static let side = 2048

    let texture: MTLTexture
    let metrics: TerminalCellMetrics
    /// Counted up whenever the texture is emptied to make room: every position handed out before
    /// is then wrong, and whoever kept one draws its rows again.
    private(set) var generation = 0

    private let faces: [CTFont]
    private var cursorX = 0
    private var cursorY = 0
    private var ascii: [[Glyph?]]
    private var others: [Key: Glyph] = [:]
    private let scratch: CGContext
    private let scratchWidth: Int

    init?(device: MTLDevice, font: CTFont) {
        let bold = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font
        let italic = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic) ?? font
        let both =
            CTFontCreateCopyWithSymbolicTraits(
                font, 0, nil, [.traitBold, .traitItalic], [.traitBold, .traitItalic]) ?? bold
        faces = [font, bold, italic, both]
        metrics = Self.measure(font)
        ascii = Array(repeating: Array(repeating: nil, count: 128), count: 4)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.side, height: Self.side, mipmapped: false)
        descriptor.usage = .shaderRead
        scratchWidth = metrics.width * 2
        guard let texture = device.makeTexture(descriptor: descriptor),
            let scratch = CGContext(
                data: nil, width: scratchWidth, height: metrics.height, bitsPerComponent: 8,
                bytesPerRow: scratchWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        self.texture = texture
        self.scratch = scratch
        scratch.setShouldSmoothFonts(false)
        scratch.setShouldAntialias(true)
        scratch.setAllowsFontSubpixelPositioning(false)
        scratch.setShouldSubpixelPositionFonts(false)
    }

    /// A cell is as wide as the face's own advance, rounded up to a whole pixel, and as tall as
    /// the face asks a line to be.
    static func measure(_ font: CTFont) -> TerminalCellMetrics {
        var character: UniChar = 0x4d
        var glyph = CGGlyph(0)
        var advance = CGSize.zero
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let height = max(Int((ascent + descent + leading).rounded(.up)), 1)
        let thickness = max(Int(CTFontGetUnderlineThickness(font).rounded()), 1)
        let baseline = Int((ascent + leading / 2).rounded())
        return TerminalCellMetrics(
            width: max(Int(advance.width.rounded(.up)), 1), height: height, ascent: baseline,
            underlineOffset: min(baseline - Int(CTFontGetUnderlinePosition(font).rounded()), height - thickness),
            strikeOffset: baseline - Int((CTFontGetXHeight(font) / 2).rounded()), lineThickness: thickness)
    }

    func glyph(codepoint: UInt32, face: Int) -> Glyph? {
        if codepoint < 128 {
            if let known = ascii[face][Int(codepoint)] { return known }
            guard let scalar = Unicode.Scalar(codepoint) else { return nil }
            let made = rasterise(String(Character(scalar)), face: face, span: 1)
            ascii[face][Int(codepoint)] = made
            return made
        }
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }
        return glyph(text: String(Character(scalar)), face: face, span: 1)
    }

    func glyph(text: String, face: Int, span: Int) -> Glyph? {
        let key = Key(text: text, face: UInt8(face), span: UInt8(span))
        if let known = others[key] { return known }
        let made = rasterise(text, face: face, span: span)
        others[key] = made
        return made
    }

    private func slot(span: Int) -> (x: Int, y: Int)? {
        let width = metrics.width * span
        if cursorX + width > Self.side {
            cursorX = 0
            cursorY += metrics.height
        }
        if cursorY + metrics.height > Self.side {
            cursorX = 0
            cursorY = 0
            ascii = Array(repeating: Array(repeating: nil, count: 128), count: 4)
            others.removeAll(keepingCapacity: true)
            generation += 1
        }
        guard width <= Self.side, metrics.height <= Self.side else { return nil }
        defer { cursorX += width }
        return (cursorX, cursorY)
    }

    private func rasterise(_ text: String, face: Int, span: Int) -> Glyph? {
        let span = min(max(span, 1), 2)
        let width = metrics.width * span
        scratch.clear(CGRect(x: 0, y: 0, width: scratchWidth, height: metrics.height))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): faces[face],
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var isColor = false
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = runAttributes[kCTFontAttributeName as String] else { continue }
            let font = value as! CTFont
            if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) { isColor = true }
        }
        scratch.textPosition = CGPoint(x: 0, y: metrics.height - metrics.ascent)
        CTLineDraw(line, scratch)
        guard let data = scratch.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var inked = false
        scan: for row in 0..<metrics.height {
            let start = row * scratchWidth * 4
            for column in 0..<width where bytes[start + column * 4 + 3] != 0 {
                inked = true
                break scan
            }
        }
        guard inked else {
            return Glyph(u0: 0, v0: 0, u1: 0, v1: 0, isColor: false, isEmpty: true)
        }
        guard let place = slot(span: span) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(place.x, place.y, width, metrics.height), mipmapLevel: 0,
            withBytes: data, bytesPerRow: scratchWidth * 4)
        let side = Float(Self.side)
        return Glyph(
            u0: Float(place.x) / side, v0: Float(place.y) / side, u1: Float(place.x + width) / side,
            v1: Float(place.y + metrics.height) / side, isColor: isColor, isEmpty: false)
    }
}
