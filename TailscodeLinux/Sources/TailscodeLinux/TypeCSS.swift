import Foundation
import TailscodeCore

/// The shared ramp rendered into GTK's dialect, so a stylesheet names a role and never a number.
///
/// Sizes come out in `rem` against the area's own preference, which is what makes three independent
/// size sliders possible at all. The prose face is left unstated on purpose: the window already
/// carries the desktop's chosen UI font, and quoting a generic family here would replace someone's
/// font with fontconfig's idea of one.
enum TypeCSS {
    static func declarations(_ role: TypeRole) -> String {
        let spec = Typography.spec(role)
        var out: [String] = []
        if let family = family(spec.family) { out.append("font-family: \(family);") }
        out.append("font-size: \(number(spec.size(base: 1, scale: Preferences.scale(area(spec.axis)))))rem;")
        out.append("font-weight: \(spec.weight.rawValue);")
        if spec.italic { out.append("font-style: italic;") }
        if spec.tracking != 0 { out.append("letter-spacing: \(number(spec.tracking))em;") }
        if spec.lineHeight != 1 { out.append("line-height: \(number(spec.lineHeight));") }
        if spec.figures == .tabular { out.append("font-feature-settings: \"tnum\";") }
        return out.joined(separator: " ")
    }

    /// A whole rule, for the many classes that are nothing but their type.
    static func rule(_ selector: String, _ role: TypeRole, _ extra: String = "") -> String {
        let tail = extra.isEmpty ? "" : " \(extra)"
        return "\(selector) { \(declarations(role))\(tail) }"
    }

    private static func family(_ family: TypeFamily) -> String? {
        switch family {
        case .prose: return nil
        case .mono, .canvas: return "monospace"
        }
    }

    private static func area(_ axis: TypeAxis) -> Preferences.Area {
        switch axis {
        case .chrome: return .chrome
        case .prose: return .prose
        case .mono: return .mono
        }
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
