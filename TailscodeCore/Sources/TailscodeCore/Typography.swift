import Foundation

/// Which of the three size preferences a role answers to. The reason to enlarge a transcript
/// (reading) is not the reason to enlarge a sidebar (glancing), and code that rewraps is worse than
/// code that stays put, so a role declares the axis it belongs to rather than one global step.
public enum TypeAxis: String, CaseIterable, Sendable {
    case chrome
    case prose
    case mono
}

/// The face a role is set in. `prose` and `mono` are decisions — one is read, the other is aligned
/// and counted — while `canvas` is the client's own voice for the two things a person says and the
/// machine echoes: the prompt and the composer. A terminal-grade canvas answers it in monospace, a
/// platform whose materials Apple drew answers it in the system face, and neither is wrong.
public enum TypeFamily: String, CaseIterable, Sendable {
    case prose
    case mono
    case canvas
}

/// The four weights an interface can actually spend. Anything lighter than regular is unreadable on
/// a dark canvas and anything heavier than bold is shouting, so the ramp stops at both ends: the
/// value is the CSS number, and every toolkit maps it to its own nearest real face.
public enum TypeWeight: Int, CaseIterable, Sendable, Comparable {
    case regular = 400
    case medium = 500
    case semibold = 600
    case bold = 700

    public static func < (lhs: TypeWeight, rhs: TypeWeight) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Whether digits keep their own widths or share one. Anything that changes while you watch it —
/// a token count, an age, a price, a gauge — is set in tabular figures, because a number that
/// shifts its neighbours every second reads as motion rather than as a fact.
public enum TypeFigures: String, Sendable {
    case natural
    case tabular
}

/// The families of role, which is what a type ramp is for: everything in one group is set to be
/// read against everything else in it, and the groups are told apart at a glance without reading a
/// word.
public enum TypeGroup: String, CaseIterable, Sendable {
    /// What the two of you said: the prompt, the answer, the thinking behind it.
    case speech
    /// What the machine did: tools, output, code, diffs, paths.
    case machine
    /// The scaffolding around a passage — headlines, cards, seams, options.
    case structure
    /// A screen made of readings rather than of prose: usage, analytics, the account.
    case panel
    /// Lists and trees, which are glanced at rather than read.
    case navigation
    /// The bars, pills, badges and identities that frame the canvas.
    case chrome
    /// Numbers, which are a group because they are set differently from words.
    case figures
    /// A fan-out reporting on itself.
    case workflow
}

/// One role's full type setting, with every axis a client could get wrong stated once.
public struct TypeSpec: Sendable, Equatable {
    public let axis: TypeAxis
    public let family: TypeFamily
    /// Size as a multiple of the client's base for this axis — a phone's body point size, a Mac's
    /// 13pt token, a desktop's rem — so one ramp survives three very different bases.
    public let ratio: Double
    public let weight: TypeWeight
    /// Letter spacing in ems. Positive opens a small tracked label; negative tightens a display
    /// number, which is the only place tightening is ever an improvement.
    public let tracking: Double
    /// Line height as a multiple of **the face's own leading**, which is what every toolkit here
    /// actually multiplies (GTK's `line-height`, AppKit and UIKit's `lineHeightMultiple`) — never a
    /// multiple of the point size. A face already leads itself by about a third of its size, so the
    /// numbers that buy a paragraph air live just above 1, and 1 itself — the face left alone — is
    /// right for anything that is one line by construction.
    public let lineHeight: Double
    public let figures: TypeFigures
    public let italic: Bool

    public init(
        axis: TypeAxis,
        family: TypeFamily,
        ratio: Double,
        weight: TypeWeight = .regular,
        tracking: Double = 0,
        lineHeight: Double = 1,
        figures: TypeFigures = .natural,
        italic: Bool = false
    ) {
        self.axis = axis
        self.family = family
        self.ratio = ratio
        self.weight = weight
        self.tracking = tracking
        self.lineHeight = lineHeight
        self.figures = figures
        self.italic = italic
    }

    /// The size this role wants, given the client's base for the axis and the person's preference.
    public func size(base: Double, scale: Double = 1) -> Double {
        base * ratio * scale
    }

    /// Tracking as a distance, which is what every toolkit actually takes.
    public func tracking(forSize size: Double) -> Double {
        tracking * size
    }
}

/// Every place the app sets type, named by what it is saying rather than by how big it is.
public enum TypeRole: String, CaseIterable, Sendable {
    case prompt
    case promptGlyph
    case answer
    case thought
    case thoughtLabel
    case interruption
    case tableHeader
    case tableCell

    case toolName
    case toolDetail
    case toolOutput
    case code
    case codeLabel
    case codeAction
    case diff
    case attachment
    case treeRow
    case treePath

    case headline
    case paneHeadline
    case cardTitle
    case cardBody
    case option
    case seamLabel
    case seamFootnote
    case panelTitle
    case panelLabel
    case panelDetail
    case panelFootnote
    case control
    case pairingCode

    case rowTitle
    case rowTitleStrong
    case rowDetail
    case rowMeta
    case rowStamp
    case rowNote
    case sectionLabel
    case hint

    case statusLine
    case segment
    case pill
    case badge
    case paneIdentity
    case chip
    case composer
    case banner
    case note

    case metricHero
    case metricLarge
    case metricValue
    case metricLabel
    case metricDetail
    case gauge
    case gaugeCaption

    case workflowName
    case workflowSummary
    case workflowMeter
    case workflowStep
    case workflowModel
}

/// The app's type ramp: one table, three clients, no client inventing a size or a weight.
///
/// A transcript is a conversation between two voices, and for a long time both were set identically
/// — same face, same weight, same size — which left an accent rule doing all the work of saying who
/// was speaking. Type can say it by itself, so it does: **the prompt is the heavier voice** and the
/// answer the lighter one, because the question is a heading over its own answer and a paragraph of
/// medium is a label while a paragraph of regular is prose. The answer gets the leading instead —
/// it is the thing actually being read, and air is worth more to it than weight.
///
/// Past the two voices the ramp spends four axes rather than one. Size separates the groups, weight
/// separates a name from its detail *inside* a group (a tool's name is semibold and its arguments
/// are not), tracking is spent only on the two extremes — small tracked labels that would otherwise
/// clot, and display numbers that would otherwise sprawl — and figures are tabular everywhere a
/// number changes under the reader. Nothing here is decoration: every step exists to answer a
/// question a reader was going to ask anyway.
public enum Typography {
    public static func spec(_ role: TypeRole) -> TypeSpec {
        switch role {
        case .prompt:
            return TypeSpec(
                axis: .prose, family: .canvas, ratio: 0.92, weight: .medium, lineHeight: 1.04)
        case .promptGlyph:
            return TypeSpec(axis: .prose, family: .canvas, ratio: 0.92, weight: .bold)
        case .answer:
            return TypeSpec(axis: .prose, family: .prose, ratio: 0.98, lineHeight: 1.08)
        case .thought:
            return TypeSpec(
                axis: .prose, family: .prose, ratio: 0.9, lineHeight: 1.06, italic: true)
        case .thoughtLabel:
            return TypeSpec(
                axis: .mono, family: .mono, ratio: 0.78, weight: .semibold, tracking: 0.06)
        case .interruption:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.8, italic: true)
        case .tableHeader:
            return TypeSpec(
                axis: .prose, family: .prose, ratio: 0.92, weight: .semibold, tracking: 0.02)
        case .tableCell:
            return TypeSpec(
                axis: .prose, family: .prose, ratio: 0.92, figures: .tabular)

        case .toolName:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.88, weight: .semibold)
        case .toolDetail:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.88)
        case .toolOutput:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.82, lineHeight: 1.1)
        case .code:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.85, lineHeight: 1.15)
        case .codeLabel:
            return TypeSpec(
                axis: .mono, family: .mono, ratio: 0.75, weight: .medium, tracking: 0.06)
        case .codeAction:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.75, weight: .medium)
        case .diff:
            return TypeSpec(
                axis: .mono, family: .mono, ratio: 0.85, figures: .tabular)
        case .attachment:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.88, weight: .medium)
        case .treeRow:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.85)
        case .treePath:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.78)

        case .headline:
            return TypeSpec(
                axis: .prose, family: .prose, ratio: 1.15, weight: .bold, tracking: -0.01)
        case .cardTitle:
            return TypeSpec(
                axis: .prose, family: .prose, ratio: 0.95, weight: .semibold, tracking: -0.005)
        case .cardBody:
            return TypeSpec(axis: .prose, family: .prose, ratio: 0.9, lineHeight: 1.06)
        case .option:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.88, weight: .medium)
        case .seamLabel:
            return TypeSpec(
                axis: .prose, family: .mono, ratio: 0.78, weight: .semibold, tracking: 0.1)
        case .seamFootnote:
            return TypeSpec(axis: .prose, family: .prose, ratio: 0.82, lineHeight: 1.05)
        case .paneHeadline:
            return TypeSpec(
                axis: .prose, family: .mono, ratio: 1.1, weight: .bold, tracking: 0.04)
        case .panelTitle:
            return TypeSpec(
                axis: .chrome, family: .prose, ratio: 1.05, weight: .semibold, tracking: -0.005)
        case .panelLabel:
            return TypeSpec(axis: .chrome, family: .prose, ratio: 0.88)
        case .panelDetail:
            return TypeSpec(axis: .chrome, family: .prose, ratio: 0.82)
        case .panelFootnote:
            return TypeSpec(axis: .chrome, family: .prose, ratio: 0.75)
        case .control:
            return TypeSpec(axis: .chrome, family: .prose, ratio: 0.85, weight: .medium)
        case .pairingCode:
            return TypeSpec(
                axis: .prose, family: .mono, ratio: 1.6, weight: .bold, tracking: 0.12,
                figures: .tabular)

        case .rowTitle:
            return TypeSpec(axis: .chrome, family: .prose, ratio: 0.92)
        case .rowTitleStrong:
            return TypeSpec(axis: .chrome, family: .prose, ratio: 0.92, weight: .semibold)
        case .rowDetail:
            return TypeSpec(axis: .chrome, family: .mono, ratio: 0.78)
        case .rowMeta:
            return TypeSpec(axis: .chrome, family: .mono, ratio: 0.78, weight: .medium)
        case .rowStamp:
            return TypeSpec(axis: .chrome, family: .mono, ratio: 0.75, figures: .tabular)
        case .rowNote:
            return TypeSpec(axis: .chrome, family: .mono, ratio: 0.72, weight: .medium)
        case .sectionLabel:
            return TypeSpec(
                axis: .chrome, family: .prose, ratio: 0.72, weight: .bold, tracking: 0.09)
        case .hint:
            return TypeSpec(axis: .chrome, family: .mono, ratio: 0.72)

        case .statusLine:
            return TypeSpec(
                axis: .mono, family: .mono, ratio: 0.82, weight: .medium, figures: .tabular)
        case .segment:
            return TypeSpec(
                axis: .mono, family: .mono, ratio: 0.78, weight: .medium, figures: .tabular)
        case .pill:
            return TypeSpec(
                axis: .chrome, family: .mono, ratio: 0.72, weight: .semibold, tracking: 0.03)
        case .badge:
            return TypeSpec(
                axis: .mono, family: .mono, ratio: 0.72, weight: .bold, tracking: 0.03)
        case .paneIdentity:
            return TypeSpec(
                axis: .mono, family: .mono, ratio: 0.72, weight: .medium, tracking: 0.03)
        case .chip:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.78, weight: .medium)
        case .composer:
            return TypeSpec(axis: .prose, family: .canvas, ratio: 0.95, lineHeight: 1.05)
        case .banner:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.85, weight: .medium)
        case .note:
            return TypeSpec(axis: .chrome, family: .mono, ratio: 0.78)

        case .metricHero:
            return TypeSpec(
                axis: .chrome, family: .prose, ratio: 2.1, weight: .bold, tracking: -0.02,
                figures: .tabular)
        case .metricLarge:
            return TypeSpec(
                axis: .chrome, family: .prose, ratio: 1.6, weight: .bold, tracking: -0.015,
                figures: .tabular)
        case .metricValue:
            return TypeSpec(
                axis: .chrome, family: .prose, ratio: 0.9, weight: .semibold, figures: .tabular)
        case .metricLabel:
            return TypeSpec(
                axis: .chrome, family: .prose, ratio: 0.72, weight: .medium, tracking: 0.08)
        case .metricDetail:
            return TypeSpec(axis: .chrome, family: .prose, ratio: 0.78, figures: .tabular)
        case .gauge:
            return TypeSpec(
                axis: .chrome, family: .mono, ratio: 0.75, weight: .medium, figures: .tabular)
        case .gaugeCaption:
            return TypeSpec(axis: .chrome, family: .mono, ratio: 0.68, figures: .tabular)

        case .workflowName:
            return TypeSpec(
                axis: .mono, family: .mono, ratio: 0.9, weight: .bold, tracking: 0.01)
        case .workflowSummary:
            return TypeSpec(axis: .prose, family: .prose, ratio: 0.85, lineHeight: 1.06)
        case .workflowMeter:
            return TypeSpec(
                axis: .mono, family: .mono, ratio: 0.8, weight: .medium, tracking: -0.04,
                figures: .tabular)
        case .workflowStep:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.78)
        case .workflowModel:
            return TypeSpec(axis: .mono, family: .mono, ratio: 0.72, weight: .medium)
        }
    }

    public static func group(_ role: TypeRole) -> TypeGroup {
        switch role {
        case .prompt, .promptGlyph, .composer, .answer, .thought, .thoughtLabel, .interruption,
            .tableHeader, .tableCell:
            return .speech
        case .toolName, .toolDetail, .toolOutput, .code, .codeLabel, .codeAction, .diff, .attachment,
            .treeRow, .treePath:
            return .machine
        case .headline, .paneHeadline, .cardTitle, .cardBody, .option, .seamLabel, .seamFootnote,
            .pairingCode:
            return .structure
        case .panelTitle, .panelLabel, .panelDetail, .panelFootnote, .control:
            return .panel
        case .rowTitle, .rowTitleStrong, .rowDetail, .rowMeta, .rowStamp, .rowNote, .sectionLabel,
            .hint:
            return .navigation
        case .statusLine, .segment, .pill, .badge, .paneIdentity, .chip, .banner, .note:
            return .chrome
        case .metricHero, .metricLarge, .metricValue, .metricLabel, .metricDetail, .gauge,
            .gaugeCaption:
            return .figures
        case .workflowName, .workflowSummary, .workflowMeter, .workflowStep, .workflowModel:
            return .workflow
        }
    }

    public static func roles(in group: TypeGroup) -> [TypeRole] {
        TypeRole.allCases.filter { self.group($0) == group }
    }
}
