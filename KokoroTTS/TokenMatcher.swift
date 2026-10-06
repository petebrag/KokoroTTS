import Foundation

/// Finds where each spoken token appears in the displayed text, for word highlighting.
///
/// Tokens come from preprocessed text (where parentheticals become dashes, etc.), so matching
/// uses whole-word search with Unicode normalization to handle mismatches. Matching is
/// sequential: each token is searched for after the previous match.
enum TokenMatcher {
  /// Normalizes Unicode quotation marks to ASCII equivalents so token text from the TTS engine
  /// can be matched against the original input even when it contains smart quotes.
  /// Preserves the character count so positions map one to one.
  static func normalizeQuotes(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{2018}", with: "'")
      .replacingOccurrences(of: "\u{2019}", with: "'")
      .replacingOccurrences(of: "\u{201C}", with: "\"")
      .replacingOccurrences(of: "\u{201D}", with: "\"")
  }

  /// Finds a non-word token in text, considering alternatives created by preprocessing.
  /// Preprocessing converts `(…)` → `- … -` and `word/word` → `word - word`, so a `-`
  /// token may correspond to `(`, `)`, or `/` in the original text. Returns the closest match.
  static func findNonWordToken(_ token: String, in text: String, from start: String.Index) -> Range<String.Index>? {
    let searchRange = start..<text.endIndex
    var best = text.range(of: token, range: searchRange)

    if token == "-" {
      for alt in ["(", ")", "/"] {
        if let altRange = text.range(of: alt, range: searchRange),
           best == nil || altRange.lowerBound < best!.lowerBound {
          best = altRange
        }
      }
    }

    return best
  }

  /// Finds the next whole-word occurrence of `word` in `text` starting from `start`.
  /// Prevents matching substrings inside longer words (e.g., "or" inside "for").
  static func findWholeWord(_ word: String, in text: String, from start: String.Index) -> Range<String.Index>? {
    var searchFrom = start
    while let range = text.range(of: word, range: searchFrom..<text.endIndex) {
      let beforeChar = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
      let afterChar = range.upperBound == text.endIndex ? nil : text[range.upperBound]
      let beforeOK = beforeChar == nil || !(beforeChar!.isLetter || beforeChar!.isNumber)
      let afterOK = afterChar == nil || !(afterChar!.isLetter || afterChar!.isNumber)
      if beforeOK && afterOK {
        return range
      }
      searchFrom = range.upperBound
      if searchFrom >= text.endIndex { break }
    }
    return nil
  }

  /// Returns, for each token, its range in `text`, or nil when it was skipped (space tokens)
  /// or not found (preprocessing artifacts). A match inside an `excluded` range (code blocks,
  /// tables, list markers) is ignored and the search continues after that range, so a common
  /// word inside a code block cannot pull the highlight forward. With no excluded ranges this
  /// is the original sequential matching.
  static func match(_ tokens: [String], in text: String, excluding excluded: [Range<String.Index>] = []) -> [Range<String.Index>?] {
    var results = [Range<String.Index>?](repeating: nil, count: tokens.count)

    // Normalize quotes for matching (smart quotes -> ASCII) since TTS may normalize them.
    // This preserves character count so we can maintain parallel indices.
    let searchText = normalizeQuotes(text)
    var normSearchStart = searchText.startIndex
    var origSearchStart = text.startIndex

    for (index, token) in tokens.enumerated() {
      // Skip space tokens added between chunks
      if token == " " { continue }

      let normalizedToken = normalizeQuotes(token)

      // Use whole-word matching for tokens containing letters/numbers (prevents "or" matching
      // inside "for"). For punctuation-only tokens (quotes, commas, etc.), use simple substring
      // matching since they naturally appear adjacent to letters.
      let tokenHasWordChars = normalizedToken.contains { $0.isLetter || $0.isNumber }

      var normFrom = normSearchStart
      var origFrom = origSearchStart
      var found: (norm: Range<String.Index>, orig: Range<String.Index>)?

      while found == nil {
        let range = tokenHasWordChars
          ? findWholeWord(normalizedToken, in: searchText, from: normFrom)
          : findNonWordToken(normalizedToken, in: searchText, from: normFrom)
        guard let range else { break }

        // Map the match position to the original text using parallel character offsets
        let skipCount = searchText.distance(from: normFrom, to: range.lowerBound)
        let tokenLength = searchText.distance(from: range.lowerBound, to: range.upperBound)
        let origMatchStart = text.index(origFrom, offsetBy: skipCount)
        let origMatchEnd = text.index(origMatchStart, offsetBy: tokenLength)
        let origRange = origMatchStart..<origMatchEnd

        if let blocked = excluded.first(where: { $0.overlaps(origRange) }) {
          // Not spoken there: search again after the excluded range.
          let jump = text.distance(from: origFrom, to: blocked.upperBound)
          origFrom = blocked.upperBound
          normFrom = searchText.index(normFrom, offsetBy: jump)
          continue
        }
        found = (range, origRange)
      }

      // Token not found - likely a preprocessing artifact (e.g., "-" from converted
      // parenthetical) or a Unicode mismatch. Skip it; the caller's gap-filling colors the
      // skipped area when the next spoken token is found.
      guard let found else { continue }

      results[index] = found.orig
      normSearchStart = found.norm.upperBound
      origSearchStart = found.orig.upperBound
    }

    return results
  }
}
