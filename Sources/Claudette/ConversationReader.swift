import Foundation

/// Reads a Claude Code session's JSONL transcript to extract the last
/// non-empty assistant message. File path:
/// `~/.claude/projects/<slug>/<sessionId>.jsonl`.
enum ConversationReader {

    /// Return the last text produced by Claude in this session.
    /// `nil` if the file is missing, unreadable, or contains no text block.
    static func lastAssistantText(for session: ClaudeSession) -> String? {
        let slug = projectSlug(for: session.cwd)
        let path = "\(NSHomeDirectory())/.claude/projects/\(slug)/\(session.sessionId).jsonl"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Iterate lines in reverse, return the first non-sidechain assistant
        // message that contains at least one non-empty text block.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let bytes = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else {
                continue
            }

            if let blocks = message["content"] as? [[String: Any]] {
                let texts = blocks.compactMap { b -> String? in
                    guard b["type"] as? String == "text",
                          let t = b["text"] as? String,
                          !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    return t
                }
                let joined = texts.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { return joined }
            } else if let str = message["content"] as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Project path encoding used by Claude Code: every non-alphanumeric
    /// character is replaced by '-' (two consecutive non-alnum characters
    /// yield '--').
    static func projectSlug(for path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        for scalar in path.unicodeScalars {
            let v = scalar.value
            let isAlnum =
                (0x30...0x39).contains(v) ||
                (0x41...0x5A).contains(v) ||
                (0x61...0x7A).contains(v)
            out.append(isAlnum ? Character(scalar) : "-")
        }
        return out
    }
}
