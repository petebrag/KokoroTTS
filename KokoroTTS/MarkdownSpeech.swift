import AppKit
import SwiftUI

/// Markdown received from kokoro-speak, ready to show and to speak.
///
/// kokoro-speak (github.com/petebrag/Kokoro-Speak) puts "speech-ready Markdown" on the
/// Service pasteboard under `pasteboardType`, next to the plain speech string. It owns every
/// rule about what is read aloud: it drops the response header, turns bare URLs into
/// `[link](url)`, and puts a "Code block skipped." / "Table skipped." paragraph before each
/// code block and table. This file has no word rules. It only renders the Markdown and
/// decides which rendered ranges are never spoken: code blocks, tables, list markers, quote
/// bars and rules.
///
/// `speech` must equal kokoro-speak's `flatten_speech_markdown()` for the same input; a
/// parity test in the Kokoro-Speak repository compiles this file and compares the two.
struct MarkdownDocument {
  static let pasteboardType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

  enum Kind: Equatable {
    case heading(level: Int)
    case paragraph
    /// The first paragraph of a list item; it gets the item's marker.
    case listItem(marker: String)
    case code
    case table
    case rule
  }

  struct Block {
    var kind: Kind
    /// Parsed inline text (bold, italic, code, links), or plain text for code and tables.
    var text: AttributedString
    /// Nesting depth of lists around the block (0 = not in a list).
    var listDepth: Int
    var inQuote: Bool

    var isSpoken: Bool {
      switch kind {
      case .code, .table, .rule: return false
      default: return true
      }
    }

    var isListItem: Bool {
      if case .listItem = kind { return true }
      return false
    }
  }

  let blocks: [Block]
  /// The text handed to the speech engine. Every word in it appears, in order, in the
  /// rendered text outside the excluded ranges.
  let speech: String

  init?(markdown: String) {
    let options = AttributedString.MarkdownParsingOptions(
      allowsExtendedAttributes: false,
      interpretedSyntax: .full,
      failurePolicy: .returnPartiallyParsedIfPossible
    )
    guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return nil }
    let blocks = Self.blocks(from: parsed)
    guard !blocks.isEmpty else { return nil }
    self.blocks = blocks
    self.speech = Self.speech(from: blocks)
  }

  // MARK: - Blocks

  private static func blocks(from parsed: AttributedString) -> [Block] {
    var blocks: [Block] = []
    var lastBlockIdentity: Int?
    var seenListItems = Set<Int>()
    var tableRows: [[String]] = []
    var currentRow = -1
    var tableIdentity: Int?

    func flushTable() {
      guard tableIdentity != nil else { return }
      let text = tableRows.map { $0.joined(separator: " │ ") }.joined(separator: "\n")
      blocks.append(Block(kind: .table, text: AttributedString(text), listDepth: 0, inQuote: false))
      tableRows = []
      currentRow = -1
      tableIdentity = nil
    }

    for (intent, range) in parsed.runs[\.presentationIntent] {
      guard let intent, let leaf = intent.components.first else { continue }
      let components = intent.components
      let slice = AttributedString(parsed[range])

      // Tables arrive one cell at a time; collect them into one block.
      if let table = components.first(where: { if case .table = $0.kind { return true } else { return false } }) {
        if tableIdentity != table.identity {
          flushTable()
          tableIdentity = table.identity
        }
        let rowIdentity = components.first { component in
          switch component.kind {
          case .tableRow, .tableHeaderRow: return true
          default: return false
          }
        }?.identity ?? 0
        if rowIdentity != currentRow {
          tableRows.append([])
          currentRow = rowIdentity
        }
        tableRows[tableRows.count - 1].append(String(slice.characters))
        continue
      }
      flushTable()

      // Several runs (bold, links) can share one block: append to it.
      if leaf.identity == lastBlockIdentity, !blocks.isEmpty {
        blocks[blocks.count - 1].text.append(slice)
        continue
      }
      lastBlockIdentity = leaf.identity

      let listDepth = components.filter { component in
        switch component.kind {
        case .orderedList, .unorderedList: return true
        default: return false
        }
      }.count
      let inQuote = components.contains { if case .blockQuote = $0.kind { return true } else { return false } }

      let kind: Kind
      switch leaf.kind {
      case .header(let level):
        kind = .heading(level: level)
      case .codeBlock:
        kind = .code
      case .thematicBreak:
        kind = .rule
      default:
        // A paragraph directly inside a list item that has not been seen yet is the
        // item's first paragraph and carries its marker.
        if components.count > 1, case .listItem(let ordinal) = components[1].kind,
           seenListItems.insert(components[1].identity).inserted {
          let ordered = components.count > 2 && { if case .orderedList = components[2].kind { return true } else { return false } }()
          kind = .listItem(marker: ordered ? "\(ordinal)." : "•")
        } else {
          kind = .paragraph
        }
      }
      blocks.append(Block(kind: kind, text: slice, listDepth: listDepth, inQuote: inQuote))
    }
    flushTable()
    return blocks
  }

  // MARK: - Speech

  /// Spoken blocks, whitespace collapsed, one per line; a blank line between blocks
  /// except between consecutive list items. Matches kokoro-speak's flatten_speech_markdown().
  private static func speech(from blocks: [Block]) -> String {
    var result = ""
    var previous: Block?
    for block in blocks where block.isSpoken {
      let text = collapseWhitespace(String(block.text.characters))
      guard !text.isEmpty else { continue }
      if let previous {
        result += previous.isListItem && block.isListItem ? "\n" : "\n\n"
      }
      result += text
      previous = block
    }
    return result
  }

  static func collapseWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  // MARK: - Rendering

  /// Rendered text with explicit fonts, plus the ranges the highlighter must treat specially.
  struct Rendered {
    var text: AttributedString
    /// `String(text.characters)`, which token matching searches.
    var string: String
    /// Ranges in `string` that are never spoken, with the color each keeps.
    var excluded: [(range: Range<String.Index>, color: Color)]
    /// "Code block skipped." captions: spoken, but drawn small and dimmed.
    var captions: [Range<String.Index>]
  }

  /// Renders the document. `scale` is the text-size factor (1.0, 1.5, 2.0).
  func rendered(scale: CGFloat) -> Rendered {
    let base = NSFont.systemFontSize * scale
    let secondary = Color(nsColor: .secondaryLabelColor)
    let dimmed = Color(nsColor: .tertiaryLabelColor)

    var out = AttributedString()
    var length = 0
    var excludedOffsets: [(range: Range<Int>, color: Color)] = []
    var captionOffsets: [Range<Int>] = []

    func append(_ piece: AttributedString, excluded color: Color? = nil) {
      let count = piece.characters.count
      if let color { excludedOffsets.append((length..<(length + count), color)) }
      out.append(piece)
      length += count
    }

    func plain(_ text: String, size: CGFloat, monospaced: Bool = false) -> AttributedString {
      var piece = AttributedString(text)
      piece.font = .system(size: size, design: monospaced ? .monospaced : .default)
      return piece
    }

    var previous: Block?
    for (index, block) in blocks.enumerated() {
      if let previous {
        append(plain(previous.isListItem && block.isListItem ? "\n" : "\n\n", size: base))
      }
      previous = block

      let indent = String(repeating: "    ", count: max(block.listDepth - 1, 0))
      let next = index + 1 < blocks.count ? blocks[index + 1] : nil
      let isCaption = block.kind == .paragraph && (next?.kind == .code || next?.kind == .table)

      if block.inQuote {
        append(plain("▎ ", size: base), excluded: secondary)
      }

      switch block.kind {
      case .code, .table:
        var text = String(block.text.characters)
        while text.hasSuffix("\n") { text.removeLast() }
        append(plain(indent + text, size: base * 0.9, monospaced: true), excluded: dimmed)

      case .rule:
        append(plain("⸻", size: base), excluded: dimmed)

      case .heading(let level):
        let factor: CGFloat = level == 1 ? 1.6 : level == 2 ? 1.4 : level == 3 ? 1.2 : 1.0
        append(Self.styled(block.text, size: base * factor, bold: true))

      case .listItem(let marker):
        append(plain(indent + marker + " ", size: base), excluded: secondary)
        append(Self.styled(block.text, size: base))

      case .paragraph:
        if block.listDepth > 0 {
          // A later paragraph of a list item lines up under the item's text.
          append(plain(indent + "    ", size: base), excluded: secondary)
        }
        if isCaption {
          let start = length
          append(Self.styled(block.text, size: base * 0.85, italic: true))
          captionOffsets.append(start..<length)
        } else {
          append(Self.styled(block.text, size: base))
        }
      }
    }

    let string = String(out.characters)
    func indexRange(_ offsets: Range<Int>) -> Range<String.Index> {
      let lower = string.index(string.startIndex, offsetBy: offsets.lowerBound, limitedBy: string.endIndex) ?? string.endIndex
      let upper = string.index(lower, offsetBy: offsets.count, limitedBy: string.endIndex) ?? string.endIndex
      return lower..<upper
    }
    return Rendered(
      text: out,
      string: string,
      excluded: excludedOffsets.map { (indexRange($0.range), $0.color) },
      captions: captionOffsets.map(indexRange)
    )
  }

  /// Applies explicit fonts for bold, italic, inline code and strikethrough. SwiftUI Text
  /// does not style block-level presentation intents, so sizes are set here directly.
  private static func styled(_ text: AttributedString, size: CGFloat, bold: Bool = false, italic: Bool = false) -> AttributedString {
    var result = text
    for run in text.runs {
      let inline = run.inlinePresentationIntent ?? []
      let isCode = inline.contains(.code)
      var font = Font.system(
        size: isCode ? size * 0.9 : size,
        weight: bold || inline.contains(.stronglyEmphasized) ? .bold : .regular,
        design: isCode ? .monospaced : .default
      )
      if italic || inline.contains(.emphasized) { font = font.italic() }
      result[run.range].font = font
      if inline.contains(.strikethrough) { result[run.range].strikethroughStyle = .single }
      if run.link != nil { result[run.range].underlineStyle = .single }
    }
    return result
  }
}
