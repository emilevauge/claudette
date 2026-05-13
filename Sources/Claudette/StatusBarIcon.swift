import SwiftUI

/// SwiftUI image shown inside the `NSStatusItem` button. Lives in an
/// `NSHostingView` (see `AppDelegate.setupStatusItem`) so it can apply
/// `.symbolEffect(.pulse)`, which would not be available on a plain
/// `NSImage` set on `button.image`.
struct StatusBarIcon: View {

    enum Phase: Equatable {
        /// No live Claude session at all.
        case empty
        /// At least one session has been seen but every one of them is idle.
        case idle
        /// At least one session is actively thinking (Braille spinner).
        case busy
        /// At least one session is blocked waiting on the user (permission
        /// prompt or `AskUserQuestion`). Takes priority over `.busy` in the
        /// global aggregation: if anything needs attention, show it.
        case needsAttention

        static func compute(from sessions: [ClaudeSession]) -> Phase {
            if sessions.isEmpty { return .empty }
            if sessions.contains(where: { $0.phase == .needsAttention }) {
                return .needsAttention
            }
            if sessions.contains(where: { $0.phase == .busy }) {
                return .busy
            }
            return .idle
        }
    }

    let phase: Phase

    var body: some View {
        icon
            .frame(width: 22, height: 22)
            .accessibilityLabel("Claudette")
    }

    @ViewBuilder
    private var icon: some View {
        let base = Image(systemName: symbol)
            .font(.system(size: 14, weight: phase == .needsAttention ? .bold : .semibold))
            .foregroundStyle(phase == .needsAttention ? Color.red : .primary)
            .symbolEffect(.pulse, options: .repeating, isActive: shouldPulse)

        if phase == .needsAttention {
            // Soft white halo around the red glyph: stacked low,radius
            // shadows reinforce each other into a thin glow that reads as
            // an outline against any menu bar wallpaper.
            base
                .shadow(color: .white, radius: 0.8)
                .shadow(color: .white, radius: 0.8)
        } else {
            base
        }
    }

    private var symbol: String {
        phase == .empty ? "terminal" : "terminal.fill"
    }

    private var shouldPulse: Bool {
        phase == .busy || phase == .needsAttention
    }
}
