import os

/// Where the window's time goes, named so it can be read rather than guessed.
///
/// Every interval here is a signpost, which costs next to nothing unless Instruments is recording —
/// the Points of Interest track then shows each chat opened, each state applied, each body opened
/// and each list redrawn against the frames around it. The one number worth keeping from the field
/// is written to the log as well: how long a click on a chat took to put its words on screen, as
/// `journey open`, which `log stream --predicate 'category == "performance"'` reads without a
/// debugger.
enum Pace {
    static let signposter = OSSignposter(
        subsystem: "com.guitaripod.tailscode", category: "performance")
    static let log = Logger(subsystem: "com.guitaripod.tailscode", category: "performance")
}
