import CosmoRealtime
import Foundation

extension SessionNote {
    /// Render this note as shareable plain text: title, date, recap summary,
    /// key points, action items (with `[x]`/`[ ]` state), the captured notes,
    /// and the conversation transcript. Transcript turns are labeled with
    /// `userLabel:` / `assistantLabel:`; the app passes its own brand (e.g.
    /// "Cosmo") while the SDK defaults to neutral labels. Any section with no
    /// content is skipped.
    public func plainTextExport(
        assistantLabel: String = "Assistant",
        userLabel: String = "You"
    ) -> String {
        var parts: [String] = []
        parts.append(title ?? Self.dateText(startedAt))
        parts.append(Self.dateText(startedAt))

        if let recap {
            if !recap.summary.isEmpty {
                parts.append("")
                parts.append(recap.summary)
            }
            if !recap.keyPoints.isEmpty {
                parts.append("")
                parts.append("Key points:")
                parts.append(contentsOf: recap.keyPoints.map { "• \($0)" })
            }
            if !recap.actionItems.isEmpty {
                parts.append("")
                parts.append("Action items:")
                parts.append(contentsOf: recap.actionItems.map {
                    "\($0.done ? "[x]" : "[ ]") \($0.text)"
                })
            }
        }

        if !notes.isEmpty {
            parts.append("")
            parts.append("Notes:")
            parts.append(contentsOf: notes.map { "• \($0.text)" })
        }

        if !lines.isEmpty {
            parts.append("")
            parts.append("Conversation:")
            parts.append(contentsOf: lines.map {
                "\($0.role == .user ? userLabel : assistantLabel): \($0.text)"
            })
        }

        return parts.joined(separator: "\n")
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func dateText(_ date: Date) -> String {
        exportDateFormatter.string(from: date)
    }
}
