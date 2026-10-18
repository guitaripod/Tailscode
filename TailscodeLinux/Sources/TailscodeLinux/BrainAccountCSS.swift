import Foundation
import TailscodeCore

/// The account's rules, typed by roles from Core's ramp and coloured by the theme's slots, in the
/// sizes the design was argued in: a note is the answer's own type at 15 over 24, a work line is
/// 36 tall, the card under the cursor hangs 36 in from the left on a three-point edge in its
/// zone's tone, and the thing that needs you is the one place the warning colour is a surface.
enum BrainAccountCSS {
    static func rules(palette: Palette, t: (TypeRole) -> String) -> String {
        let canvas = palette.canvas
        let raised = palette.canvasRaised
        let rule = palette.rule
        let text = palette.text
        let dim = palette.textDim
        let accent = palette.accent
        let warn = palette.warn
        let danger = palette.danger
        let info = palette.info
        let special = palette.special
        let rule2 = Contrast.blend(canvas, dim, 0.34) ?? rule
        let say = Contrast.blend(info, accent, 0.45) ?? accent
        let zones: [(String, String)] = [
            ("think", text), ("sense", info), ("act", accent), ("shell", special), ("delegate", dim),
            ("say", say),
        ]
        var tones = ""
        for (name, color) in zones {
            tones += """
            .bn-dcard.bn-z-\(name) { border-left-color: \(color); }
            .bn-detail .bn-page.bn-z-\(name) { border-left-color: \(color); }

            """
        }
        return """
        .bn-account { border-left: 1px solid \(rule2); }
        .bn-ac-head { padding: 0px 0px 0px 0px; }
        .bn-ac-title { color: \(text); }
        .bn-ac-count { \(t(.rowStamp)) color: \(dim); }
        .bn-story { outline: none; background-color: transparent; }
        .bn-story:focus-visible { outline: 2px solid alpha(\(accent), 0.55); outline-offset: -2px; border-radius: 4px; }

        .bn-said { border-left: 3px solid \(accent); border-radius: 0px; }
        .bn-said-body { padding: 2px 56px 2px 16px; }
        .bn-said.bn-cursor { background-color: alpha(\(accent), 0.07); border-radius: 0px 8px 8px 0px; }
        .bn-said:hover { background-color: alpha(\(accent), 0.04); border-radius: 0px 8px 8px 0px; }
        .bn-said.bn-cursor:hover { background-color: alpha(\(accent), 0.07); }
        .bn-spk { margin-bottom: 4px; min-height: 16px; }
        .bn-spk-name { \(t(.sectionLabel)) color: \(text); }
        .bn-spk-clock { \(t(.rowStamp)) color: \(dim); }
        .bn-just { \(t(.sectionLabel)) color: \(accent); margin-left: 8px; }
        .bn-said-text { \(t(.answer)) color: \(text); }
        button.bn-sn {
            background: none;
            border: none;
            box-shadow: none;
            padding: 0px 2px;
            min-height: 0;
            min-width: 0;
        }
        .bn-sn-text { \(t(.rowStamp)) color: \(dim); }
        button.bn-sn:hover .bn-sn-text, button.bn-sn:focus-visible .bn-sn-text { color: \(accent); }
        .bn-act { }
        .bn-acts { }

        .bn-thought-row { padding: 0px 8px 0px 19px; min-height: 24px; border-radius: 6px; }
        .bn-thought-row.bn-cursor { background-color: alpha(\(accent), 0.07); }
        .bn-thought-row:hover { background-color: alpha(\(accent), 0.04); }
        .bn-thought-text { \(t(.thought)) color: \(dim); }

        .bn-wl {
            min-height: 36px;
            padding: 0px 12px 0px 10px;
            border: 1px solid \(rule);
            border-radius: 8px;
            background-color: \(raised);
        }
        .bn-wl:hover { border-color: \(rule2); }
        .bn-open > .bn-wl { border-bottom-left-radius: 0px; border-bottom-right-radius: 0px; border-color: \(rule2); }
        .bn-wl-chev { \(t(.rowStamp)) color: \(dim); }
        .bn-live-word { \(t(.cardTitle)) }
        .bn-live-counts { \(t(.rowStamp)) }
        .bn-lc-title { \(t(.rowTitleStrong)) }
        .bn-lc-arg { \(t(.rowDetail)) }
        .bn-lc-out { \(t(.rowDetail)) }
        .bn-lc-quote { \(t(.thought)) }
        .bn-lc-speaker { \(t(.rowTitleStrong)) }
        .bn-now-title { \(t(.rowTitleStrong)) color: \(text); }
        .bn-now-arg { \(t(.rowDetail)) color: \(dim); }
        .bn-wc { \(t(.control)) color: \(text); }
        .bn-wc-dot { \(t(.control)) color: \(dim); }
        .bn-wc-more { \(t(.control)) color: \(dim); }
        .bn-wc-dot { padding: 0px 8px; }
        .bn-wf-text { \(t(.control)) color: \(text); }
        .bn-wf-fixed { color: \(warn); }
        .bn-wf-failed { color: \(danger); }
        .bn-wfile { \(t(.toolDetail)) color: \(text); }
        .bn-wrows {
            border: 1px solid \(rule2);
            border-top: none;
            border-radius: 0px 0px 8px 8px;
            padding: 4px 0px;
            background-color: alpha(\(raised), 0.6);
        }
        .bn-wrows-canvas { background: transparent; }

        .bn-dcard {
            margin: 4px 12px 8px 36px;
            border: 1px solid \(rule2);
            border-left: 3px solid \(accent);
            border-radius: 8px;
            background-color: \(canvas);
            padding: 0px 14px 6px 14px;
        }
        .bn-dcard-flat { margin-left: 0px; }
        .bn-dcard-preview { border-style: dashed; border-left-style: solid; opacity: 0.92; }
        .bn-dcard .bn-ro-head { padding: 0px; }
        .bn-dcard .bn-ro-body { padding: 0px; }
        .bn-dcard .bn-ro-foot { padding: 0px; margin-top: 8px; }
        .bn-dcard-live { margin-bottom: 4px; }
        \(tones)
        .bn-detail { border-left: none; }
        .bn-detail .bn-page { border-left: 3px solid \(rule2); padding-left: 16px; }
        .bn-detail .bn-ro-head { padding: 0px 12px 0px 0px; }
        .bn-detail .bn-ro-body { padding: 4px 12px 12px 0px; }
        .bn-detail .bn-ro-foot { padding: 0px 12px 0px 0px; }

        .bn-ask-card {
            padding: 14px 16px 14px 19px;
            border: 1px solid alpha(\(warn), 0.55);
            border-left: 3px solid \(warn);
            border-radius: 0px 10px 10px 0px;
            background-color: alpha(\(warn), 0.09);
            box-shadow: 0px 8px 20px alpha(black, 0.18);
        }
        .bn-ask-cmd {
            padding: 8px 12px;
            border-radius: 6px;
            background-color: alpha(\(canvas), 0.7);
            border: 1px solid \(rule2);
        }
        .bn-ask-option {
            \(t(.chip))
            color: \(text);
            border: 1px solid \(rule2);
            border-radius: 12px;
            padding: 2px 10px;
        }
        button.bn-ask-ghost {
            \(t(.control))
            color: \(text);
            background-color: transparent;
            background-image: none;
            border: 1px solid \(rule2);
            border-radius: 16px;
            padding: 0px 14px;
            min-height: 30px;
            box-shadow: none;
        }
        button.bn-ask-ghost:hover, button.bn-ask-ghost:focus-visible { border-color: \(accent); }

        .bn-answer-row { padding: 12px 56px 12px 19px; border-top: 1px solid \(rule); }
        .bn-answer-label { color: \(dim); margin-bottom: 4px; }
        .bn-answer-link { color: \(dim); }
        .bn-answer-row:hover .bn-answer-link { color: \(accent); }

        button.bn-follow {
            \(t(.control))
            color: \(text);
            background-color: \(raised);
            background-image: none;
            border: 1px solid \(accent);
            border-radius: 14px;
            padding: 0px 14px;
            min-height: 28px;
            box-shadow: 0px 6px 18px alpha(black, 0.35);
        }
        .bn-follow-text { \(t(.control)) color: \(text); }
        .bn-follow-key {
            \(t(.rowStamp))
            color: \(dim);
            border: 1px solid \(rule2);
            border-radius: 4px;
            padding: 0px 5px;
        }
        .bn-chip-filtered { color: \(warn); }

        .bn-ent-who { }
        .bn-ent-name { \(t(.rowTitleStrong)) color: \(text); }
        .bn-ent-time { \(t(.control)) color: \(dim); }
        .bn-ent-clause { \(t(.control)) color: \(warn); }
        .bn-ent-warn { \(t(.control)) color: \(warn); }
        .bn-ent-sentence { }
        .bn-ent-pill { padding: 1px 10px 1px 7px; }
        .bn-ac-head-row { }
        .bn-asked { padding: 4px 0px 6px 0px; }
        .bn-asked-text { \(t(.rowTitle)) color: \(dim); }

        .bn-plan {
            background-color: \(raised);
            border: 1px solid \(rule);
            border-radius: 10px;
            padding: 6px 14px 8px 14px;
        }
        .bn-plan-head { min-height: 24px; }
        .bn-plan-count { \(t(.rowStamp)) color: \(text); }
        .bn-plan-items { padding-top: 4px; }
        .bn-plan-row { min-height: 24px; }
        .bn-plan-done { \(t(.rowTitle)) color: \(dim); }
        .bn-plan-todo { \(t(.rowTitle)) color: \(dim); }
        .bn-plan-now { \(t(.rowTitleStrong)) color: \(text); }
        .bn-plan-current { \(t(.rowTitleStrong)) color: \(text); }

        .bn-now-box {
            padding: 8px 12px 10px 12px;
            border: 1px solid \(rule2);
            border-radius: 8px;
            background-color: \(raised);
        }
        .bn-now-box.bn-now-silent {
            border-color: alpha(\(warn), 0.6);
            background-color: alpha(\(warn), 0.07);
        }
        .bn-now-live { color: \(accent); }
        .bn-now-since { \(t(.rowStamp)) color: \(dim); }
        .bn-now-silence { \(t(.rowStamp)) color: \(warn); }
        .bn-now-tail { }

        .bn-result {
            background-color: \(raised);
            border: 1px solid \(rule);
            border-radius: 10px;
            padding: 12px 14px 12px 14px;
        }
        .bn-result-title { color: \(dim); margin-bottom: 4px; }
        .bn-res-group { margin-top: 8px; padding-top: 8px; border-top: 1px solid \(rule); }
        .bn-res-row { min-height: 26px; }
        .bn-res-check { \(t(.rowTitleStrong)) color: \(text); }
        .bn-res-command { \(t(.rowDetail)) color: \(dim); }
        .bn-res-nums { \(t(.rowStamp)) color: \(dim); }
        .bn-res-verdict { \(t(.rowMeta)) color: \(dim); }
        .bn-res-words { \(t(.rowTitle)) color: \(dim); }
        .bn-verdict { }
        """
    }
}
