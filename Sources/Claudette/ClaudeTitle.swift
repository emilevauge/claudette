import Foundation

/// Decoding of the terminal title Claude Code publishes via OSC.
///
/// The title is `<glyph> <aiTitle>`, where the glyph encodes the session
/// phase. Both halves are load-bearing for us:
///   - the glyph is the freshest busy signal we have (Claude repaints it on
///     every spinner tick, while `~/.claude/sessions/<pid>.json` lags),
///   - the `aiTitle` is a unique per-session key, which is the only way to
///     tell apart two sessions running in the same directory.
///
/// Centralized here because four call sites used to inline their own copy of
/// the glyph ranges, and Claude Code changing spinner alphabet silently broke
/// all of them at once (see `isBusySpinner`).
enum ClaudeTitle {

    /// True for a spinner frame, i.e. the model is producing output.
    ///
    /// Two alphabets, both accepted: Claude Code used Braille frames
    /// (U+2800..U+28FF) up to ~2.0 and switched to circle-fill frames
    /// (◐◑◒◓, U+25D0..U+25D3) after that. Keeping both means we don't
    /// misreport a busy session as idle on either version.
    static func isBusySpinner(_ v: UInt32) -> Bool {
        (0x2800...0x28FF).contains(v) || (0x25D0...0x25D3).contains(v)
    }

    /// True for `✳` (U+2733): the turn is over, Claude waits for input.
    static func isIdleMark(_ v: UInt32) -> Bool { v == 0x2733 }

    /// True for any glyph Claude Code prefixes to the title. Used to tell a
    /// Claude terminal from a plain shell sitting in the same directory
    /// (whose title looks like `user@host:path`).
    static func isClaudeMark(_ v: UInt32) -> Bool {
        isBusySpinner(v) || isIdleMark(v)
    }

    /// True when this terminal title was written by Claude Code.
    static func isClaudeTerminal(title: String) -> Bool {
        guard let first = title.trimmingCharacters(in: .whitespaces).unicodeScalars.first else {
            return false
        }
        return isClaudeMark(first.value)
    }

    /// Strip the leading phase glyph and surrounding whitespace, leaving the
    /// bare `aiTitle`. Returns the trimmed title unchanged when there is no
    /// glyph to strip.
    static func stripGlyph(_ title: String) -> String {
        var s = Substring(title)
        if let first = s.unicodeScalars.first, isClaudeMark(first.value) {
            s = s.dropFirst()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a Ghostty terminal title designates the session owning
    /// `aiTitle`. Compared after stripping the glyph, with `hasPrefix` rather
    /// than equality so a future status suffix wouldn't break the match.
    static func matches(title: String, aiTitle: String) -> Bool {
        guard !aiTitle.isEmpty else { return false }
        let trimmed = stripGlyph(title)
        return trimmed == aiTitle || trimmed.hasPrefix(aiTitle)
    }
}
