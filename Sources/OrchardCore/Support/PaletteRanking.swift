import Foundation

/// Fuzzy ranking for jump palettes. Pure and side-effect free so it can be unit-tested
/// without standing up any UI. Salvaged from the v1 app's `JumpPalette`, generalized:
/// the caller supplies each item's searchable fields with their weights (v1 used
/// title 300 / branch 200 / repo 100), so the ranking is reusable for worktrees,
/// agents, files, and commands alike.
public enum PaletteRanking {
    /// Subsequence match (so "fxp" finds "fix-parser"), weighted by which field matched
    /// and bonused when the match starts at a word boundary. Empty query keeps the
    /// caller's order.
    public static func rank<Item>(
        query: String,
        items: [Item],
        fields: (Item) -> [(text: String, weight: Int)]
    ) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }

        return items.compactMap { item -> (Item, Int)? in
            var best: Int?
            for (text, weight) in fields(item) {
                guard let score = matchScore(query: q, in: text.lowercased()) else { continue }
                best = max(best ?? 0, weight + score)
            }
            guard let score = best else { return nil }
            return (item, score)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// `nil` when `query` isn't a subsequence of `text`. Otherwise a score that prefers
    /// matches which are contiguous and start early.
    public static func matchScore(query: String, in text: String) -> Int? {
        if query.isEmpty { return 0 }
        var score = 0
        var lastIndex: String.Index?
        var searchStart = text.startIndex

        for char in query {
            guard let found = text[searchStart...].firstIndex(of: char) else { return nil }
            // Contiguous with the previous match, or sitting on a word boundary.
            if let last = lastIndex, text.index(after: last) == found {
                score += 12
            } else if found == text.startIndex
                        || text[text.index(before: found)] == "-"
                        || text[text.index(before: found)] == "/"
                        || text[text.index(before: found)] == "_" {
                score += 8
            }
            lastIndex = found
            searchStart = text.index(after: found)
        }
        // Earlier overall matches beat later ones.
        let offset = text.distance(from: text.startIndex, to: lastIndex ?? text.startIndex)
        return score + max(0, 40 - offset)
    }
}
