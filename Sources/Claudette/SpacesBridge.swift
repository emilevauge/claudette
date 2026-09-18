import Foundation
import AppKit
import ApplicationServices

/// Which macOS Space (what the UI calls a desktop) a window sits on.
///
/// macOS ships no public API for this. `CGWindowListCopyWindowInfo` with
/// `.optionOnScreenOnly` can only answer "current space or not", and the
/// Spaces layout itself (how many, in which order, on which screen) is
/// nowhere in the public frameworks. The window,manager crowd (yabai,
/// Amethyst, …) reads it from the private SkyLight framework instead, which
/// is what this does.
///
/// Everything is resolved through `dlsym`, never linked: a renamed or
/// withdrawn symbol on a future macOS turns every call here into `nil`, and
/// the UI falls back to a flat, ungrouped session list. Nothing else in
/// Claudette depends on it.
enum SpacesBridge {

    /// One Space, as the UI labels it.
    struct Desktop: Hashable {
        /// WindowServer id of the space (`ManagedSpaceID`).
        let spaceID: Int
        /// Position in the global ordering: screens in WindowServer order,
        /// spaces in Mission Control order within each screen. Sort key for
        /// the grouped list.
        let order: Int
        /// 1,based desktop number on its screen, `nil` for a full,screen
        /// space (macOS numbers only the regular ones).
        let number: Int?
        /// Ready,to,render section title.
        let label: String
    }

    /// Snapshot of the Spaces layout at one instant.
    struct Layout {
        /// Space id → desktop.
        let desktops: [Int: Desktop]
        /// Space id of the frontmost space on each screen.
        let activeSpaceIDs: Set<Int>
    }

    // MARK: public API

    /// Current Spaces layout, or `nil` when unavailable.
    static func layout() -> Layout? {
        guard let conn = connection(), let copy = copyManagedDisplaySpaces,
              let displays = copy(conn) as? [[String: Any]] else { return nil }

        var desktops: [Int: Desktop] = [:]
        var active: Set<Int> = []
        var order = 0
        let multiScreen = displays.count > 1

        for (screenIndex, display) in displays.enumerated() {
            if let current = display["Current Space"] as? [String: Any],
               let id = current["ManagedSpaceID"] as? Int {
                active.insert(id)
            }

            var number = 0
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = space["ManagedSpaceID"] as? Int else { continue }
                // `type` 0 is a regular desktop; anything else is a
                // full-screen (or tiled) app space, which Mission Control
                // leaves out of the "Desktop N" numbering.
                let isFullScreen = (space["type"] as? Int ?? 0) != 0
                if !isFullScreen { number += 1 }

                let base = isFullScreen ? L("Full screen") : L("Desktop \(number)")
                let label = multiScreen ? "\(L("Screen \(screenIndex + 1)")) · \(base)" : base

                desktops[id] = Desktop(
                    spaceID: id,
                    order: order,
                    number: isFullScreen ? nil : number,
                    label: label
                )
                order += 1
            }
        }

        guard !desktops.isEmpty else { return nil }
        return Layout(desktops: desktops, activeSpaceIDs: active)
    }

    /// Space hosting each window, keyed by window id. Windows absent from the
    /// result are on no space we could read (minimized, or the call failed).
    ///
    /// A window set to appear on *every* space reports several; we keep the
    /// active one so it groups where the user is actually looking.
    static func spaceIDs(forWindows ids: [CGWindowID], activeSpaceIDs: Set<Int>) -> [CGWindowID: Int] {
        guard let conn = connection(), let copy = copySpacesForWindows else { return [:] }

        var result: [CGWindowID: Int] = [:]
        for id in ids where id != 0 {
            let arg = [NSNumber(value: id)] as CFArray
            // Mask 0x7 (`kCGSAllSpacesMask`): ask about every space, not just
            // the current one, otherwise a window on another desktop answers
            // with an empty list.
            guard let spaces = copy(conn, 0x7, arg) as? [Int], !spaces.isEmpty else { continue }
            result[id] = spaces.first(where: { activeSpaceIDs.contains($0) }) ?? spaces[0]
        }
        return result
    }

    /// `CGWindowID` behind an accessibility window element.
    ///
    /// The public AX API deliberately hides it, and the documented way round
    /// (matching `CGWindowListCopyWindowInfo` titles) needs the Screen
    /// Recording permission to read `kCGWindowName` at all. `_AXUIElement,
    /// GetWindow` rides the Accessibility grant Claudette already asks for.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow = axGetWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    // MARK: private symbols

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> CFArray?
    private typealias GetWindowFn =
        @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let skyLight: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static let applicationServices: UnsafeMutableRawPointer? =
        dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)

    private static let mainConnectionID: MainConnectionIDFn? =
        symbol("CGSMainConnectionID", in: skyLight)
    private static let copySpacesForWindows: CopySpacesForWindowsFn? =
        symbol("CGSCopySpacesForWindows", in: skyLight)
    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? =
        symbol("CGSCopyManagedDisplaySpaces", in: skyLight)
    private static let axGetWindow: GetWindowFn? =
        symbol("_AXUIElementGetWindow", in: applicationServices)

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// WindowServer connection for this process. Cheap, but not free, so we
    /// keep the one handed out on first use: it is stable for the lifetime of
    /// the process.
    private static var cachedConnection: Int32?

    private static func connection() -> Int32? {
        if let cachedConnection { return cachedConnection }
        guard let fn = mainConnectionID else { return nil }
        let conn = fn()
        guard conn != 0 else { return nil }
        cachedConnection = conn
        return conn
    }
}

/// User preference: group the session list by desktop.
///
/// On by default, but the grouping only shows up once sessions actually sit
/// on two different desktops, so a single,desktop user never sees a change.
enum DesktopGrouping {
    static let defaultsKey = "groupSessionsByDesktop"

    static var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: defaultsKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
