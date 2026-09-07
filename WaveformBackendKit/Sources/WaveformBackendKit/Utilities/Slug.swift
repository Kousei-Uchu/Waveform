import Foundation

enum Slug {
    /// Turns arbitrary text into a safe folder-name component: alphanumerics
    /// and whitespace only, spaces collapsed to underscores, capped length.
    static func make(_ input: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_"))

        let filteredScalars = input.unicodeScalars.filter { allowed.contains($0) }
        let filtered = String(String.UnicodeScalarView(filteredScalars))
        let trimmed = filtered.trimmingCharacters(in: .whitespaces)
        let collapsed = trimmed.replacingOccurrences(
            of: "\\s+", with: "_", options: .regularExpression
        )
        let truncated = String(collapsed.prefix(80))
        return truncated.isEmpty ? "untitled" : truncated
    }
}
