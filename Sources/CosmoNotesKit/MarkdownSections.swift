import Foundation

/// Pure Markdown text rules for note documents — section replacement and the
/// daily-note header/append composition. No IO; callers own reading and
/// writing the note. The exact byte-level behavior is pinned by the shared
/// vector file `contract/notes-markdown-vectors.json` so every platform's
/// notes implementation produces identical files.
public enum MarkdownSections {
    public enum SectionError: Error, Equatable, Sendable {
        case multilineSectionName
    }

    /// Replace the `## section` block (up to the next `## `-prefixed line or
    /// EOF — a deeper `###` heading does not terminate it) with `body`;
    /// append the section if it isn't present yet. Headings match `section`
    /// by whitespace-trimmed exact equality, and every matching heading is
    /// replaced. Throws ``SectionError/multilineSectionName`` when `section`
    /// contains any Unicode newline character.
    public static func replaceSection(in content: String, section: String, body: String) throws -> String {
        guard section.rangeOfCharacter(from: .newlines) == nil else {
            throw SectionError.multilineSectionName
        }
        let heading = "## \(section)"
        let lines = content.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        var replaced = false
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == heading {
                out.append(heading)
                out.append(body)
                i += 1
                while i < lines.count, !lines[i].hasPrefix("## ") { i += 1 }
                replaced = true
                continue
            }
            out.append(lines[i])
            i += 1
        }
        if !replaced {
            if !content.hasSuffix("\n") { out.append("") }
            out.append(heading)
            out.append(body)
        }
        return out.joined(separator: "\n")
    }

    /// Append `text` as its own block: empty `content` seeds a fresh note as
    /// `"<header>\n\n<text>\n"`; otherwise the result is `content` +
    /// `"\n<text>\n"` and `header` is unused.
    public static func appendBlock(to content: String, text: String, header: String) -> String {
        content.isEmpty ? "\(header)\n\n\(text)\n" : content + "\n\(text)\n"
    }

    /// The H1 title line of a daily note (no trailing newline).
    public static func dailyHeader(stamp: String) -> String {
        "# \(stamp)"
    }

    /// True when `s` is a real calendar date in `YYYY-MM-DD` form.
    public static func isValidStamp(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              s.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "-" }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return false }
        return DateComponents(year: year, month: month, day: day)
            .isValidDate(in: Calendar(identifier: .gregorian))
    }

    /// `date` as a `YYYY-MM-DD` stamp in `timeZone` (Gregorian).
    public static func dateStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
