import CAdw
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    func panelRules() -> String {
        return """
        .watch-followed { color: \(special); \(t(.panelDetail)) }
        .watch-step { color: \(accent); \(t(.statusLine)) font-weight: 700; }
        .watch-code { color: \(accent); \(t(.pairingCode)) }
        .pill-source { color: \(info); border: 1px solid alpha(\(info), 0.5); }
        .lane-row {
            background-color: transparent;
            border: none;
            padding: 0;
        }
        .forge-pane { background-color: \(canvas); }
        .forge-call {
            \(t(.control))
            min-height: 36px;
            padding: 8px 18px;
            border: none;
            border-radius: 10px;
            color: \(palette.onAccent);
            background-color: \(accent);
            background-image: none;
            box-shadow: none;
            font-weight: 600;
        }
        .forge-call:hover { background-color: \(accentDim); }
        .forge-call-stop {
            color: \(palette.onAccent);
            background-color: \(danger);
        }
        .forge-call-stop:hover { background-color: alpha(\(danger), 0.85); }
        .forge-stage {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 14px;
            min-height: 280px;
            padding: 16px;
        }
        .forge-stage-glyph { color: \(textDim); \(t(.paneHeadline)) font-size: 280%; }
        .forge-stage-caption { color: \(textDim); \(t(.hint)) }
        .forge-affordance { color: \(textDim); \(t(.hint)) opacity: 0.7; }
        .forge-row-spent { opacity: 0.5; }
        .forge-prompt {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 12px;
        }
        .forge-prompt textview, .forge-prompt text {
            background: transparent;
            color: \(text);
            \(t(.composer))
        }
        .forge-renderer, .forge-model {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 10px;
        }
        .forge-renderer:hover, .forge-model:hover { background-color: alpha(\(accent), 0.10); }
        .forge-chip {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 10px;
            min-width: 72px;
        }
        .forge-chip:hover { background-color: alpha(\(accent), 0.10); }
        .forge-chip-on {
            border-color: \(accent);
            background-color: alpha(\(accent), 0.14);
        }
        .forge-chip-label { color: \(textDim); \(t(.sectionLabel)) }
        .forge-chip-value { color: \(text); \(t(.rowTitleStrong)) }
        .forge-chips { }
        .forge-film { background: transparent; }
        .forge-film-card {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 10px;
        }
        .forge-film-card:hover { background-color: alpha(\(accent), 0.10); }
        .forge-film-more { color: \(accent); \(t(.rowTitle)) }
        .forge-bar trough {
            min-height: 4px;
            background-color: \(rule);
            border: none;
            border-radius: 2px;
        }
        .forge-bar progress {
            min-height: 4px;
            background-color: \(accent);
            border: none;
            border-radius: 2px;
        }
        .forge-reason { \(t(.note)) padding: 0 2px; }
        .forge-sketch { border-radius: 10px; }
        .forge-enhance {
            color: \(text);
            border: 1px solid alpha(\(accent), 0.35);
            border-radius: 8px;
            padding: 4px 12px;
            \(t(.rowTitle))
        }
        .forge-enhance:hover { background-color: alpha(\(accent), 0.10); }
        .forge-working { color: \(textDim); }
        .forge-refusal { color: \(danger); }
        .pane-focused { border: 1px solid alpha(\(accent), 0.55); }
        .pane-identity {
            color: \(textDim);
            background-color: \(canvasRaised);
            border-bottom: 1px solid \(rule);
            \(t(.paneIdentity))
            padding: 2px \(inset)px;
        }
        .pane-focused .pane-identity { color: \(accent); }
        .drop-zone {
            background-color: alpha(\(accent), 0.16);
            border: 2px solid \(accent);
            border-radius: 4px;
        }
        .drop-caption { color: \(accent); \(t(.banner)) font-weight: 700; }
        .restore-banner {
            background-color: \(canvasRaised);
            border-bottom: 2px solid \(warn);
            padding: 6px 12px;
        }
        .restore-banner-text { color: \(text); \(t(.banner)) }
        .restore-banner button {
            \(t(.chip))
            min-height: 0;
            padding: 2px 10px;
            background-color: \(canvas);
            border: 1px solid \(rule);
            border-radius: 0;
            color: \(text);
        }
        .restore-banner button:hover { border-color: \(accent); }
        .restore-banner button.restore-primary { border-color: \(warn); color: \(warn); }
        .restore-banner button.restore-dismiss { border-color: transparent; color: \(textDim); }
        tile-canvas, .tile-shell { background-color: \(canvas); }
        .tile-face { background-color: \(canvas); border: 1px solid transparent; }
        .glance-tile.pane-focused, .parked-face.pane-focused {
            border-color: alpha(\(accent), 0.55);
        }
        .glance-header {
            background-color: \(canvasRaised);
            border-bottom: 1px solid \(rule);
            padding: 2px 10px;
            min-height: 24px;
        }
        .glance-title { color: \(text); \(t(.rowTitle)) }
        .glance-pin { color: \(accent); \(t(.chip)) }
        .glance-badge { color: \(textDim); \(t(.chip)) }
        .glance-tail { color: \(text); \(t(.rowDetail)) }
        .glance-tail.glance-waiting, .glance-foot.glance-waiting { color: \(warn); }
        .glance-footer { padding: 2px 10px 6px 10px; }
        .glance-foot { color: \(textDim); \(t(.chip)) }
        .glance-actions { opacity: 0; }
        .glance-tile:hover .glance-actions { opacity: 1; }
        .glance-action {
            min-height: 0;
            min-width: 0;
            padding: 0 5px;
            color: \(textDim);
            border-radius: 0;
        }
        .glance-action:hover { color: \(text); }
        .parked-detail { color: \(textDim); \(t(.rowDetail)) }
        .parked-tail { color: \(textDim); opacity: 0.7; \(t(.rowDetail)) }
        .parked-age { color: \(textDim); \(t(.chip)) }
        .parked-resume {
            \(t(.chip))
            min-height: 0;
            padding: 3px 14px;
            background-color: \(canvas);
            border: 1px solid \(rule);
            border-radius: 0;
            color: \(text);
        }
        .parked-resume:hover { border-color: \(accent); }
        tile-divider { color: \(rule); }
        tile-divider:hover, tile-divider:focus-visible, tile-divider.dragging { color: \(accent); }
        .tile-ghost { background-color: alpha(\(accent), 0.8); }
        .tile-strip { background-color: \(canvasRaised); border-top: 1px solid \(rule); }
        .tile-chip {
            \(t(.chip))
            min-height: 0;
            padding: 1px 8px;
            border: 1px solid \(rule);
            border-radius: 0;
            color: \(text);
        }
        .tile-chip:hover { border-color: \(accent); }
        .tile-chip-dot { color: \(warn); }
        .tile-strip-more { color: \(textDim); \(t(.chip)) }
        .live-chip { \(t(.chip)) }
        .find-hit {
            background-color: \(palette.findHit);
            box-shadow: inset 2px 0 0 \(warn);
        }
        .usage-footer { border-top: 1px solid alpha(currentColor, 0.15); }
        .glance-row { min-height: \(c(1.15)); }
        .glance-dot { font-size: \(c(0.5)); }
        .glance-label { color: \(text); \(t(.rowDetail)) }
        .glance-value { \(t(.gauge)) }
        .glance-notice { \(t(.gaugeCaption)) }
        .glance-ok { color: \(accent); }
        .glance-warn { color: \(warn); }
        .glance-danger { color: \(danger); }
        .glance-balance { color: \(text); }
        .glance-quiet { color: \(textDim); }
        .glance-row .glance-notice.glance-quiet { opacity: 0.85; }
        .update-footer { border-top: 1px solid alpha(currentColor, 0.15); }
        .update-footer:hover { background-color: alpha(currentColor, 0.04); }
        .gauge-ok, .gauge-warn, .gauge-danger { \(t(.gauge)) }
        .gauge-ok { color: \(textDim); }
        .gauge-warn { color: \(warn); }
        .gauge-danger { color: \(danger); }
        .gauge-reset { \(t(.gaugeCaption)) color: \(textDim); opacity: 0.8; margin-bottom: 2px; }
        .gauge-track {
            background-color: alpha(currentColor, 0.12);
            border-radius: 3px;
        }
        .gauge-fill-ok { background-color: \(accentDim); border-radius: 3px; }
        .gauge-fill-warn { background-color: \(warn); border-radius: 3px; }
        .gauge-fill-danger { background-color: \(danger); border-radius: 3px; }
        .brand-claude { color: \(palette.brandClaude); }
        .brand-opencode { color: \(palette.brandOpencode); }
        .brand-omp { color: \(brandOmp(in: palette)); }
        .brand-grok { color: \(palette.brandGrok); }
        .brand-deepseek { color: \(palette.brandDeepseek); }
        .brand-ollama-cloud { color: \(palette.brandOllama); }
        .gauge-fill-claude { background-color: \(palette.brandClaude); border-radius: 3px; }
        .gauge-fill-opencode { background-color: \(palette.brandOpencode); border-radius: 3px; }
        .gauge-fill-omp { background-color: \(brandOmp(in: palette)); border-radius: 3px; }
        .gauge-fill-grok { background-color: \(palette.brandGrok); border-radius: 3px; }
        .gauge-fill-deepseek { background-color: \(palette.brandDeepseek); border-radius: 3px; }
        .gauge-fill-ollama-cloud { background-color: \(palette.brandOllama); border-radius: 3px; }
        .usage-card {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 10px;
            padding: 12px 14px;
        }
        .usage-provider { color: \(text); \(t(.panelTitle)) }
        .usage-plan { color: \(textDim); \(t(.panelDetail)) }
        .usage-live {
            color: \(accent);
            \(t(.metricLabel))
            border: 1px solid alpha(\(accent), 0.4);
            border-radius: 99px;
            padding: 1px 8px;
        }
        .usage-stale {
            color: \(textDim);
            \(t(.metricLabel))
            border: 1px solid alpha(currentColor, 0.4);
            border-radius: 99px;
            padding: 1px 8px;
        }
        .usage-gauge-label { color: \(text); \(t(.panelLabel)) }
        .usage-board { padding: 0px 0px 4px 0px; }
        .usage-chip {
            \(t(.pill))
            padding: 2px 10px;
            min-height: 0px;
            border-radius: 99px;
            border: 1px solid alpha(currentColor, 0.35);
            background: none;
            color: \(textDim);
            opacity: 0.6;
        }
        .usage-chip:checked { opacity: 1; color: \(text); border-color: alpha(currentColor, 0.6); }
        .usage-chip.chip-claude:checked { color: \(palette.brandClaude); }
        .usage-chip.chip-opencode:checked { color: \(palette.brandOpencode); }
        .usage-chip.chip-grok:checked { color: \(palette.brandGrok); }
        .usage-chip.chip-deepseek:checked { color: \(palette.brandDeepseek); }
        .usage-chip.chip-ollama-cloud:checked { color: \(palette.brandOllama); }
        .usage-chip.usage-chip-offer { border-style: dashed; }
        .usage-arrangement { \(t(.control)) }
        .usage-lead { \(t(.panelDetail)) color: \(textDim); }
        .usage-move {
            \(t(.pill))
            padding: 0px 5px;
            min-height: 0px;
            min-width: 0px;
            background: none;
            border: none;
            color: \(textDim);
            opacity: 0.7;
        }
        .usage-move:hover { opacity: 1; color: \(text); }
        .usage-move:disabled { opacity: 0.2; }
        .usage-hero { border-color: alpha(\(accent), 0.35); }
        .usage-rule { background-color: \(rule); min-height: 1px; margin: 2px 0px; }
        .usage-detail-key { color: \(textDim); \(t(.panelDetail)) }
        .usage-detail-value { color: \(text); \(t(.metricDetail)) }
        .usage-source { color: \(textDim); \(t(.panelFootnote)) }
        .spend-total { color: \(text); \(t(.metricLarge)) }
        .spend-caption { color: \(textDim); \(t(.metricLabel)) }
        .spend-bar { background-color: \(accentDim); border-radius: 2px; }
        .context-headline { color: \(text); \(t(.metricLarge)) }
        .context-summary { color: \(textDim); \(t(.panelDetail)) }
        .context-advice { color: \(warn); \(t(.panelDetail)) }
        .context-advice-danger { color: \(danger); \(t(.panelDetail)) }
        .context-track { background-color: \(rule); border-radius: 4px; }
        .context-band-cacheRead { background-color: \(info); }
        .context-band-cacheWrite { background-color: alpha(\(info), 0.55); }
        .context-band-input { background-color: \(accent); }
        .context-band-output { background-color: \(warn); }
        .context-swatch { border-radius: 2px; }
        .gauge-news { color: \(textDim); \(t(.gaugeCaption)) margin-bottom: 2px; }
        .range-verdict { color: \(text); \(t(.metricLarge)) }
        .range-verdict-attention { color: \(warn); }
        .range-verdict-danger { color: \(danger); }
        .range-section { color: \(textDim); \(t(.metricLabel)) margin-top: 4px; }
        .range-slice-system { background-color: alpha(\(textDim), 0.55); }
        .range-slice-you { background-color: \(accent); }
        .range-slice-answers { background-color: \(info); }
        .range-slice-tools { background-color: \(special); }
        .range-slice-images { background-color: \(accentDim); }
        .range-slice-summary { background-color: \(rule); }
        .range-item { padding: 4px 6px; border-radius: 6px; background: none; border: none; box-shadow: none; }
        .range-item:hover { background-color: alpha(currentColor, 0.08); }
        .range-switch button { padding: 1px 10px; min-height: 0px; \(t(.pill)) }
        .range-bar-turn { background-color: \(accent); border-radius: 2px 2px 0px 0px; }
        .range-bar-refill { border-left: 1px dashed \(textDim); }
        .range-bar-projected {
            background-image: repeating-linear-gradient(45deg, \(warn) 0px, \(warn) 2px, transparent 2px, transparent 5px);
            border-radius: 2px 2px 0px 0px;
        }
        .range-danger-line { border-top: 1px dashed \(danger); min-height: 0px; }
        .range-cache-track { background-color: alpha(currentColor, 0.12); border-radius: 3px; }
        .range-cache-fill { background-color: \(info); border-radius: 3px; }
        .spend-bar-hot { background-color: \(accent); border-radius: 2px; }
        .git-added { color: \(accent); }
        .git-removed { color: \(danger); }
        .git-changed { color: \(info); }
        .git-untracked { color: \(textDim); }
        .git-conflict { color: \(warn); font-weight: 700; }
        .git-neutral { color: \(text); \(t(.pill)) }
        .git-neutral-ink { color: \(text); }
        .git-row { padding: 2px 4px; border-radius: 6px; }
        .git-row:hover { background-color: alpha(currentColor, 0.07); }
        .git-alert {
            color: \(warn);
            \(t(.control))
            border: 1px solid alpha(\(warn), 0.45);
            border-radius: 8px;
            padding: 4px 8px;
        }
        .git-diff { \(t(.diff)) }
        .analytics-total { color: \(text); \(t(.metricHero)) }
        .analytics-hero-percent { \(t(.metricLarge)) }
        .hero-ok { color: \(text); }
        .hero-warn { color: \(warn); }
        .hero-danger { color: \(danger); }
        .analytics-delta-up { color: \(warn); \(t(.metricDetail)) }
        .analytics-delta-down { color: \(accent); \(t(.metricDetail)) }
        .analytics-delta-flat { color: \(textDim); \(t(.metricDetail)) }
        .analytics-free { color: \(info); \(t(.metricDetail)) }
        .share-card-preview { border-radius: 14px; }
        .analytics-bar { background-color: \(accentDim); border-radius: 2px; }
        .analytics-bar-today { background-color: \(accent); border-radius: 2px; }
        .analytics-hour { background-color: alpha(\(info), 0.75); border-radius: 2px; }
        .record-card {
            background-color: alpha(currentColor, 0.04);
            border: 1px solid \(rule);
            border-radius: 8px;
            padding: 8px 10px;
        }
        .record-glyph { color: \(accent); font-size: \(c(1.2)); }
        .record-title { color: \(textDim); \(t(.metricLabel)) }
        .record-value { color: \(text); \(t(.metricValue)) }
        .record-detail { color: \(textDim); \(t(.metricDetail)) }
        .analytics-open {
            background-color: alpha(currentColor, 0.05);
            border: 1px solid \(rule);
            border-radius: 8px;
            color: \(text);
            \(t(.control))
            padding: 8px 12px;
        }
        .analytics-open:hover { background-color: alpha(\(accent), 0.12); }
        .usage-footer:hover { background-color: alpha(currentColor, 0.04); }
        .settings-group { padding: 6px 0px; }
        """
    }
}
