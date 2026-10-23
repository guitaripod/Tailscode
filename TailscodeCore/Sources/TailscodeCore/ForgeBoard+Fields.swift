import Foundation

extension ForgeBoard {
    /// The list a setting opens, in the order it is offered, with the current value marked. Seed is
    /// not a list — the only honest row is a new one — so that menu is one action.
    public func choices(of field: ForgeField) -> [ForgeChoice] {
        switch field {
        case .size:
            return ForgeSize.options.map { size in
                ForgeChoice(
                    id: size.id, title: size.label, detail: size.name,
                    selected: recipe.size == size)
            }
        case .seconds:
            return Self.secondsOptions.map { seconds in
                ForgeChoice(
                    id: "\(seconds)", title: Localized.text("%@s", "\(seconds)"),
                    detail: Localized.text("%@ frames", "\(seconds * recipe.fps + 1)"),
                    selected: recipe.seconds == seconds)
            }
        case .fps:
            return ForgeRecipe.fpsOptions.map { fps in
                ForgeChoice(
                    id: "\(fps)", title: Localized.text("%@ fps", "\(fps)"),
                    detail: "", selected: recipe.fps == fps)
            }
        case .seed:
            return [
                ForgeChoice(
                    id: "reroll", title: Localized.text("New seed"),
                    detail: Localized.text("The same seed and prompt make the same clip"),
                    selected: false)
            ]
        case .endpoint, .prompt, .negative, .sound, .frame:
            return []
        }
    }

    /// What a setting currently says, in the words the row shows. One reader for all three clients
    /// so a Mac cannot spell a frame rate differently from a phone.
    public func value(of field: ForgeField) -> String {
        switch field {
        case .endpoint:
            guard let endpoint else { return Localized.text("Not set up yet") }
            return rendererName ?? endpoint.shortName
        case .prompt:
            let trimmed = recipe.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Localized.text("Describe the video") : trimmed
        case .negative:
            let trimmed = recipe.negative.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Localized.text("Nothing in particular") : trimmed
        case .sound:
            let trimmed = recipe.sound.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? ForgeWords.soundUnset : trimmed
        case .frame:
            return recipe.frame?.label ?? ForgeWords.frameUnset
        case .size:
            return recipe.size.label
        case .seconds:
            return Localized.text("%@s", "\(recipe.seconds)")
        case .fps:
            return Localized.text("%@ fps", "\(recipe.fps)")
        case .seed:
            return "\(recipe.seed)"
        }
    }
}
