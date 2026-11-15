import SwiftUI

/// The block-level Markdown that agents write: headings, lists, tables, quotes, code and rules.
/// Text inside blocks goes through AttributedString's inline Markdown.
enum Block {
    case heading(Int, String)
    case paragraph(String)
    case list([ListItem])
    case code(String)
    case table(header: [String], rows: [[String]])
    case quote(String)
    case rule
}

struct ListItem {
    let depth: Int
    let marker: String
    var text: String
}

func tableCells(_ line: String) -> [String] {
    var s = line.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("|") { s.removeFirst() }
    if s.hasSuffix("|") { s.removeLast() }
    return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}

func isTableSeparator(_ line: String) -> Bool {
    let cells = tableCells(line)
    return !cells.isEmpty && cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }
}

/// "- item", "* item", "1. item" with its indent; nil for other lines
func listItem(_ line: String) -> ListItem? {
    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
    let rest = line.dropFirst(indent)
    if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
        return ListItem(depth: indent / 2, marker: "•", text: String(rest.dropFirst(2)))
    }
    let digits = rest.prefix { $0.isNumber }
    let after = rest.dropFirst(digits.count)
    if !digits.isEmpty, digits.count < 4, let dot = after.first, ".)".contains(dot), after.dropFirst().first == " " {
        return ListItem(depth: indent / 2, marker: "\(digits).", text: String(after.dropFirst(2)))
    }
    return nil
}

func parseBlocks(_ source: String) -> [Block] {
    let lines = source.components(separatedBy: "\n")
    var blocks: [Block] = []
    var paragraph: [String] = []
    var i = 0

    func flush() {
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
        paragraph = []
    }

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") {
            flush()
            var code: [String] = []
            i += 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                code.append(lines[i])
                i += 1
            }
            blocks.append(.code(code.joined(separator: "\n")))
            i += 1
            continue
        }
        if trimmed.isEmpty {
            flush()
            i += 1
            continue
        }
        if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
            flush()
            let header = tableCells(line)
            var rows: [[String]] = []
            i += 2
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                rows.append(tableCells(lines[i]))
                i += 1
            }
            blocks.append(.table(header: header, rows: rows))
            continue
        }
        if let hashes = Optional(trimmed.prefix { $0 == "#" }.count), (1...6).contains(hashes),
           trimmed.dropFirst(hashes).first == " " {
            flush()
            blocks.append(.heading(hashes, String(trimmed.dropFirst(hashes + 1))))
            i += 1
            continue
        }
        if ["---", "***", "___"].contains(trimmed) {
            flush()
            blocks.append(.rule)
            i += 1
            continue
        }
        if trimmed.hasPrefix(">") {
            flush()
            var quote: [String] = []
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
            }
            blocks.append(.quote(quote.joined(separator: "\n")))
            continue
        }
        if listItem(line) != nil {
            flush()
            var items: [ListItem] = []
            while i < lines.count {
                if let item = listItem(lines[i]) {
                    items.append(item)
                } else if !items.isEmpty, lines[i].hasPrefix("  "), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    // An indented line continues the item above it
                    items[items.count - 1].text += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                } else {
                    break
                }
                i += 1
            }
            blocks.append(.list(items))
            continue
        }
        paragraph.append(line)
        i += 1
    }
    flush()
    return blocks
}

func inline(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

struct MarkdownText: View {
    let source: String
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.75) {
            ForEach(Array(parseBlocks(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(.system(size: fontSize))
        .lineSpacing(fontSize * 0.25)
    }

    @ViewBuilder func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: fontSize * [1.45, 1.25, 1.1, 1.0, 1.0, 1.0][level - 1], weight: .bold))
                .padding(.top, fontSize * 0.3)
        case .paragraph(let text):
            Text(inline(text))
        case .list(let items):
            VStack(alignment: .leading, spacing: fontSize * 0.3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: fontSize, alignment: .trailing)
                        Text(inline(item.text))
                    }
                    .padding(.leading, Double(item.depth) * fontSize * 1.4)
                }
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .lineSpacing(fontSize * 0.15)
                    .fixedSize()
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(inline(cell)).fontWeight(.semibold)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                        }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .quote(let text):
            Text(inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(.tertiary).frame(width: 3)
                }
        case .rule:
            Divider()
        }
    }
}
