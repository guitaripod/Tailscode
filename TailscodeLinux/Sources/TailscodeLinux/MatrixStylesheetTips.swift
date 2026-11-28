import CGtkShim
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    /// The hover help (`Tip`): a small raised card in the theme's own ink that is invisible until
    /// `lit` is put on it and fades in over a hundred milliseconds, and fades out when `lit` is
    /// taken off — the popover stays mapped just long enough for the fade to be seen.
    func tipRules() -> String {
        return """
        popover.hover-tip {
            opacity: 0;
            transition: opacity \(TipTimings.fadeMilliseconds)ms ease-out;
        }
        popover.hover-tip.lit {
            opacity: 1;
        }
        popover.hover-tip > contents {
            background-color: \(canvasRaised);
            border: 1px solid \(rule);
            border-radius: 8px;
            padding: 5px 10px;
            box-shadow: 0 3px 12px alpha(black, 0.32);
        }
        popover.hover-tip label.hover-tip-text {
            \(t(.rowNote))
            color: \(text);
        }
        """
    }
}

/// The hover help's timings that the stylesheet needs: the fade is written into the sheet so the
/// shim's hide timer and the CSS transition cannot drift apart.
enum TipTimings {
    static var fadeMilliseconds: Int32 { Int32(tailscode_tip_fade_ms()) }
}
