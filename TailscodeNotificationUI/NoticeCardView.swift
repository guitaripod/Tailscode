import SwiftUI
import UIKit

#if !NOTICE_EXTENSION
    import TailscodeCore
#endif

/// What the card draws: the notice read into words once, and the few facts that are not words.
@MainActor
final class NoticeCardModel: ObservableObject {
    @Published var title = ""
    @Published var fallback = ""
    @Published var wire: NoticeWire?
    @Published var reading: NoticeReading?
    @Published var date = Date()

    func show(title: String, subtitle: String, body: String, wire: NoticeWire?, date: Date) {
        self.title = title
        self.fallback = [subtitle, body].filter { !$0.isEmpty }.joined(separator: "\n")
        self.wire = wire
        self.reading = wire.map { NoticeWords.reading($0) }
        self.date = date
    }
}

/// The card as the long look hosts it: pinned to the top of whatever height the system has given
/// so far, so a look that is still growing to the card's size shows its start, not its middle.
struct NoticeLongLookView: View {
    @ObservedObject var model: NoticeCardModel
    var onHeight: (CGFloat) -> Void

    var body: some View {
        NoticeCardView(model: model, onHeight: onHeight)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct NoticeCardView: View {
    @ObservedObject var model: NoticeCardModel
    var onHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let wire = model.wire, let reading = model.reading {
                kindLabel(wire, reading)
                content(wire, reading)
            } else {
                Text(model.fallback)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: onHeight)
    }

    private var presentation: NoticePresentation {
        NoticePresentation.of(model.wire?.kind ?? .done)
    }

    private var tint: Color { Color(NoticeFace.tint(presentation.tone)) }

    private var header: some View {
        HStack(spacing: 12) {
            Image(uiImage: NoticeFace.image(for: presentation, glyph: model.wire?.glyph, side: 144))
                .resizable()
                .frame(width: 46, height: 46)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.headline)
                    .lineLimit(2)
                if let line = whereLine {
                    HStack(spacing: 6) {
                        Text(line.server).font(.footnote).foregroundStyle(.secondary)
                        if let agent = line.agent {
                            Text(agent)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var whereLine: (server: String, agent: String?)? {
        guard let wire = model.wire, let server = wire.server, !server.isEmpty else { return nil }
        return (server, wire.agent.flatMap(NoticeCardView.agentName))
    }

    private static func agentName(_ raw: String) -> String? {
        switch raw {
        case "claudeCode": return "Claude Code"
        case "opencode", "openCode": return "opencode"
        case "omp": return "Oh My Pi"
        default: return raw.isEmpty ? nil : raw
        }
    }

    /// The headline alone over a finished turn, whose facts the tiles below it already show.
    private func kindLabel(_ wire: NoticeWire, _ reading: NoticeReading) -> some View {
        Text((wire.kind == .done ? reading.headline : reading.lead).uppercased())
            .font(.system(.footnote, design: .monospaced).weight(.bold))
            .foregroundStyle(tint)
            .tracking(0.8)
    }

    @ViewBuilder
    private func content(_ wire: NoticeWire, _ reading: NoticeReading) -> some View {
        switch wire.kind {
        case .done:
            let tiles = stats(wire)
            if let tiles { tiles }
            let account = tiles == nil ? reading.summary : reading.touched
            if !account.isEmpty {
                Text(account).font(.subheadline).foregroundStyle(.secondary)
            }
            if !reading.passage.isEmpty {
                Text(reading.passage).font(.body).lineLimit(9)
            }
        case .failed:
            if !reading.passage.isEmpty {
                Text(reading.passage)
                    .font(.callout)
                    .foregroundStyle(Color(.systemRed).opacity(0.95))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemRed).opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            }
            if let prompt = reading.retryPrompt {
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(localized: "You asked").uppercased())
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(prompt).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                }
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.quaternary).frame(width: 3)
                }
            }
        case .approval:
            if !reading.passage.isEmpty {
                Text(codeLine(wire, reading.passage))
                    .font(.system(.footnote, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        case .question:
            Text(reading.passage).font(.title3.weight(.semibold))
            if !reading.options.isEmpty { optionList(reading.options) }
        case .usage:
            if !reading.passage.isEmpty { Text(reading.passage).font(.body) }
        }
    }

    private func codeLine(_ wire: NoticeWire, _ text: String) -> AttributedString {
        var prompt = AttributedString("$ ")
        prompt.foregroundColor = Color(.systemGreen)
        var line = AttributedString(text)
        line.foregroundColor = Color(.label)
        let shell = (wire.subject ?? "").lowercased()
        return shell.contains("bash") || shell.contains("shell") ? prompt + line : line
    }

    private func optionList(_ options: [NoticeWire.Option]) -> some View {
        VStack(spacing: 7) {
            ForEach(Array(options.prefix(5).enumerated()), id: \.offset) { index, option in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(UnicodeScalar(UInt8(65 + index))))
                        .font(.system(.footnote, design: .monospaced).weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 26, height: 26)
                        .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label).font(.subheadline.weight(.semibold))
                        if let detail = option.detail, !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func stats(_ wire: NoticeWire) -> AnyView? {
        var tiles: [(String, String, Color?)] = []
        if let seconds = wire.seconds, seconds >= NoticeWords.durationFloor {
            tiles.append((NoticeWords.duration(TimeInterval(seconds)), String(localized: "Time"), nil))
        }
        if let tools = wire.tools, tools > 0 {
            tiles.append(("\(tools)", String(localized: "Tools"), nil))
        }
        if let added = wire.added, let removed = wire.removed, added + removed > 0 {
            tiles.append(("+\(added)", String(localized: "Added"), Color(.systemGreen)))
            tiles.append(("−\(removed)", String(localized: "Removed"), Color(.systemRed)))
        }
        guard !tiles.isEmpty else { return nil }
        return AnyView(
            HStack(spacing: 8) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tile.0)
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                            .foregroundStyle(tile.2 ?? Color.primary)
                        Text(tile.1).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                }
            })
    }
}
