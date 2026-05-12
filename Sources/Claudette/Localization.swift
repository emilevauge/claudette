import Foundation

/// Localized string lookup in Claudette's SPM bundle (`Bundle.module`).
/// Automatically picks the OS locale via `Locale.current` at startup.
@inline(__always)
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
