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
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .symbolEffect(.pulse, options: .repeating, isActive: shouldPulse)
            .frame(width: 22, height: 22)
            .accessibilityLabel("Claudette")
    }

    private var symbol: String {
        phase == .empty ? "terminal" : "terminal.fill"
    }

    /// `.primary` adapts to dark/light menu bar automatically. The
    /// `needsAttention` red is fixed so it stays alarming on both modes.
    private var tint: Color {
        switch phase {
        case .needsAttention: return Color(red: 0.92, green: 0.26, blue: 0.21)
        case .empty, .idle, .busy: return .primary
        }
    }

    private var shouldPulse: Bool {
        phase == .busy || phase == .needsAttention
    }
}
