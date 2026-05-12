import Foundation

/// Lookup localisé dans le bundle SPM de Claudette (`Bundle.module`).
/// Sélectionne automatiquement la locale OS via `Locale.current` au démarrage.
@inline(__always)
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
