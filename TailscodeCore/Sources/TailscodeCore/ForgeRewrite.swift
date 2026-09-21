import Foundation

/// What the helper is told about the clip that the words alone do not say: how long it runs and
/// how smoothly, its shape and whether that was chosen by hand, whether it opens on a picture or
/// continues a clip, what is to be heard, what to keep out, and — on a second pass — what to
/// change about the paragraph it wrote last time.
public struct ForgeRewriteContext: Sendable, Equatable {
    public var seconds: Int
    public var fps: Int
    public var size: ForgeSize
    public var sizeChosen: Bool
    public var frame: ForgeFrame?
    public var negative: String
    public var sound: String
    public var instruction: String?
    public var previous: String?

    public init(
        recipe: ForgeRecipe, sizeChosen: Bool, instruction: String? = nil, previous: String? = nil
    ) {
        seconds = recipe.seconds
        fps = recipe.fps
        size = recipe.size
        self.sizeChosen = sizeChosen
        frame = recipe.frame
        negative = recipe.negative
        sound = recipe.sound
        self.instruction = instruction
        self.previous = previous
    }

    public var isRevision: Bool {
        guard let instruction, let previous else { return false }
        return !instruction.trimmingCharacters(in: .whitespaces).isEmpty
            && !previous.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The whole question, ready for the enhancer.
    public func ask(_ brief: String) -> ImageGenRewriteAsk {
        ImageGenRewriteAsk(
            system: ForgeBrief.system, user: ForgeBrief.ask(brief, context: self),
            instruction: instruction)
    }
}

/// The rules a helper writes a video prompt to. LTX-2.5 was trained on captions of clips — one
/// paragraph that reports a shot as it plays, camera first, in the present tense, with the sound
/// named — and a request that reads as a list of nouns gets a clip that holds still. So the
/// helper is asked for the caption of the clip the person wants, and for the shape the clip
/// should be, in the same one-line JSON the image helper answers with.
public enum ForgeBrief {
    public static var system: String {
        """
        You rewrite a user's video request into the caption of the finished clip: one English \
        paragraph that reports the shot as it plays, as if you were describing it to someone \
        who cannot see the screen. You are not talking to the user and not talking to a \
        renderer.

        Open with the shot and the camera: the framing, and how the camera moves through the \
        clip, or that it holds. Then the subject and what it does, in the order it happens, \
        with concrete verbs of motion. Then the setting, the light and the colours. Close with \
        exactly one sentence on the sound — what is heard, ambient first, and any spoken line \
        in straight double quotes with who says it. Present tense, third person, declarative, \
        one continuous shot with no cuts, and everything must fit the clip's own length: a \
        five-second clip holds one action, not a sequence. Keep every count, every stated \
        colour and every quoted line the request fixed. Never write "you", "create" or "make \
        sure", never use quality boosters such as "8K", "cinematic masterpiece" or "highly \
        detailed", and never mention the frame rate, the resolution or the duration.

        Run eighty to a hundred and sixty words whether the request was three words or three \
        hundred. Hedge what is genuinely ambiguous with "appears to".

        Choose the shape from the subject unless the user gave one: 16:9 for anything that \
        reads as a film or a landscape, 9:16 for a phone screen or a standing figure, 1:1 for \
        a centred emblem. Never write the ratio into the caption itself.

        Answer with one strictly valid JSON object on a single line and nothing else:
        {"rewritten_prompt": "<the caption>", "wh_ratio": "<one of 16:9, 9:16, 1:1>"}
        """
    }

    public static func ask(_ brief: String, context: ForgeRewriteContext) -> String {
        var lines: [String] = []
        if context.isRevision, let instruction = context.instruction, let previous = context.previous {
            lines.append(
                "Revise the caption below as instructed. Keep everything the instruction does "
                    + "not touch — the same shot, the same action, the same quoted lines — and "
                    + "change only what it asks for.")
            lines.append("")
            lines.append("Instruction: \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))")
            lines.append("")
            lines.append("Previous caption: \(previous.trimmingCharacters(in: .whitespacesAndNewlines))")
            lines.append("")
            lines.append("The original request: \(brief)")
        } else {
            lines.append(
                "Rewrite this video request as the caption of the finished clip, one English "
                    + "paragraph reporting the shot as it plays.")
            lines.append("")
            lines.append("The request: \(brief)")
        }
        lines.append("")
        lines.append(contextLines(context).joined(separator: "\n"))
        lines.append("")
        lines.append("Answer with one strictly valid JSON object on a single line and nothing else:")
        lines.append("{\"rewritten_prompt\": \"<the caption>\", \"wh_ratio\": \"<one of 16:9, 9:16, 1:1>\"}")
        return lines.joined(separator: "\n")
    }

    /// Each fact the forge has that the brief does not, one line each; a fact the forge does
    /// not have is left out rather than guessed.
    static func contextLines(_ context: ForgeRewriteContext) -> [String] {
        var lines: [String] = []
        lines.append(
            "The clip runs \(context.seconds) seconds at \(context.fps) frames a second: describe "
                + "what fits in \(context.seconds) seconds and nothing that would need a cut.")
        if let frame = context.frame {
            switch frame {
            case .file, .kept:
                lines.append(
                    "The clip opens on a picture the user supplies, which becomes its first frame. "
                        + "Do not describe the still; describe what moves from it — the camera, the "
                        + "subject, the light — and assume the picture already shows the subject as "
                        + "the request names it.")
            case .clipEnd:
                lines.append(
                    "The clip continues an earlier one and opens on that clip's last frame. "
                        + "Describe what happens next, as the same shot carrying on, not a new scene.")
            }
        }
        if context.sizeChosen {
            let ratio = Self.ratioWord(for: context.size)
            lines.append("The shape is already chosen: \(ratio). Compose for it and answer wh_ratio \"\(ratio)\".")
        }
        let heard = context.sound.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heard.isEmpty {
            lines.append(
                "The user already wrote what is heard, and it is sent to the model after the "
                    + "caption: \"\(heard)\". Do not repeat it; end the caption without a sound sentence.")
        }
        let avoid = context.negative.trimmingCharacters(in: .whitespacesAndNewlines)
        if !avoid.isEmpty {
            lines.append(
                "Keep out of the clip, and do not mention: \(avoid). These are sent to the "
                    + "renderer separately as things to avoid, so the caption simply never contains them.")
        }
        return lines
    }

    /// The ratio word for a size, in the three the helper is offered.
    static func ratioWord(for size: ForgeSize) -> String {
        if size.width == size.height { return "1:1" }
        return size.width > size.height ? "16:9" : "9:16"
    }
}
