import Foundation
import TailscodeCore

/// The brain's rules in the app's style sheet: the card, the readout, the footer and the strip,
/// each named by what it is and typed by a role from Core's ramp, so no size is written here that
/// the ramp does not hold. Colours are the theme's own slots; a zone's colour is carried by a
/// class on the panel it belongs to (`bn-z-shell`) and read by the parts that wear it.
enum BrainCSS {
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
        var zoneRules = ""
        for (name, color) in zones {
            zoneRules += """
            .bn-z-\(name) .bn-tone-text { color: \(color); }
            .bn-z-\(name) .bn-tone-rule { border-left-color: \(color); }
            .bn-z-\(name).bn-strip { border-left-color: \(color); background-color: alpha(\(color), 0.06); }
            .bn-z-\(name) .bn-zrow:hover { background-color: alpha(\(color), 0.09); }
            .bn-z-\(name) .bn-zrow-sel { background-color: alpha(\(color), 0.14); box-shadow: inset 2px 0 0 \(color); }
            .bn-zchip-name.bn-z-\(name) { color: \(color); }

            """
        }
        return """
        .brain-row { }
        brain-frame:focus-visible {
            outline: 2px solid alpha(\(accent), 0.55);
            outline-offset: -2px;
            border-radius: 12px;
        }
        .brain-pill {
            \(t(.pill))
            color: \(dim);
            background-color: transparent;
            background-image: none;
            border: 1px solid alpha(\(dim), 0.45);
            border-radius: 999px;
            padding: 0px 9px;
            min-height: 0;
            box-shadow: none;
        }
        .brain-pill:hover { color: \(accent); border-color: alpha(\(accent), 0.7); }
        .brain-pill:focus-visible { outline: 2px solid alpha(\(accent), 0.55); outline-offset: 1px; }
        .brain-pill.on { color: \(accent); border-color: alpha(\(accent), 0.7); }
        .brain-pill:disabled { opacity: 0.45; }
        .bn-card-button, .bn-foot-button, .bn-copy {
            \(t(.control))
            color: \(dim);
            background-color: \(raised);
            border: 1px solid \(rule2);
            border-radius: 12px;
            padding: 0px 10px;
            min-height: 22px;
        }
        .bn-foot-button { background-color: transparent; color: \(text); }
        .bn-card-button:hover, .bn-foot-button:hover, .bn-copy:hover {
            color: \(text);
            border-color: \(accent);
        }
        .brain-stage { outline: none; background-color: transparent; }
        .brain-stage:focus-visible { outline: none; }

        .bn-count { \(t(.metricLarge)) color: \(text); }
        .bn-unit { \(t(.panelLabel)) color: \(dim); }
        .bn-dur { \(t(.rowStamp)) color: \(dim); }
        .bn-tally { \(t(.diff)) }
        .bn-clause { \(t(.control)) color: \(dim); }
        .bn-digest { \(t(.panelDetail)) color: \(dim); }
        .bn-tone-danger { color: \(danger); }
        .bn-tone-attention { color: \(warn); }
        .bn-tone-quiet { color: \(dim); }
        .bn-dim { color: \(dim); }
        button.bn-zchip, .bn-zchip-still {
            background-color: \(canvas);
            background-image: none;
            border: 1px solid \(rule2);
            border-radius: 12px;
            padding: 0px 10px 0px 6px;
            min-height: 22px;
            box-shadow: none;
        }
        button.bn-zchip:hover, button.bn-zchip:focus-visible { border-color: \(accent); }
        .bn-zchip-compact { padding: 0px 8px 0px 4px; }
        .bn-zchip-name { \(t(.sectionLabel)) color: \(dim); }
        .bn-zchip-count { \(t(.gauge)) color: \(text); }

        .bn-readout { border-left: 1px solid \(rule2); }
        .bn-page { background-color: transparent; }
        .bn-ro-head { padding: 0px 12px 0px 20px; }
        .bn-ro-body { padding: 4px 12px 12px 20px; }
        .bn-ro-foot { padding: 0px 12px 0px 20px; border-top: 1px solid \(rule); }
        .bn-ro-fade {
            background-image: linear-gradient(to bottom, alpha(\(canvas), 0), \(canvas));
        }
        .bn-zone { \(t(.sectionLabel)) color: \(dim); }
        .bn-chip {
            \(t(.badge))
            border: 1px solid currentColor;
            border-radius: 10px;
            padding: 0px 8px;
            min-height: 18px;
            color: \(dim);
        }
        .bn-chip-live { color: \(accent); }
        .bn-chip-attention { color: \(warn); }
        .bn-chip-danger { color: \(danger); }
        .bn-chip-quiet { color: \(dim); }
        .bn-pin { \(t(.rowNote)) color: \(dim); }
        .bn-counter { \(t(.rowStamp)) color: \(dim); }
        .bn-sec { margin-top: 16px; }
        .bn-sec-first { margin-top: 8px; }
        .bn-label { \(t(.sectionLabel)) color: \(dim); }
        .bn-label-right { \(t(.rowMeta)) color: \(dim); }
        .bn-title { \(t(.cardTitle)) color: \(text); }
        .bn-cmd { \(t(.toolDetail)) color: \(text); }
        .bn-path { \(t(.toolDetail)) color: \(text); }
        .bn-agent { \(t(.cardBody)) color: \(text); }
        .bn-thought { \(t(.thought)) color: \(text); }
        .bn-fact { \(t(.rowStamp)) color: \(dim); }
        button.bn-link {
            \(t(.rowMeta))
            color: \(dim);
            background: none;
            border: none;
            box-shadow: none;
            padding: 0px;
            min-height: 0;
            text-decoration: underline;
            text-decoration-color: \(rule2);
        }
        button.bn-link:hover, button.bn-link:focus-visible { color: \(text); }
        .bn-why { border-left: 2px solid \(accent); padding-left: 12px; }
        .bn-why-text { \(t(.thought)) color: \(text); }
        .bn-out-box { border-left: 1px solid \(rule2); padding: 8px 0px 8px 12px; }
        .bn-out-bad { border-left-color: \(danger); }
        .bn-out { \(t(.toolOutput)) color: \(dim); }
        .bn-diff { border: 1px solid \(rule); border-radius: 6px; }
        .bn-diff-line { padding: 0px 4px; }
        .bn-diff-add { background-color: alpha(\(accent), 0.14); }
        .bn-diff-del { background-color: alpha(\(danger), 0.14); }
        .bn-diff-add .bn-diff-mark { color: \(accent); }
        .bn-diff-del .bn-diff-mark { color: \(danger); }
        .bn-diff-mark { \(t(.diff)) color: \(dim); }
        .bn-diff-text { \(t(.diff)) color: \(text); }
        button.bn-rel {
            \(t(.chip))
            color: \(text);
            background-color: transparent;
            background-image: none;
            border: 1px solid \(rule2);
            border-radius: 12px;
            padding: 0px 10px;
            min-height: 22px;
            box-shadow: none;
        }
        button.bn-rel:hover, button.bn-rel:focus-visible { border-color: \(accent); }
        button.bn-rel-retry { border-color: alpha(\(accent), 0.55); }

        .bn-headline { \(t(.headline)) color: \(text); }
        .bn-bar-row { min-height: 18px; }
        .bn-bar-row:hover .bn-bar-name { color: \(text); }
        .bn-bar-name { \(t(.sectionLabel)) color: \(dim); }
        .bn-bar-count { \(t(.rowStamp)) color: \(dim); }
        .bn-list-row { padding: 6px 0px; border-bottom: 1px solid \(rule); }
        .bn-list-row:hover { background-color: alpha(\(text), 0.04); }
        .bn-fail-no { \(t(.rowMeta)) color: \(danger); }
        .bn-fail-title { \(t(.toolDetail)) color: \(text); }
        .bn-fail-line { \(t(.rowDetail)) color: \(dim); }
        .bn-fail-re { \(t(.rowMeta)) color: \(accent); }
        .bn-fail-never { color: \(danger); }
        .bn-changed-path { \(t(.toolDetail)) color: \(text); }
        .bn-answer { \(t(.cardBody)) color: \(text); }

        .bn-now { \(t(.sectionLabel)) color: \(accent); }
        .bn-now-attention { color: \(warn); }
        .bn-pulse { min-width: 8px; min-height: 8px; }
        .bn-sofar { margin-top: 16px; padding-top: 12px; border-top: 1px solid \(rule); }
        .bn-sofar-h { \(t(.rowTitleStrong)) color: \(text); }
        .bn-ask {
            border: 1px solid alpha(\(warn), 0.6);
            border-radius: 8px;
            background-color: alpha(\(warn), 0.09);
            padding: 12px 14px;
        }
        .bn-ask-title { \(t(.cardTitle)) color: \(text); }
        button.bn-ask-button {
            \(t(.control))
            color: \(canvas);
            background-color: \(warn);
            background-image: none;
            border: 1px solid \(warn);
            border-radius: 16px;
            padding: 0px 14px;
            min-height: 30px;
            box-shadow: none;
        }
        button.bn-ask-button:hover, button.bn-ask-button:focus-visible { background-color: alpha(\(warn), 0.85); }

        .bn-zlist { margin: 4px -4px 0px -8px; }
        .bn-zrow { min-height: 32px; padding: 4px 8px; border-radius: 6px; }
        .bn-zrow-no { \(t(.rowMeta)) color: \(dim); }
        .bn-zrow-title { \(t(.rowTitleStrong)) color: \(text); }
        .bn-zrow-arg { \(t(.rowDetail)) color: \(dim); }
        .bn-zrow-bad .bn-zrow-no, .bn-zrow-bad .bn-zrow-title { color: \(danger); }
        .bn-zrow-dot { border-radius: 4px; }
        .bn-dot-live { background-color: \(accent); }
        .bn-dot-danger { background-color: \(danger); }
        .bn-dot-attention { background-color: \(warn); }
        .bn-dot-quiet { background-color: \(dim); }

        .bn-strip { border-left: 3px solid \(accent); padding: 8px 12px; border-radius: 0px 8px 8px 0px; }
        .bn-strip-head { min-height: 24px; }
        .bn-strip-title { \(t(.rowTitleStrong)) color: \(text); }
        .bn-strip-line { \(t(.rowDetail)) color: \(dim); }
        \(zoneRules)
        .bn-footer { padding: 0px 2px; }
        .bn-time { \(t(.rowStamp)) color: \(dim); }
        .brain-scrub { min-height: 0; margin: 0px 2px; }
        .brain-chip {
            \(t(.rowStamp))
            color: \(info);
            background-color: transparent;
            background-image: none;
            border: 1px dashed alpha(\(info), 0.7);
            border-radius: 12px;
            padding: 0px 10px;
            min-height: 22px;
            box-shadow: none;
        }
        .brain-chip:hover, .brain-chip:focus-visible { background-color: alpha(\(info), 0.12); }
        """
    }
}
