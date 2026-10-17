import Foundation

extension NeuralBrainModel {
    /// Tells the browse state where the keyboard actually is. A client whose focus moved by a
    /// click or Tab, not by a key the reducer saw, says so here, so the next key is read by the
    /// part of the brain that has it.
    public mutating func setBrowseFocus(_ focus: NeuralBrowse.Focus) {
        guard browseState.focus != focus else { return }
        browseState.focus = focus
    }

    /// Where the browse state believes the keyboard is.
    public var browseFocus: NeuralBrowse.Focus { browseState.focus }

    /// Opens or closes the search field in the browse state without changing the query, for a
    /// field a click opened.
    public mutating func setBrowseSearchOpen(_ open: Bool) {
        guard browseState.searchOpen != open else { return }
        browseState.searchOpen = open
    }

    /// The legend popover was dismissed by something other than a key.
    public mutating func setBrowseLegend(_ shown: Bool) {
        guard browseState.legend != shown else { return }
        browseState.legend = shown
    }

    /// The readout's long output was folded or unfolded by a click rather than by Space.
    public mutating func setBrowseOutputExpanded(_ expanded: Bool) {
        guard browseState.outputExpanded != expanded else { return }
        browseState.outputExpanded = expanded
    }
}
