import CAdw
import Foundation

/// The two libraries this app is written against, and what it does when the machine has an older
/// pair than it can run on.
///
/// The floor is not a preference — it is the oldest release that has every function the client
/// calls unconditionally: GTK 4.12 for `gtk_css_provider_load_from_string` and
/// `gtk_button_set_can_shrink`, libadwaita 1.4 for `AdwToolbarView`, `AdwSwitchRow` and
/// `AdwSpinRow`. On a machine below either one the dynamic loader is the only thing that ever says
/// so, and what it says is an undefined-symbol dump naming a C function, which tells a person
/// nothing they can act on. This says which library is too old, what the machine has, and what it
/// needs — the same three facts every other version surface in this app is required to carry.
///
/// It is a courtesy rather than a guarantee: a distribution that links with `-z now` resolves every
/// symbol before the first line of this program runs, and there the loader still wins. Where lazy
/// binding is in force — the common case — this fires first.
enum ToolkitFloor {
    static let gtk = (major: 4, minor: 12)
    static let adwaita = (major: 1, minor: 4)

    static func enforce() {
        guard let complaint = complaint() else { return }
        FileHandle.standardError.write(Data((complaint + "\n").utf8))
        exit(1)
    }

    static func complaint() -> String? {
        let gtkFound = (Int(gtk_get_major_version()), Int(gtk_get_minor_version()))
        if !meets(gtkFound, floor: gtk) {
            return line(
                library: "GTK", found: gtkFound, floor: gtk,
                packages: "gtk4 (Arch) · libgtk-4-1 (Debian, Ubuntu)")
        }
        let adwFound = (Int(adw_get_major_version()), Int(adw_get_minor_version()))
        if !meets(adwFound, floor: adwaita) {
            return line(
                library: "libadwaita", found: adwFound, floor: adwaita,
                packages: "libadwaita (Arch) · libadwaita-1-0 (Debian, Ubuntu)")
        }
        return nil
    }

    private static func meets(_ found: (Int, Int), floor: (major: Int, minor: Int)) -> Bool {
        found.0 > floor.major || (found.0 == floor.major && found.1 >= floor.minor)
    }

    private static func line(
        library: String, found: (Int, Int), floor: (major: Int, minor: Int), packages: String
    ) -> String {
        """
        tailscode needs \(library) \(floor.major).\(floor.minor) or newer, and this machine has \
        \(found.0).\(found.1).
        Update \(packages), or install the Flatpak, which carries its own copy:
          flatpak install flathub \(Packaging.flatpakID)
        """
    }
}
