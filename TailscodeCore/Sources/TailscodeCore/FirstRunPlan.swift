import CodingAgentKit
import Foundation

/// The first run of all three clients as data: the ordered rows, the words in them and the one
/// press that moves on. A client draws what is here and wires each intent to its own door, and
/// invents no sentence, which is how a phone, a Mac and a Linux desktop say the same thing about
/// the same machine in the same order.
public struct FirstRunPlan: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public enum ID: String, Sendable, CaseIterable {
            case tailscale, machine, connected
        }

        public enum Glyph: Sendable, Equatable {
            case waiting, current, working, proven, attention
        }

        public let id: ID
        public let number: Int
        public let title: String
        public let glyph: Glyph
        public let pill: String?
        public let detail: String?
        public let blocks: [Block]
    }

    public enum Block: Sendable, Equatable {
        case note(String)
        case ways([Way])
        case paste(Paste)
        case agents([AgentChoice])
        case command(CommandCard)
        case waiting(String)
        case diagnosis(ConnectDiagnosis)
        case link(LinkCard)
        case password(PasswordField)
        case signIn(SignInCard)
        case remedy(TailscaleReading)
    }

    public struct Way: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            case scan, link, install, tailnet
        }

        public let kind: Kind
        public let title: String
        public let detail: String
        public var id: String { kind.rawValue }
    }

    public struct Paste: Sendable, Equatable {
        public let text: String
        public let placeholder: String
        public let reading: String?
        public let offer: String?
        public let message: ConnectLinkReading.Message?
    }

    public struct AgentChoice: Sendable, Equatable, Identifiable {
        public let agent: AgentType
        public let title: String
        public let detail: String
        public let isSelected: Bool
        public var id: AgentType { agent }
    }

    public struct CommandCard: Sendable, Equatable {
        public let title: String
        public let detail: String
        public let command: String
        public let note: String?
        public let copyTitle: String
        public let sendTitle: String?
        public let sharedMessage: String
    }

    public struct LinkCard: Sendable, Equatable {
        public let headline: String
        public let lines: [String]
        public let connectAnywayTitle: String?
    }

    public struct PasswordField: Sendable, Equatable {
        public let text: String
        public let note: String?
    }

    public struct SignInCard: Sendable, Equatable {
        public let title: String
        public let detail: String
        public let action: String
    }

    public struct Primary: Sendable, Equatable {
        public enum Intent: Sendable, Equatable {
            case connect, openTailscale, signIn
        }

        public let title: String
        public let intent: Intent
        public let isEnabled: Bool
        public let isLoading: Bool
    }

    public struct Demo: Sendable, Equatable {
        public let title: String
        public let detail: String
    }

    /// A link found on the pasteboard, offered and never used: the title and the machine it names,
    /// without the key, which stays in the pairing link until the person presses Connect.
    public struct Offer: Sendable, Equatable {
        public let title: String
        public let detail: String
    }

    public let mode: FirstRunState.Mode
    public let intro: String
    public let rows: [Row]
    public let primary: Primary?
    public let later: String?
    public let dismiss: String
    public let back: String?
    public let demo: Demo?
    public let offer: Offer?
    public let isFinished: Bool
    public let outcome: FirstRunState.Outcome?

    public func row(_ id: Row.ID) -> Row? { rows.first { $0.id == id } }
}

extension FirstRunPlan {
    public static func make(_ state: FirstRunState) -> FirstRunPlan {
        var rows: [Row] = []
        if state.mode == .firstRun { rows.append(tailscaleRow(state)) }
        rows.append(machineRow(state, number: rows.count + 1))
        rows.append(connectedRow(state, number: rows.count + 1))
        return FirstRunPlan(
            mode: state.mode,
            intro: FirstRunReading.intro,
            rows: rows,
            primary: primary(state),
            later: later(state),
            dismiss: later(state) ?? (state.mode == .addition ? ConnectLinkReading.notNow : FirstRunReading.later),
            back: state.way != .choosing && !state.hasLiveConnection ? FirstRunReading.back : nil,
            demo: state.mode == .firstRun && !state.hasLiveConnection ? FirstRunReading.demo : nil,
            offer: offer(state),
            isFinished: state.finished,
            outcome: state.outcome)
    }

    private static func offer(_ state: FirstRunState) -> Offer? {
        guard let link = state.clipboard, !state.hasLiveConnection, state.way != .link else {
            return nil
        }
        return FirstRunReading.clipboardOffer(link)
    }

    private static func tailscaleRow(_ state: FirstRunState) -> Row {
        let reading = state.tailscale
        let glyph: Row.Glyph
        var pill: String?
        var detail: String?
        var blocks: [Block] = []
        switch reading {
        case .none:
            glyph = .working
            pill = FirstRunReading.checking
        case .up(let address):
            glyph = .proven
            pill = address
            detail = FirstRunReading.onTailnet(state.platform)
        case .some(let reading):
            glyph = reading.blocksReaching ? .attention : .current
            if state.platform.isPhone {
                pill = FirstRunReading.notConnected
                detail = FirstRunReading.installTailscaleHere
            } else {
                pill = reading.title
                detail = reading.detail
            }
            blocks = [.remedy(reading)]
        }
        return Row(
            id: .tailscale, number: 1, title: FirstRunReading.tailscaleTitle(state.platform),
            glyph: glyph, pill: pill, detail: detail, blocks: blocks)
    }

    private static func machineRow(_ state: FirstRunState, number: Int) -> Row {
        var pill: String?
        var glyph = Row.Glyph.current
        var detail: String? = state.way == .choosing ? FirstRunReading.whatAMachineIs : nil
        switch state.machine {
        case .found(let found):
            glyph = .proven
            pill = FirstRunReading.answering(found)
        case .holdsKey:
            glyph = .proven
            pill = FirstRunReading.wantsItsPassword
        case .looking:
            glyph = .working
        case .failed:
            glyph = .attention
        case .idle:
            if state.way == .install { pill = FirstRunReading.waiting }
        }
        if state.hasLiveConnection || isSaved(state) { glyph = .proven }
        if case .holdsKey(let label, _, _) = state.machine {
            detail = FirstRunReading.holdsKey(label)
        }
        return Row(
            id: .machine, number: number, title: FirstRunReading.machineTitle, glyph: glyph,
            pill: pill, detail: detail, blocks: machineBlocks(state))
    }

    private static func isSaved(_ state: FirstRunState) -> Bool {
        if case .saved = state.connection { return true }
        return false
    }

    private static func machineBlocks(_ state: FirstRunState) -> [Block] {
        if state.hasLiveConnection { return [] }
        var blocks: [Block] = []
        switch state.way {
        case .choosing:
            blocks.append(.ways(FirstRunReading.ways(state, includingInstall: true)))
            if state.platform.watchesTailnet, !state.offersTailnetScan {
                blocks.append(.note(FirstRunReading.tailnetScanUnavailable))
            }
        case .paste:
            blocks.append(.paste(FirstRunReading.paste(state)))
        case .install:
            blocks.append(.agents(FirstRunReading.agentChoices(state)))
            if let install = state.install {
                blocks.append(.command(FirstRunReading.commandCard(install, state: state)))
            }
            blocks.append(.waiting(FirstRunReading.waitingForMachine(state.platform)))
            blocks.append(.ways(FirstRunReading.ways(state, includingInstall: false)))
        case .link:
            if let link = state.link {
                blocks.append(.link(FirstRunReading.linkCard(link, confirmed: state.offTailnetConfirmed)))
            }
        }
        blocks.append(contentsOf: statusBlocks(state))
        if state.passwordShown {
            blocks.append(.password(FirstRunPlan.PasswordField(text: state.password, note: state.passwordNote)))
        }
        return blocks
    }

    private static func statusBlocks(_ state: FirstRunState) -> [Block] {
        switch state.machine {
        case .looking(let label): return [.waiting(FirstRunReading.looking(label))]
        case .failed(let diagnosis): return [.diagnosis(diagnosis)]
        case .idle, .found, .holdsKey: return []
        }
    }

    private static func connectedRow(_ state: FirstRunState, number: Int) -> Row {
        let title = FirstRunReading.connectedTitle
        switch state.connection {
        case .saving:
            return Row(
                id: .connected, number: number, title: title, glyph: .working, pill: nil,
                detail: FirstRunReading.saving, blocks: [])
        case .failed(let diagnosis):
            return Row(
                id: .connected, number: number, title: title, glyph: .attention, pill: nil,
                detail: nil, blocks: [.diagnosis(diagnosis)])
        case .saved(let name):
            return savedRow(state, name: name, title: title, number: number)
        case .notYet:
            return notYetRow(state, title: title, number: number)
        }
    }

    private static func notYetRow(_ state: FirstRunState, title: String, number: Int) -> Row {
        switch state.machine {
        case .found(let found):
            return Row(
                id: .connected, number: number, title: title, glyph: .current, pill: nil,
                detail: FirstRunReading.savedNothing(found.label), blocks: [])
        case .holdsKey(let label, _, _):
            return Row(
                id: .connected, number: number, title: title, glyph: .current, pill: nil,
                detail: FirstRunReading.savedNothing(label), blocks: [])
        case .idle, .looking, .failed:
            return Row(
                id: .connected, number: number, title: title, glyph: .waiting, pill: nil,
                detail: nil, blocks: [])
        }
    }

    private static func savedRow(
        _ state: FirstRunState, name: String, title: String, number: Int
    ) -> Row {
        switch state.claude {
        case .checking, .notAsked:
            return Row(
                id: .connected, number: number, title: title, glyph: .working, pill: nil,
                detail: FirstRunReading.readingClaude(name), blocks: [])
        case .signedOut:
            let card = FirstRunReading.signInCard(name)
            return Row(
                id: .connected, number: number, title: title, glyph: .attention,
                pill: FirstRunReading.signedOutPill, detail: card.detail, blocks: [.signIn(card)])
        case .signedIn(let account):
            return Row(
                id: .connected, number: number, title: title, glyph: .proven,
                pill: FirstRunReading.connectedPill,
                detail: FirstRunReading.signedInDetail(name, account: account), blocks: [])
        case .cannotSay:
            return Row(
                id: .connected, number: number, title: title, glyph: .proven,
                pill: FirstRunReading.connectedPill, detail: FirstRunReading.connectedDetail(name),
                blocks: [])
        }
    }

    private static func primary(_ state: FirstRunState) -> Primary? {
        switch state.connection {
        case .saving:
            return Primary(
                title: FirstRunReading.connecting, intent: .connect, isEnabled: false, isLoading: true)
        case .saved:
            switch state.claude {
            case .signedOut:
                return Primary(
                    title: FirstRunReading.signInAction, intent: .signIn, isEnabled: true,
                    isLoading: false)
            case .checking, .notAsked:
                return Primary(
                    title: FirstRunReading.checking, intent: .connect, isEnabled: false,
                    isLoading: true)
            case .signedIn, .cannotSay:
                return nil
            }
        case .notYet, .failed:
            return machinePrimary(state)
        }
    }

    private static func machinePrimary(_ state: FirstRunState) -> Primary? {
        switch state.machine {
        case .found(let found):
            return Primary(
                title: connectTitle(state, label: found.label), intent: .connect, isEnabled: true,
                isLoading: false)
        case .holdsKey(let label, _, _):
            return Primary(
                title: connectTitle(state, label: label), intent: .connect, isEnabled: true,
                isLoading: false)
        case .looking:
            return Primary(
                title: FirstRunReading.checking, intent: .connect, isEnabled: false, isLoading: true)
        case .idle, .failed:
            if state.platform.isPhone, state.mode == .firstRun, state.tailscale?.isUp == false,
                state.way == .choosing || state.way == .install
            {
                return Primary(
                    title: FirstRunReading.openTailscale, intent: .openTailscale, isEnabled: true,
                    isLoading: false)
            }
            guard state.way == .link || state.way == .paste, hasSomethingToConnect(state) else {
                return nil
            }
            return Primary(
                title: FirstRunReading.connect, intent: .connect, isEnabled: false, isLoading: false)
        }
    }

    private static func hasSomethingToConnect(_ state: FirstRunState) -> Bool {
        state.way == .link || !state.typed.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func connectTitle(_ state: FirstRunState, label: String) -> String {
        state.mode == .addition ? FirstRunReading.addTitle(label) : FirstRunReading.connectTo(label)
    }

    private static func later(_ state: FirstRunState) -> String? {
        if case .saved = state.connection, state.claude == .signedOut { return FirstRunReading.later }
        return nil
    }
}
