import Foundation
import TailscodeCore

/// The world clock's stylesheet. Every colour is a palette slot and every size a type role, so the
/// chip, the glance and the sheet follow the theme and the type scale like everything else.
enum ClockCSS {
    static func rules(palette: Palette) -> String {
        func t(_ role: TypeRole) -> String { TypeCSS.declarations(role) }
        let canvas = palette.canvas
        let raised = palette.canvasRaised
        let rule = palette.rule
        let text = palette.text
        let dim = palette.textDim
        let accent = palette.accent
        let warn = palette.warn
        let info = palette.info
        let special = palette.special
        return """
        .clock-footer { border-top: 1px solid alpha(currentColor, 0.15); }
        .clock-footer .update-footer { border-top: none; }
        .clock-chip {
            min-height: 28px;
            padding: 0 12px 0 9px;
            border-radius: 999px;
            background-color: \(raised);
            border: 1px solid \(rule);
        }
        .clock-chip:hover { border-color: \(accent); box-shadow: 0 0 0 3px alpha(\(accent), 0.12); }
        .clock-chip:focus-visible { outline: 2px solid \(accent); outline-offset: 2px; }
        .clock-chip-time { \(t(.chip)) font-feature-settings: "tnum"; color: \(text); }
        popover.clock-glance > contents {
            border-radius: 18px;
            padding: 0;
            background-color: \(raised);
            border: 1px solid alpha(\(accent), 0.28);
        }
        .clock-date { \(t(.panelTitle)) color: \(text); }
        .clock-dim { \(t(.panelDetail)) color: \(dim); }
        .clock-name { \(t(.rowTitleStrong)) color: \(text); }
        .clock-section { \(t(.sectionLabel)) color: \(dim); }
        .clock-time { \(t(.statusLine)) font-size: 0.9rem; color: \(text); }
        .clock-stamp { \(t(.rowStamp)) color: \(text); }
        .clock-status { \(t(.panelDetail)) font-weight: 600; }
        .clock-ok { color: \(accent); }
        .clock-warn { color: \(warn); }
        .clock-quiet { color: \(dim); }
        .clock-countdown { \(t(.statusLine)) font-weight: 600; color: \(accent); }
        .clock-rule { background-color: \(rule); min-height: 1px; }
        .clock-dot { border-radius: 999px; min-width: 7px; min-height: 7px; }
        .clock-dot-ok { background-color: \(accent); }
        .clock-dot-warn { background-color: \(warn); }
        .clock-dot-quiet { background-color: \(dim); }
        .clock-card-warn {
            \(t(.panelDetail))
            color: \(warn);
            background-color: alpha(\(warn), 0.1);
            border-radius: 10px;
            padding: 8px 10px;
        }
        .clock-tile { border-radius: 8px; background-color: alpha(\(info), 0.16); padding: 6px; }
        .clock-suggest {
            \(t(.panelDetail))
            min-height: 0;
            padding: 2px 10px;
            border-radius: 999px;
            border: 1px solid \(rule);
            background-color: transparent;
            color: \(text);
        }
        .clock-suggest:hover { border-color: \(accent); }
        .clock-title { \(t(.metricLarge)) color: \(text); }
        .clock-head { \(t(.metricHero)) font-family: monospace; font-weight: 500; color: \(text); }
        .clock-delta { \(t(.panelLabel)) font-weight: 700; }
        .clock-now {
            \(t(.control))
            font-weight: 700;
            padding: 6px 16px;
            border-radius: 999px;
            background-color: \(raised);
            border: 1px solid \(rule);
            color: \(text);
        }
        .clock-now:hover { border-color: \(accent); }
        .clock-lane-tile { border-radius: 9px; background-color: \(raised); padding: 7px; }
        .clock-lane-name { \(t(.rowTitleStrong)) font-weight: 700; color: \(text); }
        .clock-lane-time { \(t(.statusLine)) font-size: 0.95rem; color: \(text); }
        .clock-ticks, .clock-strip { \(t(.hint)) }
        .clock-lines { \(t(.pill)) }
        .clock-scrubber:focus-visible { outline: 2px solid \(info); outline-offset: 2px; border-radius: 15px; }
        .clock-insight {
            border-radius: 12px;
            padding: 10px 14px;
            background-color: alpha(\(info), 0.1);
        }
        .clock-insight-text { \(t(.panelLabel)) color: \(text); }
        .clock-alarm {
            border-radius: 999px;
            padding: 2px 4px 2px 12px;
            background-color: alpha(\(special), 0.12);
            border: 1px solid alpha(\(special), 0.5);
        }
        .clock-remove { min-width: 18px; min-height: 18px; padding: 0 6px; \(t(.panelLabel)) color: \(dim); }
        .clock-remove:hover { color: \(warn); }
        .clock-footer-bar { border-top: 1px solid \(rule); }
        .clock-copy {
            padding: 6px 14px;
            border-radius: 14px;
            background-color: \(raised);
            border: 1px solid \(rule);
            color: \(text);
        }
        .clock-copy:hover { border-color: \(accent); }
        .clock-copy-title { \(t(.sectionLabel)) color: \(dim); }
        .clock-copy-title.clock-copied { color: \(accent); }
        .clock-copy-value { \(t(.rowStamp)) color: \(text); }
        .clock-notify { \(t(.control)) font-weight: 800; padding: 10px 20px; border-radius: 999px; }
        .clock-style { \(t(.panelDetail)) }
        .clock-result { padding: 2px 8px; }
        popover.clock-glance { background: none; }
        .meridian-sheet { background-color: \(canvas); }
        """
    }
}
