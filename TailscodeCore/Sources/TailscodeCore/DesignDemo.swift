import Foundation

/// A board with no server behind it, so every client can open the design surface and be
/// photographed without spending minutes of somebody's machine drawing mocks first. The markup is
/// the real thing — self-contained, light and dark, sized for a phone — because a demo that draws
/// something the real path could not render proves nothing about the real path.
public enum DesignDemo {
    public static let directory = ".tailscode/design/composer-0818-1423"

    public static var board: DesignBoard {
        DesignBoard(
            directory: directory,
            manifest: DesignManifest(
                title: "Composer redesign",
                brief: "redesign the composer around what people actually use it for",
                artboards: [
                    DesignArtboard(
                        letter: "A", name: "Conservative",
                        rationale:
                            "Keeps the layout exactly as it is and swaps one control: the seldom-used tool menu becomes the model switch. Nothing to relearn, and almost nothing gained.",
                        file: "A.html",
                        notes: [
                            "Switch model takes the slot MCP had.",
                            "Everything else stays where a hand already expects it.",
                        ]),
                    DesignArtboard(
                        letter: "B", name: "Adaptive row",
                        rationale:
                            "The three actions this person reaches for stay one tap away and the long tail folds under a plus. Costs a moment of learning; wins a tap on almost every message.",
                        file: "B.html",
                        notes: [
                            "The row is ordered by what was used, not by what shipped.",
                            "The long tail folds under +, never disappears.",
                            "Send stays anchored bottom-right through every state.",
                        ]),
                    DesignArtboard(
                        letter: "C", name: "Dense icons",
                        rationale:
                            "Every action visible at once as a glyph. Fastest for someone who has learned it, and unreadable for everyone else.",
                        file: "C.html",
                        notes: [
                            "Nine actions in the height of one line of text.",
                            "No labels — the tooltip is the only teacher.",
                        ]),
                ]))
    }

    public static var pages: [String: String] {
        ["A": mock(letter: "A", title: "Conservative", body: conservative),
         "B": mock(letter: "B", title: "Adaptive row", body: adaptive),
         "C": mock(letter: "C", title: "Dense icons", body: dense)]
    }

    private static func mock(letter: String, title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
          color-scheme: light dark;
          --ink: #16181d; --dim: #6b7280; --canvas: #f6f7f9; --card: #ffffff;
          --rule: #e3e6ea; --accent: #2f6df6; --chip: #f1f3f6;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --ink: #e8eaee; --dim: #9aa3b2; --canvas: #101216; --card: #181b21;
            --rule: #262b33; --accent: #6f9bff; --chip: #22262e;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; background: var(--canvas); color: var(--ink);
          font: 15px/1.5 -apple-system, "SF Pro Text", Inter, "Segoe UI", system-ui, sans-serif;
          padding: 22px 18px 30px;
        }
        .frame { max-width: 620px; margin: 0 auto; }
        .head { display: flex; align-items: baseline; gap: 10px; margin-bottom: 14px; }
        .letter {
          font-weight: 700; font-size: 12px; letter-spacing: .08em;
          background: var(--accent); color: #fff; border-radius: 4px; padding: 3px 7px;
        }
        .head h1 { font-size: 15px; font-weight: 600; margin: 0; }
        .head span { color: var(--dim); font-size: 13px; }
        .turn { color: var(--dim); font-size: 14px; margin: 0 0 18px; }
        .turn b { color: var(--ink); font-weight: 600; }
        .composer {
          background: var(--card); border: 1px solid var(--rule); border-radius: 14px;
          padding: 12px 14px; box-shadow: 0 1px 2px rgba(0,0,0,.05);
        }
        .field { color: var(--dim); padding: 4px 0 12px; }
        .row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
        .grow { flex: 1; }
        .chip {
          display: inline-flex; align-items: center; gap: 6px; font-size: 13px;
          background: var(--chip); border-radius: 999px; padding: 6px 11px; color: var(--ink);
          border: 1px solid transparent; white-space: nowrap;
        }
        .chip.ghost { background: transparent; border-color: var(--rule); color: var(--dim); }
        .icon {
          width: 30px; height: 30px; border-radius: 8px; background: var(--chip);
          display: inline-flex; align-items: center; justify-content: center; font-size: 14px;
        }
        .send {
          width: 32px; height: 32px; border-radius: 50%; background: var(--accent); color: #fff;
          display: inline-flex; align-items: center; justify-content: center; font-size: 15px;
        }
        .foot { color: var(--dim); font-size: 12px; margin-top: 10px; }
        </style></head><body><div class="frame">
        <div class="head"><span class="letter">\(letter)</span><h1>\(title)</h1><span>composer</span></div>
        <p class="turn"><b>You</b> — redesign the composer based on what people actually use it for</p>
        \(body)
        </div></body></html>
        """
    }

    private static let conservative = """
        <div class="composer">
          <div class="field">What are we building today?</div>
          <div class="row">
            <span class="chip ghost">📎 Attach</span>
            <span class="chip ghost">⌥ Switch model</span>
            <span class="chip ghost">🎙 Dictate</span>
            <span class="grow"></span>
            <span class="chip">Opus ⌄</span>
            <span class="send">↑</span>
          </div>
        </div>
        <p class="foot">One control changed. Everything else is where it was yesterday.</p>
        """

    private static let adaptive = """
        <div class="composer">
          <div class="row" style="margin-bottom:10px">
            <span class="chip">⌥ Switch model</span>
            <span class="chip">📎 Attach</span>
            <span class="chip">🎙 Dictate</span>
            <span class="chip ghost">More ⌄</span>
          </div>
          <div class="field">What are we building today?</div>
          <div class="row">
            <span class="chip ghost">+</span>
            <span class="grow"></span>
            <span class="chip">Opus ⌄</span>
            <span class="send">↑</span>
          </div>
        </div>
        <p class="foot">The row is ordered by use. The tail folds under +.</p>
        """

    private static let dense = """
        <div class="composer">
          <div class="field">What are we building today?</div>
          <div class="row">
            <span class="icon">📎</span><span class="icon">⌥</span><span class="icon">🎙</span>
            <span class="icon">⌘</span><span class="icon">🧠</span><span class="icon">⚙︎</span>
            <span class="icon">↺</span><span class="icon">⋯</span>
            <span class="grow"></span>
            <span class="send">↑</span>
          </div>
        </div>
        <p class="foot">Nine actions in one line. Learn it once, or never.</p>
        """
}
