import CAdw
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    func drawRules() -> String {
        return """
        .draw-ref-drop {
            border: 1px dashed alpha(\(text), 0.30);
            border-radius: 10px;
            color: \(textDim);
            padding: 6px 12px;
            background-color: alpha(\(text), 0.03);
            \(t(.hint))
        }
        .draw-ref-drop:hover { border-color: alpha(\(accent), 0.55); color: \(text); }
        .draw-empty-title { color: \(text); \(t(.panelTitle)) }
        .draw-history { color: \(textDim); \(t(.badge)) margin-top: 4px; }
        .draw-thumb {
            padding: 0;
            border-radius: 8px;
            border: 1px solid transparent;
        }
        .draw-thumb:hover { border-color: alpha(\(accent), 0.45); }
        .draw-thumb-on { border-color: \(accent); }
        .draw-tile-zoomed { background-color: \(canvas); }
        .draw-shelf { margin-top: 4px; }
        .draw-shelf-heading { color: \(text); \(t(.panelDetail)) }
        .draw-shelf-grid { margin-top: 2px; }
        .draw-progress-bar {
            min-height: 4px;
            margin-top: 2px;
        }
        .draw-progress-bar trough { background-color: alpha(\(text), 0.10); }
        .draw-progress-bar progress { background-color: \(accent); }
        .draw-brief-scroller { border-right: 1px solid \(rule); background-color: \(canvasRaised); }
        .draw-brief { background-color: \(canvasRaised); }
        .draw-lbl { color: \(textDim); \(t(.sectionLabel)) }
        .draw-textarea {
            background-color: \(canvas);
            border: 1px solid \(rule);
            border-radius: 12px;
        }
        .draw-textarea:focus-within { border-color: alpha(\(accent), 0.55); }
        .draw-textarea textview, .draw-textarea text {
            background: transparent;
            color: \(text);
            \(t(.composer))
        }
        .draw-count { color: \(textDim); \(t(.hint)) }
        .draw-link {
            color: \(accent);
            background: none;
            border: none;
            box-shadow: none;
            padding: 0 2px;
            \(t(.hint))
        }
        .draw-link:hover { text-decoration-line: underline; }
        .draw-link.draw-chip-on { color: \(text); }
        .draw-opt, .draw-shape, .draw-seg-item {
            background-color: \(canvas);
            background-image: none;
            color: \(text);
            border: 1px solid \(rule);
            box-shadow: none;
        }
        .draw-opt { border-radius: 10px; padding: 8px 10px; }
        .draw-shape { border-radius: 8px; padding: 4px 2px; }
        .draw-opt:hover, .draw-shape:hover, .draw-seg-item:hover { border-color: alpha(\(accent), 0.45); }
        .draw-opt.draw-chip-on, .draw-shape.draw-chip-on, .draw-seg-item.draw-chip-on {
            border-color: alpha(\(accent), 0.60);
            background-color: alpha(\(accent), 0.14);
        }
        .draw-opt:disabled, .draw-shape:disabled, .draw-seg-item:disabled { opacity: 0.45; }
        .draw-opt-title { color: \(text); \(t(.panelDetail)) }
        .draw-opt-detail { color: \(textDim); \(t(.hint)) }
        .draw-shape-glyph { border: 1.5px solid \(textDim); border-radius: 2px; }
        .draw-shape.draw-chip-on .draw-shape-glyph { border-color: \(text); }
        .draw-shape-label { color: \(textDim); \(t(.badge)) }
        .draw-shape.draw-chip-on .draw-shape-label { color: \(text); }
        .draw-seg { border-radius: 8px; }
        .draw-seg-item { border-radius: 0; padding: 6px 4px; margin-left: -1px; color: \(textDim); }
        .draw-seg-item:first-child { border-top-left-radius: 8px; border-bottom-left-radius: 8px; margin-left: 0; }
        .draw-seg-item:last-child { border-top-right-radius: 8px; border-bottom-right-radius: 8px; }
        .draw-seg-item.draw-chip-on { color: \(text); }
        .draw-toggle-title { color: \(text); \(t(.panelDetail)) }
        .draw-toggle-detail { color: \(textDim); \(t(.hint)) }
        .draw-keys { color: \(textDim); \(t(.hint)) opacity: 0.8; }
        .draw-go-wide { border-radius: 12px; padding: 12px; }
        .draw-progress-block { }
        .draw-clock { color: \(textDim); \(t(.statusLine)) font-variant-numeric: tabular-nums; }
        .draw-caption-lead { color: \(text); \(t(.panelDetail)) opacity: 1; }
        .draw-shelf-column { border-left: 1px solid \(rule); background-color: \(canvasRaised); }
        .draw-row {
            padding: 5px;
            border-radius: 10px;
            border: 1px solid transparent;
            background: none;
            box-shadow: none;
        }
        .draw-row:hover { border-color: alpha(\(accent), 0.35); }
        .draw-row-on { border-color: \(accent); background-color: alpha(\(accent), 0.12); }
        .draw-row:disabled { opacity: 1; }
        .draw-row-thumb { border-radius: 7px; }
        .draw-row-thumb picture { border-radius: 7px; }
        scrolledwindow.draw-row-thumb { background: none; border: none; }
        .draw-row-thumb-busy { border: 1px dashed \(rule); border-radius: 7px; }
        .draw-row-words { color: \(text); \(t(.hint)) }
        .draw-row-words-busy { color: \(textDim); \(t(.hint)) }
        .draw-row-facts { color: \(textDim); \(t(.badge)) font-variant-numeric: tabular-nums; }
        .studio-scrim { background-color: #000000; }
        .studio-sheet {
            background-color: \(canvas);
            border-radius: \(Int(StudioSheetMetrics.cornerRadius))px \(Int(StudioSheetMetrics.cornerRadius))px 0 0;
            box-shadow: 0 0 0 \(Int(StudioSheetMotion.edgeHairlineWidth))px \(rule), 0 -2px \(Int(StudioSheetMotion.edgeShadowBlur))px alpha(#000000, \(StudioSheetMotion.edgeShadowAlpha));
        }
        .studio-sheet-clip {
            border-radius: \(Int(StudioSheetMetrics.cornerRadius))px \(Int(StudioSheetMetrics.cornerRadius))px 0 0;
        }
        .studio-sheet-bar { padding: 0 12px; }
        .studio-lanes > button {
            background-image: none;
            background-color: transparent;
            color: \(textDim);
            border: 1px solid \(rule);
            border-radius: 0;
            box-shadow: none;
            padding: 3px 14px;
            min-height: 0;
            \(t(.chip))
        }
        .studio-lanes > button:first-child { border-radius: 6px 0 0 6px; }
        .studio-lanes > button:last-child { border-radius: 0 6px 6px 0; border-left-width: 0; }
        .studio-lanes > button.studio-lane-on { background-color: alpha(\(accent), 0.16); color: \(text); }
        .studio-lanes > button:hover { color: \(text); }
        .studio-lanes > button:focus-visible { outline: 2px solid alpha(\(accent), 0.55); outline-offset: 1px; }
        .studio-queue { color: \(textDim); \(t(.hint)) font-variant-numeric: tabular-nums; }
        .studio-done {
            background-image: none;
            background-color: transparent;
            color: \(text);
            border: 1px solid \(rule);
            border-radius: 6px;
            box-shadow: none;
            padding: 3px 12px;
            min-height: 0;
            \(t(.chip))
        }
        .studio-done:hover { border-color: alpha(\(accent), 0.50); }
        .studio-done:focus-visible { outline: 2px solid alpha(\(accent), 0.55); outline-offset: 1px; }
        .viewer-sheet {
            background-color: #0e0e10;
            box-shadow: 0 0 0 \(Int(StudioSheetMotion.edgeHairlineWidth))px alpha(#ffffff, 0.16), 0 -2px \(Int(StudioSheetMotion.edgeShadowBlur))px alpha(#000000, \(StudioSheetMotion.edgeShadowAlpha));
        }
        .viewer-canvas, .viewer-canvas > viewport { background-color: transparent; }
        .viewer-canvas:focus-visible { outline: none; }
        .viewer-title { color: #ececee; \(t(.chip)) }
        .viewer-sub { color: alpha(#ececee, 0.62); \(t(.hint)) font-variant-numeric: tabular-nums; }
        .viewer-loading { color: alpha(#ececee, 0.62); \(t(.hint)) }
        .viewer-bar button {
            background-image: none;
            background-color: transparent;
            color: #ececee;
            border: 1px solid alpha(#ffffff, 0.22);
            border-radius: 6px;
            box-shadow: none;
            padding: 3px 12px;
            min-height: 0;
            \(t(.chip))
        }
        .viewer-bar button:hover { border-color: alpha(\(accent), 0.60); }
        .viewer-bar button:focus-visible { outline: 2px solid alpha(\(accent), 0.65); outline-offset: 1px; }
        .studio-toolbar { padding: 8px 12px 0 12px; }
        .studio-pill {
            background-color: \(canvasRaised);
            background-image: none;
            color: \(text);
            border: 1px solid \(rule);
            border-radius: 999px;
            padding: 4px 14px;
            box-shadow: none;
            min-height: 0;
        }
        .studio-pill:hover { border-color: alpha(\(accent), 0.50); }
        .studio-pill:focus-visible { outline: 2px solid alpha(\(accent), 0.55); outline-offset: 1px; }
        .studio-pill-line { color: \(text); \(t(.chip)) }
        .studio-dot { \(t(.hint)) }
        .studio-note { color: \(textDim); \(t(.hint)) margin-top: 1px; }
        .studio-stage {
            background-color: alpha(\(text), 0.035);
            border-radius: 16px;
            margin: 8px 12px 0 12px;
        }
        .studio-state { color: \(textDim); \(t(.statusLine)) font-variant-numeric: tabular-nums; }
        .studio-art { border-radius: 10px; }
        .studio-drop { border: 1px dashed alpha(\(text), 0.22); border-radius: 12px; }
        .studio-main, .studio-main:hover { background: none; background-image: none; border-radius: 10px; padding: 0; box-shadow: none; }
        .studio-backdrop picture { opacity: 1; }
        .studio-badge {
            color: \(text);
            background-color: alpha(\(canvas), 0.72);
            border-radius: 999px;
            padding: 3px 10px;
            font-variant-numeric: tabular-nums;
            \(t(.badge))
        }
        .studio-progress trough {
            min-height: 2px;
            background-color: alpha(\(text), 0.08);
            border: none;
            border-radius: 0;
        }
        .studio-progress progress {
            min-height: 2px;
            background-color: \(accent);
            border: none;
            border-radius: 0;
        }
        .studio-verbs {
            background-color: \(canvasRaised);
            background-image: linear-gradient(to bottom, alpha(\(text), 0.09), alpha(\(text), 0.05));
            border: 1px solid alpha(\(text), 0.16);
            border-radius: 999px;
            padding: 4px 6px;
            box-shadow: 0 6px 18px alpha(#000000, 0.30);
            transition: opacity 160ms ease-out;
        }
        .studio-verb {
            color: \(text);
            background: none;
            background-image: none;
            border: none;
            box-shadow: none;
            border-radius: 999px;
            padding: 5px 12px;
            min-height: 0;
            \(t(.chip))
        }
        .studio-verb:hover { background-color: alpha(\(text), 0.12); }
        .studio-verb:focus-visible { outline: 2px solid alpha(\(accent), 0.55); outline-offset: 1px; }
        .studio-verb.danger { color: \(danger); }
        .studio-verb.danger:hover { background-color: alpha(\(danger), 0.16); }
        .studio-verb-lead { color: \(palette.onAccent); background-color: \(accent); }
        .studio-verb-lead:hover { background-color: \(accentDim); }
        .studio-verbs-rule { min-width: 1px; background-color: alpha(\(text), 0.18); margin: 5px 6px; }
        .studio-card {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 16px;
            padding: 18px 20px;
            box-shadow: 0 10px 28px alpha(#000000, 0.32);
        }
        .studio-card-mark {
            color: \(danger);
            background-color: alpha(\(danger), 0.16);
            border-radius: 999px;
            min-width: 28px;
            min-height: 28px;
            font-weight: 700;
        }
        .studio-card-mark-live { color: \(accent); background-color: alpha(\(accent), 0.16); }
        .studio-card-sentence { color: \(text); \(t(.panelDetail)) }
        .studio-rewrite { background-color: \(canvasRaised); box-shadow: 0 10px 28px alpha(#000000, 0.32); }
        .studio-dock {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 16px;
            padding: 12px;
            box-shadow: 0 6px 20px alpha(#000000, 0.18);
        }
        .studio-wordsbox { min-height: 56px; }
        .studio-placeholder { color: \(textDim); \(t(.composer)) opacity: 0.75; }
        .studio-locked { opacity: 0.65; }
        .studio-go { border-radius: 999px; padding: 8px 18px; }
        .studio-enhance, menubutton.studio-enhance > button {
            color: \(text);
            background-color: alpha(\(text), 0.07);
            border: 1px solid alpha(\(text), 0.10);
            border-radius: 999px;
            padding: 2px 10px;
            \(t(.chip))
        }
        .studio-enhance:hover { background-color: alpha(\(accent), 0.16); border-color: alpha(\(accent), 0.45); }
        flowboxchild { padding: 0; }
        .studio-chips { background: none; }
        .draw-chip-name { color: \(textDim); }
        .draw-chip-value { color: \(text); font-weight: 600; font-variant-numeric: tabular-nums; }
        .draw-chip-mark { color: \(textDim); \(t(.badge)) }
        .studio-chip-warn, .studio-chip-warn > button { border-color: alpha(\(danger), 0.70); }
        .studio-chip-warn .draw-chip-value { color: \(danger); }
        .studio-foot { color: \(textDim); \(t(.hint)) opacity: 0.85; font-variant-numeric: tabular-nums; }
        .studio-slot > button {
            padding: 0;
            border: none;
            background: none;
            background-image: none;
            box-shadow: none;
            min-width: 56px;
            min-height: 56px;
        }
        .studio-slot-art {
            border: 1px solid alpha(\(accent), 0.45);
            border-radius: 10px;
            background-color: alpha(\(text), 0.05);
        }
        .studio-slot-art.studio-slot-empty {
            border: 1px dashed alpha(\(text), 0.32);
            background-color: alpha(\(text), 0.03);
        }
        .studio-slot:hover .studio-slot-art { border-color: \(accent); }
        .studio-slot-plus { color: \(textDim); font-size: 160%; padding-top: 3px; }
        .studio-slot-caption {
            color: \(textDim);
            padding: 0 0 3px 0;
            font-size: 68%;
        }
        .studio-slot-caption-held {
            color: \(text);
            background-color: alpha(\(canvas), 0.72);
            border-radius: 0 0 9px 9px;
        }
        .studio-slot-remove {
            min-width: 16px;
            min-height: 16px;
            padding: 0;
            border-radius: 999px;
            color: \(text);
            background-color: alpha(\(canvas), 0.85);
            background-image: none;
            border: 1px solid \(rule);
            margin: -5px -5px 0 0;
            font-size: 80%;
            box-shadow: none;
        }
        .studio-slot-count {
            color: \(palette.onAccent);
            background-color: \(accent);
            border-radius: 999px;
            padding: 0 6px;
            margin: 3px;
            \(t(.badge))
        }
        .studio-rail { border-left: 1px solid \(rule); background: none; }
        .studio-strip { border-top: 1px solid \(rule); background: none; margin: 8px 12px 0 12px; }
        .draw-shelf-count, .draw-shelf-note { color: \(textDim); \(t(.hint)) }
        .draw-shelf-refresh { padding: 0 6px; min-height: 0; min-width: 0; color: \(textDim); }
        .studio-tile {
            padding: 0;
            border: none;
            background: none;
            background-image: none;
            box-shadow: none;
            border-radius: 10px;
            min-width: 0;
            min-height: 0;
            outline: 2px solid transparent;
            outline-offset: 0;
        }
        .studio-tile:hover { outline-color: alpha(\(accent), 0.45); }
        .studio-tile:focus-visible { outline: 2px solid alpha(\(accent), 0.70); outline-offset: 2px; }
        .studio-tile-on, .studio-tile-on:hover { outline: 2px solid \(accent); outline-offset: 0; }
        .studio-tile-art { border-radius: 10px; }
        .studio-tile-picture { border-radius: 10px; }
        .studio-tile-picture picture { border-radius: 10px; }
        .studio-tile-glyph { color: \(textDim); \(t(.panelTitle)) }
        .studio-tile-badge {
            color: \(text);
            background-color: alpha(\(canvas), 0.78);
            border-radius: 999px;
            padding: 1px 7px;
            font-variant-numeric: tabular-nums;
            \(t(.badge))
        }
        .studio-tile-sliver trough { min-height: 3px; background-color: alpha(\(text), 0.12); border: none; border-radius: 0; }
        .studio-tile-sliver progress { min-height: 3px; background-color: \(accent); border: none; border-radius: 0; }
        .studio-machine-missing .draw-facts { color: \(danger); }
        .video-notice {
            color: \(textDim);
            background-color: alpha(\(accent), 0.10);
            border: 1px solid alpha(\(accent), 0.30);
            border-radius: 10px;
            padding: 8px 12px;
            \(t(.note))
        }
        .watch-ask { background-color: \(canvas); }
        .watch-section-detail { color: \(textDim); \(t(.hint)) opacity: 0.6; }
        .watch-meta { color: \(textDim); \(t(.hint)) opacity: 0.75; }
        .watch-note { color: \(textDim); \(t(.note)) opacity: 0.7; }
        .watch-thumb {
            background-color: alpha(\(text), 0.06);
            border: 1px solid \(rule);
            border-radius: 4px;
        }
        """
    }
}
