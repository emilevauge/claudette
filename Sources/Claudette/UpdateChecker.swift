import Foundation
import AppKit

/// Checks at startup whether a newer release is published on GitHub.
/// Public anonymous API (60 req/h limit per IP, more than enough for one
/// check at startup). When a newer version is found, fires a clickable
/// system notification that opens the release page in the browser.
@MainActor
enum UpdateChecker {

    private static let owner = "emilevauge"
    private static let repo = "claudette"

    /// Run the check in the background, silently ignore any network error.
    static func checkInBackground() {
        // Skip when not in a .app bundle (raw SPM binary: no reliable version).
        guard Bundle.main.bundleIdentifier != nil else { return }

        Task.detached(priority: .background) {
            await runCheck()
        }
    }

    private static func runCheck() async {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Claudette/\(currentVersion()) (macOS)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = obj["tag_name"] as? String else {
            return
        }

        let latest = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let current = currentVersion()
        guard isNewer(latest, than: current) else { return }

        // Don't re-notify for the same version on every launch.
        let key = "lastNotifiedUpdateVersion"
        if UserDefaults.standard.string(forKey: key) == latest { return }
        UserDefaults.standard.set(latest, forKey: key)

        let pageURL = (obj["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!

        await MainActor.run {
            SystemNotifications.shared.notifyUpdateAvailable(
                version: latest,
                url: pageURL
            )
        }
    }

    private static func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// Compare two semver-ish strings like "0.1.0".
    private static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
