#if os(macOS)
import TailscodeCore

struct Screen {
    let name: String
    let width: Double
    let height: Double
    let safe: WallInsets
    let fold: WallFold?
}

enum Screens {
    static let all: [Screen] = [
        Screen(name: "ipad-landscape", width: 1376, height: 1032, safe: WallInsets(bottom: 20), fold: nil),
        Screen(name: "ipad-portrait", width: 1032, height: 1376, safe: WallInsets(bottom: 20), fold: nil),
        Screen(name: "duo-wide", width: 951, height: 669, safe: WallInsets(trailing: 84), fold: nil),
        Screen(
            name: "duo-book", width: 951, height: 669, safe: .zero,
            fold: WallFold(axis: .vertical, from: 455.5, to: 495.5)),
        Screen(
            name: "duo-laptop", width: 669, height: 951, safe: .zero,
            fold: WallFold(axis: .horizontal, from: 455.5, to: 495.5)),
        Screen(
            name: "duo-closed", width: 466, height: 678,
            safe: WallInsets(top: 82, bottom: 34, trailing: 84), fold: nil),
        Screen(name: "duo-tent", width: 678, height: 466, safe: WallInsets(bottom: 21, trailing: 84), fold: nil),
        Screen(name: "display", width: 1920, height: 1080, safe: .zero, fold: nil),
    ]
}
#endif
