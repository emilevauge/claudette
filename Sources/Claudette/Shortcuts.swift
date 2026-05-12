import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global shortcut to show / hide the Claudette popover.
    static let toggleClaudette = Self(
        "toggleClaudette",
        default: .init(.space, modifiers: [.control])
    )
}
