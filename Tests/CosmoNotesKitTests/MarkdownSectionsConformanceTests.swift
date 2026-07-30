import Foundation
import Testing
@testable import CosmoNotesKit

/// Executes the shared Markdown note-text vectors
/// (``sdks/cosmo-realtime/contract/notes-markdown-vectors.json``) against
/// ``MarkdownSections``. The macOS notes tools are expected to consume the
/// same file, so both platforms pin one byte-level format.
@Suite struct MarkdownSectionsConformanceTests {
    private struct VectorFile: Decodable {
        struct Case: Decodable {
            let name: String
            let op: String
            let inputs: Inputs
            let expected: Expected?
            let expectedError: String?
        }
        struct Inputs: Decodable {
            let content: String?
            let section: String?
            let body: String?
            let text: String?
            let stamp: String?
        }
        enum Expected: Decodable, Equatable {
            case text(String)
            case valid(Bool)
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let flag = try? container.decode(Bool.self) {
                    self = .valid(flag)
                } else {
                    self = .text(try container.decode(String.self))
                }
            }
        }
        let cases: [Case]
    }

    private func loadCases() throws -> [VectorFile.Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CosmoNotesKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift/
            .deletingLastPathComponent()  // cosmo-realtime/
            .appendingPathComponent("contract/notes-markdown-vectors.json", isDirectory: false)
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url)).cases
    }

    @Test func markdownRulesConformToSharedVectors() throws {
        let cases = try loadCases()
        #expect(!cases.isEmpty)
        for vector in cases {
            switch vector.op {
            case "replaceSection":
                let content = try #require(vector.inputs.content, "case \(vector.name): missing content")
                let section = try #require(vector.inputs.section, "case \(vector.name): missing section")
                let body = try #require(vector.inputs.body, "case \(vector.name): missing body")
                if let expectedError = vector.expectedError {
                    #expect(expectedError == "multilineSectionName", "case \(vector.name): unknown expectedError")
                    #expect(throws: MarkdownSections.SectionError.multilineSectionName, "case \(vector.name)") {
                        _ = try MarkdownSections.replaceSection(in: content, section: section, body: body)
                    }
                } else {
                    let got = try MarkdownSections.replaceSection(in: content, section: section, body: body)
                    #expect(.text(got) == vector.expected, "case \(vector.name)")
                }
            case "append":
                let got = MarkdownSections.appendBlock(
                    to: try #require(vector.inputs.content, "case \(vector.name): missing content"),
                    text: try #require(vector.inputs.text, "case \(vector.name): missing text"),
                    header: ""
                )
                #expect(.text(got) == vector.expected, "case \(vector.name)")
            case "seed":
                let stamp = try #require(vector.inputs.stamp, "case \(vector.name): missing stamp")
                let got = MarkdownSections.appendBlock(
                    to: "",
                    text: try #require(vector.inputs.text, "case \(vector.name): missing text"),
                    header: MarkdownSections.dailyHeader(stamp: stamp)
                )
                #expect(.text(got) == vector.expected, "case \(vector.name)")
            case "validStamp":
                let stamp = try #require(vector.inputs.stamp, "case \(vector.name): missing stamp")
                #expect(.valid(MarkdownSections.isValidStamp(stamp)) == vector.expected, "case \(vector.name)")
            default:
                Issue.record("unknown op \(vector.op) in case \(vector.name)")
            }
        }
    }

    @Test func replaceSectionRejectsMultilineSectionName() {
        #expect(throws: MarkdownSections.SectionError.multilineSectionName) {
            _ = try MarkdownSections.replaceSection(
                in: "## A\nx\n", section: "A\n## Injected", body: "b")
        }
        #expect(throws: MarkdownSections.SectionError.multilineSectionName) {
            _ = try MarkdownSections.replaceSection(
                in: "## A\nx\n", section: "A\r", body: "b")
        }
        #expect(throws: MarkdownSections.SectionError.multilineSectionName) {
            _ = try MarkdownSections.replaceSection(
                in: "## A\nx\n", section: "A\u{2028}B", body: "b")
        }
        #expect(throws: MarkdownSections.SectionError.multilineSectionName) {
            _ = try MarkdownSections.replaceSection(
                in: "## A\nx\n", section: "A\u{0085}B", body: "b")
        }
    }

    @Test func dateStampFormatsGregorianInGivenTimeZone() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-01-05T23:30:00Z"))
        #expect(MarkdownSections.dateStamp(date, timeZone: utc) == "2026-01-05")
    }

    @Test func dateStampStraddlesMidnightAcrossTimeZones() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-01-05T23:30:00Z"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        let auckland = try #require(TimeZone(identifier: "Pacific/Auckland"))
        #expect(MarkdownSections.dateStamp(instant, timeZone: utc) == "2026-01-05")
        #expect(MarkdownSections.dateStamp(instant, timeZone: auckland) == "2026-01-06")
    }
}
