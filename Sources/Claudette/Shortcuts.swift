import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Raccourci global pour afficher / masquer le popover Claudette.
    static let toggleClaudette = Self(
        "toggleClaudette",
        default: .init(.space, modifiers: [.control])
    )
}
