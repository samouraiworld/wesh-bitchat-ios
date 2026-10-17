//
// MessageTextHelpers.swift
// Shared text parsing helpers for message rendering.
//

import Foundation

extension String {
    // Detect if there is an extremely long token (no whitespace/newlines) that could break layout
    func hasVeryLongToken(threshold: Int) -> Bool {
        var current = 0
        for ch in self {
            if ch.isWhitespace || ch.isNewline {
                if current >= threshold { return true }
                current = 0
            } else {
                current += 1
                if current >= threshold { return true }
            }
        }
        return current >= threshold
    }

    /// True when the message should collapse behind Show more in the UI.
    /// Length alone decides this — embedding a Cashu-looking token must not
    /// disable the guard (remote DoS via unbounded layout).
    func isLongForDisplay(
        lengthThreshold: Int = TransportConfig.uiLongMessageLengthThreshold,
        tokenThreshold: Int = TransportConfig.uiVeryLongTokenThreshold
    ) -> Bool {
        count > lengthThreshold || hasVeryLongToken(threshold: tokenThreshold)
    }

    /// True when rich formatting (regex / link detectors) should be skipped.
    /// Cashu presence used to exempt oversized content from the plain path;
    /// that let untrusted input force expensive formatting work.
    func isOversizedForRichFormatting(
        lengthThreshold: Int = 4000,
        tokenThreshold: Int = 1024
    ) -> Bool {
        count > lengthThreshold || hasVeryLongToken(threshold: tokenThreshold)
    }

    // Extract up to `max` distinct Cashu tokens (cashuA/cashuB), as the bare
    // bearer strings. Allow dot '.' and shorter lengths. The `cashu:` URI
    // form matches too — the token embedded after the scheme is the match.
    func extractCashuLinks(max: Int = 3) -> [String] {
        let regex = MessageFormattingEngine.Patterns.cashu
        let ns = self as NSString
        let range = NSRange(location: 0, length: ns.length)
        var found: [String] = []
        for m in regex.matches(in: self, range: range) where m.numberOfRanges > 0 {
            let token = ns.substring(with: m.range(at: 0))
            // Dedup: repeated tokens are one bearer instrument (and duplicate
            // ForEach IDs) — one chip is enough.
            if !found.contains(token) {
                found.append(token)
                if found.count >= max { break }
            }
        }
        return found
    }
}
