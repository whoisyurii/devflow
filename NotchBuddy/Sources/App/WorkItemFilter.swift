import Foundation

enum WorkItemFilter {
    static func matches(id: String, title: String, state: String, status: String, search: String) -> Bool {
        guard status.isEmpty || state == status else { return false }
        let words = search.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { word in
            if word.hasPrefix("#") { return id == word.dropFirst() }
            return id.contains(word) || title.localizedStandardContains(String(word))
        }
    }
}
