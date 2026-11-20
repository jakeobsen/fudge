import Foundation

/// A fuzzy match: the query's characters appear in order in the candidate.
public struct FuzzyMatch: Sendable, Equatable {
    public var score: Int
    /// Offsets (in Characters) of the matched characters, for highlighting.
    public var positions: [Int]
}

public enum Fuzzy {
    /// Matches `query` against `candidate`, ignoring case and diacritics.
    ///
    /// Scoring favours matches at word starts ("vsc" in "Visual Studio Code"),
    /// runs of consecutive characters, and a candidate that starts with the query.
    /// An empty query matches everything with score 0.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let needle = Array(fold(query).filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, positions: []) }
        let original = Array(candidate)
        let haystack = original.map { Character(fold(String($0))) }
        guard needle.count <= haystack.count else { return nil }

        // Prefer the alignment that hits word starts: try each word start as the
        // anchor for the first character and keep the best-scoring alignment.
        var best: FuzzyMatch?
        for start in haystack.indices where haystack[start] == needle[0] {
            guard let positions = align(needle, in: haystack, from: start) else { break }
            let score = self.score(positions, in: original, queryLength: needle.count)
            if best == nil || score > best!.score { best = FuzzyMatch(score: score, positions: positions) }
        }
        return best
    }

    private static func align(_ needle: [Character], in haystack: [Character], from start: Int) -> [Int]? {
        var positions: [Int] = [start]
        var index = start + 1
        for character in needle.dropFirst() {
            // Jump to the next word start that matches if there is one, else the next match.
            var next: Int?
            var fallback: Int?
            var probe = index
            while probe < haystack.count {
                if haystack[probe] == character {
                    if fallback == nil { fallback = probe }
                    if probe == index || isWordStart(probe, in: haystack) {
                        next = probe
                        break
                    }
                }
                probe += 1
            }
            guard let found = next ?? fallback else { return nil }
            positions.append(found)
            index = found + 1
        }
        return positions
    }

    private static func score(_ positions: [Int], in candidate: [Character], queryLength: Int) -> Int {
        var score = 0
        var previous: Int?
        for position in positions {
            score += 10
            if isWordStart(position, in: candidate) { score += 15 }
            if let previous {
                if position == previous + 1 { score += 8 } else { score -= min(position - previous - 1, 10) }
            } else {
                score -= min(position, 10)
            }
            previous = position
        }
        if positions.first == 0, positions == Array(0..<queryLength) { score += 25 }
        score -= max(0, candidate.count - queryLength) / 8
        return score
    }

    private static func isWordStart(_ index: Int, in text: [Character]) -> Bool {
        guard index > 0 else { return true }
        let before = text[index - 1]
        let current = text[index]
        if before == " " || before == "-" || before == "_" || before == "." || before == "/" { return true }
        return before.isLowercase && current.isUppercase
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
