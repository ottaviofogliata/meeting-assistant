import Foundation

public enum ScreenText {
    public static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"\b\d{1,2}:\d{2}(?::\d{2})?\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func changed(from old: String, to new: String) -> Bool {
        let old = normalized(old); let new = normalized(new)
        guard old != new else { return false }
        let delta = Set(old.split(separator: " ")).symmetricDifference(Set(new.split(separator: " ")))
        return delta.count >= 2 || (delta.count == 1 && (delta.first?.count ?? 0) >= 5)
    }
}
