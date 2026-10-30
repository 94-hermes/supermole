import Foundation

/// Turns a line of terminal output into plain text for the window.
///
/// `NO_COLOR` removes colors, but spinners still redraw a line with `\r` and
/// some tools print cursor codes regardless.
public enum TerminalText {
    /// CSI sequences (`ESC [ ... letter`) and two-byte escapes (`ESC x`).
    private static let escapePattern = try! NSRegularExpression(pattern: "\u{1B}(\\[[0-9;?]*[ -/]*[@-~]|[@-Z\\\\-_])")

    public static func clean(_ line: String) -> String {
        // A spinner rewrites the line; what the reader sees is the last write.
        let visible = line.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let range = NSRange(visible.startIndex..., in: visible)
        return escapePattern.stringByReplacingMatches(in: visible, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
