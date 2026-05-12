# Claudette

A macOS menu bar app that lists every running Claude Code session and lets you jump to its Ghostty window in one click.

<p align="center">
  <img src="docs/screenshot.png" width="480" alt="Claudette popover showing live Claude Code sessions"/>
</p>

## Features

- **Live session list** : reads `~/.claude/sessions/*.json` every 2 s and keeps only sessions whose PID is still alive (`kill(pid, 0)`).
- **True activity state** : the busy/idle dot is derived from the Ghostty window title (Braille spinner = thinking, `✳` = waiting) so it stays accurate even when the JSON `status` field is stale.
- **Per-session metrics** : working directory, total session duration, time since last activity.
- **Instant search** : start typing as soon as the popover opens, multi-token filter on name, path and basename. `↑↓` to navigate, `↵` to focus, `esc` to clear/close.
- **One-click focus** : matches the right Ghostty terminal by `working directory` + title containing the session name + Braille/`✳` heuristic to skip neighbouring shells, then issues the Ghostty `focus terminal <id>` AppleScript so the right window, tab and split come to the front.
- **Native notifications** : when a session transitions from thinking to waiting, macOS shows a notification with title, path and preview of the last assistant message. Click it to focus the corresponding Ghostty window.
- **Global keyboard shortcut** : configurable via a `KeyboardShortcuts` recorder in the settings pane. Default `⌃Space`.
- **Launch at login** : optional, implemented via a user `LaunchAgent` so it works on a raw SPM binary (no `.app` bundle required for that feature).
- **Localised** : English, French, Spanish, auto-selected from the OS locale.

## Requirements

- macOS 14 (Sonoma) or later, tested on macOS 26 (Sequoia).
- [Ghostty](https://ghostty.org/) for the click-to-focus integration.
- Swift 5.9+ (Xcode Command Line Tools).

## Build

```sh
git clone https://github.com/emilevauge/claudette.git
cd claudette

# Dev binary (fast iteration, no bundle ID so notifs use the AppleScript fallback)
swift build
.build/debug/Claudette

# Proper .app bundle (recommended : enables native UNUserNotificationCenter)
./make-app.sh

# Or install to /Applications
./make-app.sh --install
open /Applications/Claudette.app
```

The `make-app.sh` script:

1. Builds `release`.
2. Renders the SwiftUI app icon (terminal glyph on sand/brown gradient) at 1024×1024 via `Claudette --generate-icon`, then `sips` for all required sizes, then `iconutil` to produce `AppIcon.icns`.
3. Assembles `Claudette.app/Contents/{MacOS,Resources,Info.plist}` with `CFBundleIdentifier`, `LSUIElement=true`, `NSAppleEventsUsageDescription`, and `CFBundleIconFile`.
4. Ad-hoc signs the bundle.
5. Registers it with LaunchServices so notifications work.

## Permissions

On first launch Claudette will ask for:

- **Automation → Ghostty** : required to enumerate terminals and focus the right window. Triggered automatically on the first AppleScript call.
- **Notifications** : tap *Allow* on the system prompt for banner notifications when a session goes from thinking to waiting.

If you accidentally refuse one of them, reset and relaunch:

```sh
tccutil reset AppleEvents dev.claudette.app
tccutil reset Notifications dev.claudette.app
open /Applications/Claudette.app
```

## How it works

```
~/.claude/sessions/<pid>.json   ──┐
                                  ├─►  SessionStore (2 s polling)
Ghostty AppleScript dictionary  ──┘         │
        (working directory of terminals)    │
                                            ▼
                              ClaudeSession  (PID alive, isBusy from Ghostty title)
                                            │
                            ┌───────────────┴───────────────┐
                            ▼                               ▼
                  MenuView (SwiftUI list,            SystemNotifications
                  search, click → focus)             (UNUserNotificationCenter
                            │                         + AppleScript fallback)
                            ▼
                  GhosttyBridge.focus(session)
                  └─► focus terminal <id>  (window + tab + split)
```

Key files :

- `Sources/Claudette/SessionStore.swift` : polling + Ghostty annotation.
- `Sources/Claudette/GhosttyBridge.swift` : AppleScript ↔ Ghostty.
- `Sources/Claudette/MenuView.swift` : popover UI.
- `Sources/Claudette/AppDelegate.swift` : `NSStatusItem` + `NSPopover` + global shortcut.
- `Sources/Claudette/SystemNotifications.swift` : native notifications.
- `Sources/Claudette/ConversationReader.swift` : last assistant text from `~/.claude/projects/<slug>/<sessionId>.jsonl`.
- `Sources/Claudette/LaunchAgent.swift` : login item.
- `make-app.sh` : `.app` packaging.

## License

MIT (see `LICENSE`).
