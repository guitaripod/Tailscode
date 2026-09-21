import Foundation

/// What this model wants to be told, and the studio's way of saying so without a wall of text.
///
/// Qwen-Image-2.1 was trained behind a rewriter: short asks were expanded into one long paragraph
/// describing the finished frame, and that paragraph is what the model ever saw. Three words in
/// gets a picture of three words — a menu board with no menu on it, an astronaut cat with no suit.
/// So the studio does not silently accept a thin brief: it says what a full one looks like, hands
/// over a frame to fill in, and keeps four worked examples one press away.
public enum ImageGenBrief {
    /// Under this many words, a brief is thin enough that the model is inventing most of the
    /// frame on its own. Measured rather than guessed: the failures in testing were all short.
    public static let thinWordCount = 25

    public static func words(in prompt: String) -> Int {
        prompt.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    /// Whether the words in the box are thin enough to be worth a nudge. A brief that already
    /// opens like a description is left alone however short it is — somebody writing "The image
    /// is a square logo" knows the shape and does not need telling twice.
    public static func isThin(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard words(in: trimmed) < thinWordCount else { return false }
        let opening = trimmed.lowercased()
        for start in ["the image is", "this is a", "a vertical", "a wide", "a square"] {
            if opening.hasPrefix(start) { return false }
        }
        return true
    }

    /// The nudge itself: what is wrong and what to do, in one line each. Never a block.
    public static var thinTitle: String {
        Localized.text("Thin brief")
    }

    public static var thinBody: String {
        Localized.text(
            "This model paints what it is told and invents the rest. Describing the finished "
                + "frame — what is where, what it says, how it is lit — is the difference.")
    }

    public static var craftTitle: String { Localized.text("How to describe a picture") }

    /// The whole craft, as the six decisions that actually change the picture. Each line is one
    /// rule and one example of it, because a rule with no example is a rule nobody applies.
    public struct Rule: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String

        public init(id: String, title: String, detail: String) {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    public static var rules: [Rule] {
        [
            Rule(
                id: "open",
                title: Localized.text("Open by naming the medium"),
                detail: Localized.text(
                    "\"A wide realistic photograph of…\", \"A square flat-vector poster of…\". "
                        + "The medium is the one word never left out.")),
            Rule(
                id: "place",
                title: Localized.text("Put everything somewhere"),
                detail: Localized.text(
                    "Across the top, on the left, in the lower third, tucked into the corner. "
                        + "Ten such phrases reach the edges and keep the frame locatable.")),
            Rule(
                id: "text",
                title: Localized.text("Quote every word to be read"),
                detail: Localized.text(
                    "A bold headline across the top reads \"NORTHBOUND COFFEE\". Anything not "
                        + "quoted comes back as scribble.")),
            Rule(
                id: "light",
                title: Localized.text("Give the light its own sentence"),
                detail: Localized.text(
                    "Where it comes from, how hard it is, and what it leaves behind: "
                        + "\"warm low sun from the right, long shadows to the left\".")),
            Rule(
                id: "close",
                title: Localized.text("Close on the whole frame"),
                detail: Localized.text(
                    "One sentence for balance, palette and mood. Stop there — a second summary "
                        + "costs detail elsewhere.")),
            Rule(
                id: "observe",
                title: Localized.text("Describe, never instruct"),
                detail: Localized.text(
                    "Present tense, third person, no \"make\" and no \"8K, masterpiece\". "
                        + "Quality words are noise; described detail is signal.")),
        ]
    }

    /// A frame to fill in rather than a prompt to send. The blanks are the decisions, in the
    /// order the model reads them, and it lands in the composer with the caret ready.
    public static var scaffold: String {
        Localized.text(
            "A wide realistic photograph of <subject>, <background and palette>. "
                + "In the centre of the frame, <what fills it>. "
                + "On the left side, <what sits there>. On the right, <what sits there>. "
                + "Across the lower third, <foreground>. "
                + "A <weight, colour> line across the top reads \"<exact words>\". "
                + "The lighting is <source, direction, quality>, leaving <shadows>. "
                + "The overall composition is <balance>, <palette>, <mood>.")
    }

    /// Worked examples, each one a brief that was actually rendered and came back right. They
    /// are openable, editable and send-able: the fastest way to learn the shape is to change
    /// three nouns in one that works.
    public struct Example: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        public let prompt: String
        public let aspect: ImageGenAspect

        public init(
            id: String, title: String, detail: String, prompt: String, aspect: ImageGenAspect
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.prompt = prompt
            self.aspect = aspect
        }
    }

    public static var examples: [Example] {
        [
            Example(
                id: "menu",
                title: Localized.text("A board full of text"),
                detail: Localized.text("Every price where it was put"),
                prompt: Localized.text(
                    "The image is a wide realistic photograph of a chalkboard menu on a "
                        + "whitewashed brick wall, warm amber and charcoal palette. Across the top "
                        + "of the board, a bold cream headline in hand-lettered serif capitals "
                        + "reads \"NORTHBOUND COFFEE\", underlined by a thin double rule. On the "
                        + "left side of the frame, a column headed \"ESPRESSO\" lists \"Espresso "
                        + "2.80\", \"Macchiato 3.20\", \"Cortado 3.60\". In the centre, a column "
                        + "headed \"MILK\" lists \"Flat White 4.20\", \"Cappuccino 4.00\", \"Latte "
                        + "4.20\". On the right, a narrower column headed \"BREW\" lists \"Filter "
                        + "3.00\", \"Cold Brew 4.00\". Across the lower third, a handwritten line "
                        + "in pale yellow chalk reads \"Today: Ethiopia Guji\". Tucked into the "
                        + "lower-right corner, three speckled cream cups sit on a wooden shelf "
                        + "beside a brass grinder. The lighting is warm low sun from the right, "
                        + "raking across the slate so the chalk catches. The overall composition "
                        + "is balanced and grid-like, calm and tactile."),
                aspect: .landscape),
            Example(
                id: "portrait",
                title: Localized.text("One subject, close"),
                detail: Localized.text("Walk the subject, not the room"),
                prompt: Localized.text(
                    "The image is a square photorealistic portrait of an elderly fisherman in a "
                        + "yellow oilskin, against the blurred grey of a harbour at dawn. The "
                        + "background falls off quickly, a suggestion of masts and a low stone "
                        + "wall on the far right. He is placed slightly left of centre, turned "
                        + "three-quarters toward the viewer, looking past the camera. His face is "
                        + "weathered and deeply lined, with a short white beard and pale blue "
                        + "eyes; a knitted navy cap sits low on his forehead. The oilskin is wet "
                        + "and catching light along the shoulder seam, its collar turned up. In "
                        + "the lower-left of the frame, one hand holds a coil of blue rope, the "
                        + "knuckles swollen and the nails short. The lighting is soft cold dawn "
                        + "light from the left with a faint warm bounce off the deck. The overall "
                        + "composition is a centred, shallow-depth-of-field portrait in grey, "
                        + "yellow and salt white, quiet and unsentimental."),
                aspect: .square),
            Example(
                id: "diagram",
                title: Localized.text("A labelled diagram"),
                detail: Localized.text("Leader lines and real labels"),
                prompt: Localized.text(
                    "The image is a wide technical illustration, an exploded diagram of a "
                        + "mechanical wristwatch movement on an off-white paper background with a "
                        + "faint grid. The parts float apart along a shallow diagonal, each in "
                        + "three-quarter isometric view, drawn in fine dark grey line work with "
                        + "flat brass and steel fills. In the centre sits the main plate in warm "
                        + "brass, its jewelled bearings small red dots. To its left, the mainspring "
                        + "barrel and the crown wheel; to the right, the balance wheel with its "
                        + "blued hairspring, the pallet fork and the escape wheel. Above the "
                        + "centre, the cream dial and a domed crystal. Across the top, a headline "
                        + "in small black sans capitals reads \"CALIBRE 7S — EXPLODED VIEW\". Thin "
                        + "leader lines label each part in grey sans: \"mainspring barrel\", "
                        + "\"crown wheel\", \"balance wheel\", \"pallet fork\", \"escape wheel\", "
                        + "\"main plate\", \"dial\", \"crystal\". Across the lower third, a scale "
                        + "bar labelled \"10 mm\" sits beside a note reading \"28,800 vph  21 "
                        + "jewels\". The lighting is flat even ambient light with soft contact "
                        + "shadows. The overall composition is orderly and diagrammatic, precise "
                        + "and instructional."),
                aspect: .landscape),
            Example(
                id: "cutout",
                title: Localized.text("A cutout on transparency"),
                detail: Localized.text("Pairs with the Cutout switch"),
                prompt: Localized.text(
                    "A single glossy red ceramic teapot with a bamboo handle, seen in "
                        + "three-quarter view, its lid slightly ajar, a soft highlight running "
                        + "down the left of the body and the shadow of the spout falling across "
                        + "it."),
                aspect: .square),
        ]
    }

    /// The rules a prompt helper writes to: Qwen's own rewriting spec, cut to what fits in one
    /// system turn. The studio teaches the same six rules in its own words, so what a person
    /// learns here and what the helper writes are the same shape.
    public static var expansionSystem: String {
        """
        You rewrite a user's image request into one English paragraph describing the finished         image, as if you were looking at it. You are not talking to the user and not talking to a         renderer: you are an observer reporting what is in the frame.

        Open by naming the medium, the style and the subject, in about twenty words. Keep every         string of text, every count, every stated colour and every stated position the request         fixed, and copy quoted text character for character. Place things with eight to fourteen         positional phrases that reach the corners, the edges and the centre, and open about a         third of your sentences on the position itself. Put every piece of legible text in         straight double quotes where it sits, in its own script; call a mark that is not meant to         be read blurred or too small to read rather than inventing letters. Give the lighting its         own sentence: source, direction, quality, and the shadows it leaves. Close with exactly         one sentence on balance, palette, style and mood.

        Run about twenty sentences and four to five hundred words whether the request was three         words or three hundred. Present tense, third person, declarative. Never write "you",         "create" or "make sure", and never use quality boosters such as "8K", "masterpiece" or         "highly detailed". Name colours with a modifier, give materials rather than only nouns,         enumerate rather than summarise, and hedge what is genuinely ambiguous with "appears to         be" or "likely". People get their observable surface and a life stage rather than an age         in years. Everything must hold together physically. The description is always in English,         except text shown inside the image, which stays in its own script.

        A request that edits a picture names it as <image1>, <image2> and so on: keep those         tokens exactly where the request uses them, describe what changes, and leave what the         request does not mention as it is in the picture.

        Choose the aspect ratio from the subject unless the user gave one: 3:2 for horizontal,         2:3 for vertical, 1:1 for a badge, icon, album cover or centred emblem, 16:9 for a wide         cinematic frame, 9:16 for a phone screen or tall banner, 21:9 for an ultra-wide panorama.         Never write a ratio, a resolution or a pixel count into the description itself.

        Answer with one strictly valid JSON object on a single line and nothing else:
        {"rewritten_prompt": "<the description>", "wh_ratio": "<e.g. 3:2>"}
        """
    }

    /// The instruction handed to a model that is asked to expand a thin brief. It is Qwen's own
    /// rewriting rules, cut to what fits in one turn: the shape, the length, the register, and
    /// the one-line JSON that comes back so the ratio can be read off it too.
    public static func expansionAsk(_ brief: String) -> String {
        expansionAsk(brief, context: ImageGenRewriteContext())
    }

    /// The same ask with everything the helper is otherwise blind to: which engine paints, the
    /// shape already chosen, the pictures the words address, what to keep out of the frame, and
    /// — on a second pass — the paragraph to revise and what to change about it.
    public static func expansionAsk(_ brief: String, context: ImageGenRewriteContext) -> String {
        var lines: [String] = []
        if context.isRevision, let instruction = context.instruction, let previous = context.previous {
            lines.append(
                "Revise the description below as instructed. Keep everything the instruction "
                    + "does not touch — the same subject, the same placements, the same quoted text "
                    + "— and change only what it asks for.")
            lines.append("")
            lines.append("Instruction: \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))")
            lines.append("")
            lines.append("Previous description: \(previous.trimmingCharacters(in: .whitespacesAndNewlines))")
            lines.append("")
            lines.append("The original request: \(brief)")
        } else {
            lines.append(
                "Rewrite this image request as one English paragraph describing the finished "
                    + "image, as if you were looking at it.")
            lines.append("")
            lines.append("Rules: open by naming the medium, the style and the subject. Keep every "
                + "string of text, every count, every stated colour and position the request "
                + "fixed, and copy quoted text character for character. Place elements with "
                + "eight to fourteen positional phrases that reach the corners and edges. Put "
                + "each piece of legible text in straight double quotes where it sits. Give the "
                + "lighting its own sentence. Close with one sentence on balance, palette and "
                + "mood. Around twenty sentences, four to five hundred words, present tense, "
                + "third person, observing rather than instructing. No quality boosters, no "
                + "\"8K\", no \"masterpiece\". Hedge what is genuinely ambiguous.")
            lines.append("")
            lines.append("The request: \(brief)")
        }
        lines.append("")
        lines.append(contextLines(context).joined(separator: "\n"))
        lines.append("")
        lines.append("Answer with one strictly valid JSON object on a single line and nothing else:")
        lines.append(
            "{\"rewritten_prompt\": \"<the description>\", \"wh_ratio\": \"<one of 1:1, 3:2, 2:3, 16:9, 9:16, 21:9>\"}")
        return lines.joined(separator: "\n")
    }

    /// What the helper is told about the render that the brief itself does not say. Each fact
    /// is one line, and a fact the studio does not have is left out rather than guessed.
    static func contextLines(_ context: ImageGenRewriteContext) -> [String] {
        var lines: [String] = []
        switch context.engine {
        case .quality:
            lines.append("The picture is painted by Qwen Image 2.1, which reads a long description best.")
        case .fast:
            lines.append(
                "The picture is painted by FLUX.2 Klein in four steps: keep the description to "
                    + "its strongest elements rather than every corner, around two hundred words.")
        }
        if context.referenceCount > 0 {
            let names = (1...context.referenceCount).map { "<image\($0)>" }.joined(separator: ", ")
            lines.append(
                context.referenceCount == 1
                    ? "The words edit a reference picture the request calls <image1>. Keep that token exactly where the request uses it, describe what changes, and leave what the request does not mention as it is in the picture."
                    : "The words edit \(context.referenceCount) reference pictures the request calls \(names). Keep those tokens exactly where the request uses them, describe what changes, and leave what the request does not mention as it is in the pictures.")
            lines.append("Answer wh_ratio with the shape the edited picture already has if the request implies one, else \"1:1\".")
        } else if let aspect = context.aspect {
            lines.append(
                "The shape is already chosen: \(aspect.ratioLabel). Compose for it and answer wh_ratio \"\(aspect.ratioLabel)\".")
        }
        let avoid = context.negative.trimmingCharacters(in: .whitespacesAndNewlines)
        if !avoid.isEmpty {
            lines.append(
                "Keep out of the frame, and do not mention: \(avoid). These are sent to the painter "
                    + "separately as things to avoid, so the description simply never contains them.")
        }
        return lines
    }

    /// Reads back what a model answered the expansion ask with. A model that wrapped the JSON in
    /// prose, or in a fence, is still answering — the object is found rather than demanded.
    public static func readExpansion(_ answer: String) -> (prompt: String, aspect: ImageGenAspect?)? {
        let text = stripThinking(answer)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
            start < end
        else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let prompt = object["rewritten_prompt"] as? String,
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let ratio = (object["wh_ratio"] as? String).flatMap(aspect(forRatio:))
        return (prompt.trimmingCharacters(in: .whitespacesAndNewlines), ratio)
    }

    /// The paragraph so far, read out of a JSON object that is still being written. A model
    /// streams the object a token at a time, so the string behind `rewritten_prompt` is decoded
    /// up to wherever the stream has reached — escapes and all — and a model that skipped the
    /// JSON and is writing prose is shown as it writes. Empty while the answer has not reached
    /// the paragraph yet, which is what a card should show rather than a brace.
    public static func partialExpansion(_ answer: String) -> String {
        let text = stripThinking(answer)
        if let keyRange = text.range(of: "\"rewritten_prompt\"") {
            var cursor = keyRange.upperBound
            guard let colon = text[cursor...].firstIndex(of: ":") else { return "" }
            cursor = text.index(after: colon)
            guard let quote = text[cursor...].firstIndex(of: "\"") else { return "" }
            cursor = text.index(after: quote)
            return decodeJSONString(text[cursor...])
        }
        let opening = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if opening.isEmpty { return "" }
        if opening.hasPrefix("{") || opening.hasPrefix("`") { return "" }
        let head = opening.prefix(24).lowercased()
        if head.hasPrefix("json") || head.hasPrefix("here") && head.contains("{") { return "" }
        return opening
    }

    /// Decodes the body of a JSON string up to its closing quote or the end of what has arrived.
    /// A trailing lone backslash is left for the next token to complete.
    static func decodeJSONString(_ raw: Substring) -> String {
        var out = ""
        var iterator = raw.makeIterator()
        while let character = iterator.next() {
            if character == "\"" { break }
            guard character == "\\" else {
                out.append(character)
                continue
            }
            guard let escaped = iterator.next() else { break }
            switch escaped {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b", "f": break
            case "u":
                var hex = ""
                for _ in 0..<4 {
                    guard let digit = iterator.next() else { return out }
                    hex.append(digit)
                }
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                    out.unicodeScalars.append(scalar)
                }
            default: out.append(escaped)
            }
        }
        return out
    }

    /// A model that thinks aloud wraps it in `<think>` tags, closed or — while it is still
    /// thinking — not. Neither is the paragraph.
    public static func stripThinking(_ answer: String) -> String {
        var text = answer
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        return text
    }

    /// The shape chip that matches a ratio the rewriter chose, when one of them does.
    public static func aspect(forRatio ratio: String) -> ImageGenAspect? {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        let wanted = parts[0] / parts[1]
        return ImageGenAspect.allCases.min {
            abs(log(Double($0.ratio.width) / Double($0.ratio.height)) - log(wanted))
                < abs(log(Double($1.ratio.width) / Double($1.ratio.height)) - log(wanted))
        }
    }
}
