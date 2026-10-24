import CAdw
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    func composerRules() -> String {
        return """
        \(dialTintCSS(for: palette))

        \(partyRules())

        .chip {
            \(t(.chip))
            min-height: 0;
            padding: 2px 10px;
            background-color: \(canvasRaised);
            border: 1px solid \(info);
            border-radius: 0;
            color: \(info);
        }
        .chip:hover { border-color: \(danger); color: \(danger); }
        .empty-chat { padding: 24px 0; }
        .wrap-row flowboxchild { padding: 0; min-height: 0; min-width: 0; }
        .empty-headline { \(t(.headline)) color: \(text); }
        .answer-option-mark { font-size: \(chipIconEm)em; color: \(accent); }
        .hover-bar {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 8px;
            padding: 1px 2px 1px 8px;
            opacity: 0;
            transition: opacity 120ms ease-out;
        }
        .hover-bar-on { opacity: 1; }
        .hover-stamp { \(t(.rowStamp)) color: \(textDim); margin-right: 4px; }
        .hover-verb {
            \(t(.codeAction))
            min-height: 0;
            min-width: 0;
            padding: 1px 7px;
            color: \(text);
            border-radius: 6px;
        }
        .hover-verb:hover { color: \(accent); background-color: alpha(\(accent), 0.12); }
        .row-verbs {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 7px;
            padding: 0 1px;
            opacity: 0;
            transition: opacity 100ms ease-out;
        }
        .row-verbs-on { opacity: 1; }
        .row-verb {
            min-width: 20px;
            min-height: 20px;
            padding: 0;
            color: \(textDim);
            border-radius: 5px;
        }
        .row-verb:hover { color: \(text); background-color: alpha(\(accent), 0.14); }
        .row-verb-on { color: \(accent); }
        .find-bar {
            background-color: \(canvasRaised);
            border-bottom: 1px solid \(rule);
            padding: 2px \(inset)px;
        }
        .chat-pane { border: 1px solid transparent; }
        .video-pane { background-color: #000000; }
        .web-pane { background-color: \(canvas); }
        .video-heading { color: \(accent); \(t(.paneHeadline)) }
        .draw-pane { background-color: \(canvas); }
        .draw-ask { background-color: alpha(\(canvas), 0.0); }
        .draw-entry {
            background-color: \(canvasRaised);
            color: \(text);
            border: 1px solid \(rule);
            border-radius: 12px;
            padding: 10px 14px;
            \(t(.composer))
        }
        .draw-entry:focus {
            border-color: alpha(\(accent), 0.55);
            box-shadow: 0 0 0 1px alpha(\(accent), 0.35) inset;
        }
        .draw-avoid {
            background-color: alpha(\(danger), 0.06);
            color: \(text);
            border: 1px solid alpha(\(danger), 0.28);
            border-radius: 10px;
            padding: 7px 12px;
            \(t(.hint))
        }
        .draw-avoid:focus {
            border-color: alpha(\(danger), 0.55);
            box-shadow: 0 0 0 1px alpha(\(danger), 0.28) inset;
        }
        .draw-chip, .draw-chip > button {
            background-image: linear-gradient(to bottom, alpha(\(text), 0.07), alpha(\(text), 0.02));
            background-color: \(canvasRaised);
            color: \(textDim);
            border: 1px solid \(rule);
            border-radius: 999px;
            padding: 4px 13px;
            box-shadow: 0 1px 0 alpha(\(text), 0.06) inset, 0 1px 2px alpha(#000000, 0.22);
            transition: 120ms ease-out;
            \(t(.hint))
        }
        menubutton.draw-chip { padding: 0; background-image: none; box-shadow: none; border: none; }
        .draw-chip > button {
            box-shadow: 0 1px 0 alpha(\(text), 0.06) inset, 0 1px 2px alpha(#000000, 0.22);
            border: 1px solid \(rule);
            padding: 4px 13px;
            border-radius: 999px;
        }
        .draw-chip:hover, .draw-chip > button:hover {
            color: \(text);
            border-color: alpha(\(accent), 0.50);
            background-image: linear-gradient(to bottom, alpha(\(accent), 0.16), alpha(\(accent), 0.06));
        }
        .draw-chip:active, .draw-chip > button:active {
            box-shadow: 0 1px 3px alpha(#000000, 0.30) inset;
            background-image: linear-gradient(to bottom, alpha(\(accent), 0.22), alpha(\(accent), 0.10));
        }
        .draw-chip:focus-visible, .draw-chip > button:focus-visible {
            outline: 2px solid alpha(\(accent), 0.55);
            outline-offset: 1px;
        }
        .draw-chip:disabled, .draw-chip > button:disabled {
            opacity: 0.45;
            box-shadow: none;
        }
        .draw-chip-on, .draw-chip-on > button {
            color: \(text);
            border-color: alpha(\(accent), 0.60);
            background-image: linear-gradient(to bottom, alpha(\(accent), 0.30), alpha(\(accent), 0.14));
            box-shadow: 0 1px 0 alpha(\(text), 0.10) inset, 0 1px 3px alpha(#000000, 0.26);
        }
        .draw-chip-lead { color: alpha(\(text), 0.55); }
        .draw-chips { margin-top: 2px; }
        .draw-chips-more { margin-top: 4px; }
        .draw-section { color: \(textDim); \(t(.badge)) opacity: 0.75; margin-top: 6px; }
        .draw-picture { min-height: 170px; min-width: 240px; }
        .draw-status { color: \(text); \(t(.panelDetail)) }
        .draw-progress { color: \(accent); \(t(.statusLine)) }
        .draw-working {
            background-image: linear-gradient(to bottom, alpha(\(accent), 0.10), alpha(\(text), 0.04));
            border: 1px solid alpha(\(accent), 0.28);
            border-radius: 12px;
        }
        .draw-tile { padding: 0; border-radius: 10px; background: none; border: none; }
        .draw-tile:hover { background-color: alpha(\(text), 0.04); }
        .draw-tile-empty {
            background-color: alpha(\(text), 0.05);
            border-radius: 10px;
        }
        .draw-caption { color: \(textDim); \(t(.hint)) opacity: 0.85; }
        .preview-pane { background-color: \(canvas); }
        .preview-entry {
            background-color: \(canvasRaised);
            color: \(text);
            border: 1px solid \(rule);
            border-radius: 12px;
            padding: 10px 14px;
            \(t(.composer))
        }
        .preview-entry:focus {
            border-color: alpha(\(accent), 0.55);
            box-shadow: 0 0 0 1px alpha(\(accent), 0.35) inset;
        }
        .preview-say {
            background-color: \(canvasRaised);
            color: \(text);
            border: 1px solid \(rule);
            border-radius: 10px;
            padding: 4px 10px;
            min-height: 0;
            \(t(.rowDetail))
        }
        .preview-say:focus {
            border-color: alpha(\(accent), 0.55);
            box-shadow: 0 0 0 1px alpha(\(accent), 0.35) inset;
        }
        .preview-chip {
            background-color: \(canvasRaised);
            background-image: none;
            color: \(textDim);
            border: 1px solid \(rule);
            border-radius: 999px;
            padding: 3px 12px;
            min-height: 0;
            box-shadow: none;
            \(t(.chip))
        }
        .preview-chip:hover { color: \(text); border-color: alpha(\(accent), 0.45); }
        .preview-chip-on { color: \(text); border-color: alpha(\(accent), 0.65); }
        .preview-picture { border-radius: 16px; }
        .preview-lens {
            background-color: transparent;
            background-image: none;
            color: \(textDim);
            border: 1px solid transparent;
            border-radius: 999px;
            padding: 2px 11px;
            min-height: 0;
            box-shadow: none;
            \(t(.chip))
        }
        .preview-lens:hover { color: \(text); }
        .preview-lens-on { color: \(text); background-color: alpha(\(text), 0.08); border-color: \(rule); }
        .preview-caption {
            background-color: alpha(\(canvas), 0.78);
            color: \(text);
            border-radius: 999px;
            padding: 2px 10px;
            \(t(.chip))
        }
        .preview-shot {
            background-color: transparent;
            background-image: none;
            border: 1px solid transparent;
            border-radius: 10px;
            padding: 6px 10px;
            min-height: 0;
            box-shadow: none;
        }
        .preview-shot:hover { background-color: alpha(\(text), 0.05); }
        .preview-shot-on { border-color: alpha(\(special), 0.7); background-color: alpha(\(special), 0.10); }
        .preview-cell {
            background-color: transparent;
            background-image: none;
            border: 1px solid transparent;
            border-radius: 12px;
            padding: 6px;
            box-shadow: none;
        }
        .preview-cell:hover:not(:disabled) { background-color: alpha(\(text), 0.05); border-color: \(rule); }
        .preview-status { color: \(text); \(t(.statusLine)) }
        .preview-row {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 12px;
            padding: 10px 14px;
        }
        .preview-row-title { color: \(text); \(t(.rowTitle)) }
        .preview-row-detail { color: \(textDim); \(t(.rowDetail)) }
        .preview-ok { color: \(accent); \(t(.rowTitle)) }
        .preview-attention { color: \(warn); \(t(.rowTitle)) }
        .preview-bad { color: \(danger); \(t(.rowTitle)) }
        .preview-progress trough { min-height: 4px; background-color: alpha(\(text), 0.10); }
        .preview-progress progress { min-height: 4px; background-color: \(accent); }
        .setup-section { color: \(textDim); \(t(.rowDetail)) }
        .setup-chip { color: \(accent); \(t(.rowDetail)) }
        .setup-capability { padding: 6px 4px; min-height: 0; }
        .setup-name { color: \(textDim); \(t(.rowDetail)) }
        .setup-row {
            padding: 12px 14px;
            border: 1px solid \(rule);
            border-radius: 8px;
            background-color: alpha(\(canvasRaised), 0.55);
        }
        .setup-row-done { padding: 6px 14px; border-color: transparent; background-color: transparent; }
        .setup-failure { color: \(danger); \(t(.rowDetail)) }
        .setup-command {
            background-color: \(palette.codeBg);
            border-left: 2px solid \(rule);
            padding: 8px 6px 8px 10px;
        }
        .setup-command-text { color: \(text); \(t(.code)) }
        .setup-progress trough { min-height: 6px; background-color: alpha(\(text), 0.10); }
        .setup-progress progress { min-height: 6px; background-color: \(accent); }
        .preview-banner {
            background-color: alpha(\(canvasRaised), 0.94);
            border: 1px solid alpha(\(danger), 0.55);
            border-radius: 12px;
            padding: 10px 12px;
        }
        .preview-banner-title { color: \(danger); \(t(.banner)) }
        .preview-problem { color: \(text); \(t(.code)) }
        .draw-stage-room { min-height: 180px; }
        .draw-facts { color: \(textDim); \(t(.badge)) }
        .draw-actions { margin-top: 4px; transition: opacity 450ms ease-out; }
        .draw-actions-reserved { opacity: 0; transition: none; }
        .draw-action {
            color: \(textDim);
            background-color: alpha(\(text), 0.04);
            border: 1px solid alpha(\(text), 0.10);
            border-radius: 9px;
            padding: 4px 11px;
            transition: 120ms ease-out;
            \(t(.hint))
        }
        .draw-action:hover {
            color: \(text);
            background-color: alpha(\(text), 0.10);
            border-color: alpha(\(accent), 0.42);
        }
        .draw-action:active { background-color: alpha(\(text), 0.16); }
        .draw-action:focus-visible { outline: 2px solid alpha(\(accent), 0.50); outline-offset: 1px; }
        .draw-action.danger { color: \(danger); border-color: alpha(\(danger), 0.24); }
        .draw-action.danger:hover {
            background-color: alpha(\(danger), 0.16);
            border-color: alpha(\(danger), 0.55);
        }
        .draw-go {
            background-image: linear-gradient(to bottom, alpha(\(accent), 0.95), alpha(\(accent), 0.72));
            color: \(canvas);
            border: 1px solid alpha(\(accent), 0.85);
            border-radius: 999px;
            padding: 8px 20px;
            box-shadow: 0 1px 0 alpha(#ffffff, 0.22) inset, 0 2px 6px alpha(#000000, 0.30);
            transition: 120ms ease-out;
            \(t(.panelDetail))
        }
        .draw-go:hover {
            background-image: linear-gradient(to bottom, \(accent), alpha(\(accent), 0.82));
            box-shadow: 0 1px 0 alpha(#ffffff, 0.28) inset, 0 3px 10px alpha(\(accent), 0.35);
        }
        .draw-go:active { box-shadow: 0 2px 5px alpha(#000000, 0.35) inset; }
        .draw-go:disabled { opacity: 0.45; box-shadow: none; }
        .draw-go.stopping {
            background-image: linear-gradient(to bottom, alpha(\(danger), 0.92), alpha(\(danger), 0.70));
            border-color: alpha(\(danger), 0.85);
        }
        .draw-hint {
            background-image: linear-gradient(to bottom, alpha(\(accent), 0.14), alpha(\(accent), 0.06));
            border: 1px solid alpha(\(accent), 0.34);
            border-radius: 12px;
            padding: 9px 12px;
            margin-top: 4px;
        }
        .draw-rewrite {
            background-image: linear-gradient(to bottom, alpha(\(accent), 0.10), alpha(\(text), 0.03));
            border: 1px solid alpha(\(accent), 0.30);
            border-radius: 12px;
            padding: 9px 12px;
            margin-top: 4px;
        }
        .draw-rewrite-head { color: \(text); \(t(.panelDetail)) }
        .draw-rewrite-head.danger { color: \(danger); }
        .draw-rewrite-scroller { border-radius: 9px; }
        .draw-rewrite-body, .draw-rewrite-body text {
            background-color: alpha(\(canvas), 0.55);
            color: \(text);
            \(t(.panelDetail))
        }
        menubutton.draw-link, menubutton.draw-link > button {
            color: \(accent);
            background: none;
            background-image: none;
            border: none;
            box-shadow: none;
            padding: 0 2px;
            min-height: 0;
            \(t(.hint))
        }
        menubutton.draw-link > button:hover { text-decoration-line: underline; }
        menubutton.draw-helper-link, menubutton.draw-helper-link > button { color: \(textDim); }
        menubutton.draw-helper-link > button:hover { color: \(accent); }
        .draw-action-lead {
            color: \(text);
            border-color: alpha(\(accent), 0.55);
            background-image: linear-gradient(to bottom, alpha(\(accent), 0.26), alpha(\(accent), 0.12));
        }
        .draw-sketch { border-radius: 10px; }
        .menu-heading { color: \(textDim); \(t(.badge)) opacity: 0.75; }
        .menu-row-on { background-color: alpha(\(accent), 0.10); }
        .draw-hint-title { color: \(text); \(t(.panelDetail)) }
        .draw-hint-body { color: \(textDim); \(t(.hint)) }
        .draw-example {
            background-image: linear-gradient(to bottom, alpha(\(text), 0.06), alpha(\(text), 0.02));
            border: 1px solid \(rule);
            border-radius: 12px;
            padding: 10px 12px;
            transition: 120ms ease-out;
        }
        .draw-example:hover {
            border-color: alpha(\(accent), 0.50);
            background-image: linear-gradient(to bottom, alpha(\(accent), 0.14), alpha(\(accent), 0.05));
        }
        .draw-example-title { color: \(text); \(t(.panelDetail)) }
        .draw-example-detail { color: \(textDim); \(t(.hint)) }
        .draw-rule-title { color: \(text); \(t(.panelDetail)) }
        .draw-rule-detail { color: \(textDim); \(t(.hint)) }
        .draw-ref {
            padding: 0;
            border-radius: 10px;
            border: 1px solid alpha(\(accent), 0.45);
            background-color: alpha(\(text), 0.05);
        }
        .draw-ref:hover { border-color: \(accent); }
        """
    }
}
