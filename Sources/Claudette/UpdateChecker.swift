import Foundation
import AppKit

/// Queries the GitHub releases API to detect newer versions of Claudette.
/// Public anonymous API (60 req/h limit per IP, more than enough). Two
/// entry points :
///   `checkInBackground()` : called at launch, fires a clickable system
///       notification when a newer release is found. Deduplicated via
///       UserDefaults so the same version is only signalled once.
///   `checkManually()` : called from the Settings panel, returns the
///       result synchronously and does not touch the dedup state.
@MainActor
enum UpdateChecker {

    private static let owner = "emilevauge"
    private static let repo = "claudette"

    /// Minimum delay between two successful background checks.
    private static let checkIntervalSeconds: TimeInterval = 24 * 60 * 60
    private static let lastCheckedAtKey = "lastUpdateCheckedAt"

    /// Hold the recurring timer alive across the app's lifetime.
    private static var periodicTimer: Timer?

    /// Outcome of a manual check, surfaced to the Settings UI.
    enum ManualResult {
        case upToDate(current: String)
        case newer(version: String, pageURL: URL, dmgURL: URL?)
        case error(String)
    }

    /// Version of the running bundle as displayed in Settings and used as
    /// the comparison base.
    static func currentVersionString() -> String { currentVersion() }

    /// Arm the launch,time check and a 24h recurring check, plus a re,check
    /// on wake from sleep (the Timer doesn't tick while macOS is asleep, so
    /// a long sleep would otherwise skip a day). All paths share the same
    /// `lastUpdateCheckedAt` cooldown so we never hammer the API on rapid
    /// restarts or back,to,back wake events.
    static func startPeriodicCheck() {
        // Skip when not in a .app bundle (raw SPM binary: no reliable version).
        guard Bundle.main.bundleIdentifier != nil else { return }

        triggerInBackground()

        periodicTimer?.invalidate()
        let timer = Timer(timeInterval: checkIntervalSeconds, repeats: true) { _ in
            triggerInBackground()
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            triggerInBackground()
        }
    }

    /// `nonisolated` so the Timer and NSWorkspace wake observer (which run
    /// on the main thread but in nonisolated closures) can call it directly.
    /// The body only spawns a detached task that hops to main via `await`.
    nonisolated private static func triggerInBackground() {
        Task.detached(priority: .background) {
            await maybeRunBackgroundCheck()
        }
    }

    /// Honour the 24h cooldown to avoid hammering GitHub on rapid restarts
    /// or back,to,back wake events.
    private static func maybeRunBackgroundCheck() async {
        let now = Date()
        if let last = UserDefaults.standard.object(forKey: lastCheckedAtKey) as? Date,
           now.timeIntervalSince(last) < checkIntervalSeconds {
            return
        }
        UserDefaults.standard.set(now, forKey: lastCheckedAtKey)
        await runBackgroundCheck()
    }

    /// Synchronous,style check for the Settings panel. Always returns a
    /// result, including network errors. Does not update the dedup
    /// UserDefault: repeated clicks always hit the network.
    static func checkManually() async -> ManualResult {
        let current = currentVersion()
        guard let release = await fetchLatest() else {
            return .error("Could not reach github.com")
        }
        if isNewer(release.version, than: current) {
            return .newer(version: release.version,
                          pageURL: release.pageURL,
                          dmgURL: release.dmgURL)
        }
        return .upToDate(current: current)
    }

    // MARK: private

    /// Internal representation of a parsed GitHub release.
    private struct Release {
        let version: String
        let pageURL: URL
        let dmgURL: URL?
    }

    /// Hit the GitHub API and parse the bits we care about. Returns `nil`
    /// on any network or parsing failure.
    private static func fetchLatest() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return nil
        }
        var req = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Claudette/\(currentVersion()) (macOS)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = obj["tag_name"] as? String else {
            return nil
        }

        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        let pageURL = (obj["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!

        // Pull the Claudette.dmg asset URL when present, so the "Update"
        // path can drive a self,replace. Releases without a DMG fall back
        // to opening the release page.
        let dmgURL = (obj["assets"] as? [[String: Any]])?.first(where: {
            ($0["name"] as? String) == "Claudette.dmg"
        }).flatMap { $0["browser_download_url"] as? String }
        .flatMap(URL.init(string:))

        return Release(version: version, pageURL: pageURL, dmgURL: dmgURL)
    }

    private static func runBackgroundCheck() async {
        guard let release = await fetchLatest() else { return }
        let current = currentVersion()
        guard isNewer(release.version, than: current) else { return }

        // Don't re-notify for the same version on every launch.
        let key = "lastNotifiedUpdateVersion"
        if UserDefaults.standard.string(forKey: key) == release.version { return }
        UserDefaults.standard.set(release.version, forKey: key)

        await MainActor.run {
            SystemNotifications.shared.notifyUpdateAvailable(
                version: release.version,
                pageURL: release.pageURL,
                dmgURL: release.dmgURL
            )
        }
    }

    private static func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// Compare two semver,ish strings like "0.1.0".
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
